// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title A simple mintable and burnable Ghost Strat Token with ERC20Permit and Ownable2Step
contract GhostStratToken is ERC20Permit, Ownable2Step {
    constructor(address owner)
        ERC20("Ghost Strat Token", "gSTRAT")
        ERC20Permit("Ghost Strat Token")
        Ownable(owner)
    {}

    /// @dev Allows only the owner to mint new tokens.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @dev Allows anyone to burn their own tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
