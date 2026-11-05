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

    function exposed_firstFreeIndex(string memory op) external view returns (uint256) {
        return _firstFreeIndex(op);
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
}
