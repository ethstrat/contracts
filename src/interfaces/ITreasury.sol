// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface ITreasury {
    function withdraw(uint256 amount, address to) external;
    function total() external view returns (uint256);
}
