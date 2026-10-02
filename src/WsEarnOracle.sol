// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IMorphoOracle} from "./interfaces/IMorphoOracle.sol";

/**
 * @title wsEARN / USDS oracle for Morpho Blue
 * @notice Prices 1 wsEARN as (EARN per wsEARN) * PAR, where PAR is a fixed USDS value per EARN. No external
 *         feed and no pool read: nothing to manipulate, nothing to update. The EARN-per-share ratio comes from
 *         the vault itself and only rises (via owner donations).
 * @dev Scaling: both tokens are 18 decimals, so Morpho expects price * 1e36. `convertToAssets(1e18)` is EARN
 *      per wsEARN in 18 decimals; `par` is USDS per EARN in 18 decimals; the product is already price * 1e36.
 *      Check: 1e18 * 100e18 = 1e38 = 100 * 1e36.
 */
contract WsEarnOracle is IMorphoOracle {
    IERC4626 public immutable vault;
    /// @notice USDS per EARN, 18 decimals (e.g. 100e18).
    uint256 public immutable par;

    error ZeroAddress();
    error ZeroPar();

    constructor(IERC4626 vault_, uint256 par_) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (par_ == 0) revert ZeroPar();
        vault = vault_;
        par = par_;
    }

    function price() external view returns (uint256) {
        return vault.convertToAssets(1e18) * par;
    }
}
