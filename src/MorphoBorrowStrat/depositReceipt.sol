// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

contract DepositReceipt is ERC721, Ownable2Step {
    uint256 private _tokenIdCounter;

    // Structure to store deposit details for each receipt NFT.
    struct Deposit {
        uint256 cdtAmount;
        uint256 optionId;
        uint256 timestamp;
    }
    
    // Mapping from tokenId to deposit details.
    mapping(uint256 => Deposit) public deposits;

    constructor(address owner) ERC721("Deposit Receipt", "DR") Ownable(owner) {

    }

    /**
     * @notice Mints a new deposit receipt NFT.
     * @param to The address that will receive the NFT.
     * @param cdtAmount The amount of CDT deposited.
     * @param optionId The option ID associated with the deposit.
     * @return tokenId The ID of the minted NFT.
     */
    function mint(
        address to, 
        uint256 cdtAmount, 
        uint256 optionId
    ) external returns (uint256 tokenId) {
        tokenId = _tokenIdCounter;
        _tokenIdCounter++;  // Increment the counter for the next token
        _safeMint(to, tokenId);
        deposits[tokenId] = Deposit({
            cdtAmount: cdtAmount,
            optionId: optionId,
            timestamp: block.timestamp
        });
    }

    /**
     * @notice Burns a deposit receipt NFT.
     * @param tokenId The token ID of the deposit receipt to burn.
     */
    function burn(uint256 tokenId) external {
        // Only the owner or an approved operator can burn the NFT.
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        _burn(tokenId);
        delete deposits[tokenId];
    }
}
