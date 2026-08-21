// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract StryToken is ERC20, Ownable {
    error LengthMismatch();

    constructor(address initialOwner) ERC20("ETH Strategy Yield", "STRY") Ownable(initialOwner) {}

    function mintBatch(address[] calldata to, uint256[] calldata amounts) external onlyOwner {
        if (to.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < to.length; ++i) {
            _mint(to[i], amounts[i]);
        }
    }
}
