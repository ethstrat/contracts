// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface TokenURIRenderer {
    function render(uint256 tokenId) external view returns (string memory);
}
