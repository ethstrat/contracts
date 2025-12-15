// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {WETH, USD} from "../../src/lib/PriceOracleConstants.sol";

abstract contract EthUsdPriceOracleProvider {
    MockPriceOracle public ethUsdOracle;

    function _setUpEthUsdOracle(uint256 basePerQuote) internal {
        ethUsdOracle = new MockPriceOracle(basePerQuote, "ETH/USD", WETH, USD);
    }
}
