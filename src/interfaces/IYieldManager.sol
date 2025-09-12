// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/**
 * @title IYieldManager
 * @notice Interface for the yield manager
 * @dev The yield manager is responsible for accounting and remitting accrued yield to
 *      various vaults (OZ erc4626 implementations, where sending tokens should
 *      increase the totalAssets)
 */
interface IYieldManager {
    function remit() external;
    function accrued() external view returns (uint256);
}
