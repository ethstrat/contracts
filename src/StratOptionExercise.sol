// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {StratOption} from "./StratOption.sol";

/// @title StratOptionExercise
/// @notice This contract allows a user to exercise a STRAT option
contract StratOptionExercise {
    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    StratOption public immutable stratOption;

    error TimelockActive(address account, uint256 tokenId);
    error OptionExpired(address account, uint256 tokenId);
    error InvalidTokenId(address account, uint256 tokenId);

    event OptionExercised(address indexed optionOwner, uint256 tokenId, uint256 optionQuantity, uint256 stratQuantity);

    uint256 internal constant SCALE = 1e18;

    /// @notice Constructor
    ///
    /// @param _cdtToken The CDT token
    /// @param _stratToken The STRAT token
    /// @param _stratOption The STRAT option
    constructor(address _cdtToken, address _stratToken, address _stratOption) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        stratOption = StratOption(_stratOption);
    }

    /// @notice Exercise a STRAT option
    /// @dev    This function performs the following actions:
    ///         - Validates the option can be exercised
    ///         - Burns the CDT tokens from the caller
    ///         - Mints the STRAT tokens to the option owner
    ///         - Burns the STRAT option from the option owner
    ///         - Emits an OptionExercised event
    ///
    ///         That the function can be called by the option owner or an another address (as long as the option owner
    /// has granted approval)
    ///
    ///         The function reverts if:
    ///         - The option is not yet exercisable (timelock has not passed)
    ///         - The option has expired
    ///         - The caller is not the owner of the option and does not have approval by the owner
    ///         - The caller has not provided enough CDT tokens
    ///         - The caller has not approved spending of the required amount of CDT tokens
    ///
    /// @param tokenId The ID of the option to exercise
    /// @param amount_ The amount of option tokens to burn
    function exercise(uint256 tokenId, uint256 amount_) external {
        StratOption.Option memory option = stratOption.getOption(tokenId);

        // TODO add on behalf of

        if (option.timelock == 0) revert InvalidTokenId(msg.sender, tokenId);
        if (option.timelock > block.timestamp) revert TimelockActive(msg.sender, tokenId);
        if (option.expiry < block.timestamp) revert OptionExpired(msg.sender, tokenId);

        uint256 stratQuantity = amount_ * SCALE / option.strikePrice;

        // Some option types may not require a CDT payment
        if (option.requiresInputBurn) {
            cdtToken.burnFrom(msg.sender, amount_);
        }

        stratToken.mint(msg.sender, stratQuantity);
        stratOption.burnFrom(msg.sender, tokenId, amount_);

        emit OptionExercised(msg.sender, tokenId, amount_, stratQuantity);
    }
}
