// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Distribute} from "../../script/deployments/1/004-stry-migration/Distribute.s.sol";
import {MockEspn} from "./BuildOrderSnapshotFreshnessTest.sol";

contract EarnDistributeHarness is Distribute {
    function checkSnapshotFreshness(address espn, string memory holdersFile) external view {
        _checkSnapshotFreshness(espn, holdersFile);
    }
}

/// @notice Track B Distribute.run() must refuse to mint if live ESPN supply or NAV moved since the
/// snapshot. Strict: a snapshot without `totalAssets` also refuses (EARN sizing depends on NAV).
contract EarnDistributeSnapshotFreshnessTest is Test {
    EarnDistributeHarness harness;
    MockEspn mockEspn;

    function setUp() public {
        harness = new EarnDistributeHarness();
        mockEspn = new MockEspn();
    }

    /// @dev Distinct block per test: vm.writeFile is real file I/O, shared paths race in parallel.
    function _writeFixture(uint256 block_, uint256 totalSupply, string memory totalAssetsField)
        internal
        returns (string memory path)
    {
        string memory json = string.concat(
            '{"snapshotBlock":',
            vm.toString(block_),
            ',"totalSupply":"',
            vm.toString(totalSupply),
            '"',
            totalAssetsField,
            ',"holders":[{"address":"0x1111111111111111111111111111111111111111",',
            '"balance":"1000000000000000000","excluded":false,"isContract":false},',
            // Two holders: parseJson on a one-element array decodes as a scalar, not an array.
            '{"address":"0x2222222222222222222222222222222222222222",',
            '"balance":"2000000000000000000","excluded":false,"isContract":false}]}'
        );
        path = string.concat("./tmp/espn-holders-", vm.toString(block_), ".json");
        vm.writeFile(path, json);
    }

    function test_revertsOnTotalAssetsDrift() public {
        string memory path = _writeFixture(881, 1000e18, ',"totalAssets":"2000000000000000000000"');
        mockEspn.set(1000e18, 2500e18);
        vm.expectRevert("Distribute: ESPN totalAssets drifted since snapshot (NAV moved)");
        harness.checkSnapshotFreshness(address(mockEspn), path);
    }

    function test_revertsOnTotalSupplyDrift() public {
        string memory path = _writeFixture(882, 1000e18, ',"totalAssets":"2000000000000000000000"');
        mockEspn.set(1100e18, 2000e18);
        vm.expectRevert("Distribute: ESPN totalSupply drifted since snapshot");
        harness.checkSnapshotFreshness(address(mockEspn), path);
    }

    function test_revertsWhenSnapshotLacksTotalAssets() public {
        string memory path = _writeFixture(883, 1000e18, "");
        mockEspn.set(1000e18, 2000e18);
        vm.expectRevert("Distribute: ESPN totalAssets drifted since snapshot (NAV moved)");
        harness.checkSnapshotFreshness(address(mockEspn), path);
    }

    function test_passesWhenLiveStateMatchesSnapshot() public {
        string memory path = _writeFixture(884, 1000e18, ',"totalAssets":"2000000000000000000000"');
        mockEspn.set(1000e18, 2000e18);
        harness.checkSnapshotFreshness(address(mockEspn), path);
    }
}
