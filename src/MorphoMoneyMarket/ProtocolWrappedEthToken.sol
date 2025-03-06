// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface ProtocolWrappedEthTokenFlashMintCallback {
    function onFlashMint(uint256 assets, bytes calldata data);
}

/// @title A wrapper around the borrow token
/// @dev It's required to control liquidation incentives, doesn't return
///      the market strat price, but the STRAT nav. This means the liquidation
///      incentive is always the STRAT premium
contract ProtocolWrappedEthToken is ERC20Permit, Ownable2Step {
    mapping(address => bool) public minters;

    event FlashMint(address sender, uint256 assets);
    event Mint(address to, uint256 assets);
    event Burn(address from, uint256 assets);

    error MinterUnauthorizedAccount(address account);
    error BurnAmountExceedsAllowance(address from, uint256 allowance, uint256 burnAmount);
    error ZeroAssets();

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
    function mint(address to) external onlyMinter {
        _mint(to, msg.value);
        emit Mint(to, msg.value);
    }

    /**
     * @dev Any holder can burn their tokens
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
        emit Burn(msg.sender, msg.value);
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
        payable(from).transfer(amount);
        emit Burn(from, msg.value);
    }

    /**
     * @dev minter only flash loan via an unbacked mint and repay
     */
    function flashMint(uint256 assets, bytes calldata data) external onlyOwner {
        require(assets != 0, ZeroAssets);

        emit FlashMint(msg.sender, assets);

        _mint(msg.sender, assets);

        ProtocolWrappedEthTokenFlashMintCallback(msg.sender).onFlashMint(assets, data);

        safeTransferFrom(msg.sender, address(this), assets);
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
