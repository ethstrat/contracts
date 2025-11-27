// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {WETH, USD} from "./PriceOracleConstants.sol";

/**
 * @title   EthUsdPriceFeedConsumer
 * @dev     Abstract contract that provides the price of ETH in USD, using an Euler price oracle.
 */
abstract contract EthUsdPriceFeedConsumer {
    IPriceOracle public immutable ETH_USD_ORACLE;

    /**
     * @dev Can be pre-set as both wETH and USD have a scale of 18.
     */
    uint256 internal constant _ETH_USD_ORACLE_SCALE = 1e18;

    error EthUsdPriceInvalid();

    constructor(address _ethUsdOracle) {
        ETH_USD_ORACLE = IPriceOracle(_ethUsdOracle);

        // Validate that the oracle is correct
        _getEthUsdPrice();
    }

    /**
     * @notice Get the price of ETH in USD.
     *
     * @return price The price of ETH in USD, with a scale of 18.
     */
    function _getEthUsdPrice() internal view returns (uint256 price) {
        // Quantity of USD for 1 WETH
        // This will revert if the base or quote tokens are not as expected,
        // which would indicate that the incorrect IPriceOracle was provided.
        price = ETH_USD_ORACLE.getQuote(1e18, WETH, USD);

        // Revert if the price is not returned
        if (price == 0) revert EthUsdPriceInvalid();
    }
}
