// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ITokenURIRenderer} from "../interfaces/ITokenURIRenderer.sol";

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {DecimalString} from "./DecimalString.sol";
import {DateString} from "./DateString.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";

/// @title TokenRenderer
/// @notice Renders the token URI for the oSTRAT token
contract TokenRenderer is ITokenURIRenderer {
    function renderSvg(
        uint256 tokenId,
        uint256 strikeAmount,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 expiry,
        uint256 timelock
    ) public pure returns (string memory) {
        // Generate SVG
        string memory svg = string.concat(
            '<svg width="800" height="480" viewBox="0 0 800 480" xmlns="http://www.w3.org/2000/svg" style="border-radius: 30px">',
            "<defs>",
            '  <linearGradient id="gradient" x1="0%" y1="0%" x2="100%" y2="0%">',
            '    <stop offset="0%" stop-color="rgb(234, 56, 84)" />',
            '    <stop offset="100%" stop-color="rgb(210, 71, 191)" />',
            "  </linearGradient>",
            "</defs>",
            '<rect width="800" height="480" rx="30" fill="url(#gradient)" />',
            "<style>",
            '  .title { font-family: "Segoe UI", sans-serif; font-weight: bold; font-size: 48px; fill: #ffffff; }',
            '  .label { font-family: "Segoe UI", sans-serif; font-size: 24px; fill: #ffffff; }',
            '  .value { font-family: "Segoe UI", sans-serif; font-size: 28px; font-weight: bold; fill: #ffffff; text-anchor: end; }',
            "</style>",
            '<text x="60" y="90" class="title">ETH Strategy</text>',
            '<text x="740" y="90" class="title" text-anchor="end">oSTRAT</text>',
            '<line x1="60" y1="120" x2="740" y2="120" stroke="#ffffff" opacity="0.3" stroke-width="1"/>',
            string.concat('<text x="60" y="170" class="label">Token ID:</text>'),
            string.concat('<text x="220" y="170" class="label">#', Strings.toString(tokenId), "</text>"),
            '<text x="420" y="170" class="label">Expiry:</text>',
            string.concat(
                '<text x="740" y="170" class="label" text-anchor="end">', DateString.toPaddedString(expiry), "</text>"
            ),
            '<text x="60" y="240" class="label">Exercise Cost:</text>',
            string.concat(
                '<text x="740" y="240" class="value">',
                DecimalString.toDecimalString(strikeAmount, 18, 2),
                " CDT</text>"
            ),
            '<text x="60" y="310" class="label">STRAT Output:</text>',
            string.concat(
                '<text x="740" y="310" class="value">',
                DecimalString.toDecimalString(notionalUnderlyingAmount, 18, 2),
                " STRAT</text>"
            ),
            '<text x="60" y="380" class="label">Redeem Value:</text>',
            string.concat(
                '<text x="740" y="380" class="value">$',
                DecimalString.toDecimalString(notionalUSDAmount, 18, 2),
                "</text>"
            ),
            "</svg>"
        );

        return svg;
    }

    function render(
        uint256 tokenId,
        uint256 strikeAmount,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 expiry,
        uint256 timelock
    ) external pure returns (string memory) {
        string memory svg =
            renderSvg(tokenId, strikeAmount, notionalUnderlyingAmount, notionalUSDAmount, expiry, timelock);

        // Encode SVG to base64
        string memory base64Svg = Base64.encode(bytes(svg));

        return string.concat(
            "{",
            string.concat('"name": "', "ETH Strategy Option Token", '",'),
            string.concat('"symbol": "', "oSTRAT", '",'),
            string.concat('"image": "', "data:image/svg+xml;base64,", base64Svg, '",'),
            '"attributes": [',
            string.concat("{", '"trait_type": "ID", "value": "', Strings.toString(tokenId), '"', "},"),
            string.concat(
                "{",
                '"trait_type": "Exercise Cost (CDT)", "value": "',
                DecimalString.toDecimalString(strikeAmount, 18, 2),
                '"',
                "},"
            ),
            string.concat(
                "{",
                '"trait_type": "STRAT Output", "value": "',
                DecimalString.toDecimalString(notionalUnderlyingAmount, 18, 2),
                '"',
                "},"
            ),
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
                "}"
            ),
            "]",
            "}"
        );
    }
}
