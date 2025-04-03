// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStratOptionMinter {
    // ===== ERRORS ===== //

    error MinterUnauthorizedAccount(address account);
    error NotOwnerOrApproved(address account, uint256 tokenId);
    error InvalidParams(string reason);

    // ===== DATA STRUCTURES ===== //

    /// @notice The parameters of the option
    /// @dev    The quantity of an option token is the quantity of STRAT tokens that it can be exercised for.
    ///
    /// @param  strikePrice     Input token per STRAT, in terms of `SCALE`. Multiply by the option quantity to get the
    /// quantity of the input token that is required to exercise the option. The exact input token is determined by the
    /// option type. Can be 0.
    /// @param  redemptionPrice Redemption price in USD per STRAT, in terms of `SCALE`. Multiply by the option quantity
    /// to get the USD value that will be used for redemption. Can be 0.
    /// @param  expiry          The timestamp at which the option expires.
    /// @param  timelock        The timestamp at which the option can be exercised.
    struct Option {
        uint256 strikePrice;
        uint256 redemptionPrice;
        uint48 expiry;
        uint48 timelock;
    }

    // ===== FUNCTIONS ===== //

    /// @notice Mints a new option on behalf of a recipient address.
    ///
    /// @param  to_                 Address to mint the option to
    /// @param  amount_             Quantity of options to mint
    /// @param  strikePrice_        Strike price of the option
    /// @param  redemptionPrice_    Redemption price of the option
    /// @param  expiry_             Expiry of the option
    /// @param  timelock_           Timelock of the option
    /// @return tokenId             Token ID of the newly minted option
    function mintFor(
        address to_,
        uint256 amount_,
        uint256 strikePrice_,
        uint256 redemptionPrice_,
        uint48 expiry_,
        uint48 timelock_
    ) external returns (uint256 tokenId);

    /// @notice Returns the token ID for a given option parameters.
    ///
    /// @param  strikePrice_        Strike price of the option
    /// @param  redemptionPrice_    Redemption price of the option
    /// @param  expiry_             Expiry of the option
    /// @param  timelock_           Timelock of the option
    /// @return tokenId             Token ID of the option
    function getTokenId(uint256 strikePrice_, uint256 redemptionPrice_, uint48 expiry_, uint48 timelock_)
        external
        pure
        returns (uint256 tokenId);
}
