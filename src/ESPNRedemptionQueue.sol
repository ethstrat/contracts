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

    /// @dev Total number of redemptions to date (increments on each NFT mint)
    uint256 public totalRedemptions;

    /// @dev Cumulative dollar value of all redemptions queued (in USDS terms)
    uint256 public totalRedemptionsValue;

    /// @dev Total processed redemptions (cumulative dollar value in USDS terms)
    uint256 public totalProcessedRedemptions;

    /// @dev Address authorized to sweep USDS
    address public immutable sweeper;

    /// @dev Token ID counter
    uint256 private _tokenIdCounter;

    /// @dev Mapping from token ID to redemption data
    struct RedemptionData {
        uint256 redemptionsBefore; // Cumulative dollar value of redemptions that came before this NFT (in USDS terms)
        uint256 dollarBacking;     // Dollar value of ESPN burned (in USDS terms)
        bool redeemed;             // Whether this NFT has been redeemed
        bool cancelled;            // Whether this redemption has been cancelled
    }

    mapping(uint256 tokenId => RedemptionData) public redemptions;

    /// @dev Flash loan callback data
    struct FlashLoanCallbackData {
        address user;
        uint256 tokenId;
        uint256 dollarBacking;
    }

    /// @dev Temporary storage for flash loan callback data (cleared after use)
    FlashLoanCallbackData private _activeFlashLoan;

    /// @dev Events
    event RedemptionQueued(
        address indexed user,
        uint256 indexed tokenId,
        uint256 espnBurned,
        uint256 dollarBacking,
        uint256 redemptionsBefore
    );
    event RedemptionFulfilled(
        address indexed user,
        uint256 indexed tokenId,
        uint256 usdsAmount
    );
    event RedemptionCancelled(
        address indexed user,
        uint256 indexed tokenId,
        uint256 espnReturned
    );
    event USDSwept(address indexed sweeper, uint256 amount);

    /// @dev Errors
    error NotEligibleForRedemption(uint256 tokenId);
    error AlreadyRedeemed(uint256 tokenId);
    error AlreadyCancelled(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);
    error InsufficientUSDS();
    error FlashLoanFailed();
    error InvalidSweeper();

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
    }

    /**
     * @dev Queue a redemption by burning ESPN and minting an NFT
     * @param espnAmount The amount of ESPN to burn
     * @return tokenId The minted NFT token ID
     */
    function queueRedemption(uint256 espnAmount) external nonReentrant returns (uint256) {
        if (espnAmount == 0) revert();

        // Calculate dollar backing using ERC4626 math
        // This is the amount of USDS that would be received if redeeming the ESPN
        uint256 dollarBacking = espn.previewRedeem(espnAmount);

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
            redemptionsBefore: totalRedemptionsValue,
            dollarBacking: dollarBacking,
            redeemed: false,
            cancelled: false
        });

        // Increment counters
        totalRedemptions++;
        totalRedemptionsValue += dollarBacking;

        emit RedemptionQueued(msg.sender, tokenId, espnAmount, dollarBacking, totalRedemptionsValue - dollarBacking);
        return tokenId;
    }

    /**
     * @dev Redeem an NFT for USDS if eligible
     * @param tokenId The NFT token ID to redeem
     */
    function redeem(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);
        if (redemptions[tokenId].cancelled) revert AlreadyCancelled(tokenId);

        RedemptionData storage redemption = redemptions[tokenId];

        // Check eligibility: redemptionsBefore < (totalProcessedRedemptions + USDS balance)
        uint256 availableUSDS = totalProcessedRedemptions + usds.balanceOf(address(this));
        if (redemption.redemptionsBefore >= availableUSDS) {
            revert NotEligibleForRedemption(tokenId);
        }

        // Check if we have enough USDS
        if (usds.balanceOf(address(this)) < redemption.dollarBacking) {
            revert InsufficientUSDS();
        }

        // Mark as redeemed
        redemption.redeemed = true;

        // Update total processed redemptions
        totalProcessedRedemptions += redemption.dollarBacking;

        // Transfer USDS to the user
        usds.safeTransfer(msg.sender, redemption.dollarBacking);

        // Burn the NFT
        _burn(tokenId);

        emit RedemptionFulfilled(msg.sender, tokenId, redemption.dollarBacking);
    }

    /**
     * @dev Cancel a redemption by flashing USDS, minting ESPN, and returning it to the user
     * 
     * This function initiates a flash loan to cancel a redemption. The flash loan provider
     * must call executeOperation on this contract, which will:
     * 1. Use the flashed USDS to deposit into ESPN (minting ESPN shares)
     * 2. Transfer the minted ESPN to the user
     * 3. Repay the flash loan using USDS received from ESPN (as manager)
     * 
     * IMPORTANT: The ESPN manager must be set to this contract for cancellation to work.
     * When USDS is deposited into ESPN, ESPN sends it to the manager (this contract),
     * allowing us to repay the flash loan.
     * 
     * @param tokenId The NFT token ID to cancel
     * @param flashLoanProvider The address of the flash loan provider contract
     * @param flashLoanAmount The amount of USDS to flash loan (should be >= dollarBacking + premium)
     * @param flashLoanCalldata The calldata to call on the flash loan provider
     */
    function cancelRedemption(
        uint256 tokenId,
        address flashLoanProvider,
        uint256 flashLoanAmount,
        bytes calldata flashLoanCalldata
    ) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (redemptions[tokenId].redeemed) revert AlreadyRedeemed(tokenId);
        if (redemptions[tokenId].cancelled) revert AlreadyCancelled(tokenId);

        RedemptionData storage redemption = redemptions[tokenId];
        
        if (flashLoanAmount < redemption.dollarBacking) {
            revert InsufficientUSDS();
        }

        // Mark as cancelled before flash loan to prevent reentrancy
        redemption.cancelled = true;

        // Prepare and store callback data
        _activeFlashLoan = FlashLoanCallbackData({
            user: msg.sender,
            tokenId: tokenId,
            dollarBacking: redemption.dollarBacking
        });
        
        // Execute flash loan by calling the provider
        // The exact interface depends on your flash loan provider
        // This is a generic approach - adjust the call based on your provider's interface
        (bool success,) = flashLoanProvider.call(flashLoanCalldata);
        
        // Clear the temporary storage
        delete _activeFlashLoan;
        
        if (!success) revert FlashLoanFailed();

        // Note: The NFT will be burned in executeOperation after successful completion
    }

    /**
     * @dev Callback function for flash loan providers
     * 
     * This function is called by the flash loan provider after lending USDS.
     * It implements a standard flash loan callback interface compatible with:
     * - Aave V2/V3
     * - Other standard flash loan providers
     * 
     * The function:
     * 1. Uses flashed USDS to deposit into ESPN (minting ESPN shares)
     * 2. ESPN sends USDS to manager (this contract) as part of deposit
     * 3. Transfers minted ESPN to the user
     * 4. Repays flash loan using USDS received from ESPN
     * 
     * @param assets The assets that were flash loaned
     * @param amounts The amounts that were flash loaned
     * @param premiums The premiums to pay back
     * @param initiator The initiator of the flash loan (should be this contract)
     * @param params Encoded FlashLoanCallbackData (optional, can use _activeFlashLoan if empty)
     * @return success Whether the operation was successful
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        // Verify this contract initiated the flash loan
        if (initiator != address(this)) revert();

        // Get callback data from params or temporary storage
        FlashLoanCallbackData memory data;
        if (params.length > 0) {
            data = abi.decode(params, (FlashLoanCallbackData));
        } else {
            data = _activeFlashLoan;
        }

        // Verify the asset is USDS
        if (assets.length == 0 || assets[0] != address(usds)) revert();
        
        uint256 flashLoanAmount = amounts[0];
        uint256 premium = premiums[0];
        uint256 totalToRepay = flashLoanAmount + premium;

        // Verify the redemption hasn't been processed
        RedemptionData storage redemption = redemptions[data.tokenId];
        if (!redemption.cancelled) revert(); // Should be marked as cancelled in cancelRedemption

        // Use flashed USDS to mint ESPN by depositing into ESPN
        // NOTE: The ESPN manager must be set to this contract for this to work properly.
        // When USDS is deposited, ESPN's _deposit function sends it to the manager (this contract),
        // allowing us to repay the flash loan.
        usds.forceApprove(address(espn), flashLoanAmount);
        uint256 espnMinted = espn.deposit(flashLoanAmount, address(this));
        usds.forceApprove(address(espn), 0);

        // ESPN sends the USDS to the manager (this contract) as part of _deposit
        // Verify we have enough USDS to repay (including premium)
        uint256 usdsBalance = usds.balanceOf(address(this));
        if (usdsBalance < totalToRepay) {
            revert InsufficientUSDS();
        }

        // Return minted ESPN to the user
        IERC20(address(espn)).safeTransfer(data.user, espnMinted);

        // Approve the flash loan provider to take back the USDS + premium
        usds.forceApprove(msg.sender, totalToRepay);

        // Burn the NFT
        _burn(data.tokenId);

        emit RedemptionCancelled(data.user, data.tokenId, espnMinted);
        
        return true;
    }

    /**
     * @dev Helper function to generate flash loan calldata for Aave V3
     * @param tokenId The NFT token ID to cancel
     * @param flashLoanAmount The amount of USDS to flash loan
     * @param premium The premium to pay (typically 0.09% = 9e14 for Aave)
     * @return The calldata to pass to cancelRedemption
     */
    function generateAaveV3FlashLoanCalldata(
        uint256 tokenId,
        uint256 flashLoanAmount,
        uint256 premium
    ) external view returns (bytes memory) {
        RedemptionData memory redemption = redemptions[tokenId];
        uint256 totalAmount = flashLoanAmount + premium;
        
        address[] memory assets = new address[](1);
        assets[0] = address(usds);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;
        
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0; // No debt mode
        
        // Encode callback data (optional, we also use _activeFlashLoan)
        bytes memory params = abi.encode(FlashLoanCallbackData({
            user: ownerOf(tokenId),
            tokenId: tokenId,
            dollarBacking: redemption.dollarBacking
        }));
        
        // Generate Aave V3 flash loan calldata
        return abi.encodeWithSignature(
            "flashLoan(address,address[],uint256[],uint256[],address,bytes,uint16)",
            address(this),  // receiverAddress
            assets,         // assets
            amounts,        // amounts
            modes,          // modes
            address(this),  // onBehalfOf
            params,         // params
            0              // referralCode
        );
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
     * @return availableUSDS The available USDS for redemption
     */
    function isEligibleForRedemption(uint256 tokenId) external view returns (bool eligible, uint256 availableUSDS) {
        RedemptionData memory redemption = redemptions[tokenId];
        availableUSDS = totalProcessedRedemptions + usds.balanceOf(address(this));
        eligible = !redemption.redeemed 
                && !redemption.cancelled 
                && redemption.redemptionsBefore < availableUSDS
                && usds.balanceOf(address(this)) >= redemption.dollarBacking;
    }
}
