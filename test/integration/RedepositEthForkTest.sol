// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {esETH} from "../../src/esETH.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
import {SafeBatchDecodedLib} from "../../script/deployments/1/lib/SafeBatchDecodedLib.sol";
import {RedepositEth} from "../../script/deployments/1/009-eseth-weth-rebalance/RedepositEth.s.sol";

contract RedepositEthHarness is RedepositEth {
    function exposed_buildAndSimulate(uint256 amountEth) external returns (SafeBatchDecodedLib.Tx[] memory) {
        return buildAndSimulate(amountEth);
    }

    function exposed_txs(uint256 amt) external view returns (SafeBatchDecodedLib.Tx[] memory) {
        return _txs(amt);
    }

    function exposed_checkBatch(SafeBatchDecodedLib.Tx[] memory txs, uint256 amt) external view {
        _checkBatch(txs, amt);
    }

    function exposed_firstFreeIndex(string memory op) external view returns (uint256) {
        return _firstFreeIndex(op);
    }
}

/// @dev Emits a batch only `_checkBatch` rejects; proves `buildAndSimulate` invokes it.
contract RedepositEthTampered is RedepositEthHarness {
    function _txs(uint256 amt) internal view override returns (SafeBatchDecodedLib.Tx[] memory txs) {
        txs = super._txs(amt);
        txs[2].data = abi.encodeCall(esETH.wrapAndMint, (address(1))); // the simulation does not care
    }
}

/// @notice Fork test for RedepositEth. Run: yarn test:integration --match-contract RedepositEthForkTest -vv
contract RedepositEthForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26345235;
    address internal constant SAFE = 0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1;
    address internal constant ESETH = 0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    RedepositEthHarness internal harness;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        require(block.chainid == 1, "Must be on mainnet fork");
        harness = new RedepositEthHarness();
    }

    function testFork_one_passes() public {
        uint256 safeEsEthBefore = IERC20(ESETH).balanceOf(SAFE);
        uint256 wethEsEthBefore = IERC20(WETH).balanceOf(ESETH);
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_buildAndSimulate(1);
        assertEq(txs.length, 3);
        assertEq(txs[2].value, 1 ether);
        assertEq(txs[0].value + txs[1].value, 0);
        assertEq(safeEsEthBefore - IERC20(ESETH).balanceOf(SAFE), 1);
        assertEq(IERC20(WETH).balanceOf(ESETH), wethEsEthBefore);
    }

    function testFork_fifty_passes() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_buildAndSimulate(50);
        assertEq(txs[2].value, 50 ether);
    }

    function testFork_thresholdAboveOne_passes() public {
        vm.store(SAFE, bytes32(uint256(4)), bytes32(uint256(2)));
        harness.exposed_buildAndSimulate(1);
    }

    function testFork_zero_reverts() public {
        vm.expectRevert(bytes("Rebalance: AMOUNT must be > 0"));
        harness.exposed_buildAndSimulate(0);
    }

    function testFork_aboveWethBalance_reverts() public {
        uint256 over = IERC20(WETH).balanceOf(ESETH) / 1e18 + 1;
        vm.expectRevert(bytes("Rebalance: AMOUNT > WETH.balanceOf(esETH)"));
        harness.exposed_buildAndSimulate(over);
    }

    function testFork_weiPassedByMistake_reverts() public {
        vm.expectRevert(bytes("Rebalance: AMOUNT > WETH.balanceOf(esETH)"));
        harness.exposed_buildAndSimulate(50000000000000000000);
    }

    function testFork_aboveTotalMinted_reverts() public {
        (,,, uint256 totalMinted) = esETH(payable(ESETH)).tokenConfigs(WETH);
        deal(WETH, ESETH, totalMinted + 5 ether);
        vm.expectRevert(bytes("Rebalance: AMOUNT > esETH WETH totalMinted"));
        harness.exposed_buildAndSimulate(totalMinted / 1e18 + 1);
    }

    function testFork_safeEsEthZero_reverts() public {
        deal(ESETH, SAFE, 0);
        vm.expectRevert(bytes("Rebalance: AMOUNT + 1 > esETH.balanceOf(Safe)"));
        harness.exposed_buildAndSimulate(1);
    }

    function test_firstFreeIndex_skipsExisting() public {
        string memory op = "999-test-fixture-index";
        assertEq(harness.exposed_firstFreeIndex(op), 1);
        vm.createDir(string.concat("script/deployments/1/multisig/", op), true);
        vm.writeFile(SafeBatchLib.path(SAFE, op, 1), "{}");
        assertEq(harness.exposed_firstFreeIndex(op), 2);
        vm.removeDir(string.concat("script/deployments/1/multisig/", op), true);
    }

    // ---- _checkCommon guards ----

    function testFork_treasuryManagerNotSafe_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("treasuryManager()"), abi.encode(address(1)));
        vm.expectRevert(bytes("Rebalance: esETH.treasuryManager() != Safe"));
        harness.exposed_buildAndSimulate(1);
    }

    function testFork_safeNotMinter_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("isMinter(address)", SAFE), abi.encode(false));
        vm.expectRevert(bytes("Rebalance: Safe is not an esETH minter"));
        harness.exposed_buildAndSimulate(1);
    }

    function testFork_wethTokenTypeNotErc20_reverts() public {
        vm.mockCall(
            ESETH, abi.encodeWithSignature("tokenConfigs(address)", WETH), abi.encode(uint8(0), true, true, uint256(0))
        );
        vm.expectRevert(bytes("Rebalance: WETH tokenType != ERC20"));
        harness.exposed_buildAndSimulate(1);
    }

    // ---- _checkBatch negative tests: one tampered field per test ----

    uint256 internal constant AMT = 1 ether;

    function _expect(SafeBatchDecodedLib.Tx[] memory txs, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        harness.exposed_checkBatch(txs, AMT);
    }

    function testFork_checkBatch_txCountShort_reverts() public {
        SafeBatchDecodedLib.Tx[] memory t = harness.exposed_txs(AMT);
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](2);
        txs[0] = t[0];
        txs[1] = t[1];
        _expect(txs, "RedepositEth batch: tx count");
    }

    function testFork_checkBatch_txCountLong_reverts() public {
        SafeBatchDecodedLib.Tx[] memory t = harness.exposed_txs(AMT);
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](4);
        txs[0] = t[0];
        txs[1] = t[1];
        txs[2] = t[2];
        txs[3] = t[2];
        _expect(txs, "RedepositEth batch: tx count");
    }

    function testFork_checkBatch_redeemValue_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[0].value = 1;
        _expect(txs, "RedepositEth batch: unexpected tx value");
    }

    function testFork_checkBatch_withdrawValue_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[1].value = 1;
        _expect(txs, "RedepositEth batch: unexpected tx value");
    }

    function testFork_checkBatch_wrapAndMintValue_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[2].value = AMT - 1;
        _expect(txs, "RedepositEth batch: unexpected tx value");
    }

    function testFork_checkBatch_redeemToken_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[0].data = abi.encodeCall(esETH.redeem, (address(1), AMT, SAFE));
        _expect(txs, "RedepositEth batch: redeem args");
    }

    function testFork_checkBatch_redeemAmount_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[0].data = abi.encodeCall(esETH.redeem, (WETH, AMT + 1, SAFE));
        _expect(txs, "RedepositEth batch: redeem args");
    }

    function testFork_checkBatch_redeemReceiver_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[0].data = abi.encodeCall(esETH.redeem, (WETH, AMT, address(1)));
        _expect(txs, "RedepositEth batch: redeem args");
    }

    function testFork_checkBatch_withdrawAmount_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[1].data = abi.encodeWithSelector(bytes4(keccak256("withdraw(uint256)")), AMT + 1);
        _expect(txs, "RedepositEth batch: withdraw amount");
    }

    function testFork_checkBatch_wrapAndMintReceiver_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[2].data = abi.encodeCall(esETH.wrapAndMint, (address(1)));
        _expect(txs, "RedepositEth batch: wrapAndMint receiver");
    }

    function testFork_checkBatch_wrongTarget_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[1].to = address(0xdead);
        _expect(txs, "Rebalance batch: wrong target/selector");
    }

    function testFork_checkBatch_wrongSelector_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_txs(AMT);
        txs[2].data = abi.encodeWithSelector(bytes4(0xdeadbeef), SAFE);
        _expect(txs, "Rebalance batch: wrong target/selector");
    }

    function testFork_buildRunsCheckBatch() public {
        RedepositEthTampered t = new RedepositEthTampered();
        vm.expectRevert(bytes("RedepositEth batch: wrapAndMint receiver"));
        t.exposed_buildAndSimulate(1);
    }

    // ---- post-simulation asserts ----

    function testFork_sim_wethChanged_reverts() public {
        bytes[] memory rets = new bytes[](3);
        rets[0] = abi.encode(uint256(1000 ether)); // _checkCommon
        rets[1] = abi.encode(uint256(1000 ether)); // before
        rets[2] = abi.encode(uint256(1000 ether + 1)); // after
        vm.mockCalls(WETH, abi.encodeWithSignature("balanceOf(address)", ESETH), rets);
        vm.expectRevert(bytes("RedepositEth sim: esETH WETH changed"));
        harness.exposed_buildAndSimulate(1);
    }

    function testFork_sim_totalMintedChanged_reverts() public {
        (,,, uint256 minted) = esETH(payable(ESETH)).tokenConfigs(WETH);
        bytes[] memory rets = new bytes[](3);
        rets[0] = abi.encode(uint8(1), true, true, minted); // _checkCommon
        rets[1] = rets[0]; // before
        rets[2] = abi.encode(uint8(1), true, true, minted + 1); // after
        vm.mockCalls(ESETH, abi.encodeWithSignature("tokenConfigs(address)", WETH), rets);
        vm.expectRevert(bytes("RedepositEth sim: WETH totalMinted changed"));
        harness.exposed_buildAndSimulate(1);
    }

    function testFork_sim_supplyDelta_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1_000_000 ether)));
        vm.expectRevert(bytes("RedepositEth sim: esETH supply delta != 1"));
        harness.exposed_buildAndSimulate(1);
    }

    function testFork_sim_safeEsEthDelta_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("balanceOf(address)", SAFE), abi.encode(uint256(1000 ether)));
        vm.expectRevert(bytes("RedepositEth sim: Safe esETH delta != 1"));
        harness.exposed_buildAndSimulate(1);
    }
}
