// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {TokenURIRenderer} from "../interfaces/TokenURIRenderer.sol";

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {DecimalString} from "./DecimalString.sol";
import {DateString} from "./DateString.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";

/// @title PresaleTokenRenderer
/// @notice Renders the token URI for the presale token
contract PresaleTokenRenderer is TokenURIRenderer {
    function renderSvg(uint256, uint256, uint256 notionalUnderlyingAmount, uint256, uint256, uint256 timelock)
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
            '<svg width="290" height="500" viewBox="0 0 290 500" fill="none" xmlns="http://www.w3.org/2000/svg">',
            "<defs>",
            // Pink Gradient
            '<linearGradient id="pink" x1="145" y1="10" x2="145" y2="37" gradientUnits="userSpaceOnUse">',
            '<stop stop-color="#FA92FB"/>',
            '<stop offset="1" stop-color="#FB7FD3"/>',
            "</linearGradient>",
            // Blue Gradient
            '<linearGradient id="blue" x1="171" y1="25" x2="171" y2="240" gradientUnits="userSpaceOnUse">',
            '<stop stop-color="#8090FF"/>',
            '<stop offset="1" stop-color="#63A7DE"/>',
            "</linearGradient>",
            // Grid Pattern
            '<pattern id="grid" width="15" height="15" patternUnits="userSpaceOnUse">',
            '<rect width="15" height="15" fill="#ccc"/>',
            '<rect x="0.5" y="0.5" width="15" height="15" fill="#fff"/>',
            "</pattern>",
            // Grid Mask
            '<mask id="gridMask" maskUnits="userSpaceOnUse">',
            '<rect width="100%" height="100%" fill="url(#grid)" />',
            "</mask>",
            "</defs>",
            // Background card
            '<rect x="1" y="1" width="288" height="498" rx="15" fill="#E3E6F9" stroke="#F4F5F9" stroke-width="2"/>'
            // Blue background behind ETH
            '<g mask="url(#gridMask)">',
            '<path d="M20 29C20 25 25 21 28 21H65C70 21 73 25 73 30V30C73 42 83 52 96 52H145L192 52C210 52 216 42 216 30V30C216 25 220 21 224 21H262C266 21 270 25 270 29V237C270 242 266 245 262 245H28C25 245 20 242 20 237V29Z" fill="url(#blue)"/>',
            "</g>",
            // ETH Triangles
            '<path d="M145 130L105 148L145 82V130Z" fill="#F1E2E9"/>',
            '<path d="M145 130L105 148L145 171.5V130Z" fill="#F6ADC4"/>',
            '<path d="M145 130L185 148L145 82V130Z" fill="#FFAAC3"/>',
            '<path d="M145 130L185 148L145 171.5V130Z" fill="#F78AA8"/>',
            '<path d="M105 155L145 210V183L105 155Z" fill="#F4C1D1"/>',
            '<path d="M185 155L145 210V183L185 155Z" fill="#FEA4BA"/>',
            '<path d="M145 179L105 155L145 183L185 155L145 179Z" fill="#FECADF"/>',
            // Wavy border
            //'<path d="M10 22C10 16 16 10 22 10H75C80 10 84 14 84 18V32C84 38 89 44 95.5882 44H145H194C200 44 206 38
            // 206 32V18C206 14 209 10 214 10H268C274 10 280 16 280 22V478C280 484 274 490 268 490H22C16 490 10 484 10
            // 478V22Z" stroke="#D5DAEF"/>',

            // PRESAYLOR
            '<rect x="90" y="10" width="110" height="27" rx="6" fill="url(#pink)"/>',
            '<text x="145" y="29" text-anchor="middle" fill="black" font-family="sans-serif" font-size="15px" font-weight="300">PRESAYLOR</text>',
            // STRAT Output
            '<circle cx="50" cy="310" r="30" fill="#EBEEFE" stroke="#D5DAEF"/>',
            '<rect x="95" y="280" width="175" height="60" rx="8" fill="#EBEEFE" stroke="#D5DAEF"/>',
            '<g transform="translate(110, 285)">',
            '<text fill="black" font-family="sans-serif" font-size="12px" font-weight="100">STRAT Purchased</text>',
            string.concat(
                '<text y="40" class="value">', DecimalString.toDecimalString(notionalUnderlyingAmount, 18, 2), "</text>"
            ),
            "</g>",
            // Unlock Claimable
            '<circle cx="50" cy="380" r="30" fill="#EBEEFE" stroke="#D5DAEF"/>',
            '<rect x="95" y="350" width="175" height="60" rx="8" fill="#EBEEFE" stroke="#D5DAEF"/>',
            '<g transform="translate(110, 365)">',
            '<text fill="black" font-family="sans-serif" font-size="12px" font-weight="100">Claimable</text>',
            "</g>",
            // Expiry
            '<circle cx="50" cy="450" r="30" fill="#EBEEFE" stroke="#D5DAEF"/>',
            '<rect x="95" y="420" width="175" height="60" rx="8" fill="#EBEEFE" stroke="#D5DAEF"/>',
            '<g transform="translate(110, 445)">',
            '<text fill="black" font-family="sans-serif" font-size="12px" font-weight="100">Expiry</text>',
            "</g>",
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
