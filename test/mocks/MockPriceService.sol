// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {IPriceService} from "../../src/interfaces/IPriceService.sol";

contract MockPriceService is IPriceService {
    uint256 public ethUsdPrice;
    uint256 public ethUsdPriceScale;
    uint256 public stratEthPrice;
    uint256 public stratEthPriceScale;

    constructor(uint256 ethUsdPrice_, uint256 ethUsdPriceScale_, uint256 stratEthPrice_, uint256 stratEthPriceScale_) {
        ethUsdPrice = ethUsdPrice_;
        ethUsdPriceScale = ethUsdPriceScale_;
        stratEthPrice = stratEthPrice_;
        stratEthPriceScale = stratEthPriceScale_;
    }

    function setEthUsdPrice(uint256 newEthUsdPrice) public {
        ethUsdPrice = newEthUsdPrice;
    }

    function setStratEthPrice(uint256 newStratEthPrice) public {
        stratEthPrice = newStratEthPrice;
    }

    function getEthUsdPrice() external view override returns (uint256, uint256) {
        return (ethUsdPrice, ethUsdPriceScale);
    }

    function getStratEthPrice() external view override returns (uint256, uint256) {
        return (stratEthPrice, stratEthPriceScale);
    }
}
