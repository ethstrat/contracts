// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {TokenURIRenderer} from "./interfaces/TokenURIRenderer.sol";
import {IStratOption} from "./interfaces/IStratOption.sol";

/**
 * @title A call option over strat.
 * @dev Primarily used to represent the option part of issued convertible notes,
 * as well as during the presale and to bootstrap the DAO
 */
contract StratOption is ERC721, Ownable2Step, IStratOption {
    uint256 public _tokenIdCounter;

    uint256 public constant SCALE = 1e18;

    /// @notice The amount of CDT required to exercise the amount
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public strikeAmount;

    /// @notice The amount of STRAT that will be received if the option is exercised
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public notionalUnderlyingAmount;

    /// @notice The USD value of the ETH that was deposited, at the moment the user bonds
    /// @dev    Scale: SCALE
    mapping(uint256 tokenId => uint256) public notionalUSDAmount;

    /// @notice The timestamp at which the option expires
    mapping(uint256 tokenId => uint256) public expiry;

    /// @notice The timestamp at which the option can be exercised
    mapping(uint256 tokenId => uint256) public timelock;

    mapping(address => bool) public minters;

    address public tokenURIRenderer;

    error MinterUnauthorizedAccount(address account);
    error InvalidTimelockOrExpiry(uint256 timelock, uint256 expiry);

    event MinterUpdated(address indexed minter, bool canMint);
    event RendererUpdated(address indexed renderer);

    constructor(address owner) ERC721("STRAT Option", "oSTRAT") Ownable(owner) {
        _tokenIdCounter = 1;
    }

    /**
     * @dev Allows only the owner to manage who can mint tokens.
     */
    function manageMinter(address who, bool canMint) external onlyOwner {
        minters[who] = canMint;
        emit MinterUpdated(who, canMint);
    }

    /**
     * @dev Allows only the owner can update the token URI renderer.
     */
    function managerRenderer(address renderer) external onlyOwner {
        tokenURIRenderer = renderer;
        emit RendererUpdated(renderer);
    }

    function mint(
        address to,
        uint256 _strikeAmount,
        uint256 _notionalUnderlyingAmount,
        uint256 _notionalUSDAmount,
        uint256 _expiry,
        uint256 _timelock
    ) external onlyMinter {
        // minimal checks (NOTE: it's the caller's responsibility to ensure the values are correct)
        if (block.timestamp > _timelock || _timelock > _expiry) {
            revert InvalidTimelockOrExpiry(_timelock, _expiry);
        }

        uint256 tokenId = _tokenIdCounter++;
        _safeMint(to, tokenId);
        strikeAmount[tokenId] = _strikeAmount;
        notionalUnderlyingAmount[tokenId] = _notionalUnderlyingAmount;
        notionalUSDAmount[tokenId] = _notionalUSDAmount;
        expiry[tokenId] = _expiry;
        timelock[tokenId] = _timelock;
    }

    function burn(uint256 tokenId) external {
        _checkAuthorized(ownerOf(tokenId), msg.sender, tokenId);

        strikeAmount[tokenId] = 0;
        notionalUnderlyingAmount[tokenId] = 0;
        notionalUSDAmount[tokenId] = 0;
        expiry[tokenId] = 0;
        timelock[tokenId] = 0;

        _burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, IStratOption) returns (string memory) {
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

    function balanceOf(address owner) public view override(ERC721, IStratOption) returns (uint256) {
        return super.balanceOf(owner);
    }

    function ownerOf(uint256 tokenId) public view override(ERC721, IStratOption) returns (address) {
        return super.ownerOf(tokenId);
    }

    function isApprovedForAll(address owner, address operator)
        public
        view
        override(ERC721, IStratOption)
        returns (bool)
    {
        return super.isApprovedForAll(owner, operator);
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
