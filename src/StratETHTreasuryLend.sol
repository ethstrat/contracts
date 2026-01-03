// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {IERC20, IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

/**
 * @title The STRAT ETH Long Bonds Strategy
 * @dev convertible notes on STRAT. Bonders get CDT and a StratOption.
 */
contract StratETHTreasuryLend is Ownable2Step, ERC721 {
    uint256 public _tokenIdCounter;
    uint256 public totalOutstandingBorrow;

    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    ITreasury public immutable treasury;

    uint256 public rcf;

    mapping(uint256 tokenId => uint256) public stratAmountFor;
    mapping(uint256 tokenId => uint256) public cdtAmountFor;
    mapping(uint256 tokenId => uint256) public totalBorrowFor;
    mapping(uint256 tokenId => uint256) public totalInterestPayableFor;
    mapping(uint256 tokenId => uint256) public unpaidLoanFee;
    mapping(uint256 tokenId => uint256) public loanExpiryFor;

    uint256 public constant SCALE = 1e18;
    uint256 public constant LOAN_DURATION = 6.9 * 30 days;

    event OwnerChangedRCF(uint256 oldVal, uint256 newVal);

    event Borrow(
        address indexed borrower,
        uint256 stratAmount,
        uint256 cdtAmount,
        uint256 borrowAmount,
        uint256 maxInterest,
        uint256 expiry
    );

    event Liquidated(uint256 indexed tokenId, address indexed owner);

    error NoEthSent();
    error ZeroAddress();
    error EthTransferFailed();
    error TransactionStale(uint256 deadline);
    error InsufficientOutput(uint256 minNotionalUnderlyingAmount, uint256 notionalUnderlyingAmount);
    error LoanExpired(uint256 tokenId);

    /**
     * @param _cdtToken The CDT token
     * @param _stratToken The STRAT token
     * @param _treasury operations on treasury
     * @param _rcf scaling factor applied on the treasury utilisation to calculate the interest rate (scaled by SCALE)
     * @param owner The owner
     */
    constructor(
        address _cdtToken,
        address _stratToken,
        address _treasury,
        uint256 _rcf,
        address owner
    ) Ownable(owner) ERC721("STRAT Treasury Lend", "tlSTRAT") {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        treasury = ITreasury(_treasury);

        rcf = _rcf;
    }

    /**
     * @notice Updates the RCF (Rate Control Factor) to the new specified value.
     * @dev This function can only be called by the contract owner.
     * @param newVal The new value to set for the RCF.
     */
    function setRCF(uint256 newVal) external onlyOwner {
        emit OwnerChangedRCF(rcf, newVal);
        rcf = newVal;
    }

    function borrow(uint256 stratAmount, uint256 minBorrowAmount, uint256 deadline) external payable {
        if (deadline < block.timestamp) revert TransactionStale(deadline);

        // redemption
        uint256 cdtAmount = stratAmount * cdtToken.totalSupply() / stratToken.totalSupply();
        uint256 borrowAmount = treasury.total() * stratAmount / stratToken.totalSupply();
        uint256 maxInterest = maxInterestPayable(borrowAmount);
        uint256 expiry = block.timestamp + LOAN_DURATION;

        // Check that the borrow amount is greater than the minimum
        if (borrowAmount < minBorrowAmount) {
            revert InsufficientOutput(borrowAmount, minBorrowAmount);
        }

        cdtToken.burnFrom(msg.sender, cdtAmount);
        stratToken.burnFrom(msg.sender, stratAmount);
        
        // Calculate minimum total (15% of borrow amount)
        uint256 minTotal = (borrowAmount * 15) / 100;
        // Ensure total is at least 15% - this is what was previously totalInterestPayableFor
        uint256 totalInterestAndFee = maxInterest > minTotal ? maxInterest : minTotal;
        
        // Split into interest payable and unpaid loan fee
        // unpaidLoanFee is 20% of the total, totalInterestPayableFor is 80%
        // This ensures they add up to the previous totalInterestPayableFor value
        unpaidLoanFee[_tokenIdCounter] = (totalInterestAndFee * 20) / 100;
        totalInterestPayableFor[_tokenIdCounter] = totalInterestAndFee - unpaidLoanFee[_tokenIdCounter];
        
        stratAmountFor[_tokenIdCounter] = stratAmount;
        cdtAmountFor[_tokenIdCounter] = cdtAmount;
        totalBorrowFor[_tokenIdCounter] = borrowAmount;
        loanExpiryFor[_tokenIdCounter] = expiry;
        
        // Update totalOutstandingBorrow: add principal + interest + fees
        totalOutstandingBorrow += borrowAmount + totalInterestAndFee;
        
        _mint(msg.sender, _tokenIdCounter++);
        treasury.withdraw(borrowAmount, msg.sender);

        emit Borrow(
            msg.sender,
            stratAmount,
            cdtAmount,
            borrowAmount,
            maxInterest,
            expiry
        );
    }

    function repay(uint256 tokenId) external payable {
        uint256 stratAmount = stratAmountFor[tokenId];
        uint256 cdtAmount = cdtAmountFor[tokenId];
        uint256 borrowedAmount = totalBorrowFor[tokenId];
        uint256 interestPayable = totalInterestPayableFor[tokenId];
        uint256 fee = unpaidLoanFee[tokenId];
        uint256 expiry = loanExpiryFor[tokenId];
        address owner = ownerOf(tokenId);

        // Only the owner of the token can repay
        if (msg.sender != owner) revert("Not token owner");

        // Ensure not already repaid (can't repay twice)
        if (borrowedAmount == 0) revert("Loan already repaid");
        
        // Don't allow repayment of expired loans
        if (block.timestamp >= expiry) revert LoanExpired(tokenId);

        // Calculate repay amount: principal - (interest + fee) + accrued interest
        // The unpaidLoanFee doesn't accrue, so borrower always gets benefit of full fee reduction
        uint256 repayAmount = borrowedAmount - interestPayable - fee + accruedInterestFor(tokenId);

        // The user has to send the proper ETH amount
        if (msg.value < repayAmount) revert("Insufficient ETH sent");

        // Update totalOutstandingBorrow: subtract principal + interest + fees (what was added on borrow)
        uint256 totalInterestAndFee = interestPayable + fee;
        totalOutstandingBorrow -= borrowedAmount + totalInterestAndFee;

        // Burn the token to prevent reentrancy and reuse
        _burn(tokenId);

        // Remint the user's STRAT and CDT
        stratToken.mint(owner, stratAmount);
        cdtToken.mint(owner, cdtAmount);

        // Forward repaid ETH to the treasury
        (bool success, ) = address(treasury).call{value: repayAmount}("");
        if (!success) revert("ETH Transfer to treasury failed");

        // Refund any excess ETH sent
        if (msg.value > repayAmount) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - repayAmount}("");
            require(refundSuccess, "Refund failed");
        }

        // Clean up storage
        stratAmountFor[tokenId] = 0;
        cdtAmountFor[tokenId] = 0;
        totalBorrowFor[tokenId] = 0;
        totalInterestPayableFor[tokenId] = 0;
        unpaidLoanFee[tokenId] = 0;
        loanExpiryFor[tokenId] = 0;
    }

    /**
     * @notice Liquidates expired loans by burning NFTs and updating totalOutstandingBorrow
     * @param tokenIds Array of token IDs to liquidate
     */
    function liquidate(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 expiry = loanExpiryFor[tokenId];
            uint256 borrowedAmount = totalBorrowFor[tokenId];
            
            // Only liquidate if loan is expired and not already liquidated/repaid
            if (block.timestamp >= expiry && borrowedAmount > 0) {
                uint256 interestPayable = totalInterestPayableFor[tokenId];
                uint256 fee = unpaidLoanFee[tokenId];
                address owner = ownerOf(tokenId);
                
                // Calculate total amount (principal + interest + fees)
                uint256 totalInterestAndFee = interestPayable + fee;
                uint256 totalAmount = borrowedAmount + totalInterestAndFee;
                
                // Subtract from totalOutstandingBorrow
                totalOutstandingBorrow -= totalAmount;
                
                // Burn the NFT
                _burn(tokenId);
                
                // Clean up storage
                stratAmountFor[tokenId] = 0;
                cdtAmountFor[tokenId] = 0;
                totalBorrowFor[tokenId] = 0;
                totalInterestPayableFor[tokenId] = 0;
                unpaidLoanFee[tokenId] = 0;
                loanExpiryFor[tokenId] = 0;
                
                emit Liquidated(tokenId, owner);
            }
        }
    }

    function accruedInterestFor(uint256 tokenId) public view returns (uint256) {
        uint256 maxInterest = totalInterestPayableFor[tokenId];
        uint256 expiry = loanExpiryFor[tokenId];

        // Interest accrues linearly up to expiry
        uint256 startTime = expiry - LOAN_DURATION;
        if (block.timestamp <= startTime) {
            return 0;
        }
        if (block.timestamp >= expiry) {
            return maxInterest;
        }

        uint256 elapsed = block.timestamp - startTime;
        uint256 totalDuration = expiry - startTime;

        // Return proportional interest, linearly
        return (maxInterest * elapsed) / totalDuration;
    }

    /// @notice Provides the strike price for a given USD value of ETH
    ///
    /// @param  borrowAmount   Total borrow amount
    /// @return maxInterest_   The maximum interest payable if the borrower held loan till expiry
    function maxInterestPayable(uint256 borrowAmount) public view returns (uint256 maxInterest_) {
        uint256 treasuryTotal = treasury.total();

        if (treasuryTotal == 0) {
            return 0;
        }

        // Calculate interest using iterative approach to handle circular dependency
        // Formula: (totalOutstandingBorrow + maxBorrowWithInterestAndFees/2) / totalTreasury * RCF
        // where maxBorrowWithInterestAndFees = borrowAmount + interest + fees
        
        // Start with an initial estimate using current totalOutstandingBorrow
        uint256 estimatedUtilization = ((totalOutstandingBorrow + borrowAmount / 2) * 1e18) / treasuryTotal;
        uint256 estimatedInterestRate = (estimatedUtilization * rcf) / 1e18;
        uint256 estimatedInterest = (borrowAmount * estimatedInterestRate) / 1e18;
        
        // Calculate minimum total (15% of borrow amount)
        uint256 minTotal = (borrowAmount * 15) / 100;
        uint256 estimatedTotalInterestAndFee = estimatedInterest > minTotal ? estimatedInterest : minTotal;
        
        // Now use the refined calculation with half of the new borrow's total
        uint256 maxBorrowWithInterestAndFees = borrowAmount + estimatedTotalInterestAndFee;
        uint256 utilization = ((totalOutstandingBorrow + maxBorrowWithInterestAndFees / 2) * 1e18) / treasuryTotal;
        uint256 interestRate = (utilization * rcf) / 1e18;
        
        maxInterest_ = (borrowAmount * interestRate) / 1e18;
    }
}
