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
    function renderSvg(
        uint256 tokenId,
        uint256 strikeAmount,
        uint256 notionalUnderlyingAmount,
        uint256 notionalUSDAmount,
        uint256 expiry,
        uint256 timelock
    ) public view returns (string memory) {
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
            // SVG defs & background
            '<svg width="290" height="500" viewBox="0 0 290 500" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">',
            '<defs><path id="text-path-a" d="M40 12 H250 A28 28 0 0 1 278 40 V460 A28 28 0 0 1 250 488 H40 A28 28 0 0 1 12 460 V40 A28 28 0 0 1 40 12 z" /></defs>',
            '<rect x="0" y="0" width="290" height="500" rx="42" fill="#E3E6F9" stroke="#F4F5F9"/>',
            '<rect x="16" y="16" width="258" height="468" rx="26" ry="26" stroke="#D5DAEF"/>',
            // STRAT Logo
            '<path fill="#000" d="M65.5 34a19.5 19.5 0 1 1-6.44 37.91l1.55-1.55a17.56 17.56 0 1 0-11.4-10.33l-1.5 1.49A19.5 19.5 0 0 1 65.5 34M54.3 67.02a18 18 0 0 0 4.28 2.61l-1.47 1.48a20 20 0 0 1-4.19-2.7zM50.1 61.9a18 18 0 0 0 2.78 3.79l-1.37 1.38a20 20 0 0 1-2.84-3.73z"/>',
            '<path fill="#000" d="M72.14 58.84 60.6 70.36q-1.04-.3-2.03-.73l12.18-12.17zm-3.22-6.44L54.3 67.02q-.75-.63-1.44-1.33l14.67-14.67zm-3.02-6.3L50.09 61.9q-.5-.9-.88-1.87l15.3-15.31z"/>',
            // Pink ETH
            '<path d="M145 201 84 229 145 127z" fill="#F1E2E9"/>',
            '<path d="M145 201 84 229l61 36z" fill="#F6ADC4"/>',
            '<path d="m145 201 61 28L145 127z" fill="#FFAAC3"/>',
            '<path d="m145 201 61 28-61 36z" fill="#F78AA8"/>',
            '<path d="m84 240.5 61 86.5v-45z" fill="#F4C1D1"/>',
            '<path d="M207 240.5 145 327v-45z" fill="#FEA4BA"/>',
            '<path d="M145 277 84 240.5l61 42 61-42z" fill="#FECADF"/>',
            // Title Text
            '<path fill="#000" d="M94.82 96V84.8h4.2q1.42 0 2.44.46 1.03.45 1.57 1.32.57.84.56 2.06 0 1.18-.56 2.05-.54.84-1.57 1.31-1.03.45-2.44.46h-3.54l.53-.56V96zm1.19-4-.53-.58h3.5q1.68 0 2.55-.72.87-.73.88-2.06 0-1.35-.88-2.08-.87-.75-2.55-.74h-3.5l.53-.56zm10.94 4V84.8h4.2q1.42 0 2.44.46 1.03.45 1.57 1.32.56.84.56 2.06 0 1.18-.56 2.05-.54.84-1.57 1.31-1.02.45-2.45.45h-3.53l.53-.55V96zm7.65 0-2.88-4.06H113l2.9 4.06zm-6.46-4-.53-.56h3.5q1.68 0 2.55-.74.88-.73.88-2.06 0-1.35-.88-2.08-.87-.75-2.55-.74h-3.5l.53-.56zm12.23-2.2h5.92v1.02h-5.92zm.13 5.18h6.74V96h-7.92V84.8H127v1.02h-6.5zm13.4 1.12q-1.25 0-2.4-.4a5 5 0 0 1-1.75-1.06l.46-.91q.6.57 1.58.97a6 6 0 0 0 3.83.13q.67-.27.97-.72.32-.45.32-.99 0-.66-.38-1.06a2.5 2.5 0 0 0-.98-.62q-.6-.24-1.34-.42t-1.47-.36a7 7 0 0 1-1.36-.55q-.6-.34-1-.88a2.6 2.6 0 0 1-.36-1.45 2.8 2.8 0 0 1 1.79-2.64q.9-.44 2.34-.44a6.6 6.6 0 0 1 3.47 1l-.4.94q-.72-.48-1.54-.7a6 6 0 0 0-1.55-.23q-1.01 0-1.66.27-.66.28-.98.74-.3.45-.3 1.02 0 .66.36 1.06.39.4 1 .62.61.23 1.36.4.73.18 1.45.39.74.21 1.35.54.61.32.99.87.38.54.38 1.42 0 .81-.45 1.52-.45.69-1.37 1.12-.92.42-2.35.42m5.77-.1 5.12-11.2h1.17l5.12 11.2h-1.25l-4.7-10.51h.48L140.9 96zm2.02-3 .35-.95h6.51l.35.96zm14.06 3v-4.16l.27.74-4.75-7.78h1.26l4.18 6.83h-.68l4.18-6.83h1.18l-4.75 7.78.27-.74V96zm8.05 0V84.8h1.18v10.18h6.27V96zm14.9.1q-1.27 0-2.36-.42a6 6 0 0 1-1.87-1.2 6 6 0 0 1-1.23-1.8 6 6 0 0 1-.43-2.28q0-1.23.43-2.26a5.6 5.6 0 0 1 3.1-3q1.08-.44 2.35-.44t2.34.44a5.4 5.4 0 0 1 3.09 2.99q.45 1.05.45 2.27a5.7 5.7 0 0 1-1.68 4.08q-.79.77-1.86 1.2a6 6 0 0 1-2.34.42m0-1.06a5 5 0 0 0 1.85-.34 4.5 4.5 0 0 0 2.48-2.44q.36-.85.35-1.86a4.7 4.7 0 0 0-1.34-3.31 4.8 4.8 0 0 0-3.34-1.33 5 5 0 0 0-3.38 1.33q-.63.61-1 1.47a5 5 0 0 0-.34 1.84 4.8 4.8 0 0 0 1.34 3.33 4.6 4.6 0 0 0 3.38 1.31m9.32.96V84.8h4.2q1.41 0 2.44.46 1.02.45 1.57 1.32.56.84.56 2.06 0 1.18-.56 2.05-.55.84-1.57 1.31-1.02.45-2.45.45h-3.53l.53-.55V96zm7.65 0-2.88-4.06h1.28l2.9 4.06zm-6.46-4-.53-.56h3.5q1.68 0 2.54-.74.89-.73.88-2.06 0-1.35-.87-2.08-.87-.75-2.55-.74h-3.5l.53-.56zM65.5 34a19.5 19.5 0 1 1-6.44 37.91l1.55-1.55a17.56 17.56 0 1 0-11.4-10.33l-1.5 1.49A19.5 19.5 0 0 1 65.5 34M54.3 67.02a18 18 0 0 0 4.28 2.61l-1.47 1.48a20 20 0 0 1-4.19-2.7zM50.1 61.9a18 18 0 0 0 2.78 3.79l-1.37 1.38a20 20 0 0 1-2.84-3.73z"/>',
            '<path fill="#000" d="M72.14 58.84 60.6 70.36q-1.04-.3-2.03-.73l12.18-12.17zm-3.22-6.44L54.3 67.02q-.75-.63-1.44-1.33l14.67-14.67zm-3.02-6.3L50.09 61.9q-.5-.9-.88-1.87l15.3-15.31zM100.8 64.42q-2.15 0-4.11-.68a8 8 0 0 1-3.01-1.81l.8-1.56a8 8 0 0 0 2.7 1.67q1.73.66 3.62.65a8 8 0 0 0 2.93-.43 3.6 3.6 0 0 0 1.67-1.24q.55-.75.55-1.7a2.5 2.5 0 0 0-.66-1.8 4 4 0 0 0-1.67-1.07q-1.05-.4-2.3-.71l-2.52-.63q-1.26-.36-2.33-.93a5 5 0 0 1-1.7-1.5 4.5 4.5 0 0 1-.63-2.5q0-1.43.74-2.6a5.2 5.2 0 0 1 2.33-1.92 9 9 0 0 1 4-.74 11.3 11.3 0 0 1 5.94 1.7l-.68 1.61a9.83 9.83 0 0 0-5.29-1.59 8 8 0 0 0-2.85.47q-1.11.46-1.67 1.26-.52.77-.52 1.75 0 1.12.63 1.81.66.69 1.7 1.07 1.07.38 2.33.68t2.5.66q1.25.36 2.3.93 1.06.55 1.69 1.48.66.93.66 2.44 0 1.4-.77 2.6a5.5 5.5 0 0 1-2.36 1.92 10 10 0 0 1-4.02.71m16.4-.16V46.84h-6.75v-1.76h15.5v1.76h-6.73v17.42zm13.36 0V45.08h7.18q2.43 0 4.19.8a6 6 0 0 1 2.68 2.24q.96 1.45.96 3.54a6.3 6.3 0 0 1-.96 3.5 6 6 0 0 1-2.68 2.25q-1.75.77-4.2.77h-6.04l.9-.94v7.02zm13.1 0-4.94-6.96h2.2l4.95 6.96zm-11.07-6.85-.9-.96h6q2.87 0 4.35-1.26 1.5-1.26 1.5-3.53 0-2.3-1.5-3.56-1.48-1.26-4.36-1.26h-6l.91-.96zm16.07 6.85 8.76-19.18h2l8.77 19.18h-2.14l-8.05-18h.82l-8.05 18zm3.45-5.13.6-1.64h11.15l.6 1.64zm23.38 5.13V46.84h-6.74v-1.76h15.5v1.76h-6.73v17.42zm40.24.16q-2.18 0-4.05-.71a10 10 0 0 1-3.2-2.06q-1.35-1.3-2.11-3.1-.75-1.77-.74-3.88 0-2.1.74-3.89a9.4 9.4 0 0 1 5.34-5.12q1.86-.75 4.05-.74 2.2 0 4 .68a8 8 0 0 1 3.12 2.09l-1.26 1.28a7 7 0 0 0-2.66-1.72q-1.44-.52-3.12-.52-1.78 0-3.28.6a7.7 7.7 0 0 0-4.94 7.34q0 1.7.6 3.15.64 1.45 1.73 2.55a8 8 0 0 0 2.6 1.67q1.52.57 3.26.57 1.65 0 3.1-.5a7 7 0 0 0 2.71-1.66l1.15 1.53a9 9 0 0 1-3.2 1.84q-1.84.6-3.84.6m5.1-2.68v-7.07h1.94v7.31zm13.62 2.52v-7.13l.47 1.26-8.14-13.3h2.17l7.15 11.69h-1.16l7.15-11.7h2.03l-8.13 13.31.46-1.26v7.13zM188.8 62.5v1.76h14.15l-1.18-1.76zM188.8 53.74v1.75h11.94v-1.75zM188.8 45.08v1.76h12.97l1.16-1.76z"/>',
            // Token ID
            '<text x="30" y="370" fill="black" font-family="sans-serif" font-size="14px" font-weight="300">Token ID</text>',
            '<text x="30" y="390" fill="black" font-family="sans-serif" font-size="16px" font-weight="500">',
            Strings.toString(tokenId),
            "</text>",
            // STRAT Purchased
            '<text x="260" y="370" text-anchor="end" fill="black" font-family="sans-serif" font-size="14px" font-weight="300">STRAT Purchased</text>',
            '<text x="260" y="390" text-anchor="end" fill="black" font-family="sans-serif" font-size="16px" font-weight="500">',
            DecimalString.toDecimalString(notionalUnderlyingAmount, 18, 0),
            "</text>",
            // Unlock Time
            '<text x="30" y="420" fill="black" font-family="sans-serif" font-size="14px" font-weight="300">Vesting Terms</text>',
            '<text x="30" y="440" fill="black" font-family="sans-serif" font-size="12px" font-weight="500">STRAT vests for 6 months post-launch</text>',
            // Border text
            generateSVGBorderText(),
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

    function generateSVGBorderText() private pure returns (string memory svg) {
        svg = string(
            abi.encodePacked(
                '<text text-rendering="optimizeSpeed">',
                '<textPath startOffset="-100%" fill="black" font-family="monospace" font-size="10px" xlink:href="#text-path-a">',
                "Presale STRAT locked up for 4 months...",
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" />',
                '</textPath> <textPath startOffset="0%" fill="black" font-family="monospace" font-size="10px" xlink:href="#text-path-a">',
                "Presale STRAT locked up for 4 months...",
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" /> </textPath>',
                '<textPath startOffset="50%" fill="black" font-family="monospace" font-size="10px" xlink:href="#text-path-a">',
                "...then vests linearly over 2 months",
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s"',
                ' repeatCount="indefinite" /></textPath><textPath startOffset="-50%" fill="black" font-family="monospace" font-size="10px" xlink:href="#text-path-a">',
                "...then vests linearly over 2 months",
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" /></textPath></text>'
            )
        );
    }
}
