// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ITokenURIRenderer} from "../interfaces/ITokenURIRenderer.sol";

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

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

        // TODO convert to decimal strings
        // TODO add image

        return string.concat(
            "{",
            string.concat('"name": "', "ETH Strategy Presale Token", '",'),
            string.concat('"symbol": "', "oSTRAT", '",'),
            '"attributes": [',
            string.concat("{", '"trait_type": "ID", "value": "', Strings.toString(tokenId), '"', "},"),
            string.concat("{", '"trait_type": "Strike Amount", "value": "', Strings.toString(strikeAmount), '"', "},"), // This
                // is 0 in a presale token, but we include it for clarity
            string.concat(
                "{",
                '"trait_type": "Notional Underlying Amount", "value": "',
                Strings.toString(notionalUnderlyingAmount),
                '"',
                "},"
            ),
            string.concat(
                "{", '"trait_type": "Notional USD Amount", "value": "', Strings.toString(notionalUSDAmount), '"', "},"
            ), // This is 0 in a presale token, but we include it for clarity
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
