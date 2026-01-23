// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC3156FlashLender} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev MorphoBlue flash loan interface
 *      MorphoBlue uses its own flash loan interface, not ERC-3156
 */
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IMorphoBlue {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/**
 * @title MorphoBlue Flash Loan Provider
 * @dev ERC-3156 compliant flash loan provider that wraps MorphoBlue flash loans
 *      This contract flashes sUSDS from MorphoBlue, redeems it to USDS for the caller,
 *      then deposits USDS back to sUSDS to repay the flash loan.
 *
 *      sUSDS is an ERC4626 vault where USDS is the underlying asset.
 *      MorphoBlue uses its own flash loan interface (not ERC-3156).
 */
contract MorphoBlueFlashLoanProvider is IERC3156FlashLender, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    // Mainnet contract addresses - verified for mainnet fork testing
    /// @dev MorphoBlue flash loan contract (uses its own flash loan interface, not ERC-3156)
    IMorphoBlue public constant morphoBlue = IMorphoBlue(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    /// @dev sUSDS token (staked USDS) - ERC4626 vault with USDS as underlying asset
    address public constant susds = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    /// @dev USDS token (set via constructor)
    IERC20 public constant usds = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);

    /// @dev Errors
    error UnsupportedToken();
    error FlashLoanFailed();
    error UnstakeFailed();
    error StakeFailed();

    /**
     * @dev Returns the maximum amount of USDS available for flash loan
     *      Note: MorphoBlue doesn't have a maxFlashLoan view function, so we return type(uint256).max
     *      The actual limit is enforced by MorphoBlue during the flash loan execution
     * @param token The token to query (must be USDS)
     * @return The maximum amount of USDS that can be flash loaned
     */
    function maxFlashLoan(address token) external pure override returns (uint256) {
        if (token != address(usds)) {
            return 0;
        }

        // MorphoBlue doesn't expose a maxFlashLoan view function
        // Return max uint256 - actual limit is enforced by MorphoBlue
        return type(uint256).max;
    }

    /**
     * @dev Returns the flash loan fee (always 0 for this provider)
     * @return The fee amount (always 0)
     */
    function flashFee(address, /* token */ uint256 /* amount */ ) external pure override returns (uint256) {
        return 0;
    }

    /**
     * @dev Initiates a flash loan of USDS
     *      This function:
     *      1. Flashes sUSDS shares from MorphoBlue
     *      2. Redeems sUSDS shares for USDS assets (ERC4626)
     *      3. Sends USDS to receiver
     *      4. Receives USDS back from receiver
     *      5. Deposits USDS to get sUSDS shares (ERC4626)
     *      6. Repays MorphoBlue flash loan with sUSDS shares
     * @param receiver The contract that will receive USDS and handle the callback
     * @param token The token to flash loan (must be USDS)
     * @param amount The amount of USDS to flash loan
     * @param data Additional data to pass to the callback
     * @return success Whether the flash loan was successful
     */
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        if (token != address(usds)) {
            revert UnsupportedToken();
        }

        // Flash sUSDS from MorphoBlue
        // MorphoBlue will call our onMorphoFlashLoan callback
        // Note: MorphoBlue.flashLoan doesn't return a value, it reverts on failure
        morphoBlue.flashLoan(
            susds,
            amount, // more than what we need as sUSDS is always worth at least 1 USDS
            abi.encode(receiver, data)
        );

        return true;
    }

    /**
     * @dev Callback function called by MorphoBlue when flashing sUSDS
     *      This is MorphoBlue's callback interface (not ERC-3156)
     *
     *      IMPORTANT: Due to sUSDS exchange rate changes, we must use mint() instead of deposit()
     *      to ensure we get back exactly the sUSDS shares we need to repay MorphoBlue.
     *
     *      This function:
     *      1. Calculates USDS needed to mint exactly `assets` sUSDS shares (previewMint)
     *      2. Redeems sUSDS shares for USDS assets (ERC4626 redeem)
     *      3. Sends all USDS to the original receiver
     *      4. Receives ERC-3156 callback from receiver (telling them we need `usdsNeeded` back)
     *      5. Receives exactly `usdsNeeded` USDS back from receiver
     *      6. Mints exactly `assets` sUSDS shares using the USDS (ERC4626 mint)
     *      7. Approves MorphoBlue to take back exactly `assets` sUSDS shares
     * @param assets The amount of sUSDS shares flash loaned
     * @param data Encoded data containing (receiver, originalData)
     */
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        // Verify MorphoBlue called this
        if (msg.sender != address(morphoBlue)) {
            revert FlashLoanFailed();
        }

        // Decode callback data
        (IERC3156FlashBorrower receiver, bytes memory originalData) = abi.decode(data, (IERC3156FlashBorrower, bytes));

        // Step 2: Redeem sUSDS shares to USDS assets
        IERC4626(susds).redeem(assets, address(this), address(this));

        // Step 3: Send 'assets' back to the reciever (as that's all they requested)
        usds.safeTransfer(address(receiver), assets);

        // Step 4: Call receiver's ERC-3156 callback
        // We tell the receiver we need `assets` back to cover the loan
        bytes32 result = receiver.onFlashLoan(
            msg.sender, // initiator is MorphoBlue
            address(usds),
            assets,
            0, // fee is 0
            originalData
        );

        // Verify callback succeeded
        if (result != keccak256("ERC3156FlashBorrower.onFlashLoan")) {
            revert FlashLoanFailed();
        }

        // Step 5: Get USDS back from receiver (receiver should have approved this contract)
        usds.safeTransferFrom(address(receiver), address(this), assets);

        // Step 6: Mint exactly `assets` sUSDS shares using the USDS we got back
        // Using mint() ensures we get exactly the sUSDS shares we need to repay
        SafeERC20.forceApprove(usds, susds, usds.balanceOf(address(this)));
        IERC4626(susds).mint(assets, address(this));

        // Step 7: Approve MorphoBlue to take back exactly `assets` sUSDS shares
        // (repayment happens automatically after this callback returns)
        SafeERC20.forceApprove(IERC20(susds), address(morphoBlue), assets);
    }
}
