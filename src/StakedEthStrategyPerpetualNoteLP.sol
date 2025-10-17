// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IYieldManager} from "./interfaces/IYieldManager.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title ETH Strategy Perpetual Note LP Vault
 * @dev Vault where ESPN/STABLE LP Tokens can be staked to earn more LP tokens
 */
contract StakedEthStrategyPerpetualNoteLP is ERC4626, Ownable2Step {
    address public yieldManager;

    /**
     * @dev Constructor for the vault
     * @param _asset The underlying ERC20 LP token for a STABLE/ESPN pair
     */
    constructor(IERC20 _asset, address _owner)
        ERC4626(_asset)
        ERC20("Staked ETH Strategy Perpetual Note LP", "sESPN-LP")
        Ownable(_owner)
    {
    }

    /**
     * @dev Set the yield manager contract address.
     * Can only be called by the contract owner.
     * @param _yieldManager The new yield manager address.
     */
    function setYieldManager(address _yieldManager) external onlyOwner {
        yieldManager = _yieldManager;
    }

    /**
     * @dev See {IERC4626-totalAssets}.
     */
    function totalAssets() public view virtual override returns (uint256) {
        if (address(yieldManager) != address(0)) {
            return super.totalAssets() + IYieldManager(yieldManager).accrued();
        }
        return super.totalAssets();
    }

    /**
     * dev see {IERC4626-_withdraw}.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        // only need to pull in yield on withdraw - as it's accounted for in totalAssets
        if (address(yieldManager) != address(0)) {
            IYieldManager(yieldManager).remit();
        }
        return super._withdraw(caller, receiver, owner, assets, shares);
    }
}
