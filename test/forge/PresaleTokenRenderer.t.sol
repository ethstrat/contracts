// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PresaleTokenRenderer} from "../../src/lib/PresaleTokenRenderer.sol";
import {console2} from "forge-std/console2.sol";

contract PresaleTokenRendererTest is Test {
    PresaleTokenRenderer public renderer;

    function setUp() public {
        renderer = new PresaleTokenRenderer();

        // Set the block timestamp to 2025-06-15
        vm.warp(1749974400);
    }

    function test_render() public {
        // Example values for testing
        uint256 tokenId = 1;
        uint256 strikeAmount = 2000 * 10 ** 18; // 2000 CDT
        uint256 notionalUnderlyingAmount = 15 * 10 ** 17; // 1.5 STRAT
        uint256 notionalUSDAmount = 2200 * 10 ** 18; // $2200
        uint256 expiry = 1751328000; // 2025-06-30
        uint256 timelock = 1751328000; // Same as expiry for this example

        // Generate the URI
        string memory uri =
            renderer.render(tokenId, strikeAmount, notionalUnderlyingAmount, notionalUSDAmount, expiry, timelock);

        // Create the tmp directory if it doesn't exist
        vm.createDir("tmp", true);

        // Write to file
        vm.writeFile("tmp/uri.json", uri);

        console2.log("Wrote token URI to tmp/uri.json");
    }

    function test_renderSvg() public {
        // Example values for testing
        uint256 tokenId = 1;
        uint256 strikeAmount = 2000.12 * 10 ** 18; // 2000.12 CDT
        uint256 notionalUnderlyingAmount = 22.33 * 10 ** 18; // 22.33 STRAT
        uint256 notionalUSDAmount = 2200.44 * 10 ** 18; // $2200.44
        uint256 expiry = 1751328000; // 2025-07-01
        uint256 timelock = 1751328000; // Same as expiry for this example

        // Generate the SVG
        string memory svg =
            renderer.renderSvg(tokenId, strikeAmount, notionalUnderlyingAmount, notionalUSDAmount, expiry, timelock);

        // Create the tmp directory if it doesn't exist
        vm.createDir("tmp", true);

        // Write to file
        vm.writeFile("tmp/timelocked.svg", svg);

        console2.log("Wrote SVG to tmp/timelocked.svg");
    }

    function test_renderSvg_unlocked() public {
        // Example values for testing
        uint256 tokenId = 1;
        uint256 strikeAmount = 2000.12 * 10 ** 18; // 2000.12 CDT
        uint256 notionalUnderlyingAmount = 22.33 * 10 ** 18; // 22.33 STRAT
        uint256 notionalUSDAmount = 2200.44 * 10 ** 18; // $2200.44
        uint256 expiry = 1751328000; // 2025-07-01
        uint256 timelock = 1751328000; // Same as expiry for this example

        // Warp to timelock time
        vm.warp(1751328000 + 1);

        // Generate the SVG
        string memory svg =
            renderer.renderSvg(tokenId, strikeAmount, notionalUnderlyingAmount, notionalUSDAmount, expiry, timelock);

        // Create the tmp directory if it doesn't exist
        vm.createDir("tmp", true);

        // Write to file
        vm.writeFile("tmp/unlocked.svg", svg);

        console2.log("Wrote SVG to tmp/unlocked.svg");
    }
}
