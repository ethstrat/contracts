// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {StratOption} from "./StratOption.sol";

/**
 * @title StratOptionExercise
 * @notice Allows users to exercise STRAT options before expiry, by burning CDT tokens and minting STRAT tokens
 * @dev Interacts with external CDT and STRAT token contracts, and a StratOption contract.
 *      The contract verifies that the option's timelock has passed and that it is not expired before allowing exercise.
 *      Upon exercising, it burns the CDT tokens equivalent to the strike amount, mints the underlying
 *      STRAT tokens (with unit bias) to the option owner, and burns the STRAT option token.
 */
contract StratOptionExercise {
    // Immutable references to the CDT and STRAT tokens, and the STRAT option contract.
    IERC20MintableBurnable public immutable cdtToken;
    IERC20MintableBurnable public immutable stratToken;
    StratOption public immutable stratOption;

    // Custom errors to provide clear failure reasons.
    error NotOwnerOrApproved(address account, uint256 tokenId);
    error TimelockActive(address account, uint256 tokenId);
    error OptionExpired(address account, uint256 tokenId);
    error InvalidTokenId(address account, uint256 tokenId);

    // Event emitted when an option is successfully exercised.
    event OptionExercised(address indexed optionOwner, uint256 tokenId, uint256 strike, uint256 strat);

    /**
     * @param _cdtToken The address of the CDT token contract.
     * @param _stratToken The address of the STRAT token contract.
     * @param _stratOption The address of the STRAT option contract.
     */
    constructor(address _cdtToken, address _stratToken, address _stratOption) {
        cdtToken = IERC20MintableBurnable(_cdtToken);
        stratToken = IERC20MintableBurnable(_stratToken);
        stratOption = StratOption(_stratOption);
    }

    /**
     * @notice Exercises an option if it is not under a timelock and not expired.
     * @dev    This function performs the following actions:
     *         - Validates the option can be exercised
     *         - Burns the CDT tokens from the caller (quantity is the strike amount)
     *         - Mints the STRAT tokens to the option owner (quantity is the notional underlying amount)
     *         - Burns the STRAT option from the option owner
     *         - Emits an OptionExercised event
     *
     *         The function can be called by the option owner or an another address (as long as the option owner
     *         has granted approval)
     *
     *         The function reverts if:
     *         - The option is under a timelock
     *         - The option has expired
     *         - The caller is not the owner of the option and does not have approval by the owner
     *         - The caller has not provided enough CDT tokens
     *         - The caller has not approved spending of the required amount of CDT tokens
     * @param tokenId The identifier of the STRAT option token to exercise.
     */
    function exercise(uint256 tokenId) external {
        uint256 timelock = stratOption.timelock(tokenId);
        if (timelock == 0) revert InvalidTokenId(msg.sender, tokenId);

        // Check that the timelock period has passed.
        if (stratOption.timelock(tokenId) > block.timestamp) {
            revert TimelockActive(msg.sender, tokenId);
        }

        // Ensure the option has not expired.
        if (stratOption.expiry(tokenId) < block.timestamp) {
            revert OptionExpired(msg.sender, tokenId);
        }

        // Retrieve the owner of the option token.
        address optionOwner = stratOption.ownerOf(tokenId);

        // Retrieve strike and underlying amounts.
        uint256 strike = stratOption.strikeAmount(tokenId);
        uint256 strat = stratOption.notionalUnderlyingAmount(tokenId);

        // Burn the corresponding amount from the sender and mint the underlying token for the option owner.
        cdtToken.burnFrom(msg.sender, strike);
        uint256 premintedStratBalance = stratToken.balanceOf(address(this));
        if (premintedStratBalance < strat) {
            // Mint the required amount of STRAT tokens to this contract.
            stratToken.mint(address(this), strat - premintedStratBalance);
        }
        stratToken.transfer(optionOwner, strat);
        stratOption.burn(tokenId);

        // Emit event on successful exercise.
        emit OptionExercised(optionOwner, tokenId, strike, strat);
    }
}
