// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EthStrategyPerpetualNote} from "./EthStrategyPerpetualNote.sol";

/**
 * @title Sky Flash Loan Interface
 * @dev Minimal interface for Sky protocol flash loans
 */
interface ISkyFlashLoan {
    /**
     * @dev Initiate a flash loan
     * @param receiver The contract that will receive the flash loan and handle the callback
     * @param token The token to flash loan (should be USDS)
     * @param amount The amount to flash loan
     * @param data Additional data to pass to the callback
     */
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external;
}

/**
 * @title ESPN Redemption Queue
 * @dev NFT contract that represents a queue position for ESPN redemption
 *
 * Users burn ESPN tokens to mint an NFT that represents their position in the redemption queue.
 * Each NFT tracks the total redemptions that came before it and the dollar backing of the burned ESPN.
 * NFT holders can redeem when their position in the queue is eligible, or cancel their redemption.
 */
contract ESPNRedemptionQueue is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The ESPN contract
    EthStrategyPerpetualNote public immutable espn;

    /// @dev The USDS token (underlying asset of ESPN)
    IERC20 public immutable usds;

    /// @dev Sky flash loan contract for USDS
    ISkyFlashLoan public immutable skyFlashLoan;

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
        uint256 redemptionAmount; // Dollar value of ESPN burned (in USDS terms)
        bool redeemed; // Whether this NFT has been redeemed
        bool cancelled; // Whether this redemption has been cancelled
    }

    mapping(uint256 tokenId => RedemptionData) public redemptions;

    /// @dev Flash loan callback data
    struct FlashLoanCallbackData {
        address user;
        uint256 tokenId;
        uint256 redemptionAmount;
    }

    /// @dev Temporary storage for flash loan callback data (cleared after use)
    FlashLoanCallbackData private _activeFlashLoan;

    /// @dev Events
    event RedemptionQueued(
        address indexed user,
        uint256 indexed tokenId,
        uint256 espnBurned,
        uint256 redemptionAmount,
        uint256 redemptionsBefore
    );
    event RedemptionFulfilled(address indexed user, uint256 indexed tokenId, uint256 usdsAmount);
    event RedemptionCancelled(address indexed user, uint256 indexed tokenId, uint256 espnReturned);
    event USDSwept(address indexed sweeper, uint256 amount);

    /// @dev Errors
    error NotEligibleForRedemption(uint256 tokenId);
    error AlreadyRedeemed(uint256 tokenId);
    error AlreadyCancelled(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);
    error InsufficientUSDS();
    error FlashLoanFailed();
    error InvalidSweeper();
    error ZeroAmount();
    error InvalidFlashLoanInitiator();
    error InvalidFlashLoanAsset();
    error RedemptionNotCancelled();

    /**
     * @dev Constructor
     * @param _espn The ESPN contract address
     * @param _skyFlashLoan The Sky flash loan contract address for USDS
     * @param _sweeper The address authorized to sweep USDS
     * @param _owner The owner of the contract
     */
    constructor(address _espn, address _skyFlashLoan, address _sweeper, address _owner)
        ERC721("ESPN Redemption Queue", "ESPN-RQ")
        Ownable(_owner)
    {
        if (_sweeper == address(0)) revert InvalidSweeper();
        if (_skyFlashLoan == address(0)) revert InvalidSweeper(); // Reuse error for zero address
        espn = EthStrategyPerpetualNote(_espn);
        usds = IERC20(espn.asset());
        skyFlashLoan = ISkyFlashLoan(_skyFlashLoan);
        sweeper = _sweeper;
        _tokenIdCounter = 1;
    }

    /**
     * @dev Queue a redemption by burning ESPN and minting an NFT
     * @param espnAmount The amount of ESPN to burn
     * @return tokenId The minted NFT token ID
     */
    function queueRedemption(uint256 espnAmount) external nonReentrant returns (uint256) {
        if (espnAmount == 0) revert ZeroAmount();

        // Calculate redemption amount using ERC4626 math
        // This is the amount of USDS that would be received if redeeming the ESPN
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Transfer ESPN from the user (user must have approved this contract)
        IERC20(address(espn)).safeTransferFrom(msg.sender, address(this), espnAmount);
        // Burn the ESPN
        espn.burn(espnAmount);

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

        emit RedemptionQueued(msg.sender, tokenId, espnAmount, redemptionAmount, totalQueued - redemptionAmount);
        return tokenId;
    }

    /**
     * @dev Redeem NFTs for USDS if eligible
     * @param tokenIds Array of NFT token IDs to redeem (processed in order)
     */
    function redeem(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // Check ownership
            if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);

            // Check if already redeemed
            if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);

            RedemptionData storage redemption = redemptions[tokenId];

            // Check eligibility: redemptionsBefore < (totalRedemptionsProcessed + totalCancellationsProcessed + USDS
            // balance)
            uint256 availablePosition =
                totalRedemptionsProcessed + totalCancellationsProcessed + usds.balanceOf(address(this));
            if (redemption.redemptionsBefore >= availablePosition) {
                revert NotEligibleForRedemption(tokenId);
            }

            if (redemption.cancelled) {
                // Cancelled NFT: add to totalCancellationsProcessed and burn (no USDS transfer)
                redemption.redeemed = true;
                totalCancellationsProcessed += redemption.redemptionAmount;
                _burn(tokenId);
                emit RedemptionFulfilled(msg.sender, tokenId, 0);
            } else {
                // Active NFT: check USDS, transfer, mark as redeemed, and burn
                if (usds.balanceOf(address(this)) < redemption.redemptionAmount) {
                    revert InsufficientUSDS();
                }

                redemption.redeemed = true;
                totalRedemptionsProcessed += redemption.redemptionAmount;
                usds.safeTransfer(msg.sender, redemption.redemptionAmount);
                _burn(tokenId);
                emit RedemptionFulfilled(msg.sender, tokenId, redemption.redemptionAmount);
            }
        }
    }

    /**
     * @dev Cancel a redemption by flashing USDS via Sky, minting ESPN, and returning it to the user
     *
     * This function initiates a Sky flash loan to cancel a redemption. Sky will call
     * onFlashLoan on this contract, which will:
     * 1. Use the flashed USDS to deposit into ESPN (minting ESPN shares)
     * 2. Transfer the minted ESPN to the user
     * 3. Repay the flash loan using USDS received from ESPN (as manager)
     *
     * IMPORTANT: The ESPN manager must be set to this contract for cancellation to work.
     * When USDS is deposited into ESPN, ESPN sends it to the manager (this contract),
     * allowing us to repay the flash loan.
     *
     * @param tokenId The NFT token ID to cancel
     */
    function cancelRedemption(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);
        if (redemptions[tokenId].cancelled) revert AlreadyCancelled(tokenId);

        RedemptionData storage redemption = redemptions[tokenId];

        // Mark as cancelled before flash loan to prevent reentrancy
        redemption.cancelled = true;

        // No need to update redemptionsBefore for other NFTs - they will naturally
        // advance when cancelled NFTs are processed via redeem()
        // totalQueued remains unchanged (always growing)

        // Prepare and store callback data
        _activeFlashLoan =
            FlashLoanCallbackData({user: msg.sender, tokenId: tokenId, redemptionAmount: redemption.redemptionAmount});

        // Encode callback data to pass to Sky flash loan
        bytes memory callbackData = abi.encode(
            FlashLoanCallbackData({user: msg.sender, tokenId: tokenId, redemptionAmount: redemption.redemptionAmount})
        );

        // Initiate Sky flash loan
        skyFlashLoan.flashLoan(
            address(this), // receiver (this contract)
            address(usds), // token (USDS)
            redemption.redemptionAmount, // amount
            callbackData // data to pass to callback
        );

        // Clear the temporary storage
        delete _activeFlashLoan;
    }

    /**
     * @dev Callback function for Sky flash loans
     *
     * This function is called by Sky after lending USDS. It:
     * 1. Uses flashed USDS to deposit into ESPN (minting ESPN shares)
     * 2. ESPN sends USDS to manager (this contract) as part of deposit
     * 3. Transfers minted ESPN to the user
     * 4. Repays flash loan using USDS received from ESPN
     *
     * IMPORTANT: The ESPN manager must be set to this contract for this to work properly.
     * When USDS is deposited, ESPN's _deposit function sends it to the manager (this contract),
     * allowing us to repay the flash loan.
     *
     * @param token The token that was flash loaned (should be USDS)
     * @param amount The amount that was flash loaned
     * @param fee The fee/premium to pay back (Sky typically charges 0 for USDS)
     * @param data Encoded FlashLoanCallbackData
     * @return success Whether the operation was successful
     */
    function onFlashLoan(address token, uint256 amount, uint256 fee, bytes calldata data) external returns (bool) {
        // Verify Sky flash loan contract called this
        if (msg.sender != address(skyFlashLoan)) revert InvalidFlashLoanInitiator();

        // Verify the token is USDS
        if (token != address(usds)) revert InvalidFlashLoanAsset();

        // Get callback data from params or temporary storage
        FlashLoanCallbackData memory callbackData;
        if (data.length > 0) {
            callbackData = abi.decode(data, (FlashLoanCallbackData));
        } else {
            callbackData = _activeFlashLoan;
        }

        uint256 totalToRepay = amount + fee;

        // Verify the redemption hasn't been processed
        RedemptionData storage redemption = redemptions[callbackData.tokenId];
        if (!redemption.cancelled) revert RedemptionNotCancelled();

        // Use flashed USDS to mint ESPN by depositing into ESPN
        // NOTE: The ESPN manager must be set to this contract for this to work properly.
        // When USDS is deposited, ESPN's _deposit function sends it to the manager (this contract),
        // allowing us to repay the flash loan.
        SafeERC20.forceApprove(usds, address(espn), amount);
        uint256 espnMinted = espn.deposit(amount, address(this));
        SafeERC20.forceApprove(usds, address(espn), 0);

        // ESPN sends the USDS to the manager (this contract) as part of _deposit
        // Verify we have enough USDS to repay (including fee)
        uint256 usdsBalance = usds.balanceOf(address(this));
        if (usdsBalance < totalToRepay) {
            revert InsufficientUSDS();
        }

        // Return minted ESPN to the user
        IERC20(address(espn)).safeTransfer(callbackData.user, espnMinted);

        // Approve Sky flash loan provider to take back the USDS + fee
        // msg.sender is the Sky flash loan contract that called this callback
        SafeERC20.forceApprove(usds, msg.sender, totalToRepay);

        // NFT is NOT burned here - it stays in queue and will be processed via redeem()
        // The cancelled flag is already set in cancelRedemption()

        emit RedemptionCancelled(callbackData.user, callbackData.tokenId, espnMinted);

        return true;
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
