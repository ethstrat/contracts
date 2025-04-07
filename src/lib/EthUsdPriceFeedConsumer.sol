// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/**
 * @title   EthUsdPriceFeedConsumer
 * @dev     Abstract contract that provides the price of ETH in USD, using an Euler price oracle.
 */
abstract contract EthUsdPriceFeedConsumer {
    IPriceOracle public immutable ethUsdOracle;

    address internal constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @dev Euler USD special designator. Has a scale of 18.
     *      See:
     * https://github.com/euler-xyz/euler-price-oracle/blob/15c6e68bd62e108a8243d9a61c843c5981d75477/src/adapter/BaseAdapter.sol#L38
     */
    address internal constant _USD = 0x0000000000000000000000000000000000000348;

    uint256 internal constant _ETH_USD_ORACLE_SCALE = 1e18;

    error EthUsdPriceInvalid();

    constructor(address _ethUsdOracle) {
        ethUsdOracle = IPriceOracle(_ethUsdOracle);
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
        price = ethUsdOracle.getQuote(1e18, _WETH, _USD);

        // Revert if the price is not returned
        if (price == 0) revert EthUsdPriceInvalid();
    }
}
