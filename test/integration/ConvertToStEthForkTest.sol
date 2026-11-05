// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeBatchDecodedLib} from "../../script/deployments/1/lib/SafeBatchDecodedLib.sol";
import {ConvertToStEth} from "../../script/deployments/1/009-eseth-weth-rebalance/ConvertToStEth.s.sol";

contract ConvertToStEthHarness is ConvertToStEth {
    function exposed_buildAndSimulate(uint256 amountEth, Route route, uint256 slippageBps)
        external
        returns (SafeBatchDecodedLib.Tx[] memory, Route)
    {
        return buildAndSimulate(amountEth, route, slippageBps);
    }

    function exposed_parseRoute(string memory s) external pure returns (Route) {
        return _parseRoute(s);
    }
}

/// @notice Fork test for ConvertToStEth. Run: yarn test:integration --match-contract ConvertToStEthForkTest -vv
contract ConvertToStEthForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26345235;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    ConvertToStEthHarness internal harness;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        require(block.chainid == 1, "Must be on mainnet fork");
        harness = new ConvertToStEthHarness();
    }

    function testFork_lido_fifty_passes() public {
        (SafeBatchDecodedLib.Tx[] memory txs, ConvertToStEth.Route chosen) =
            harness.exposed_buildAndSimulate(50, ConvertToStEth.Route.Lido, 10);
        assertEq(uint8(chosen), uint8(ConvertToStEth.Route.Lido));
        assertEq(txs.length, 5);
        assertEq(txs[2].value, 50 ether);
    }

    function testFork_auto_defaultSlippage_picksLido() public {
        (, ConvertToStEth.Route chosen) = harness.exposed_buildAndSimulate(50, ConvertToStEth.Route.Auto, 10);
        assertEq(uint8(chosen), uint8(ConvertToStEth.Route.Lido));
    }

    function testFork_zero_reverts() public {
        vm.expectRevert(bytes("Rebalance: AMOUNT must be > 0"));
        harness.exposed_buildAndSimulate(0, ConvertToStEth.Route.Lido, 10);
    }

    function testFork_slippageAbove100_reverts() public {
        vm.expectRevert(bytes("ConvertToStEth: SLIPPAGE_BPS > 100"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Lido, 101);
    }

    function testFork_lidoPaused_forcedLido_reverts() public {
        vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
        vm.expectRevert(bytes("ConvertToStEth: Lido staking paused"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Lido, 10);
    }

    function testFork_stakeLimit_forcedLido_reverts() public {
        vm.mockCall(STETH, abi.encodeWithSignature("getCurrentStakeLimit()"), abi.encode(uint256(0.5 ether)));
        vm.expectRevert(bytes("ConvertToStEth: AMOUNT > Lido stake limit"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Lido, 10);
    }

    function test_parseRoute_unknownReverts() public {
        vm.expectRevert(bytes("ConvertToStEth: ROUTE must be auto|lido|uniswap"));
        harness.exposed_parseRoute("curve");
    }
}
