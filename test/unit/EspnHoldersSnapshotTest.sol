// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HoldersLib} from "../../script/deployments/1/lib/HoldersLib.sol";

/// @notice Proves the artifact/consumer contract between `script/snapshot/espn-holders.mjs`'s
/// output and `HoldersLib.load` end-to-end, against the REAL committed snapshot rather than a
/// hand-written fixture. `ScriptLibsTest`'s fixture only uses 1e18/2e18 balances, which sit on
/// the safe side of a `vm.parseJson` magnitude-based type-inference boundary (~9.22e18, `int64`
/// max) that a real holder set straddles — this test is what catches a regression there.
contract EspnHoldersSnapshotTest is Test {
    string constant SNAPSHOT_PATH = "script/deployments/1/config/espn-holders-25800912.json";

    function test_load_decodesCommittedSnapshot() public view {
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(SNAPSHOT_PATH);

        assertEq(snapshot.snapshotBlock, 25800912);
        assertEq(snapshot.totalSupply, 34795546682818036103184);
        assertEq(snapshot.holders.length, 113);

        uint256 sum;
        bool sawBalanceAboveInt64Max;
        for (uint256 i = 0; i < snapshot.holders.length; i++) {
            uint256 balance = vm.parseUint(snapshot.holders[i].balance);
            sum += balance;
            if (balance > uint256(uint64(type(int64).max))) sawBalanceAboveInt64Max = true;
        }

        // Sanity check that this test actually exercises the coercion boundary rather than
        // silently sitting below it like ScriptLibsTest's fixture does.
        assertTrue(sawBalanceAboveInt64Max, "fixture no longer exercises the parseJson coercion boundary");
        assertEq(sum, snapshot.totalSupply);
    }
}
