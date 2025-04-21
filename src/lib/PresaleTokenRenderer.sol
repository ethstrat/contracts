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
            "  .title { font: bold 32px sans-serif; fill: white; }",
            "  .subtitle { font: bold 48px sans-serif; fill: white; }",
            "  .label { font: 20px sans-serif; fill: white; opacity: 0.8; }",
            "  .value { font: bold 24px sans-serif; fill: white; }",
            "  .value-right { font: bold 24px sans-serif; fill: white; text-anchor: end; }",
            "</style>",
            // Header - adjusted for new margins
            '<text x="50" y="70" class="title">ETH Strategy</text>',
            // Logo in top-right corner, aligned with title
            '<g transform="translate(270, 130) scale(0.004000,-0.004000)" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="8">',
            '<path d="M12115 23534 c-1084 -47 -2053 -219 -3025 -536 -1659 -541 -3150 -1458 -4390 -2698 -2387 -2387 -3544 -5688 -3169 -9045 116 -1042 389 -2084 799 -3054 l73 -172 243 242 c134 134 245 241 247 239 2 -3 32 -70 66 -150 86 -202 254 -553 266 -557 6 -2 2101 2088 4658 4645 l4647 4647 -265 265 -265 265 -4555 -4555 c-4295 -4295 -4555 -4553 -4564 -4529 -5 13 -32 80 -59 149 -350 878 -588 1875 -676 2830 -34 371 -40 517 -40 975 0 549 18 848 79 1330 251 1956 1053 3793 2325 5320 215 259 355 411 645 700 289 290 441 430 700 645 1527 1272 3364 2074 5320 2325 482 61 781 79 1330 79 549 0 848 -18 1330 -79 1956 -251 3793 -1053 5320 -2325 259 -215 411 -355 700 -645 290 -289 430 -441 645 -700 1279 -1536 2084 -3388 2329 -5355 58 -466 75 -758 75 -1295 0 -537 -17 -829 -75 -1295 -245 -1967 -1050 -3819 -2329 -5355 -215 -259 -355 -411 -645 -700 -289 -290 -441 -430 -700 -645 -1527 -1272 -3364 -2074 -5320 -2325 -481 -61 -781 -79 -1330 -79 -459 0 -601 5 -975 40 -848 78 -1796 290 -2557 572 l-102 38 3529 3529 c1942 1942 3530 3535 3530 3540 0 6 -117 127 -260 270 l-260 260 -3640 -3640 c-2002 -2002 -3640 -3642 -3640 -3645 0 -8 311 -144 528 -231 106 -42 196 -80 200 -83 3 -4 -104 -117 -238 -251 -232 -233 -243 -244 -219 -254 746 -291 1426 -487 2144 -616 1262 -226 2566 -231 3835 -14 2698 461 5140 1928 6842 4109 1780 2281 2589 5178 2252 8060 -288 2468 -1397 4753 -3164 6520 -1240 1240 -2731 2156 -4390 2698 -869 284 -1723 449 -2680 517 -201 15 -940 27 -1125 19z"/>',
            '<path d="M9310 9675 l-4345 -4345 160 -161 c88 -88 209 -206 268 -261 l108 -102 4345 4345 4344 4344 -262 262 c-145 145 -265 263 -268 263 -3 0 -1960 -1955 -4350 -4345z"/>',
            '<path d="M2987 7552 l-236 -237 93 -167 c450 -804 1014 -1578 1600 -2196 l70 -73 223 223 c123 122 223 225 223 228 0 3 -45 55 -101 115 -371 404 -720 848 -1024 1305 -202 305 -350 554 -567 957 l-44 82 -237 -237z"/>',
            '<path d="M5272 4577 l-223 -223 83 -75 c685 -619 1465 -1156 2342 -1614 l168 -88 240 240 240 240 -223 111 c-821 407 -1652 967 -2297 1548 -51 46 -96 84 -100 84 -4 0 -107 -100 -230 -223z"/>',
            "</g>",
            '<text x="50" y="120" class="subtitle">Presale</text>',
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
