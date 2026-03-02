// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EthStrategyPerpetualNote} from "./EthStrategyPerpetualNote.sol";

/**
 * @title ESPN Redemption Queue
 * @dev NFT contract that represents a queue position for ESPN redemption
 *
 * Users transfer ESPN tokens to the queue to mint an NFT that represents their position in the redemption queue.
 * Queued ESPN doesn't benefit from yield.
 * Each NFT tracks the total redemptions that came before it and the dollar backing of the queued ESPN.
 * NFT holders can redeem when their position in the queue is eligible, or cancel their redemption.
 */
contract ESPNRedemptionQueue is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The ESPN contract
    EthStrategyPerpetualNote public immutable espn;

    /// @dev The USDS token (underlying asset of ESPN)
    IERC20 public immutable usds;

    /// @dev Cumulative dollar value of all redemptions queued (in USDS terms)
    ///      This value always grows and never decreases
    uint256 public totalQueued;

    /// @dev Total redemptions processed (cumulative dollar value in USDS terms)
    ///      This value always grows and never decreases
    uint256 public totalRedemptionsProcessed;

    /// @dev Total cancellations processed (cumulative dollar value in USDS terms)
    ///      This value always grows and never decreases
    ///      Invariant: totalRedemptionsProcessed + totalCancellationsProcessed <= totalQueued
    uint256 public totalCancellationsProcessed;

    /// @dev Address authorized to sweep USDS
    address public immutable sweeper;

    /// @dev Token ID counter
    uint256 private _tokenIdCounter;

    /// @dev Mapping from token ID to redemption data
    struct RedemptionData {
        uint256 redemptionsBefore; // Cumulative dollar value of redemptions that came before this NFT (in USDS terms)
        uint256 redemptionAmount; // Dollar value of ESPN queued (in USDS terms)
        bool redeemed; // Whether this NFT has been redeemed
        bool cancelled; // Whether this redemption has been cancelled
    }

    mapping(uint256 tokenId => RedemptionData) public redemptions;

    /// @dev Events
    event RedemptionQueued(
        address indexed user,
        uint256 indexed tokenId,
        uint256 espnQueued,
        uint256 redemptionAmount,
        uint256 redemptionsBefore
    );
    event RedemptionFulfilled(address indexed user, uint256 indexed tokenId, uint256 usdsAmount);
    event RedemptionCancelled(address indexed user, uint256 indexed tokenId, uint256 espnReturned);
    event USDSwept(address indexed sweeper, uint256 amount);
    event ExcessESPNBurned(uint256 espnBurned, uint256 excessValue);

    /// @dev Errors
    error NotEligibleForRedemption(uint256 tokenId);
    error AlreadyRedeemed(uint256 tokenId);
    error AlreadyCancelled(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);
    error InvalidSweeper();
    error ZeroAmount();
    error RedemptionNotCancelled();

    /**
     * @dev Constructor
     * @param _espn The ESPN contract address
     * @param _sweeper The address authorized to sweep USDS
     * @param _owner The owner of the contract
     */
    constructor(address _espn, address _sweeper, address _owner)
        ERC721("ESPN Redemption Queue", "ESPN-RQ")
        Ownable(_owner)
    {
        if (_sweeper == address(0)) revert InvalidSweeper();
        espn = EthStrategyPerpetualNote(_espn);
        usds = IERC20(espn.asset());
        sweeper = _sweeper;
        _tokenIdCounter = 1;

        // Set infinite approval for ESPN's increaseAssetsPerShare function
        // ESPN is immutable, and increaseAssetsPerShare is the only function that uses this approval
        // This is safe because:
        // 1. ESPN contract is immutable (set once, cannot be changed)
        // 2. increaseAssetsPerShare is a controlled function that only transfers the exact amount passed
        // 3. No other ESPN functions can drain USDS from this contract
        SafeERC20.forceApprove(usds, address(espn), type(uint256).max);
    }

    /**
     * @dev Queue a redemption by transferring ESPN to the queue and minting an NFT
     * @param espnAmount The amount of ESPN to queue
     * @return tokenId The minted NFT token ID
     */
    function queueRedemption(uint256 espnAmount) external nonReentrant returns (uint256) {
        if (espnAmount == 0) revert ZeroAmount();

        // Calculate redemption amount using ERC4626 math
        // This is the amount of USDS that would be received if redeeming the ESPN
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Transfer ESPN from the user (user must have approved this contract)
        // ESPN is held (not burned) so users don't benefit from yield while in queue
        IERC20(address(espn)).safeTransferFrom(msg.sender, address(this), espnAmount);

        // Mint NFT
        uint256 tokenId = _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);

        // Record redemption data
        // redemptionsBefore is the cumulative dollar value of all redemptions before this one
        redemptions[tokenId] = RedemptionData({
            redemptionsBefore: totalQueued,
            redemptionAmount: redemptionAmount,
            redeemed: false,
            cancelled: false
        });

        // Increment total queued (always growing)
        totalQueued += redemptionAmount;

        // Burn excess ESPN if we hold more than totalQueued
        _burnExcessESPN();

        emit RedemptionQueued(msg.sender, tokenId, espnAmount, redemptionAmount, totalQueued - redemptionAmount);
        return tokenId;
    }

    /**
     * @dev Redeem an active (non-cancelled) NFT for USDS if eligible
     * Automatically deposits USDS to ESPN, withdraws the right amount of ESPN, and sends USDS to user
     * @param tokenId The NFT token ID to redeem
     */
    function redeem(uint256 tokenId) external nonReentrant {
        // Check ownership
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);

        // Check if already redeemed
        if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);

        // Check if cancelled (should use processCancelledRedemptions instead)
        if (redemptions[tokenId].cancelled) revert AlreadyCancelled(tokenId);

        RedemptionData storage redemption = redemptions[tokenId];

        // Check eligibility: redemptionsBefore < (totalRedemptionsProcessed + totalCancellationsProcessed + USDS
        // balance)
        uint256 availablePosition =
            totalRedemptionsProcessed + totalCancellationsProcessed + usds.balanceOf(address(this));
        if (redemption.redemptionsBefore >= availablePosition) {
            revert NotEligibleForRedemption(tokenId);
        }

        // Step 1: Increase assets per share by adding USDS to ESPN
        // This increases ESPN's totalAssets without minting new shares
        // Approval is set to max in constructor, so no need to approve here
        // This transfers redemptionAmount from queue to ESPN, then ESPN sends it to manager
        espn.increaseAssetsPerShare(redemption.redemptionAmount);

        // Step 2: Transfer USDS to ESPN so it can fulfill the withdrawal
        // increaseAssetsPerShare sends USDS to the manager, but withdraw needs USDS in ESPN's balance
        // The queue needs redemptionAmount * 2 total: one for increaseAssetsPerShare, one for this transfer
        usds.safeTransfer(address(espn), redemption.redemptionAmount);

        // Step 3: Calculate how many ESPN shares we need to withdraw to get redemptionAmount USDS
        // We use previewWithdraw to get the exact shares needed
        // Note: The ESPN shares we hold from queueing may have grown in value due to yield,
        // but we only withdraw enough to give the user their redemptionAmount (they don't benefit from yield)
        uint256 espnSharesToWithdraw = espn.previewWithdraw(redemption.redemptionAmount);

        // Step 4: Withdraw USDS from ESPN by withdrawing the calculated amount
        // This burns ESPN shares and gives us USDS
        // Note: withdraw() returns shares burned, not assets received
        // The actual USDS received is redemption.redemptionAmount (the amount we requested)
        espn.withdraw(redemption.redemptionAmount, address(this), address(this));

        // Step 5: Send USDS to user
        // The USDS received is exactly redemption.redemptionAmount (the amount we requested)
        usds.safeTransfer(msg.sender, redemption.redemptionAmount);

        // Mark as redeemed and update counters
        redemption.redeemed = true;
        totalRedemptionsProcessed += redemption.redemptionAmount;

        // Burn excess ESPN if we hold more than totalQueued
        _burnExcessESPN();

        // Burn NFT
        _burn(tokenId);
        emit RedemptionFulfilled(msg.sender, tokenId, redemption.redemptionAmount);
    }

    /**
     * @dev Process cancelled NFTs to advance the queue (permissionless)
     * This allows anyone to process cancelled NFTs to improve capital efficiency
     * for active redemptions behind them in the queue
     * @param tokenIds Array of cancelled NFT token IDs to process
     */
    function processCancelledRedemptions(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // Check if already redeemed
            if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);

            // Must be cancelled
            if (!redemptions[tokenId].cancelled) revert RedemptionNotCancelled();

            RedemptionData storage redemption = redemptions[tokenId];

            // Check eligibility
            uint256 availablePosition =
                totalRedemptionsProcessed + totalCancellationsProcessed + usds.balanceOf(address(this));
            if (redemption.redemptionsBefore >= availablePosition) {
                revert NotEligibleForRedemption(tokenId);
            }

            // Process cancelled NFT: increment counter and burn (no USDS transfer)
            address owner = ownerOf(tokenId);
            redemption.redeemed = true;
            totalCancellationsProcessed += redemption.redemptionAmount;
            _burn(tokenId);
            emit RedemptionFulfilled(owner, tokenId, 0);
        }

        // Burn excess ESPN after processing cancellations
        _burnExcessESPN();
    }

    /**
     * @dev Cancel a redemption by returning ESPN equal to the dollar amount queued
     * Returns ESPN based on current share price, so user gets back $100 notional worth of ESPN
     * if they queued $100, regardless of how ESPN share price changed while in queue
     * @param tokenId The NFT token ID to cancel
     */
    function cancelRedemption(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);
        if (redemptions[tokenId].cancelled) revert AlreadyCancelled(tokenId);

        RedemptionData storage redemption = redemptions[tokenId];

        // Mark as cancelled to prevent reentrancy
        redemption.cancelled = true;

        // Calculate how many ESPN shares equal the redemptionAmount in dollar terms
        // We use previewDeposit to get the exact shares needed for redemptionAmount USDS
        // previewDeposit(assets) returns shares, which is what we need
        uint256 espnSharesToReturn = espn.previewDeposit(redemption.redemptionAmount);

        // Return ESPN to user (equal to dollar amount queued, not original shares)
        IERC20(address(espn)).safeTransfer(msg.sender, espnSharesToReturn);

        // Burn excess ESPN if we hold more than totalQueued
        _burnExcessESPN();

        // NFT stays in queue and will be processed via processCancelledRedemptions()
        emit RedemptionCancelled(msg.sender, tokenId, espnSharesToReturn);
    }

    /**
     * @dev Sweep USDS from this contract to the sweeper address
     * @dev Only callable by the owner
     */
    function sweepUSDS() external onlyOwner {
        uint256 balance = usds.balanceOf(address(this));
        if (balance > 0) {
            usds.safeTransfer(sweeper, balance);
            emit USDSwept(sweeper, balance);
        }
    }

    /**
     * @dev Permissionless function to burn excess ESPN
     * Burns ESPN if the contract holds more ESPN (in dollar terms) than totalQueued
     * Should be called on each join/leave/cancel to maintain invariant
     * @return espnBurned The amount of ESPN burned
     * @return excessValue The dollar value of excess ESPN burned
     */
    function burnExcessESPN() external nonReentrant returns (uint256 espnBurned, uint256 excessValue) {
        return _burnExcessESPN();
    }

    /**
     * @dev Internal function to burn excess ESPN
     * @return espnBurned The amount of ESPN burned
     * @return excessValue The dollar value of excess ESPN burned
     */
    function _burnExcessESPN() internal returns (uint256 espnBurned, uint256 excessValue) {
        uint256 espnBalance = IERC20(address(espn)).balanceOf(address(this));
        if (espnBalance == 0) {
            return (0, 0);
        }

        // Calculate current dollar value of ESPN held
        uint256 espnValue = espn.previewRedeem(espnBalance);

        // If we hold more than totalQueued, burn the excess
        if (espnValue > totalQueued) {
            excessValue = espnValue - totalQueued;
            // Subtract 1 wei to be conservative (ensures we burn less than true excess)
            // This guarantees we always have enough ESPN if everyone cancels
            if (excessValue > 0) {
                excessValue -= 1;
            }
            // Calculate how many ESPN shares equal the excess value
            // excessValue is in USDS (assets), so we use previewDeposit to get shares
            espnBurned = espn.previewDeposit(excessValue);
            
            // Burn the excess ESPN
            espn.burn(espnBurned);
            
            emit ExcessESPNBurned(espnBurned, excessValue);
        }

        return (espnBurned, excessValue);
    }

    /**
     * @dev Get redemption data for a token ID
     * @param tokenId The NFT token ID
     * @return data The redemption data
     */
    function getRedemptionData(uint256 tokenId) external view returns (RedemptionData memory data) {
        return redemptions[tokenId];
    }

    /**
     * @dev Check if a token ID is eligible for redemption
     * @param tokenId The NFT token ID
     * @return eligible Whether the token is eligible
     * @return availablePosition The available position for redemption (totalRedemptionsProcessed +
     * totalCancellationsProcessed + USDS balance)
     */
    function isEligibleForRedemption(uint256 tokenId)
        external
        view
        returns (bool eligible, uint256 availablePosition)
    {
        RedemptionData memory redemption = redemptions[tokenId];
        availablePosition = totalRedemptionsProcessed + totalCancellationsProcessed + usds.balanceOf(address(this));

        if (redemption.cancelled) {
            // Cancelled NFTs are eligible when they reach the head (no USDS needed)
            eligible = !redemption.redeemed && redemption.redemptionsBefore < availablePosition;
        } else {
            // Active NFTs need USDS balance
            eligible = !redemption.redeemed && redemption.redemptionsBefore < availablePosition
                && usds.balanceOf(address(this)) >= redemption.redemptionAmount;
        }
    }
}
