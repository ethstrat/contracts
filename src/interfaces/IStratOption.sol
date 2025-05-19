// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStratOption {
    function strikeAmount(uint256 tokenId) external view returns (uint256);

    function notionalUnderlyingAmount(uint256 tokenId) external view returns (uint256);

    function notionalUSDAmount(uint256 tokenId) external view returns (uint256);

    function expiry(uint256 tokenId) external view returns (uint256);

    function timelock(uint256 tokenId) external view returns (uint256);

    function tokenURI(uint256 tokenId) external view returns (string memory);

    function ownerOf(uint256 tokenId) external view returns (address);

    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function balanceOf(address owner) external view returns (uint256);

    function burn(uint256 tokenId) external;

    function mint(
        address to,
        uint256 _strikeAmount,
        uint256 _notionalUnderlyingAmount,
        uint256 _notionalUSDAmount,
        uint256 _expiry,
        uint256 _timelock
    ) external;
}
