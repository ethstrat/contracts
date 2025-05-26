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
    function renderSvg(uint256 tokenId, uint256, uint256 notionalUnderlyingAmount, uint256, uint256, uint256)
        public
        pure
        returns (string memory)
    {
        // Generate SVG
        string memory svg = string.concat(
            // SVG defs & background
            '<svg width="290" height="500" viewBox="0 0 290 500" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">',
            '<defs><path id="text-path-a" d="M40 12 H250 A28 28 0 0 1 278 40 V460 A28 28 0 0 1 250 488 H40 A28 28 0 0 1 12 460 V40 A28 28 0 0 1 40 12 z" /></defs>',
            '<rect x="0" y="0" width="290" height="500" rx="42" fill="#E3E6F9" stroke="#F4F5F9"/>',
            '<rect x="16" y="16" width="258" height="468" rx="26" ry="26" stroke="#D5DAEF"/>',
            // ETH Strategy
            '<path fill="#000" d="M64.69 33.81a19.69 19.69 0 1 1-6.5 38.28l1.56-1.57A17.72 17.72 0 1 0 48.24 60.1l-1.5 1.5a19.69 19.69 0 0 1 17.95-27.78m-11.3 33.34a18 18 0 0 0 4.31 2.64l-1.48 1.48a20 20 0 0 1-4.23-2.73zm-4.26-5.17q1.15 2.11 2.81 3.83l-1.4 1.39a20 20 0 0 1-2.86-3.77z"/>',
            '<path fill="#000" d="M71.38 58.89 59.75 70.52q-1.05-.3-2.05-.73L70 57.49zm-3.24-6.5L53.38 67.15q-.75-.63-1.44-1.34L66.74 51zm-3.05-6.36L49.13 61.98q-.5-.9-.9-1.89L63.7 44.63zM100.32 64.52q-2.16 0-4.15-.69a8 8 0 0 1-3.04-1.82l.8-1.58q1.02 1 2.74 1.69 1.74.66 3.65.66 1.83 0 2.96-.44a3.6 3.6 0 0 0 1.68-1.24q.56-.79.56-1.72 0-1.13-.67-1.82a4 4 0 0 0-1.68-1.08q-1.05-.42-2.33-.72-1.27-.3-2.54-.64-1.27-.36-2.35-.94-1.05-.58-1.71-1.52a4.5 4.5 0 0 1-.64-2.51 4.8 4.8 0 0 1 3.1-4.56q1.58-.75 4.03-.75a11.5 11.5 0 0 1 6 1.71l-.69 1.63a9.93 9.93 0 0 0-5.34-1.6q-1.73 0-2.87.47a3.7 3.7 0 0 0-1.69 1.27q-.52.77-.52 1.77 0 1.14.63 1.83.67.7 1.72 1.07 1.08.4 2.35.7t2.52.66q1.27.36 2.32.94 1.08.55 1.71 1.5.66.93.66 2.45a5 5 0 0 1-.77 2.63q-.77 1.2-2.38 1.93-1.57.72-4.06.72m16.55-.16V46.77h-6.8V45h15.64v1.77h-6.8v17.59zm13.5 0V45h7.24q2.46 0 4.23.8a6 6 0 0 1 2.71 2.27q.97 1.47.97 3.57 0 2.04-.97 3.54a6 6 0 0 1-2.71 2.27q-1.77.77-4.23.77h-6.11l.91-.94v7.08zm13.21 0-4.98-7.02h2.22l5 7.02zm-11.17-6.91-.91-.97h6.05q2.9 0 4.4-1.27a4.4 4.4 0 0 0 1.52-3.57q0-2.32-1.52-3.6-1.5-1.27-4.4-1.27h-6.05l.91-.96zm16.22 6.9L157.48 45h2.02l8.85 19.36h-2.16l-8.13-18.17h.83l-8.13 18.17zm3.49-5.16.6-1.66h11.26l.6 1.66zm23.6 5.17V46.77h-6.8V45h15.65v1.77h-6.8v17.59zm40.62.16q-2.21 0-4.09-.72a10 10 0 0 1-3.23-2.07 10 10 0 0 1-2.13-3.12q-.75-1.8-.75-3.93t.75-3.92a9.5 9.5 0 0 1 5.39-5.17 11 11 0 0 1 4.1-.75q2.2 0 4.03.69a8 8 0 0 1 3.15 2.1l-1.27 1.3a7 7 0 0 0-2.68-1.74 9 9 0 0 0-3.16-.53q-1.8 0-3.31.61a7.7 7.7 0 0 0-4.98 7.41q0 1.71.6 3.18.64 1.47 1.75 2.57a8 8 0 0 0 2.63 1.69q1.51.58 3.29.58 1.65 0 3.12-.5 1.49-.5 2.74-1.69l1.16 1.55q-1.38 1.22-3.23 1.86-1.86.6-3.88.6m5.15-2.7v-7.14h1.96v7.38zm13.75 2.54v-7.2l.47 1.28L227.5 45h2.18l7.22 11.81h-1.16l7.21-11.8H245l-8.21 13.43.47-1.27v7.19zM189.16 62.59v1.77h14.28l-1.2-1.77zM189.16 53.74v1.77h12.05v-1.77zM189.16 45v1.77h13.09l1.17-1.77z"/>',
            // Presaylor
            '<path fill="#000" d="M94.82 96V84.8h4.2q1.42 0 2.44.46 1.03.45 1.57 1.32.57.84.56 2.06 0 1.18-.56 2.05-.54.84-1.57 1.31-1.03.45-2.44.46h-3.54l.53-.56V96zm1.19-4-.53-.58h3.5q1.68 0 2.55-.72.87-.73.88-2.06 0-1.35-.88-2.08-.87-.75-2.55-.74h-3.5l.53-.56zm10.94 4V84.8h4.2q1.42 0 2.44.46 1.03.45 1.57 1.32.56.84.56 2.06 0 1.18-.56 2.05-.54.84-1.57 1.31-1.02.45-2.45.45h-3.53l.53-.55V96zm7.65 0-2.88-4.06H113l2.9 4.06zm-6.46-4-.53-.56h3.5q1.68 0 2.55-.74.88-.73.88-2.06 0-1.35-.88-2.08-.87-.75-2.55-.74h-3.5l.53-.56zm12.23-2.2h5.92v1.02h-5.92zm.13 5.18h6.74V96h-7.92V84.8H127v1.02h-6.5zm13.4 1.12q-1.25 0-2.4-.4a5 5 0 0 1-1.75-1.06l.46-.91q.6.57 1.58.97a6 6 0 0 0 3.83.13q.67-.27.97-.72.32-.45.32-.99 0-.66-.38-1.06a2.5 2.5 0 0 0-.98-.62q-.6-.24-1.34-.42t-1.47-.36a7 7 0 0 1-1.36-.55q-.6-.34-1-.88a2.6 2.6 0 0 1-.36-1.45 2.8 2.8 0 0 1 1.79-2.64q.9-.44 2.34-.44a6.6 6.6 0 0 1 3.47 1l-.4.94q-.72-.48-1.54-.7a6 6 0 0 0-1.55-.23q-1.01 0-1.66.27-.66.28-.98.74-.3.45-.3 1.02 0 .66.36 1.06.39.4 1 .62.61.23 1.36.4.73.18 1.45.39.74.21 1.35.54.61.32.99.87.38.54.38 1.42 0 .81-.45 1.52-.45.69-1.37 1.12-.92.42-2.35.42m5.77-.1 5.12-11.2h1.17l5.12 11.2h-1.25l-4.7-10.51h.48L140.9 96zm2.02-3 .35-.95h6.51l.35.96zm14.06 3v-4.16l.27.74-4.75-7.78h1.26l4.18 6.83h-.68l4.18-6.83h1.18l-4.75 7.78.27-.74V96zm8.05 0V84.8h1.18v10.18h6.27V96zm14.9.1q-1.27 0-2.36-.42a6 6 0 0 1-1.87-1.2 6 6 0 0 1-1.23-1.8 6 6 0 0 1-.43-2.28q0-1.23.43-2.26a5.6 5.6 0 0 1 3.1-3q1.08-.44 2.35-.44t2.34.44a5.4 5.4 0 0 1 3.09 2.99q.45 1.05.45 2.27a5.7 5.7 0 0 1-1.68 4.08q-.79.77-1.86 1.2a6 6 0 0 1-2.34.42m0-1.06a5 5 0 0 0 1.85-.34 4.5 4.5 0 0 0 2.48-2.44q.36-.85.35-1.86a4.7 4.7 0 0 0-1.34-3.31 4.8 4.8 0 0 0-3.34-1.33 5 5 0 0 0-3.38 1.33q-.63.61-1 1.47a5 5 0 0 0-.34 1.84 4.8 4.8 0 0 0 1.34 3.33 4.6 4.6 0 0 0 3.38 1.31m9.32.96V84.8h4.2q1.41 0 2.44.46 1.02.45 1.57 1.32.56.84.56 2.06 0 1.18-.56 2.05-.55.84-1.57 1.31-1.02.45-2.45.45h-3.53l.53-.55V96zm7.65 0-2.88-4.06h1.28l2.9 4.06zm-6.46-4-.53-.56h3.5q1.68 0 2.54-.74.89-.73.88-2.06 0-1.35-.87-2.08-.87-.75-2.55-.74h-3.5l.53-.56z"/>',
            // Pink ETH
            '<path d="M145 201 84 229 145 127z" fill="#F1E2E9"/>',
            '<path d="M145 201 84 229l61 36z" fill="#F6ADC4"/>',
            '<path d="m145 201 61 28L145 127z" fill="#FFAAC3"/>',
            '<path d="m145 201 61 28-61 36z" fill="#F78AA8"/>',
            '<path d="m84 240.5 61 86.5v-45z" fill="#F4C1D1"/>',
            '<path d="M207 240.5 145 327v-45z" fill="#FEA4BA"/>',
            '<path d="M145 277 84 240.5l61 42 61-42z" fill="#FECADF"/>',
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
    ) external pure returns (string memory) {
        // If not a presale token, return nothing
        if (!(strikeAmount == 0 && notionalUSDAmount == 0)) {
            return "";
        }

        string memory svg =
            renderSvg(tokenId, strikeAmount, notionalUnderlyingAmount, notionalUSDAmount, expiry, timelock);

        // Encode SVG to base64
        string memory base64Svg = Base64.encode(bytes(svg));

        string memory json = string.concat(
            "{",
            string.concat('"name": "', "ETH Strategy Presale", '",'),
            string.concat(
                '"description": "',
                "This NFT represents participation in the ETH Strategy presale. Proceeds are used to bootstrap the protocol's treasury, establish initial liquidity, and fund initial development. Presaylors acquire STRAT at face value with 6-month vesting (4-month lockup + 2-month linear unlock).",
                '",'
            ),
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

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
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
