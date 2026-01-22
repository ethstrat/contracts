// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title StratETHTreasuryLend
 * @notice Borrow ETH-liquidity using STRAT + CDT collateral via a term loan represented by an ERC721.
 *
 * Key mechanics (per user stories):
 * - Positions are transferable NFTs; the NFT owner controls repay/roll.
 * - Interest accrues linearly over time using a fixed per-position rate snapshot.
 * - Positions are unliquidatable until expiry; after expiry anyone can liquidate (permissionless cleanup).
 * - Borrow capacity is derived from STRAT backing value (via ITreasury.total()) and a maxLTV parameter.
 * - Borrow amount is net of the maximum term interest (reserved) and a configurable fee (also reserved).
 */
contract StratETHTreasuryLend is Ownable2Step, ERC721 {
    // ======== Types ========
    struct Position {
        uint256 stratCollateral;
        uint256 cdtCollateral;
        uint256 principal; // amount borrowed (WETH / ETH-representation) sent to borrower
        uint256 maxTermInterest; // full-term interest amount for this position (principal * rate * duration / 365d)
        uint256 rate; // per-position APR, scaled by 1e18
        uint256 fee; // per-position fee snapshot (reserved at origination/roll)
        uint256 startTime;
        uint256 expiry;
    }

    // ======== Immutable config ========
    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    ITreasury public immutable treasury;
    IWETH public immutable wrappedETH;

    // ======== Global parameters ========
    uint256 public constant SCALE = 1e18;
    uint256 public constant YEAR = 365 days;

    /// @notice Maximum loan-to-value for new borrows/rolls (scaled by 1e18). Example: 0.9e18 = 90%.
    uint256 public maxLTV;

    /// @notice Term length for new borrows/rolls (seconds).
    uint256 public loanDuration;

    /// @notice Borrow APR for new borrows/rolls (scaled by 1e18).
    uint256 public borrowRate;

    /// @notice CDT required per STRAT of covered collateral (scaled by 1e18).
    uint256 public debtPerStrat;

    /// @notice Reserved fee deducted from borrow capacity for new borrows/rolls (in wei of wrappedETH).
    uint256 public delinquentFee;

    /// @notice Address that receives interest revenue (e.g. a staking rewards pool).
    address public revenueRecipient;

    /// @notice Delegated roles for parameter updates (owner-managed).
    address public rateSetter;
    address public feeSetter;

    // ======== State ========
    uint256 public nextTokenId;
    uint256 public totalOutstandingPrincipal;
    mapping(uint256 tokenId => Position) internal _positions;

    // ======== Events ========
    event RateSetterUpdated(address indexed oldSetter, address indexed newSetter);
    event FeeSetterUpdated(address indexed oldSetter, address indexed newSetter);
    event MaxLTVUpdated(uint256 oldVal, uint256 newVal);
    event LoanDurationUpdated(uint256 oldVal, uint256 newVal);
    event BorrowRateUpdated(uint256 oldVal, uint256 newVal);
    event DebtPerStratUpdated(uint256 oldVal, uint256 newVal);
    event DelinquentFeeUpdated(uint256 oldVal, uint256 newVal);
    event RevenueRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    event Borrowed(
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 stratCollateral,
        uint256 cdtCollateral,
        uint256 coveredStrat,
        uint256 principal,
        uint256 maxTermInterest,
        uint256 rate,
        uint256 fee,
        uint256 startTime,
        uint256 expiry
    );

    event Repaid(
        address indexed payer,
        uint256 indexed tokenId,
        uint256 principalRepaid,
        uint256 interestPaid,
        uint256 timestamp
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
    error BorrowTooSmall();
    error TransferFailed();
    error UnauthorizedRateSetter(address caller);
    error UnauthorizedFeeSetter(address caller);

    /**
     * @param _cdtToken     The CDT token (mintable/burnable)
     * @param _stratToken   The STRAT token (mintable/burnable)
     * @param _treasury     Treasury (ETH backing source)
     * @param _wrappedETH   ERC20 wrapper for ETH payouts/repayments (e.g. WETH-like)
     * @param _borrowRate   Initial borrow APR for new positions (scaled by 1e18)
     * @param owner         Contract owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _treasury,
        address _wrappedETH,
        uint256 _borrowRate,
        address owner
    ) Ownable(owner) ERC721("STRAT Treasury Lend", "tlSTRAT") {
        if (_cdtToken == address(0) || _stratToken == address(0) || _treasury == address(0) || _wrappedETH == address(0)) {
            revert ZeroAddress();
        }

        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        treasury = ITreasury(_treasury);
        wrappedETH = IWETH(_wrappedETH);

        // Defaults per user stories (targets).
        maxLTV = 0.9e18;
        loanDuration = 180 days;
        borrowRate = _borrowRate;
        debtPerStrat = 1e18; // default: 1 CDT per 1 STRAT, can be tuned by owner

        // Delegated roles initialized to owner.
        rateSetter = owner;
        feeSetter = owner;

        // Revenue recipient defaults to owner (governance can later point to a staking rewards pool).
        revenueRecipient = owner;
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

    // ======== Owner-managed risk parameters (US-001) ========
    function setMaxLTV(uint256 newMaxLTV) external onlyOwner {
        uint256 old = maxLTV;
        maxLTV = newMaxLTV;
        emit MaxLTVUpdated(old, newMaxLTV);
    }

    function setLoanDuration(uint256 newLoanDuration) external onlyOwner {
        uint256 old = loanDuration;
        loanDuration = newLoanDuration;
        emit LoanDurationUpdated(old, newLoanDuration);
    }

    function setDebtPerStrat(uint256 newDebtPerStrat) external onlyOwner {
        uint256 old = debtPerStrat;
        debtPerStrat = newDebtPerStrat;
        emit DebtPerStratUpdated(old, newDebtPerStrat);
    }

    // ======== Delegated parameter setters (US-500/US-501) ========
    function setBorrowRate(uint256 newBorrowRate) external {
        if (msg.sender != rateSetter) revert UnauthorizedRateSetter(msg.sender);
        uint256 old = borrowRate;
        borrowRate = newBorrowRate;
        emit BorrowRateUpdated(old, newBorrowRate);
    }

    function setDelinquentFee(uint256 newFee) external {
        if (msg.sender != feeSetter) revert UnauthorizedFeeSetter(msg.sender);
        uint256 old = delinquentFee;
        delinquentFee = newFee;
        emit DelinquentFeeUpdated(old, newFee);
    }

    function setRevenueRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = revenueRecipient;
        revenueRecipient = newRecipient;
        emit RevenueRecipientUpdated(old, newRecipient);
    }

    // ======== Views ========
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return _positions[tokenId];
    }

    /// @notice Preview borrow outcome using *current* global parameters (US-101).
    function previewBorrow(uint256 stratIn, uint256 cdtIn)
        external
        view
        returns (uint256 coveredStrat, uint256 maxBorrowBeforeInterest, uint256 maxTermInterest, uint256 borrowAmount)
    {
        if (stratIn == 0 || cdtIn == 0) revert ZeroAmount();
        (coveredStrat,) = _coveredStratAndRequiredCdt(stratIn, cdtIn);

        uint256 collateralValue = _stratBackingValue(coveredStrat);
        maxBorrowBeforeInterest = (collateralValue * maxLTV) / SCALE;

        // principal = (maxBorrowBeforeInterest - fee) / (1 + rate * duration / YEAR)
        // maxTermInterest = principal * rate * duration / YEAR
        uint256 fee = delinquentFee;
        if (maxBorrowBeforeInterest <= fee) revert BorrowTooSmall();

        uint256 termFactor = (borrowRate * loanDuration) / YEAR; // scaled by 1e18
        uint256 denom = SCALE + termFactor;
        borrowAmount = ((maxBorrowBeforeInterest - fee) * SCALE) / denom;
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
    /// @notice Borrow by supplying up to `stratIn` and `cdtIn` as collateral. Only the covered portion is pulled (US-100).
    function borrow(uint256 stratIn, uint256 cdtIn, uint256 minBorrowAmount, uint256 deadline) external {
        if (deadline < block.timestamp) revert TransactionStale(deadline);
        if (stratIn == 0 || cdtIn == 0) revert ZeroAmount();

        (uint256 coveredStratAmount, uint256 requiredCdtAmount) = _coveredStratAndRequiredCdt(stratIn, cdtIn);

        (
            uint256 maxBorrowBeforeInterest,
            uint256 maxTermInterestAmount,
            uint256 principalAmount,
            uint256 feeAmount,
            uint256 rateSnapshot
        ) = _computeBorrowTerms(coveredStratAmount);

        if (principalAmount < minBorrowAmount) revert InsufficientOutput(minBorrowAmount, principalAmount);

        // Pull collateral (burn) only for the covered portion.
        stratToken.burnFrom(msg.sender, coveredStratAmount);
        cdtToken.burnFrom(msg.sender, requiredCdtAmount);

        uint256 tokenId = nextTokenId++;
        uint256 startTime = block.timestamp;
        uint256 expiry = startTime + loanDuration;

        _positions[tokenId] = Position({
            stratCollateral: coveredStratAmount,
            cdtCollateral: requiredCdtAmount,
            principal: principalAmount,
            maxTermInterest: maxTermInterestAmount,
            rate: rateSnapshot,
            fee: feeAmount,
            startTime: startTime,
            expiry: expiry
        });

        totalOutstandingPrincipal += principalAmount;

        // Mint position NFT (US-010).
        _mint(msg.sender, tokenId);

        // Withdraw ETH from treasury, wrap, and send to borrower (US-100).
        treasury.withdraw(principalAmount, address(this));
        wrappedETH.deposit{value: principalAmount}();
        if (!wrappedETH.transfer(msg.sender, principalAmount)) revert TransferFailed();

        emit Borrowed(
            msg.sender,
            tokenId,
            coveredStratAmount,
            requiredCdtAmount,
            coveredStratAmount,
            principalAmount,
            maxTermInterestAmount,
            rateSnapshot,
            feeAmount,
            startTime,
            expiry
        );

        // silence unused warning in terms computation (kept for clarity in preview parity)
        maxBorrowBeforeInterest;
    }

    /// @notice Repay before expiry (US-201). Pays accrued interest to `revenueRecipient`.
    function repay(uint256 tokenId) external {
        address posOwner = ownerOf(tokenId);
        if (msg.sender != posOwner) revert NotPositionOwner(msg.sender, tokenId);

        Position memory p = _positions[tokenId];
        if (block.timestamp >= p.expiry) revert LoanExpired(tokenId);

        uint256 interest = accruedInterest(tokenId);
        uint256 totalPay = p.principal + interest;

        // Pull wrappedETH from payer.
        if (!wrappedETH.transferFrom(msg.sender, address(this), totalPay)) revert TransferFailed();

        // Route interest to revenue recipient (US-600 intent).
        if (interest > 0) {
            if (!wrappedETH.transfer(revenueRecipient, interest)) revert TransferFailed();
        }

        // Unwrap and return principal to treasury (ETH).
        wrappedETH.withdraw(p.principal);
        (bool ok,) = address(treasury).call{value: p.principal}("");
        if (!ok) revert TransferFailed();

        // Close: burn NFT and restore collateral (mint back).
        _burn(tokenId);
        stratToken.mint(posOwner, p.stratCollateral);
        cdtToken.mint(posOwner, p.cdtCollateral);
        totalOutstandingPrincipal -= p.principal;
        delete _positions[tokenId];

        emit Repaid(msg.sender, tokenId, p.principal, interest, block.timestamp);
    }

    /// @notice Roll a position: settle interest to date, adjust collateral and principal, reset term (US-300/301/302).
    function roll(uint256 tokenId, uint256 newStratCollateral, uint256 newCdtCollateral, uint256 deadline) external {
        if (deadline < block.timestamp) revert TransactionStale(deadline);

        address posOwner = ownerOf(tokenId);
        if (msg.sender != posOwner) revert NotPositionOwner(msg.sender, tokenId);

        Position memory p = _positions[tokenId];
        if (block.timestamp >= p.expiry) revert LoanExpired(tokenId);

        if (newStratCollateral == 0 || newCdtCollateral == 0) revert ZeroAmount();

        // Settle accrued interest up to now.
        uint256 interest = accruedInterest(tokenId);
        if (interest > 0) {
            if (!wrappedETH.transferFrom(msg.sender, revenueRecipient, interest)) revert TransferFailed();
        }

        // Adjust collateral (burn/mint to match target amounts).
        if (newStratCollateral > p.stratCollateral) {
            stratToken.burnFrom(msg.sender, newStratCollateral - p.stratCollateral);
        } else if (newStratCollateral < p.stratCollateral) {
            stratToken.mint(msg.sender, p.stratCollateral - newStratCollateral);
        }

        if (newCdtCollateral > p.cdtCollateral) {
            cdtToken.burnFrom(msg.sender, newCdtCollateral - p.cdtCollateral);
        } else if (newCdtCollateral < p.cdtCollateral) {
            cdtToken.mint(msg.sender, p.cdtCollateral - newCdtCollateral);
        }

        // Recompute coveredStrat under current debt-per-strat (US-300).
        (uint256 coveredStratAmount, uint256 requiredCdtAmount) =
            _coveredStratAndRequiredCdt(newStratCollateral, newCdtCollateral);

        // If target collateral is not fully coverable, we treat the position as resized to the covered portion only.
        // Any "excess" over covered is effectively returned above via minting back.
        if (coveredStratAmount != newStratCollateral) {
            // return uncovered STRAT
            if (newStratCollateral > coveredStratAmount) {
                stratToken.mint(msg.sender, newStratCollateral - coveredStratAmount);
            }
            newStratCollateral = coveredStratAmount;
        }
        if (requiredCdtAmount != newCdtCollateral) {
            // return excess CDT
            if (newCdtCollateral > requiredCdtAmount) {
                cdtToken.mint(msg.sender, newCdtCollateral - requiredCdtAmount);
            }
            newCdtCollateral = requiredCdtAmount;
        }

        // Compute new terms from covered collateral under current params.
        (
            ,
            uint256 maxTermInterestAmount,
            uint256 newPrincipal,
            uint256 feeAmount,
            uint256 rateSnapshot
        ) = _computeBorrowTerms(newStratCollateral);

        // Adjust principal (US-301). If increasing, pay out delta; if decreasing, require pay-in delta.
        if (newPrincipal > p.principal) {
            uint256 delta = newPrincipal - p.principal;
            treasury.withdraw(delta, address(this));
            wrappedETH.deposit{value: delta}();
            if (!wrappedETH.transfer(msg.sender, delta)) revert TransferFailed();
        } else if (newPrincipal < p.principal) {
            uint256 delta = p.principal - newPrincipal;
            if (!wrappedETH.transferFrom(msg.sender, address(this), delta)) revert TransferFailed();
            wrappedETH.withdraw(delta);
            (bool ok,) = address(treasury).call{value: delta}("");
            if (!ok) revert TransferFailed();
        }

        // Update outstanding principal accounting.
        if (newPrincipal > p.principal) {
            totalOutstandingPrincipal += (newPrincipal - p.principal);
        } else if (newPrincipal < p.principal) {
            totalOutstandingPrincipal -= (p.principal - newPrincipal);
        }

        // Reset term and snapshot new rate/fee (US-011).
        uint256 startTime = block.timestamp;
        uint256 expiry = startTime + loanDuration;
        _positions[tokenId] = Position({
            stratCollateral: newStratCollateral,
            cdtCollateral: newCdtCollateral,
            principal: newPrincipal,
            maxTermInterest: maxTermInterestAmount,
            rate: rateSnapshot,
            fee: feeAmount,
            startTime: startTime,
            expiry: expiry
        });

        emit Rolled(
            msg.sender,
            tokenId,
            newStratCollateral,
            newCdtCollateral,
            newPrincipal,
            maxTermInterestAmount,
            rateSnapshot,
            feeAmount,
            block.timestamp,
            expiry
        );
    }

    /// @notice Permissionless liquidation after expiry (US-400/401).
    function liquidate(uint256 tokenId) external {
        Position memory p = _positions[tokenId];
        if (block.timestamp < p.expiry) revert LoanUnexpired(tokenId);

        address prevOwner = ownerOf(tokenId);

        // Burn the position NFT; collateral was already burned at origination (forfeited).
        _burn(tokenId);

        totalOutstandingPrincipal -= p.principal;
        delete _positions[tokenId];

        emit Liquidated(tokenId, prevOwner, block.timestamp);
    }

    // ======== Internals ========
    function _stratBackingValue(uint256 stratAmount) internal view returns (uint256) {
        uint256 stratSupply = stratToken.totalSupply();
        if (stratSupply == 0) revert StratSupplyIsZero();
        // backing value in ETH wei: treasury.total() * stratAmount / totalSupply
        return (treasury.total() * stratAmount) / stratSupply;
    }

    function _coveredStratAndRequiredCdt(uint256 stratIn, uint256 cdtIn)
        internal
        view
        returns (uint256 coveredStratAmount, uint256 requiredCdtAmount)
    {
        uint256 dps = debtPerStrat; // CDT per STRAT, 1e18 scaled
        if (dps == 0) revert ZeroAmount();
        // coveredStrat = min(stratIn, cdtIn / dps)
        uint256 coverableStrat = (cdtIn * SCALE) / dps;
        coveredStratAmount = stratIn < coverableStrat ? stratIn : coverableStrat;
        if (coveredStratAmount == 0) revert ZeroAmount();
        requiredCdtAmount = (coveredStratAmount * dps) / SCALE;
        if (requiredCdtAmount == 0) revert ZeroAmount();
    }

    function _computeBorrowTerms(uint256 coveredStratAmount)
        internal
        view
        returns (
            uint256 maxBorrowBeforeInterest,
            uint256 maxTermInterestAmount,
            uint256 principalAmount,
            uint256 feeAmount,
            uint256 rateSnapshot
        )
    {
        uint256 collateralValue = _stratBackingValue(coveredStratAmount);
        maxBorrowBeforeInterest = (collateralValue * maxLTV) / SCALE;

        feeAmount = delinquentFee;
        if (maxBorrowBeforeInterest <= feeAmount) revert BorrowTooSmall();

        rateSnapshot = borrowRate;

        uint256 termFactor = (rateSnapshot * loanDuration) / YEAR; // 1e18 scaled
        uint256 denom = SCALE + termFactor;
        principalAmount = ((maxBorrowBeforeInterest - feeAmount) * SCALE) / denom;
        maxTermInterestAmount = (principalAmount * termFactor) / SCALE;

        if (principalAmount == 0) revert BorrowTooSmall();
    }

    receive() external payable {}
}
