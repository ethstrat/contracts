// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MorphoIOracle} from "../interfaces/MorphoIOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/// @title General purpose oracle used for pricing STRAT for the morpho borrow/lend
/// @dev Implements the morpho IOracle interface, gives the NAV value of strat
///      with a discount
contract TreasuryNavOracle is MorphoIOracle {
    ITreasury public immutable treasury;
    IERC20 public immutable cdtToken;
    IERC20 public immutable stratToken;
    IOracle public immutable ethUsdOracle;
    uint256 public immutable oracleScalingFactor;

    /// @dev discount scaled by 1e18
    uint256 public discountFactor;

    constructor(
        address _treasury,
        address _cdtToken,
        address _stratToken,
        address _ethUsdOracle,
        uint256 _discountFactor
    ) {
        treasury = ITreasury(_treasury);
        cdtToken = IERC20(_cdtToken);
        discountFactor = _discountFactor;
        oracleScalingFactor = (10 ** ethUsdOracle.quoteTokenDecimals());
    }

    function price() external view override returns (uint256) {
        uint256 totalDebt = cdtToken.totalSupply();
        uint256 treasuryETHInUSD = treasury.total() * ethUsdOracle.price() / oracleScalingFactor;
        uint256 nav = treasuryETHInUSD - cdtToken.totalSupply();
        return nav * discountFactor / stratToken.totalSupply() * 1e18;
    }
}
