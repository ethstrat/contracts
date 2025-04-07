// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

abstract contract EthUsdPriceOracleProvider {
    MockPriceOracle public ethUsdOracle;
    address internal _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal _USD = 0x0000000000000000000000000000000000000348;

    function _setUpEthUsdOracle(uint256 basePerQuote) internal {
        ethUsdOracle = new MockPriceOracle(basePerQuote, "ETH/USD", _WETH, _USD);
    }
}
