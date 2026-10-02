// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Morpho Blue oracle interface. `price()` is the value of 1 unit of collateral token in loan token,
///         scaled by 1e36 * 10^(loanDecimals - collateralDecimals). For two 18-decimal tokens: price * 1e36.
interface IMorphoOracle {
    function price() external view returns (uint256);
}
