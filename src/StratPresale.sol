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

    /// @notice The amount of ETH raised
    uint256 public totalRaised = 0;

    /// @notice Records the contribution made per address
    /// @dev Technically not needed, but saves having to setup chain indexers for presale dapp
    mapping(address => uint256) public contributions;

    event PresaleMint(address indexed from, uint256 value);

    constructor(uint256 _cap, address _stratOption, address _presaleMultisig) {
        cap = _cap;
        stratOption = IStratOptionMinter(_stratOption);
        presaleMultisig = _presaleMultisig;
    }

    /// @notice Mint a STRAT option
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
    function mint() external payable {
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
        // - Strike amount: 2e18
        // - Underlying amount: 2e18
        // - Can be exercised for 2e18 CDT (total input of 2 ETH + 2e18 CDT) for 2e18 STRAT
        stratOption.mint(
            msg.sender, // Owner
            msg.value, // Strike amount
            msg.value, // Underlying amount
            0, // Underlying USD amount, cannot be redeemed
            block.timestamp + (420 * 365 days), // Expiry
            block.timestamp + 90 days // Timelock
        );

        // This does NOT mint CDT tokens to the caller
        // CDT tokens will need to be bought on the open market when exercising the presale option

        // Send ETH to presale multisig
        (bool success,) = presaleMultisig.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit PresaleMint(msg.sender, msg.value);
    }
}
