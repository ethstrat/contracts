// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable2Step, Ownable} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {TokenURIRenderer} from "./interfaces/TokenURIRenderer.sol";
import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";
/**
 * @title A call option over strat.
 * @dev Primarily used to represent the option part of issued convertible notes,
 * as well as during the presale and to bootstrap the DAO
 */

contract StratOption is ERC1155, Ownable2Step, IStratOptionMinter {
    // ===== CONSTANTS ===== //

    uint256 public constant SCALE = 1e18;

    // ===== STATE VARIABLES ===== //

    mapping(uint256 tokenId => Option) internal _options;

    mapping(address => bool) public minters;

    address public tokenURIRenderer;

    // ===== CONSTRUCTOR ===== //

    constructor(address owner) ERC1155("") Ownable(owner) {}

    // ===== ADMIN FUNCTIONS ===== //

    /**
     * @dev Allows only the owner to manage who can mint tokens.
     */
    function manageMinter(address who, bool canMint) external onlyOwner {
        minters[who] = canMint;
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

    /**
     * @dev Allows only the owner can update the token URI renderer.
     */
    function managerRenderer(address renderer) external onlyOwner {
        tokenURIRenderer = renderer;
    }

    // ===== MINT/BURN FUNCTIONS ===== //

    /// @inheritdoc IStratOptionMinter
    /// @dev    This function performs the following steps:
    ///         - Validates inputs
    ///         - Generates the token ID based on the option parameters
    ///         - Mints the option to the recipient
    ///         - Adds the option to the options mapping if it is not already present
    ///
    ///         It does not mint a unique event, and expects the minter to emit a specific event.
    ///
    ///         The function reverts if:
    ///         - The caller is not an authorized minter
    ///         - The timelock is equal to or after the expiry
    ///         - The timelock is not in the future
    function mintFor(
        address to_,
        uint256 amount_,
        uint256 strikePrice_,
        uint256 redemptionPrice_,
        uint48 expiry_,
        uint48 timelock_
    ) external onlyMinter returns (uint256 tokenId) {
        // Check timelock is before expiry
        if (timelock_ >= expiry_) {
            revert InvalidParams("timelock");
        }

        // Check timelock is in the future
        if (timelock_ <= block.timestamp) {
            revert InvalidParams("timelock");
        }

        tokenId = getTokenId(strikePrice_, redemptionPrice_, expiry_, timelock_);
        _mint(to_, tokenId, amount_, "");

        // If the option is not already in the mapping, add it
        if (_options[tokenId].expiry == 0) {
            _options[tokenId] = Option({
                strikePrice: strikePrice_,
                redemptionPrice: redemptionPrice_,
                expiry: expiry_,
                timelock: timelock_
            });
        }

        // Expect the minter to emit a specific event

        return tokenId;
    }

    /// @notice Burns a quantity of options from an address.
    /// @dev    This function performs the following steps:
    ///         - Validates inputs
    ///         - Burns the options from the specified address
    ///
    ///         The function reverts if:
    ///         - The caller is not the owner of the options and is not approved to perform actions on behalf of the
    /// owner
    ///         - The token ID is not valid
    ///         - The amount to burn is greater than the balance of the owner
    ///
    /// @param  from_       Address to burn the options from
    /// @param  tokenId_    Token ID of the options to burn
    /// @param  amount_     Quantity of options to burn
    function burnFrom(address from_, uint256 tokenId_, uint256 amount_) external {
        if (from_ != msg.sender && !isApprovedForAll(from_, msg.sender)) {
            revert ERC1155MissingApprovalForAll(msg.sender, from_);
        }

        _burn(from_, tokenId_, amount_);
    }

    // ===== VIEW FUNCTIONS ===== //

    function getOption(uint256 tokenId) external view returns (Option memory) {
        return _options[tokenId];
    }

    function getTokenId(
        uint256 strikePrice_,
        uint256 redemptionPrice_,
        uint48 expiry_,
        uint48 timelock_
    ) public pure override returns (uint256 tokenId) {
        tokenId = uint256(keccak256(abi.encodePacked(strikePrice_, redemptionPrice_, expiry_, timelock_)));
    }

    // ===== TOKEN URI FUNCTIONS ===== //

    function uri(uint256 tokenId) public view override returns (string memory) {
        if (tokenURIRenderer == address(0)) {
            return "";
        }

        // TODO update TokenURIRenderer interface

        Option memory option = _options[tokenId];
        return TokenURIRenderer(tokenURIRenderer).render(tokenId, 0, 0, 0, option.expiry, option.timelock);
    }
}
