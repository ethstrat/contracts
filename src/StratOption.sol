// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "./interfaces/TokenURIRenderer.sol";

/**
 * @title A call option over strat.
 * @dev Primarily used to represent the option part of issued convertible notes,
 * as well as during the presale and to bootstrap the DAO
 */
contract StratOption is ERC721, Ownable2Step {
    uint256 public _tokenIdCounter;

    mapping(uint256 => uint256) public strikeAmount;
    mapping(uint256 => uint256) public notionalUnderlyingAmount;
    mapping(uint256 => uint256) public notionalUSDAmount;
    mapping(uint256 => uint256) public expiry;
    mapping(uint256 => uint256) public timelock;

    mapping(address => bool) public minters;

    error MinterUnauthorizedAccount(address account);

    address public tokenURIRenderer;

    constructor() ERC721("STRAT Option", "oSTRAP") Ownable(msg.sender) {
        _tokenIdCounter = 1;
    }

    /**
     * @dev Allows only the owner to manage who can mint tokens.
     */
    function manageMinter(address who, bool canMint) external onlyOwner {
        minters[who] = canMint;
    }

    /**
     * @dev Allows only the owner to manage who can mint tokens.
     */
    function managerRenderer(address renderer) external onlyOwner {
        tokenURIRenderer = renderer;
    }

    function mint(
        uint256 _strikeAmount,
        uint256 _notionalUnderlyingAmount,
        uint256 _notionalUSDAmount,
        uint256 _expiry,
        uint256 _timelock
    ) external onlyMinter {
        uint256 tokenId = _tokenIdCounter++;
        _mint(msg.sender, tokenId);
        strikeAmount[tokenId] = _strikeAmount;
        notionalUnderlyingAmount[tokenId] = _notionalUnderlyingAmount;
        notionalUSDAmount[tokenId] = _notionalUSDAmount;
        expiry[tokenId] = _expiry;
        timelock[tokenId] = _timelock;
    }

    function burn(uint256 tokenId) external {
        require(
            ownerOf(tokenId) == msg.sender || getApproved(tokenId) == msg.sender,
            "StratOption: Not token owner or approved"
        );

        strikeAmount[tokenId] = 0;
        notionalUnderlyingAmount[tokenId] = 0;
        notionalUSDAmount[tokenId] = 0;
        expiry[tokenId] = 0;
        timelock[tokenId] = 0;

        _burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (tokenURIRenderer != address(0)) {
            return TokenURIRenderer(tokenURIRenderer).render(
                tokenId,
                strikeAmount[tokenId],
                notionalUnderlyingAmount[tokenId],
                notionalUSDAmount[tokenId],
                expiry[tokenId],
                timelock[tokenId]
            );
        } else {
            return "";
        }
    }

    /**
     * @dev Throws if called by any account other than a minter.
     */
    modifier onlyMinter() {
        if (!minters[msg.sender]) {
            revert MinterUnauthorizedAccount(msg.sender);
        }
        _;
    }
}
