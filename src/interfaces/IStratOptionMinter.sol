// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStratOptionMinter {
    function mint(
        address to,
        uint256 _strikeAmount,
        uint256 _notionalUnderlyingAmount,
        uint256 _notionalUSDAmount,
        uint256 _expiry,
        uint256 _timelock
    ) external;
}
