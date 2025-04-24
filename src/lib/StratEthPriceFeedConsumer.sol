// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IERC20MintableBurnable} from "../interfaces/IERC20.sol";
import {WETH} from "./PriceOracleConstants.sol";

/**
 * @title   StratEthPriceFeedConsumer
 * @dev     Abstract contract that provides the price of STRAT in ETH, using an Euler price oracle.
 */
abstract contract StratEthPriceFeedConsumer {
    IPriceOracle public immutable STRAT_ETH_ORACLE;
    IERC20MintableBurnable public immutable STRAT;

    /**
     * @dev Can be pre-set as both STRAT and ETH have a scale of 18.
     */
    uint256 internal constant _STRAT_ETH_ORACLE_SCALE = 1e18;

    error StratEthPriceInvalid();
    error StratDecimalsInvalid();

    constructor(address _stratEthOracle, address _strat) {
        STRAT_ETH_ORACLE = IPriceOracle(_stratEthOracle);
        STRAT = IERC20MintableBurnable(_strat);

        // Validate that the STRAT token has a scale of 18
        if (STRAT.decimals() != 18) revert StratDecimalsInvalid();

        // Validate that the oracle is correct
        _getStratEthPrice();
    }

    /**
     * @notice Get the price of STRAT in ETH.
     *
     * @return price The price of STRAT in ETH, with a scale of 18.
     */
    function _getStratEthPrice() internal view returns (uint256 price) {
        // Quantity of ETH for 1 STRAT
        // This will revert if the base or quote tokens are not as expected,
        // which would indicate that the incorrect IPriceOracle was provided.
        price = STRAT_ETH_ORACLE.getQuote(1e18, address(STRAT), WETH);

        // Revert if the price is not returned
        if (price == 0) revert StratEthPriceInvalid();
    }
}
