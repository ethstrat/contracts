// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuildOrderLib} from "../../script/deployments/1/003-espn-redemption/BuildOrderLib.sol";

contract BuildOrderLibTest is Test {
    uint256 internal constant FILL_GRID = 1_000_000_000;
    uint256 internal constant REDEMPTION_RATIO = 5;
    uint256 internal constant TARGET_REDEMPTION_USD = 700_000e18;

    // Block-25,800,591 figures from the design spec / plan.
    uint256 internal constant REAL_TOTAL_ASSETS = 3878653235910468821362228;
    uint256 internal constant REAL_TOTAL_SUPPLY = 34795546682818036103184;

    function test_deriveAmounts_atSnapshotFigures() public pure {
        (uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk, uint256 navPerEspn) = BuildOrderLib.deriveAmounts(
            TARGET_REDEMPTION_USD, REDEMPTION_RATIO, FILL_GRID, REAL_TOTAL_ASSETS, REAL_TOTAL_SUPPLY
        );

        assertEq(navPerEspn, 111469817424243522517);
        assertEq(usdsOffer, TARGET_REDEMPTION_USD);
        assertEq(usdsOffer % FILL_GRID, 0);
        assertEq(espnAsk % FILL_GRID, 0);
        assertEq(redemptionAsk % FILL_GRID, 0);
        assertEq(redemptionAsk, espnAsk * REDEMPTION_RATIO);
    }

    function test_deriveAmounts_snapsToGrid_awkwardNavs() public pure {
        // (i) a prime-ish totalAssets (not a round multiple of anything), real totalSupply/target.
        _assertSnapped(3878653235910468821362231, REAL_TOTAL_SUPPLY, TARGET_REDEMPTION_USD);

        // (ii) totalAssets == totalSupply forces navPerEspn == 1e18 exactly, so espnAskRaw ==
        // target exactly; a target ending in 9 makes both usdsOfferRaw and espnAskRaw end in 9 —
        // raw amounts that are deliberately not clean multiples of the grid.
        _assertSnapped(1, 1, TARGET_REDEMPTION_USD + 9);
    }

    function _assertSnapped(uint256 totalAssets, uint256 totalSupply, uint256 target) internal pure {
        (uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk,) =
            BuildOrderLib.deriveAmounts(target, REDEMPTION_RATIO, FILL_GRID, totalAssets, totalSupply);
        assertEq(usdsOffer % FILL_GRID, 0);
        assertEq(espnAsk % FILL_GRID, 0);
        assertEq(redemptionAsk % FILL_GRID, 0);
        assertEq(redemptionAsk, espnAsk * REDEMPTION_RATIO);
    }

    /// @dev With equal ESPN and REDEMPTION balances, the REDEMPTION leg always binds (redemptionAsk
    /// == 5 * espnAsk), and the numerator the formula returns must be one the holder can actually
    /// afford on both legs.
    function testFuzz_deriveNumerator_redemptionBoundAndAffordable(uint256 balance) public pure {
        balance = bound(balance, 0, 1e30);
        (, uint256 espnAsk, uint256 redemptionAsk,) = BuildOrderLib.deriveAmounts(
            TARGET_REDEMPTION_USD, REDEMPTION_RATIO, FILL_GRID, REAL_TOTAL_ASSETS, REAL_TOTAL_SUPPLY
        );

        uint256 n = BuildOrderLib.deriveNumerator(balance, balance, espnAsk, redemptionAsk, FILL_GRID);

        assertEq(n, balance * FILL_GRID / redemptionAsk, "REDEMPTION leg must bind when balances are equal");
        assertLe(espnAsk * n / FILL_GRID, balance);
        assertLe(redemptionAsk * n / FILL_GRID, balance);
    }

    /// @dev The grid invariant `_getFraction` depends on: every derived amount times any numerator
    /// up to `fillGrid` is itself a multiple of `fillGrid`. Asserted directly, not inferred.
    function testFuzz_gridInvariant_holdsForAnyNumerator(uint256 n) public pure {
        n = bound(n, 1, FILL_GRID);
        (uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk,) = BuildOrderLib.deriveAmounts(
            TARGET_REDEMPTION_USD, REDEMPTION_RATIO, FILL_GRID, REAL_TOTAL_ASSETS, REAL_TOTAL_SUPPLY
        );

        assertEq(usdsOffer * n % FILL_GRID, 0);
        assertEq(espnAsk * n % FILL_GRID, 0);
        assertEq(redemptionAsk * n % FILL_GRID, 0);
    }
}
