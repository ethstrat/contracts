// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ConfigLib} from "../../script/deployments/1/lib/ConfigLib.sol";
import {HoldersLib} from "../../script/deployments/1/lib/HoldersLib.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";

contract ScriptLibsTest is Test {
    function test_ConfigLib_addr_confirmedAddresses() public view {
        assertEq(
            ConfigLib.addr("externalAddresses.json", ".opensea.seaport"), 0x0000000000000068F116a894984e2DB1123eB395
        );
        assertEq(
            ConfigLib.addr("externalAddresses.json", ".sky-money.USDS"), 0xdC035D45d973E3EC169d2276DDab16f1e407384F
        );
        assertEq(
            ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn"), 0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE
        );
        assertEq(
            ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption"),
            0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D
        );
    }

    function test_ConfigLib_num_targetRedemptionUsd() public view {
        assertEq(ConfigLib.num("settings.json", ".espnv3.targetRedemptionUsd"), 700_000e18);
    }

    function test_ConfigLib_num_basisPriceAndFillGrid() public view {
        assertEq(ConfigLib.num("settings.json", ".espnv3.basisPriceUsd"), 100);
        assertEq(ConfigLib.num("settings.json", ".espnv3.fillGrid"), 1_000_000_000);
    }

    function test_ConfigLib_addrArray_emptyExcludedAddresses() public view {
        assertEq(ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses").length, 0);
    }

    function _writeFixture(string memory path, uint256 bodyBlock) internal {
        string memory json = string.concat(
            '{"snapshotBlock":',
            vm.toString(bodyBlock),
            ',"totalSupply":"3000000000000000000",',
            '"holders":[',
            '{"address":"0x1111111111111111111111111111111111111111","balance":"1000000000000000000","excluded":true,"isContract":false},',
            '{"address":"0x2222222222222222222222222222222222222222","balance":"2000000000000000000","excluded":false,"isContract":true}',
            "]}"
        );
        vm.writeFile(path, json);
    }

    function test_HoldersLib_load_decodesAndCrossChecks() public {
        string memory path = "./tmp/espn-holders-123.json";
        _writeFixture(path, 123);

        HoldersLib.Snapshot memory snapshot = HoldersLib.load(path);

        assertEq(snapshot.snapshotBlock, 123);
        assertEq(snapshot.holders.length, 2);

        assertEq(snapshot.holders[0].addr, 0x1111111111111111111111111111111111111111);
        assertEq(vm.parseUint(snapshot.holders[0].balance), 1e18);
        assertTrue(snapshot.holders[0].excluded);
        assertFalse(snapshot.holders[0].isContract);

        assertEq(snapshot.holders[1].addr, 0x2222222222222222222222222222222222222222);
        assertEq(vm.parseUint(snapshot.holders[1].balance), 2e18);
        assertFalse(snapshot.holders[1].excluded);
        assertTrue(snapshot.holders[1].isContract);

        (address[] memory addrs, uint256[] memory balances, uint256 includedCount, uint256 excludedCount) =
            HoldersLib.included(snapshot);
        assertEq(includedCount, 1);
        assertEq(excludedCount, 1);
        assertEq(addrs.length, 1);
        assertEq(addrs[0], 0x2222222222222222222222222222222222222222);
        assertEq(balances[0], 2e18);
        assertEq(HoldersLib.sum(balances), 2e18);
    }

    function test_HoldersLib_load_revertsOnBlockMismatch() public {
        string memory path = "./tmp/espn-holders-999.json";
        _writeFixture(path, 123); // body says 123, filename says 999

        vm.expectRevert();
        this._loadExternal(path);
    }

    /// @dev `HoldersLib.load` is a library-internal call inlined into this contract, so
    /// `vm.expectRevert` cannot observe its revert directly — it needs a CALL boundary.
    function _loadExternal(string memory path) external view {
        HoldersLib.load(path);
    }

    function test_SafeBatchLib_write_roundTrips() public {
        address safe = 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D;
        address spender = 0x0000000000000068F116a894984e2DB1123eB395;
        uint256 amount = 700_000e18;

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({to: spender, data: abi.encodeCall(IERC20.approve, (spender, amount))});

        SafeBatchLib.write(safe, "003-espn-redemption", 1, "test batch", "test description", txs);

        string memory path = "script/deployments/1/multisig/003-espn-redemption/001-0x0cbe9bDD-multisig.json";
        string memory json = vm.readFile(path);

        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), spender);
        assertEq(
            vm.parseJsonString(json, ".transactions[0].data"),
            vm.toString(abi.encodeCall(IERC20.approve, (spender, amount)))
        );
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), safe);
    }
}
