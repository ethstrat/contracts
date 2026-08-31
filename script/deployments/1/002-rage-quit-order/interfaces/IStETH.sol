// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IStETH is IERC20 {
    function submit(address referral) external payable returns (uint256);
}
