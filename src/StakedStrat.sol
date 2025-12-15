// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title Staked STRAT Vault
 * @dev Vault where STRAT can be staked to earn rewards. The intention isn't to remit rewards in STRAT, but
 *      reward stakers (MasterChefV2 style) directly in other assets (USDC, ETH, etc.)
 *      Claiming other assets is done via helper contracts we'll deploy/leverage existing building blocks (like merkle)
 *      as we roll them out
 */
contract StakedStrat is ERC4626 {
    /**
     * @dev Constructor for the vault
     * @param stratTokenAddress The underlying ERC20 for the STRAT token
     */
    constructor(address stratTokenAddress)
        ERC4626(IERC20(stratTokenAddress))
        ERC20("Staked STRAT", "sSTRAT")
    {}
}