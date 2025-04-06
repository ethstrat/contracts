// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

contract MockOracle {
    uint256 private _price;
    uint8 public baseTokenDecimals;
    uint8 public quoteTokenDecimals;

    constructor(uint256 initialPrice, uint8 _baseTokenDecimals, uint8 _quoteTokenDecimals) {
        _price = initialPrice;
        baseTokenDecimals = _baseTokenDecimals;
        quoteTokenDecimals = _quoteTokenDecimals;
    }

    function setPrice(uint256 newPrice) public {
        _price = newPrice;
    }

    function price() external view returns (uint256) {
        return _price;
    }

    function setQuoteTokenDecimals(uint8 newQuoteTokenDecimals) public {
        quoteTokenDecimals = newQuoteTokenDecimals;
    }

    function setBaseTokenDecimals(uint8 newBaseTokenDecimals) public {
        baseTokenDecimals = newBaseTokenDecimals;
    }
}
