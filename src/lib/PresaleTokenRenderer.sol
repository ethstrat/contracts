// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ITokenURIRenderer} from "../interfaces/ITokenURIRenderer.sol";

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {DecimalString} from "./DecimalString.sol";
import {DateString} from "./DateString.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";

/// @title PresaleTokenRenderer
/// @notice Renders the token URI for the presale token
contract PresaleTokenRenderer is ITokenURIRenderer {
    function renderSvg(uint256 tokenId, uint256, uint256 notionalUnderlyingAmount, uint256, uint256, uint256 timelock)
        public
        view
        returns (string memory)
    {
        // Calculate time until unlock
        uint256 currentTime = block.timestamp;
        uint256 timeUntilUnlock = timelock > currentTime ? timelock - currentTime : 0;
        uint256 daysUntilUnlock = timeUntilUnlock / 86400;
        uint256 hoursUntilUnlock = (timeUntilUnlock % 86400) / 3600;

        string memory unlockText = timeUntilUnlock > 0
            ? string.concat(Strings.toString(daysUntilUnlock), " days, ", Strings.toString(hoursUntilUnlock), " hours")
            : "Unlocked";

        // Generate SVG
        string memory svg = string.concat(
            '<svg width="400" height="600" viewBox="0 0 400 600" xmlns="http://www.w3.org/2000/svg">',
            "<defs>",
            // Background gradient
            '  <linearGradient id="bg-gradient" x1="0%" y1="0%" x2="0%" y2="100%">',
            '    <stop offset="0%" style="stop-color:#1a1b2e"/>',
            '    <stop offset="100%" style="stop-color:#131320"/>',
            "  </linearGradient>",
            // Card gradient
            '  <linearGradient id="card-gradient" x1="0%" y1="0%" x2="100%" y2="100%">',
            '    <stop offset="0%" style="stop-color:#FF3399"/>',
            '    <stop offset="50%" style="stop-color:#6633FF"/>',
            '    <stop offset="100%" style="stop-color:#00CCFF"/>',
            "  </linearGradient>",
            // Glow effect
            '  <filter id="glow">',
            '    <feGaussianBlur stdDeviation="3" result="blur"/>',
            '    <feComposite in="SourceGraphic" in2="blur" operator="over"/>',
            "  </filter>",
            "</defs>",
            // Background
            '<rect width="400" height="600" fill="url(#bg-gradient)"/>',
            // Card with border and glow
            '<g transform="translate(20, 20)">',
            '<rect width="360" height="560" rx="30" fill="none" stroke="#00CCFF" stroke-width="1" stroke-opacity="0.3" filter="url(#glow)"/>',
            '<rect width="360" height="560" rx="30" fill="url(#card-gradient)"/>',
            "</g>",
            "<style>",
            "  .title { font: bold 36px sans-serif; fill: white; }",
            "  .subtitle { font: bold 48px sans-serif; fill: white; }",
            "  .label { font: 20px sans-serif; fill: white; opacity: 0.8; }",
            "  .value { font: bold 24px sans-serif; fill: white; }",
            "  .value-right { font: bold 24px sans-serif; fill: white; text-anchor: end; }",
            "</style>",
            // Header - adjusted for new margins
            '<text x="50" y="70" class="title">ETH Strategy</text>',
            '<text x="50" y="140" class="subtitle">Presale</text>',
            // Token ID
            '<g transform="translate(50, 200)">',
            '  <text class="label">Token ID</text>',
            string.concat('  <text y="40" class="value">', Strings.toString(tokenId), "</text>"),
            "</g>",
            // STRAT Output
            '<g transform="translate(50, 300)">',
            '  <text class="label">STRAT Output</text>',
            string.concat(
                '  <text y="40" class="value">',
                DecimalString.toDecimalString(notionalUnderlyingAmount, 18, 2),
                "</text>"
            ),
            "</g>",
            // Unlock Time
            '<g transform="translate(50, 400)">',
            '  <text class="label">Unlock</text>',
            string.concat('  <text y="40" class="value">', unlockText, "</text>"),
            "</g>",
            // Ethereum Logo
            '<circle cx="320" cy="90" r="30" fill="#627EEA"/>',
            '<path d="M320 50l-20 35 20 12 20-12z" fill="white" fill-opacity="0.6"/>',
            '<path d="M320 97l-20-12 20 28 20-28z" fill="white"/>',
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
    ) external view returns (string memory) {
        // If not a presale token, return nothing
        if (!(strikeAmount == 0 && notionalUSDAmount == 0)) {
            return "";
        }

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
