// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ITokenURIRenderer} from "../interfaces/ITokenURIRenderer.sol";

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {DecimalString} from "./DecimalString.sol";

/// @title PresaleTokenRenderer
/// @notice Renders the token URI for the presale token
contract PresaleTokenRenderer is ITokenURIRenderer {
    function render(
        uint256 tokenId,
        uint256 strikeAmount,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 expiry,
        uint256 timelock
    ) external pure returns (string memory) {
        // If it is not a presale token, return an empty string
        if (strikeAmount != 0 || notionalUSDAmount != 0) {
            return "";
        }

        // TODO add image

        return string.concat(
            "{",
            string.concat('"name": "', "ETH Strategy Presale Token", '",'),
            string.concat('"symbol": "', "oSTRAT", '",'),
            '"attributes": [',
            string.concat("{", '"trait_type": "ID", "value": "', Strings.toString(tokenId), '"', "},"),
            // This is 0 in a presale token, but we include it for clarity
            string.concat(
                "{",
                '"trait_type": "Exercise Cost (CDT)", "value": "',
                DecimalString.toDecimalString(strikeAmount, 18, 2),
                '"',
                "},"
            ),
            // Display the notional underlying amount with 2 decimal places, e.g. "1.23"
            string.concat(
                "{",
                '"trait_type": "STRAT Output", "value": "',
                DecimalString.toDecimalString(notionalUnderlyingAmount, 18, 2),
                '"',
                "},"
            ),
            // This is 0 in a presale token, but we include it for clarity
            string.concat(
                "{",
                '"trait_type": "Redeem Value (USD)", "value": "',
                DecimalString.toDecimalString(notionalUSDAmount, 18, 2),
                '"',
                "},"
            ),
            string.concat(
                "{", '"trait_type": "Expiry", "display_type": "date", "value": "', Strings.toString(expiry), '"', "},"
            ),
            string.concat(
                "{",
                '"trait_type": "Timelock", "display_type": "date", "value": "',
                Strings.toString(timelock),
                '"',
                "},"
            ),
            "]",
            "}"
        );
    }
}
