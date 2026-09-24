// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProposeLp} from "../../script/deployments/1/005-earn-lp/ProposeLp.s.sol";

/// @dev deriveTicks/deriveLiquidity/floorToSpacing/ceilToSpacing are `internal` on the ProposeLp
/// Script contract; this harness re-exports them as `external`. Same pattern as PeriodicYieldTest.
contract ProposeLpHarness is ProposeLp {
    function exposedDeriveTicks(bool earnIsC0, uint256 basis, uint256 lo, uint256 hi, int24 s)
        external
        pure
        returns (uint160, int24, int24, int24)
    {
        return deriveTicks(earnIsC0, basis, lo, hi, s);
    }

    function exposedDeriveLiquidity(bool earnIsC0, uint160 sqrtPriceX96, int24 bandLower, int24 bandUpper, int24 s)
        external
        pure
        returns (uint128, uint128)
    {
        return deriveLiquidity(earnIsC0, sqrtPriceX96, bandLower, bandUpper, s, 250_000e18, 2_500e18, 250_000e18);
    }

    function exposedFloor(int24 t, int24 s) external pure returns (int24) {
        return floorToSpacing(t, s);
    }

    function exposedCeil(int24 t, int24 s) external pure returns (int24) {
        return ceilToSpacing(t, s);
    }
}

contract ProposeLpTest is Test {
    ProposeLpHarness internal harness;

    function setUp() public {
        harness = new ProposeLpHarness();
    }

    // Spec section 6 reference table, B = Hi = 100, Lo = 50, s = 60.

    function test_deriveTicks_caseA_referenceTable() public view {
        (uint160 sqrtP, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(true, 100, 50, 100, 60);
        assertEq(sqrtP, 792281625142643375935439503360);
        assertEq(tick, 46054);
        assertEq(lower, 39120);
        assertEq(upper, 46020);
    }

    function test_deriveTicks_caseB_referenceTable() public view {
        (uint160 sqrtP, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(false, 100, 50, 100, 60);
        assertEq(sqrtP, 7922816251426433759354395033);
        assertEq(tick, -46055);
        assertEq(lower, -46020);
        assertEq(upper, -39120);
    }

    // Equality case (spec V3): with s = 1 every tick is a spacing multiple, so the near band edge
    // lands exactly on currentTick. Case A keeps it (currentTick >= upper is still USDS-only);
    // Case B must move it up one spacing (currentTick == lower would be in range).

    function test_deriveTicks_caseA_upperEqualsCurrentTickStays() public view {
        (, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(true, 100, 50, 100, 1);
        assertEq(tick, 46054);
        assertEq(upper, 46054);
        assertEq(lower, 39122);
    }

    function test_deriveTicks_caseB_lowerEqualsCurrentTickMovesUp() public view {
        (, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(false, 100, 50, 100, 1);
        assertEq(tick, -46055);
        assertEq(lower, -46054);
        assertEq(upper, -39123);
    }

    // Hi < B (spec N4): the same rounding rule covers it; no extra spacing is added.

    function test_deriveTicks_bandUpperBelowBasis() public view {
        (,, int24 lowerA, int24 upperA) = harness.exposedDeriveTicks(true, 100, 50, 90, 60);
        assertEq(lowerA, 39120);
        assertEq(upperA, 45000);
        (,, int24 lowerB, int24 upperB) = harness.exposedDeriveTicks(false, 100, 50, 90, 60);
        assertEq(lowerB, -45000);
        assertEq(upperB, -39120);
    }

    // A band above the pool price would hold EARN. buildBatch rejects Hi > B first; this pins
    // deriveTicks' own guard for both orderings.

    function test_deriveTicks_caseA_revertsWhenBandAbovePrice() public {
        vm.expectRevert(bytes("ProposeLp: bid wall would hold EARN (case A)"));
        harness.exposedDeriveTicks(true, 100, 50, 200, 60);
    }

    function test_deriveTicks_caseB_revertsWhenBandAbovePrice() public {
        vm.expectRevert(bytes("ProposeLp: bid wall would hold EARN (case B)"));
        harness.exposedDeriveTicks(false, 100, 50, 200, 60);
    }

    // Liquidity: both orderings give the same values, and the amounts they settle are <= the
    // configured amounts (checked by the fork runs; values here pin the math).

    function test_deriveLiquidity_bothCases() public view {
        (uint160 sqrtA,, int24 lowerA, int24 upperA) = harness.exposedDeriveTicks(true, 100, 50, 100, 60);
        (uint128 fullA, uint128 bandA) = harness.exposedDeriveLiquidity(true, sqrtA, lowerA, upperA, 60);
        (uint160 sqrtB,, int24 lowerB, int24 upperB) = harness.exposedDeriveTicks(false, 100, 50, 100, 60);
        (uint128 fullB, uint128 bandB) = harness.exposedDeriveLiquidity(false, sqrtB, lowerB, upperB, 60);
        assertEq(fullA, 25_000e18 + 135);
        assertEq(fullB, 25_000e18 + 135);
        assertEq(bandA, 85_830_483_191_952_473_195_169);
        assertEq(bandB, 85_830_483_191_952_473_195_169);
    }

    // Sign handling (spec N3): Solidity `/` truncates toward zero.

    function test_floorToSpacing_signs() public view {
        assertEq(harness.exposedFloor(61, 60), 60);
        assertEq(harness.exposedFloor(60, 60), 60);
        assertEq(harness.exposedFloor(0, 60), 0);
        assertEq(harness.exposedFloor(-1, 60), -60);
        assertEq(harness.exposedFloor(-60, 60), -60);
        assertEq(harness.exposedFloor(-61, 60), -120);
    }

    function test_ceilToSpacing_signs() public view {
        assertEq(harness.exposedCeil(61, 60), 120);
        assertEq(harness.exposedCeil(60, 60), 60);
        assertEq(harness.exposedCeil(0, 60), 0);
        assertEq(harness.exposedCeil(-1, 60), 0);
        assertEq(harness.exposedCeil(-60, 60), -60);
        assertEq(harness.exposedCeil(-61, 60), -60);
    }
}
