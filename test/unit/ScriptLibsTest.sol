// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ConfigLib} from "../../script/deployments/1/lib/ConfigLib.sol";
import {HoldersLib} from "../../script/deployments/1/lib/HoldersLib.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
import {SafeBatchDecodedLib} from "../../script/deployments/1/lib/SafeBatchDecodedLib.sol";
import {ConvertToStEth} from "../../script/deployments/1/009-eseth-weth-rebalance/ConvertToStEth.s.sol";
import {RedepositEth} from "../../script/deployments/1/009-eseth-weth-rebalance/RedepositEth.s.sol";

/// @dev Exposes the real 009 batch builders and writer so the default (no-fork) CI run exercises the
/// real decoded descriptors: `_write` -> `SafeBatchDecodedLib.verify` reverts on any wrong descriptor.
contract ConvertHarness is ConvertToStEth {
    function lido(uint256 amt) external view returns (SafeBatchDecodedLib.Tx[] memory) {
        return _lidoTxs(amt);
    }

    function uni(uint256 amt, uint256 minWst, uint256 stMint) external view returns (SafeBatchDecodedLib.Tx[] memory) {
        return _uniTxs(amt, minWst, stMint);
    }

    function write(string memory op, SafeBatchDecodedLib.Tx[] memory txs)
        external
        returns (string memory, string memory)
    {
        return _write(op, "n", "d", txs);
    }
}

contract RedepositHarness is RedepositEth {
    function txs(uint256 amt) external view returns (SafeBatchDecodedLib.Tx[] memory) {
        return _txs(amt);
    }

    function write(string memory op, SafeBatchDecodedLib.Tx[] memory t)
        external
        returns (string memory, string memory)
    {
        return _write(op, "n", "d", t);
    }
}

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

    function test_ConfigLib_addrArray_excludedAddresses() public view {
        address[] memory excluded = ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses");
        assertEq(excluded.length, 3);
        assertEq(excluded[0], 0x000000000004444c5dc75cB358380D2e3dE08A90); // V4 PoolManager singleton
        assertEq(excluded[1], 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D); // redemption Safe/treasury
        assertEq(excluded[2], 0x0000000000000068F116a894984e2DB1123eB395); // Seaport
    }

    function test_ConfigLib_addr_merklAddresses() public view {
        assertEq(
            ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator"),
            0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd
        );
        assertEq(
            ConfigLib.addr("externalAddresses.json", ".merkl.distributor"), 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae
        );
    }

    function test_ConfigLib_num_merklSettings() public view {
        assertEq(ConfigLib.num("settings.json", ".espnv3.merkl.campaignType"), 18);
        assertEq(ConfigLib.num("settings.json", ".espnv3.merkl.duration"), 604_800);
    }

    function test_ConfigLib_addrArray_emptyMerklBlacklist() public view {
        assertEq(ConfigLib.addrArray("settings.json", ".espnv3.merkl.blacklist").length, 0);
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
        // Dummy safe + non-production operation name so this never collides with the real
        // Task 4/5 output path (script/deployments/1/multisig/003-espn-redemption/001-...json,
        // the redemption treasury's real approve+validate batch) and can't be mistaken for it.
        address safe = 0x1111111111111111111111111111111111111111;
        address spender = 0x0000000000000068F116a894984e2DB1123eB395;
        uint256 amount = 700_000e18;

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({to: spender, data: abi.encodeCall(IERC20.approve, (spender, amount))});

        string memory operation = "999-test-fixture";
        SafeBatchLib.write(safe, operation, 1, "test batch", "test description", txs);

        string memory dir = string.concat("script/deployments/1/multisig/", operation);
        string memory path = SafeBatchLib.path(safe, operation, 1);
        assertEq(path, string.concat(dir, "/001-0x11111111-multisig.json"));
        string memory json = vm.readFile(path);

        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), spender);
        assertEq(
            vm.parseJsonString(json, ".transactions[0].data"),
            vm.toString(abi.encodeCall(IERC20.approve, (spender, amount)))
        );
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), safe);

        // Leave no test artifact behind in the committed multisig output tree.
        vm.removeDir(dir, true);
    }

    function test_SafeBatchLib_writeWithValues_emitsValue() public {
        address safe = 0x1111111111111111111111111111111111111111;
        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](2);
        txs[0] = SafeBatchLib.Tx({to: address(0xA), data: hex"01"});
        txs[1] = SafeBatchLib.Tx({to: address(0xB), data: hex"02"});
        uint256[] memory values = new uint256[](2);
        values[1] = 1 ether;

        string memory operation = "999-test-fixture-values";
        SafeBatchLib.write(safe, operation, 1, "n", "d", txs, values);
        string memory json = vm.readFile(SafeBatchLib.path(safe, operation, 1));

        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        assertEq(vm.parseJsonString(json, ".transactions[1].value"), "1000000000000000000");
        vm.removeDir(string.concat("script/deployments/1/multisig/", operation), true);
    }

    /// @dev Pins the 6-arg writer's exact bytes (format copied from the pre-change writer), so the
    /// delegation is proven byte-identical. The existing round-trip test does not check `value`.
    function test_SafeBatchLib_write_sixArgBytesUnchanged() public {
        address safe = 0x1111111111111111111111111111111111111111;
        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({to: address(0xA), data: hex"01"});

        string memory operation = "999-test-fixture-bytes";
        SafeBatchLib.write(safe, operation, 1, "n", "d", txs);
        string memory expected = string.concat(
            "{\"version\":\"1.0\",\"chainId\":\"1\",\"createdAt\":",
            vm.toString(block.timestamp * 1000),
            ",\"meta\":{\"name\":\"n\",\"description\":\"d\",\"txBuilderVersion\":\"2.0.1\",\"createdFromSafeAddress\":\"",
            vm.toString(safe),
            "\",\"createdFromOwnerAddress\":\"\",\"checksum\":null},\"transactions\":[{\"to\":\"",
            vm.toString(address(0xA)),
            "\",\"value\":\"0\",\"data\":\"0x01\",\"contractMethod\":null,\"contractInputsValues\":null}]}"
        );
        assertEq(vm.readFile(SafeBatchLib.path(safe, operation, 1)), expected);
        vm.removeDir(string.concat("script/deployments/1/multisig/", operation), true);
    }

    function test_SafeBatchDecodedLib_write_valueAndPayable() public {
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](2);
        SafeBatchDecodedLib.Input[] memory none = new SafeBatchDecodedLib.Input[](0);
        SafeBatchDecodedLib.Input[] memory ref = new SafeBatchDecodedLib.Input[](1);
        ref[0] = SafeBatchDecodedLib.Input("_referral", "address", "address", vm.toString(address(0)));
        txs[0] = SafeBatchDecodedLib.Tx(address(0xA), 0, abi.encodeWithSignature("withdraw()"), "withdraw", none);
        txs[1] = SafeBatchDecodedLib.Tx(
            address(0xB), 5, abi.encodeWithSignature("submit(address)", address(0)), "submit", ref
        );
        SafeBatchDecodedLib.verify(txs[0], 0);
        SafeBatchDecodedLib.verify(txs[1], 1);

        string memory path = "./tmp/decoded-test.tx-builder.json";
        SafeBatchDecodedLib.write(path, address(0x1111111111111111111111111111111111111111), "n", "d", txs);
        string memory json = vm.readFile(path);

        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        assertEq(vm.parseJsonString(json, ".transactions[1].value"), "5");
        assertFalse(vm.parseJsonBool(json, ".transactions[0].contractMethod.payable"));
        assertTrue(vm.parseJsonBool(json, ".transactions[1].contractMethod.payable"));
        assertEq(vm.parseJsonString(json, ".transactions[1].contractInputsValues._referral"), vm.toString(address(0)));
        vm.removeFile(path);
    }

    // External wrappers: library internals revert in the test frame, so expectRevert needs a CALL boundary.
    function writeDecodedExt(string memory p, string memory name, SafeBatchDecodedLib.Tx[] memory txs) external {
        SafeBatchDecodedLib.write(p, address(0x1111111111111111111111111111111111111111), name, "d", txs);
    }

    function writeRawExt(SafeBatchLib.Tx[] memory txs, uint256[] memory values) external {
        SafeBatchLib.write(
            address(0x1111111111111111111111111111111111111111), "999-test-fixture-len", 1, "n", "d", txs, values
        );
    }

    function _withdrawTx(uint256 encoded, string memory declared)
        internal
        pure
        returns (SafeBatchDecodedLib.Tx[] memory txs)
    {
        SafeBatchDecodedLib.Input[] memory ins = new SafeBatchDecodedLib.Input[](1);
        ins[0] = SafeBatchDecodedLib.Input("wad", "uint256", "uint256", declared);
        txs = new SafeBatchDecodedLib.Tx[](1);
        txs[0] = SafeBatchDecodedLib.Tx(
            address(0xA), 0, abi.encodeWithSignature("withdraw(uint256)", encoded), "withdraw", ins
        );
    }

    function test_SafeBatchDecodedLib_verify_mismatchReverts() public {
        string memory p = "./tmp/decoded-mismatch.tx-builder.json";
        vm.expectRevert(bytes("SafeBatchDecodedLib.verify: decoded descriptor mismatch for tx 0 (withdraw)"));
        this.writeDecodedExt(p, "n", _withdrawTx(2, "1"));
        assertFalse(vm.exists(p));
    }

    function test_SafeBatchDecodedLib_uint256Input_roundTrips() public {
        string memory p = "./tmp/decoded-uint.tx-builder.json";
        SafeBatchDecodedLib.write(p, address(0x1111111111111111111111111111111111111111), "n", "d", _withdrawTx(2, "2"));
        string memory json = vm.readFile(p);
        assertEq(vm.parseJsonString(json, ".transactions[0].contractInputsValues.wad"), "2");
        assertEq(vm.parseJsonString(json, ".transactions[0].contractMethod.inputs[0].type"), "uint256");
        vm.removeFile(p);
    }

    function test_SafeBatchLib_write_valuesLengthReverts() public {
        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](2);
        txs[0] = SafeBatchLib.Tx(address(0xA), hex"01");
        txs[1] = SafeBatchLib.Tx(address(0xB), hex"02");
        vm.expectRevert(bytes("SafeBatchLib: values length != txs length"));
        this.writeRawExt(txs, new uint256[](1));
    }

    function test_SafeBatchDecodedLib_quoteGuardReverts() public {
        string memory p = "./tmp/decoded-quote.tx-builder.json";
        vm.expectRevert(bytes("SafeBatchDecodedLib: quote or backslash in string"));
        this.writeDecodedExt(p, "a\"b", _withdrawTx(1, "1"));
        assertFalse(vm.exists(p));
        vm.expectRevert(bytes("SafeBatchDecodedLib: quote or backslash in string"));
        this.writeDecodedExt(p, "n", _withdrawTx(1, "1\\"));
        assertFalse(vm.exists(p));
    }

    function test_SafeBatchDecodedLib_rawFallback_writesData() public {
        string memory p = "./tmp/decoded-raw.tx-builder.json";
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](1);
        txs[0] = SafeBatchDecodedLib.Tx(address(0xC), 0, hex"04e45aaf01", "", new SafeBatchDecodedLib.Input[](0));
        SafeBatchDecodedLib.write(p, address(0x1111111111111111111111111111111111111111), "n", "d", txs);
        string memory json = vm.readFile(p);
        assertEq(vm.parseJsonBytes(json, ".transactions[0].data"), hex"04e45aaf01");
        assertTrue(vm.contains(json, "\"contractMethod\":null,\"contractInputsValues\":null"));
        vm.removeFile(p);
    }

    function test_009_realDescriptors_verifyAndWrite() public {
        string memory op = "999-test-fixture-descriptors";
        string memory dir = string.concat("script/deployments/1/multisig/", op);
        if (vm.exists(dir)) vm.removeDir(dir, true); // left behind by a prior failed run
        ConvertHarness c = new ConvertHarness();
        RedepositHarness r = new RedepositHarness();
        (, string memory lidoJson) = c.write(op, c.lido(50 ether));
        (, string memory uniJson) = c.write(op, c.uni(1 ether, 0.8 ether, 0.9 ether));
        (, string memory ethJson) = r.write(op, r.txs(50 ether));

        string memory lido = vm.readFile(lidoJson);
        string memory uniswap = vm.readFile(uniJson);
        string memory eth = vm.readFile(ethJson);
        string[5] memory lidoNames = ["redeem", "withdraw", "submit", "approve", "mint"];
        for (uint256 i; i < lidoNames.length; i++) {
            assertTrue(vm.contains(lido, string.concat("\"name\":\"", lidoNames[i], "\"")));
        }
        assertTrue(vm.contains(uniswap, "\"name\":\"unwrap\""));
        assertTrue(vm.contains(eth, "\"name\":\"wrapAndMint\""));
        vm.removeDir(dir, true);
    }
}
