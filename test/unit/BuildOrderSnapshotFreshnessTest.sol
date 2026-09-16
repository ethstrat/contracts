// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {BuildOrder} from "../../script/deployments/1/003-espn-redemption/BuildOrder.s.sol";

/// @notice Minimal IERC4626 stand-in — `_checkSnapshotFreshness` only ever calls `totalSupply()`
/// and `totalAssets()` on `espn`, so that's all this needs to implement.
contract MockEspn {
    uint256 public totalSupply;
    uint256 public totalAssets;

    function set(uint256 totalSupply_, uint256 totalAssets_) external {
        totalSupply = totalSupply_;
        totalAssets = totalAssets_;
    }
}

/// @dev Exposes `BuildOrder`'s internal snapshot-freshness check for direct testing, without
/// paying for the full `_buildOrder` flow's ConfigLib/USDS/Seaport setup.
contract BuildOrderHarness is BuildOrder {
    function setEspn(address espn_) external {
        espn = IERC4626(espn_);
    }

    function checkSnapshotFreshness(string memory holdersFile) external view {
        _checkSnapshotFreshness(holdersFile);
    }
}

/// @notice Covers the NAV/supply-drift guard added to `BuildOrder._checkSnapshotFreshness`
/// (founder ask: "can we add a check that NAV didn't change since the snapshot?").
contract BuildOrderSnapshotFreshnessTest is Test {
    BuildOrderHarness harness;
    MockEspn mockEspn;

    function setUp() public {
        harness = new BuildOrderHarness();
        mockEspn = new MockEspn();
        harness.setEspn(address(mockEspn));
    }

    /// @dev Each test writes its own `espn-holders-<block>.json` (distinct block per test, like
    /// `ScriptLibsTest`'s fixtures) — `vm.writeFile` is real file I/O, not EVM state, so a path
    /// shared across tests races when forge runs tests in parallel.
    /// `withTotalAssets = false` omits the `totalAssets` key entirely, matching an older,
    /// pre-NAV-drift-check snapshot file.
    function _writeFixture(uint256 block_, uint256 totalSupply, uint256 totalAssets, bool withTotalAssets)
        internal
        returns (string memory path)
    {
        string memory totalAssetsField =
            withTotalAssets ? string.concat(',"totalAssets":"', vm.toString(totalAssets), '"') : "";
        string memory json = string.concat(
            '{"snapshotBlock":',
            vm.toString(block_),
            ',"totalSupply":"',
            vm.toString(totalSupply),
            '"',
            totalAssetsField,
            ',"holders":[',
            '{"address":"0x1111111111111111111111111111111111111111",',
            '"balance":"1000000000000000000","excluded":false,"isContract":false},',
            '{"address":"0x2222222222222222222222222222222222222222",',
            '"balance":"2000000000000000000","excluded":false,"isContract":false}',
            "]}"
        );
        path = string.concat("./tmp/espn-holders-", vm.toString(block_), ".json");
        vm.writeFile(path, json);
    }

    function test_revertsOnTotalAssetsDrift() public {
        string memory path = _writeFixture(777, 1000e18, 2000e18, true);
        mockEspn.set(1000e18, 2500e18); // totalSupply matches, totalAssets (NAV) drifted

        vm.expectRevert("BuildOrder: ESPN totalAssets drifted since snapshot (NAV moved)");
        harness.checkSnapshotFreshness(path);
    }

    function test_revertsOnTotalSupplyDrift() public {
        string memory path = _writeFixture(778, 1000e18, 2000e18, true);
        mockEspn.set(1100e18, 2000e18); // totalAssets matches, totalSupply drifted

        vm.expectRevert("BuildOrder: ESPN totalSupply drifted since snapshot");
        harness.checkSnapshotFreshness(path);
    }

    function test_passesWhenLiveStateMatchesSnapshot() public {
        string memory path = _writeFixture(779, 1000e18, 2000e18, true);
        mockEspn.set(1000e18, 2000e18);

        harness.checkSnapshotFreshness(path); // does not revert
    }

    function test_passesWhenTotalAssetsAbsentFromOlderSnapshot() public {
        string memory path = _writeFixture(780, 1000e18, 0, false); // no `totalAssets` key at all
        mockEspn.set(1000e18, 999_999e18); // NAV free to differ — check is skipped

        harness.checkSnapshotFreshness(path); // does not revert
    }
}
