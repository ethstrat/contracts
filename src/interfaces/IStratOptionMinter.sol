// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStratOptionMinter {
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
}
