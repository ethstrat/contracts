pragma solidity ^0.8.0;

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title IOracle
/// @dev Oracle interface used throughout the protocol.
interface IOracle {
    /// @notice the price of 1 base token quoted in 1 of quote token
    /// @dev It corresponds to the price of 10**(base token decimals) quoted in
    /// 10**(quote token decimals)
    function price() external view returns (uint256);

    function baseTokenDecimals() external view returns (uint8);
    function quoteTokenDecimals() external view returns (uint8);
}
