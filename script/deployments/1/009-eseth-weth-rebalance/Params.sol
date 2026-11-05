// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Tunable params for the 009 rebalance script. Edit here; an env var of the same name overrides
/// per run (`AMOUNT=50 ROUTE=lido SLIPPAGE_BPS=5 forge script ...`).
library RebalanceParams {
    /// @dev Whole ETH to pull from esETH. 0 = unset: the script reverts unless `AMOUNT` is given.
    uint256 internal constant AMOUNT = 0;
    /// @dev `lido` | `uniswap` | `auto` (Uniswap only if its post-slippage mint beats Lido's).
    string internal constant ROUTE = "auto";
    /// @dev Uniswap route only: max slippage vs the QuoterV2 quote, in bps.
    uint256 internal constant SLIPPAGE_BPS = 10;
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;
}
