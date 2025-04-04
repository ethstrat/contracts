// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IStratOptionMinter} from "./interfaces/IStratOptionMinter.sol";

/// @title StratPresale
/// @notice This contract allows a user to mint STRAT options during the presale
contract StratPresale {
    /// @notice The STRAT option minter contract
    IStratOptionMinter public stratOption;

    /// @notice The presale multisig
    /// @dev    This address receives the ETH raised during the presale
    address public immutable presaleMultisig;

    /// @notice The total amount of ETH that can be raised during the presale
    uint256 public immutable cap;

    /// @notice The expiry used for presale options
    uint48 public immutable expiry;

    /// @notice The timelock used for presale options
    uint48 public immutable timelock;

    /// @notice The amount of ETH raised
    uint256 public totalRaised = 0;

    /// @notice Records the contribution made per address
    /// @dev Technically not needed, but saves having to setup chain indexers for presale dapp
    mapping(address => uint256) public contributions;

    event PresaleMint(address indexed from, uint256 value, uint256 tokenId);

    constructor(uint256 _cap, address _stratOption, address _presaleMultisig, uint48 _baseTimestamp) {
        cap = _cap;
        stratOption = IStratOptionMinter(_stratOption);
        presaleMultisig = _presaleMultisig;

        expiry = _baseTimestamp + (420 * 365 days);
        timelock = _baseTimestamp + 90 days;
    }

    /// @notice Mint a presale STRAT option. Presale options are fungible.
    /// @dev    This function performs the following actions:
    ///         - Validates the inputs
    ///         - Updates the total amount of ETH raised
    ///         - Updates the contribution made by the caller
    ///         - Mints the STRAT option to the caller
    ///         - Sends the ETH raised to the presale multisig
    ///         - Emits a PresaleMint event
    ///
    ///         The function reverts if:
    ///         - The value of the function call is 0
    ///         - The updated total amount of ETH raised exceeds the cap
    function mint() external payable returns (uint256 tokenId) {
        require(msg.value > 0, "No ETH sent");

        totalRaised += msg.value;
        require(totalRaised <= cap, "Cap reached");

        contributions[msg.sender] += msg.value;

        // Mint the STRAT option
        // When exercised, this will result in:
        // - `msg.value` CDT tokens being burned from the caller
        // - `msg.value` STRAT tokens being minted to the caller
        //
        // e.g. if 2 ETH (2e18) is provided:
        // - Quantity of option tokens: 2e18
        // - Strike price: 1e18
        // - Can be exercised for 2e18 CDT (total input of 2 ETH + 2e18 CDT) for 2e18 STRAT
        tokenId = stratOption.mintFor(
            msg.sender, // Owner
            msg.value, // Quantity of option tokens to mint
            1e18, // Strike price: 1 CDT per STRAT
            0, // Redemption price: cannot be redeemed, so 0
            expiry, // Expiry
            timelock, // Timelock
            true // Requires burning CDT from the caller during exercise
        );

        // This does NOT mint CDT tokens to the caller
        // CDT tokens will need to be bought on the open market when exercising the presale option

        // Send ETH to presale multisig
        (bool success,) = presaleMultisig.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit PresaleMint(msg.sender, msg.value, tokenId);

        return tokenId;
    }

    function getTokenId() public view returns (uint256) {
        return stratOption.getTokenId(1e18, 0, expiry, timelock, true);
    }
}
