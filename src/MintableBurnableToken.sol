// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title Base token for CDT and STRAT
 */
contract MintableBurnableToken is ERC20Permit, Ownable2Step {
    mapping(address => bool) public minters;

    error MinterUnauthorizedAccount(address account);

    constructor(string memory name, string memory symbol, address owner)
        ERC20(name, symbol)
        ERC20Permit(name)
        Ownable(owner)
    {}

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
        _spendAllowance(from, msg.sender, amount);
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
