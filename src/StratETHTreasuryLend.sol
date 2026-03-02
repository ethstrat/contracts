// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

/**
 * @title StratETHTreasuryLend
 * @notice Borrow ETH-liquidity using STRAT + CDT collateral via a term loan represented by an ERC721.
 *
 * Key mechanics (per user stories):
 * - Positions are transferable NFTs; the NFT owner controls repay/roll.
 * - Interest accrues linearly over time using a fixed per-position rate snapshot.
 * - Positions are unliquidatable until expiry; after expiry anyone can liquidate (permissionless cleanup).
 * - Borrow capacity is derived from STRAT backing value (via esETH balances in holdings addresses) and a maxLTV
 * parameter.
 * - Borrow amount is net of the maximum term interest (reserved) and a configurable fee (also reserved).
 */
contract StratETHTreasuryLend is Ownable2Step, ERC721 {
    // ======== Types ========
    struct Position {
        uint256 stratCollateral;
        uint256 cdtCollateral;
        uint256 principal; // amount borrowed (esETH) sent to borrower
        uint256 maxTermInterest; // full-term interest amount for this position (principal * rate * duration / 365d)
        uint256 rate; // scaled by 1e18
        uint256 delinquentFee; // diliquent fee if loan isn't repaid by expiry
        uint256 startTime;
        uint256 expiry;
    }

    // ======== Immutable config ========
    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    IERC20 public immutable esETHToken;
    address public immutable unencumberedHoldings;
    address public immutable encumberedHoldings;

    // ======== Global parameters ========
    uint256 public constant SCALE = 1e18;
    uint256 public constant YEAR = 365 days;

    /// @notice % fee payable if a borrower fails to repay their loan
    uint256 public delinquentFeeRate;

    /// @notice Term length for new borrows/rolls (seconds).
    uint256 public loanDuration;

    /// @notice Borrow APR for new borrows/rolls (scaled by 1e18).
    uint256 public borrowRate;

    /// @notice Address that receives interest revenue (e.g. a staking rewards pool).
    address public interestRevenueRecipient;

    /// @notice Delegated roles for parameter updates (owner-managed).
    address public rateSetter;
    address public feeSetter;

    // ======== State ========
    uint256 public nextTokenId;
    mapping(uint256 tokenId => Position) internal _positions;

    // ======== Events ========
    event RateSetterUpdated(address indexed oldSetter, address indexed newSetter);
    event FeeSetterUpdated(address indexed oldSetter, address indexed newSetter);
    event MaxLTVUpdated(uint256 oldVal, uint256 newVal);
    event LoanDurationUpdated(uint256 oldVal, uint256 newVal);
    event BorrowRateUpdated(uint256 oldVal, uint256 newVal);
    event DebtPerStratUpdated(uint256 oldVal, uint256 newVal);
    event DelinquentFeeUpdated(uint256 oldVal, uint256 newVal);
    event InterestRevenueRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    event Borrowed(
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 stratCollateral,
        uint256 cdtCollateral,
        uint256 coveredStrat,
        uint256 principal,
        uint256 maxTermInterest,
        uint256 rate,
        uint256 delinquentFee,
        uint256 startTime,
        uint256 expiry
    );

    event Repaid(
        address indexed payer, uint256 indexed tokenId, uint256 principalRepaid, uint256 interestPaid, uint256 timestamp
    );

    event Rolled(
        address indexed payer,
        uint256 indexed tokenId,
        uint256 newStratCollateral,
        uint256 newCdtCollateral,
        uint256 newPrincipal,
        uint256 newMaxTermInterest,
        uint256 newRate,
        uint256 newFee,
        uint256 timestamp,
        uint256 newExpiry
    );

    event Liquidated(uint256 indexed tokenId, address indexed previousOwner, uint256 timestamp);

    // ======== Errors ========
    error ZeroAddress();
    error ZeroAmount();
    error TransactionStale(uint256 deadline);
    error InsufficientOutput(uint256 minBorrowAmount, uint256 borrowAmount);
    error NotPositionOwner(address caller, uint256 tokenId);
    error LoanExpired(uint256 tokenId);
    error LoanUnexpired(uint256 tokenId);
    error StratSupplyIsZero();
    error TransferFailed();
    error UnauthorizedRateSetter(address caller);
    error UnauthorizedFeeSetter(address caller);

    /**
     * @param _cdtToken     The CDT token (mintable/burnable)
     * @param _stratToken   The STRAT token (mintable/burnable)
     * @param _esETHToken   The esETH token used for payouts/repayments
     * @param _unencumberedHoldings Address holding unencumbered esETH (source of all loan payouts)
     * @param _encumberedHoldings Address holding encumbered esETH (included in total backing for STRAT valuation)
     * @param _borrowRate   Initial borrow APR for new positions (scaled by 1e18)
     * @param owner         Contract owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _esETHToken,
        address _unencumberedHoldings,
        address _encumberedHoldings,
        uint256 _borrowRate,
        address owner
    ) Ownable(owner) ERC721("STRAT Treasury Lend", "tlSTRAT") {
        if (
            _cdtToken == address(0) || _stratToken == address(0) || _esETHToken == address(0)
                || _unencumberedHoldings == address(0) || _encumberedHoldings == address(0)
        ) {
            revert ZeroAddress();
        }

        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        esETHToken = IERC20(_esETHToken);
        unencumberedHoldings = _unencumberedHoldings;
        encumberedHoldings = _encumberedHoldings;

        // Defaults
        loanDuration = 180 days;
        borrowRate = _borrowRate;

        // Delegated roles initialized to owner.
        rateSetter = owner;
        feeSetter = owner;

        // Revenue recipient defaults to owner (governance can later point to a staking rewards pool).
        interestRevenueRecipient = owner;
    }

    // ======== Owner-managed role delegation (US-000) ========
    function setRateSetter(address newSetter) external onlyOwner {
        if (newSetter == address(0)) revert ZeroAddress();
        address old = rateSetter;
        rateSetter = newSetter;
        emit RateSetterUpdated(old, newSetter);
    }

    function setFeeSetter(address newSetter) external onlyOwner {
        if (newSetter == address(0)) revert ZeroAddress();
        address old = feeSetter;
        feeSetter = newSetter;
        emit FeeSetterUpdated(old, newSetter);
    }

    function setLoanDuration(uint256 newLoanDuration) external onlyOwner {
        uint256 old = loanDuration;
        loanDuration = newLoanDuration;
        emit LoanDurationUpdated(old, newLoanDuration);
    }

    // ======== Delegated parameter setters (US-500/US-501) ========
    function setBorrowRate(uint256 newBorrowRate) external {
        if (msg.sender != rateSetter) revert UnauthorizedRateSetter(msg.sender);
        uint256 old = borrowRate;
        borrowRate = newBorrowRate;
        emit BorrowRateUpdated(old, newBorrowRate);
    }

    function setDelinquentFeeRate(uint256 newFee) external {
        if (msg.sender != feeSetter) revert UnauthorizedFeeSetter(msg.sender);
        uint256 old = delinquentFeeRate;
        delinquentFeeRate = newFee;
        emit DelinquentFeeUpdated(old, newFee);
    }

    function setInterestRevenueRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = interestRevenueRecipient;
        interestRevenueRecipient = newRecipient;
        emit InterestRevenueRecipientUpdated(old, newRecipient);
    }

    // ======== Views ========
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return _positions[tokenId];
    }

    /// @notice Preview borrow outcome using *current* global parameters (US-101).
    function previewBorrow(uint256 maxStratIn, uint256 maxCdtIn)
        public
        view
        returns (uint256 stratIn, uint256 cdtIn, uint256 ethBacking, uint256 borrowAmount, uint256 maxTermInterest, uint256 delinquentFee)
    {
        cdtIn = maxStratIn * cdtToken.totalSupply() / stratToken.totalSupply();
        if (cdtIn > maxCdtIn) {
            cdtIn = maxCdtIn;
            stratIn = cdtIn * stratToken.totalSupply() / cdtToken.totalSupply();
        } else {
            stratIn = maxStratIn;
        }
        ethBacking = (_totalHoldingsInETH() * stratIn) / stratToken.totalSupply();

        delinquentFee = (ethBacking * delinquentFeeRate) / SCALE;

        uint256 termFactor = (borrowRate * loanDuration) / YEAR; // scaled by 1e18
        uint256 denom = SCALE + termFactor;
        borrowAmount = ((ethBacking - delinquentFee) * SCALE) / denom;
        maxTermInterest = (borrowAmount * termFactor) / SCALE;
    }

    function accruedInterest(uint256 tokenId) public view returns (uint256) {
        Position memory p = _positions[tokenId];
        if (p.principal == 0) return 0;

        if (block.timestamp <= p.startTime) return 0;
        if (block.timestamp >= p.expiry) return p.maxTermInterest;

        uint256 elapsed = block.timestamp - p.startTime;
        uint256 interest = (p.maxTermInterest * elapsed) / (p.expiry - p.startTime);
        return interest;
    }

    // ======== Core flows ========
    /// @notice Borrow by supplying up to `stratIn` and `cdtIn` as collateral. Only the covered portion is pulled
    /// (US-100).
    function borrow(uint256 maxStratIn, uint256 maxCdtIn, uint256 minBorrowAmount, uint256 deadline) external {
        if (deadline < block.timestamp) revert TransactionStale(deadline);
        if (maxStratIn == 0 && maxCdtIn == 0) revert ZeroAmount();
        (uint256 stratIn
        , uint256 cdtIn
        , uint256 ethBacking
        , uint256 borrowAmount
        , uint256 maxTermInterest
        , uint256 delinquentFee) = previewBorrow(maxStratIn, maxCdtIn);

        if (borrowAmount < minBorrowAmount) revert InsufficientOutput(minBorrowAmount, borrowAmount);

        // Pull collateral (burn) only for the covered portion.
        stratToken.burnFrom(msg.sender, stratIn);
        cdtToken.burnFrom(msg.sender, cdtIn);

        uint256 tokenId = nextTokenId++;
        uint256 startTime = block.timestamp;
        uint256 expiry = startTime + loanDuration;

        _positions[tokenId] = Position({
            stratCollateral: stratIn,
            cdtCollateral: cdtIn,
            principal: borrowAmount,
            maxTermInterest: maxTermInterest,
            rate: borrowRate,
            delinquentFee: delinquentFee,
            startTime: startTime,
            expiry: expiry
        });

        // Mint position NFT (US-010).
        _mint(msg.sender, tokenId);

        // Pull full backing (principal + reserved interest + delinquent fee) from unencumbered into this contract.
        esETHToken.transferFrom(unencumberedHoldings, address(this), ethBacking);
        // Send only the principal to the borrower; the remainder stays reserved in this contract.
        esETHToken.transfer(msg.sender, borrowAmount);

        emit Borrowed(
            msg.sender,
            tokenId,
            stratIn,
            cdtIn,
            ethBacking,
            borrowAmount,
            maxTermInterest,
            borrowRate,
            delinquentFee,
            startTime,
            expiry
        );
    }

    /// @notice Repay before expiry (US-201). Pays accrued interest to `interestRevenueRecipient`.
    function repay(uint256 tokenId) external {
        address posOwner = ownerOf(tokenId);
        if (msg.sender != posOwner) revert NotPositionOwner(msg.sender, tokenId);

        Position memory p = _positions[tokenId];
        if (block.timestamp >= p.expiry) revert LoanExpired(tokenId);

        uint256 interest = accruedInterest(tokenId);
        esETHToken.transferFrom(msg.sender, address(this), p.principal + interest);

        // Return full backing (principal + reserved interest + delinquent fee) to unencumbered holdings.
        esETHToken.transfer(unencumberedHoldings, p.principal + p.maxTermInterest + p.delinquentFee);

        // Route interest to interest revenue recipient.
        if (interest > 0) {
            esETHToken.transfer(interestRevenueRecipient, interest);
        }

        // Close: burn NFT and restore collateral (mint back).
        _burn(tokenId);
        stratToken.mint(posOwner, p.stratCollateral);
        cdtToken.mint(posOwner, p.cdtCollateral);
        delete _positions[tokenId];

        emit Repaid(msg.sender, tokenId, p.principal, interest, block.timestamp);
    }

    /// @notice Roll a position: settle interest to date, adjust collateral and principal, reset term (US-300/301/302).
    function roll(uint256 tokenId, uint256 maxNewStratIn, uint256 maxNewCdtIn, uint256 minNewBorrowAmount, uint256 deadline) external {
        if (deadline < block.timestamp) revert TransactionStale(deadline);
        if (maxNewStratIn == 0 && maxNewCdtIn == 0) revert ZeroAmount();

        address posOwner = ownerOf(tokenId);
        if (msg.sender != posOwner) revert NotPositionOwner(msg.sender, tokenId);

        Position memory p = _positions[tokenId];
        if (block.timestamp >= p.expiry) revert LoanExpired(tokenId);

        uint256 interest = accruedInterest(tokenId);

        (uint256 newStratIn
        , uint256 newCdtIn
        , uint256 newEthBacking
        , uint256 newBorrowAmount
        , uint256 newMaxTermInterest
        , uint256 newDiliquentFee) = previewBorrow(maxNewStratIn, maxNewCdtIn);
        if (newBorrowAmount < minNewBorrowAmount) revert InsufficientOutput(minNewBorrowAmount, newBorrowAmount);

        uint256 oldStratIn = p.stratCollateral;
        uint256 oldCdtIn = p.cdtCollateral;
        uint256 oldEthBacking = p.principal + p.maxTermInterest + p.delinquentFee;
        uint256 oldBorrowAmount = p.principal;

        if ((oldBorrowAmount + interest) > newBorrowAmount) {
            esETHToken.transferFrom(msg.sender, address(this), oldBorrowAmount + interest - newBorrowAmount);
            esETHToken.transfer(unencumberedHoldings, oldEthBacking - newEthBacking);
        } else {
            esETHToken.transferFrom(unencumberedHoldings, address(this), newEthBacking - oldEthBacking);
            esETHToken.transfer(msg.sender, newBorrowAmount - oldBorrowAmount - interest);
        }
        esETHToken.transfer(interestRevenueRecipient, interest);

        // Adjust collateral (burn/mint to match target amounts).
        if (newStratIn > oldStratIn) {
            stratToken.burnFrom(msg.sender, newStratIn - oldStratIn);
        } else if (newStratIn < oldStratIn) {
            stratToken.mint(msg.sender, oldStratIn - newStratIn);
        }

        if (newCdtIn > oldCdtIn) {
            cdtToken.burnFrom(msg.sender, newCdtIn - oldCdtIn);
        } else if (newCdtIn < oldCdtIn) {
            cdtToken.mint(msg.sender, oldCdtIn - newCdtIn);
        }

        // Reset term and snapshot new rate/fee (US-011).
        uint256 startTime = block.timestamp;
        uint256 expiry = startTime + loanDuration;
        _positions[tokenId] = Position({
            stratCollateral: newStratIn,
            cdtCollateral: newCdtIn,
            principal: newBorrowAmount,
            maxTermInterest: newMaxTermInterest,
            rate: borrowRate,
            delinquentFee: newDiliquentFee,
            startTime: startTime,
            expiry: expiry
        });

        emit Rolled(
            msg.sender,
            tokenId,
            newStratIn,
            newCdtIn,
            newBorrowAmount,
            newMaxTermInterest,
            borrowRate,
            newDiliquentFee,
            startTime,
            expiry
        );
    }

    /// @notice Permissionless liquidation after expiry (US-400/401).
    function liquidate(uint256 tokenId) external {
        Position memory p = _positions[tokenId];
        if (block.timestamp < p.expiry) revert LoanUnexpired(tokenId);

        address prevOwner = ownerOf(tokenId);

        // On default (expiry), route the unpaid full-term interest that was reserved at origination/roll
        // from unencumbered holdings to the interest revenue recipient.
        if (p.maxTermInterest > 0) {
            esETHToken.transfer(interestRevenueRecipient, p.maxTermInterest);
        }

        if (p.delinquentFee > 0) {
            esETHToken.transfer(unencumberedHoldings, p.delinquentFee);
        }

        // Burn the position NFT; collateral was already burned at origination (forfeited).
        _burn(tokenId);
        delete _positions[tokenId];
        emit Liquidated(tokenId, prevOwner, block.timestamp);
    }

    function _totalHoldingsInETH() internal view returns (uint256) {
        return esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
    }
}
