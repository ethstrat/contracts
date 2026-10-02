// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {WrappedStakedEarn} from "./WrappedStakedEarn.sol";
import {IMorphoOracle} from "./interfaces/IMorphoOracle.sol";

/**
 * @title wsEARN / USDS oracle for Morpho Blue
 * @notice Prices 1 wsEARN as (EARN per wsEARN) * PAR, where PAR is a fixed USDS value per EARN. No external
 *         feed and no pool read: nothing to manipulate, nothing to update. The EARN-per-share ratio comes from
 *         the vault itself and only rises, as owner donations vest.
 * @dev Scaling: both tokens are 18 decimals, so Morpho expects price * 1e36. `convertToAssets(1e18)` is EARN
 *      per wsEARN in 18 decimals; `par` is USDS per EARN in 18 decimals; the product is already price * 1e36.
 *      Check: 1e18 * 100e18 = 1e38 = 100 * 1e36.
 *      Reverts while wsEARN cannot be redeemed (vault or staking tripped). On Morpho that blocks borrow,
 *      withdrawCollateral and liquidate until the trip is reset, so nobody can borrow against collateral that
 *      cannot be unwrapped. Repay and supplyCollateral do not read the oracle and keep working.
 */
contract WsEarnOracle is IMorphoOracle {
    WrappedStakedEarn public immutable vault;
    /// @notice USDS per EARN, 18 decimals (e.g. 100e18).
    uint256 public immutable par;

    error ZeroAddress();
    error ZeroPar();
    error RedemptionsFrozen();

    constructor(WrappedStakedEarn vault_, uint256 par_) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (par_ == 0) revert ZeroPar();
        vault = vault_;
        par = par_;
    }

    function price() external view returns (uint256) {
        if (!vault.redeemable()) revert RedemptionsFrozen();
        return vault.convertToAssets(1e18) * par;
    }
}
