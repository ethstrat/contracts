// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface TokenURIRenderer {
    function render(
        uint256 tokenId,
        uint256 strikeAmount,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 expiry,
        uint256 timelock
    ) external view returns (string memory);
}
