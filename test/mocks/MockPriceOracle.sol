// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public basePerQuote;
    string public name;
    address public baseToken;
    address public quoteToken;

    constructor(uint256 basePerQuote_, string memory name_, address baseToken_, address quoteToken_) {
        basePerQuote = basePerQuote_;
        name = name_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
    }

    function setBasePerQuote(uint256 newBasePerQuote) public {
        basePerQuote = newBasePerQuote;
    }

    function getQuote(uint256 amount_, address baseToken_, address quoteToken_)
        external
        view
        override
        returns (uint256)
    {
        // Ensure it is in the supported order
        if (baseToken != baseToken_ || quoteToken != quoteToken_) revert("Invalid order");
        if (amount_ != 1e18) revert("Invalid amount");

        return basePerQuote;
    }

    function getQuotes(uint256 amount_, address baseToken_, address quoteToken_)
        external
        view
        override
        returns (uint256, uint256)
    {
        // Ensure it is in the supported order
        if (baseToken != baseToken_ || quoteToken != quoteToken_) revert("Invalid order");
        if (amount_ != 1e18) revert("Invalid amount");

        return (basePerQuote, basePerQuote);
    }
}
