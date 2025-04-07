// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {WETH} from "../../src/lib/PriceOracleConstants.sol";

abstract contract StratEthPriceOracleProvider {
    MockPriceOracle public stratEthOracle;

    function _setUpStratEthOracle(uint256 basePerQuote_, address strat_) internal {
        stratEthOracle = new MockPriceOracle(basePerQuote_, "STRAT/ETH", strat_, WETH);
    }
}
