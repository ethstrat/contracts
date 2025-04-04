// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITokenURIRenderer {
    function render(
        uint256 strikePrice,
        uint256 redemptionPrice,
        uint48 expiry,
        uint48 timelock,
        bool requiresInputBurn
    ) external view returns (string memory);
}
