// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITreasury} from "../../src/interfaces/ITreasury.sol";

contract MockTreasury is ITreasury {
    function withdraw(uint256, address) external pure {
        revert("MockTreasury: StratETHLongBonds should never withdraw from treasury");
    }

    function total() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
