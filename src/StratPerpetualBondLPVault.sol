// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title Strat Perpetual LP Vault 
 * @dev Vault where SPB/STABLE LP Tokens can be staked to earn more LP tokens
 */
contract StakedStratPerpetualBondLP is ERC4626 {
    /**
     * @dev Constructor for the vault
     * @param _asset The underlying ERC20 LP token for a STABLE/PBS pair
     */
    constructor(
        IERC20 _asset
    ) ERC4626(_asset) ERC20("Staked ETH Strategy Perpetual Note LP", "sESPN-LP") {
    }
} 