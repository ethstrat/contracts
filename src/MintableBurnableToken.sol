// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title The STRAT Token
 */
contract MintableBurnableToken is ERC20, Ownable2Step {
    mapping(address => bool) public minters;

    error MinterUnauthorizedAccount(address account);

    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {}

    /**
     * @dev Allows only the owner to manage who can mint tokens.
     */
    function manageMinter(address who, bool canMint) external onlyOwner {
        minters[who] = canMint;
    }

    /**
     * @dev Allows only minters to mint new tokens.
     *
     * @param to Address to receive the tokens.
     * @param amount Number of tokens to be minted
     */
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    /**
     * @dev Any holder can burn their tokens
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Allows the owner to approve someone else to burn their tokens.
     *
     * @param from Address whose tokens are to be burned.
     * @param amount Number of tokens to be burned.
     */
    function burnFrom(address from, uint256 amount) external {
        uint256 currentAllowance = allowance(from, msg.sender);
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        _approve(from, msg.sender, currentAllowance - amount);
        _burn(from, amount);
    }

    /**
     * @dev Throws if called by any account other than a minter.
     */
    modifier onlyMinter() {
        if (!minters[msg.sender]) {
            revert MinterUnauthorizedAccount(msg.sender);
        }
        _;
    }
}
