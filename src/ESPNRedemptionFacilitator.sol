// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {EthStrategyPerpetualNote} from "./EthStrategyPerpetualNote.sol";

/**
 * @title ESPN Redemption Facilitator
 * @dev Contract to facilitate redeem and withdraw operations atop ESPN
 *
 * This contract allows users to redeem or withdraw from ESPN by:
 * 1. Calculating the required USDS amount using previewWithdraw/previewRedeem
 * 2. Transferring the required USDS from the caller to ESPN
 * 3. Calling the appropriate ESPN method (redeem/withdraw) with the caller as receiver
 *
 * The caller must have sufficient USDS balance and allowance to ESPN for this to work.
 */
contract ESPNRedemptionFacilitator {
    using SafeERC20 for IERC20;

    /// @dev The ESPN contract instance
    EthStrategyPerpetualNote public immutable espn;

    /// @dev The underlying USDS token
    IERC20 public immutable usds;

    /// @dev The address authorized to sweep USDS from this contract
    address public immutable sweeper;

    /**
     * @dev Constructor
     * @param _espn The ESPN contract address
     * @param _sweeper The address authorized to sweep USDS from this contract
     */
    constructor(address _espn, address _sweeper) {
        espn = EthStrategyPerpetualNote(_espn);
        usds = IERC20(espn.asset());
        sweeper = _sweeper;
    }

    /**
     * @dev Redeem ESPN shares for underlying assets with USDS payment.
     * @param shares The number of ESPN shares to redeem
     * @param receiver The address to receive the underlying assets
     * @param owner The account whose ESPN shares will be redeemed
     *
     * This function:
     * 1. Calculates the required USDS using previewRedeem
     * 2. Transfers USDS from caller to ESPN
     * 3. Calls ESPN.redeem with the provided receiver and owner
     *
     * Requirements:
     * - The caller must have sufficient USDS balance and allowance to this contract
     * - The owner must have approved this contract to spend their ESPN shares
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        // Short-circuit for zero shares
        if (shares == 0) return 0;

        // Transfer the required USDS (only the delta needed)
        _transferUsdsRequired(espn.previewRedeem(shares));

        // Call ESPN.redeem with the provided receiver and owner
        // Note: owner must have approved this contract to spend their ESPN shares
        return espn.redeem(shares, receiver, owner);
    }

    /**
     * @dev Withdraw underlying assets from ESPN with USDS payment.
     * @param assets The amount of underlying assets to withdraw
     * @param receiver The address to receive the underlying assets
     * @param owner The account whose ESPN shares will be burned
     *
     * This function:
     * 1. Calculates the required USDS using previewWithdraw
     * 2. Transfers USDS from caller to ESPN
     * 3. Calls ESPN.withdraw with the provided receiver and owner
     *
     * Requirements:
     * - The caller must have sufficient USDS balance and allowance to this contract
     * - The owner must have approved this contract to spend their ESPN shares
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        // Short-circuit for zero assets
        if (assets == 0) return 0;

        // Transfer the required USDS (only the delta needed)
        _transferUsdsRequired(espn.previewWithdraw(assets));

        // Call ESPN.withdraw with the provided receiver and owner
        // Note: owner must have approved this contract to spend their ESPN shares
        return espn.withdraw(assets, receiver, owner);
    }

    /**
     * @dev Private helper to transfer only the delta USDS required to ESPN
     * @param usdsRequired The total USDS amount required for the operation
     */
    function _transferUsdsRequired(uint256 usdsRequired) private {
        // Calculate how much USDS ESPN currently has
        uint256 espnCurrentBalance = usds.balanceOf(address(espn));

        // Calculate the delta needed (only send what ESPN doesn't already have)
        uint256 usdsDelta = usdsRequired > espnCurrentBalance ? usdsRequired - espnCurrentBalance : 0;

        // Check facilitator has sufficient USDS balance for the delta
        uint256 facilitatorBalance = usds.balanceOf(address(this));
        if (facilitatorBalance < usdsDelta) {
            revert ERC4626.ERC4626ExceededMaxDeposit(address(this), usdsDelta, facilitatorBalance);
        }

        // Transfer only the delta USDS to ESPN
        if (usdsDelta > 0) {
            usds.safeTransfer(address(espn), usdsDelta);
        }
    }

    /**
     * @dev Sweep USDS balance from this contract to the sweeper address
     * @dev Only callable by the designated sweeper address
     */
    function sweepUSDS() external {
        if (msg.sender != sweeper) {
            revert("Unauthorized");
        }

        uint256 balance = usds.balanceOf(address(this));
        if (balance > 0) {
            usds.safeTransfer(sweeper, balance);
        }
    }
}
