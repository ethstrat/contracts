// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITreasury} from "../../src/interfaces/ITreasury.sol";

contract MockTreasury is ITreasury {
    bool public isWithdrawAllowed = false;

    function withdraw(uint256 amount, address to) external {
        if (!isWithdrawAllowed) {
            revert("MockTreasury: Withdrawal not allowed");
        }

        payable(to).transfer(amount);
    }

    function setWithdrawAllowed(bool allowed) external {
        isWithdrawAllowed = allowed;
    }

    function total() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
