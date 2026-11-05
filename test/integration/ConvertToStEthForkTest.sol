// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeBatchDecodedLib} from "../../script/deployments/1/lib/SafeBatchDecodedLib.sol";
import {
    ConvertToStEth,
    IQuoterV2,
    ISwapRouter02,
    IWstETH
} from "../../script/deployments/1/009-eseth-weth-rebalance/ConvertToStEth.s.sol";

contract ConvertToStEthHarness is ConvertToStEth {
    function exposed_buildAndSimulate(uint256 amountEth, Route route, uint256 slippageBps)
        external
        returns (SafeBatchDecodedLib.Tx[] memory, Route)
    {
        return buildAndSimulate(amountEth, route, slippageBps);
    }

    function exposed_uniTxs(uint256 amt, uint256 minWst, uint256 stMint)
        external
        view
        returns (SafeBatchDecodedLib.Tx[] memory)
    {
        return _uniTxs(amt, minWst, stMint);
    }

    function exposed_checkBatch(
        SafeBatchDecodedLib.Tx[] memory txs,
        Route chosen,
        uint256 amt,
        uint256 minWst,
        uint256 slippageBps
    ) external view {
        _checkBatch(txs, chosen, amt, minWst, slippageBps);
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
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant SAFE = 0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1;

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

    function testFork_uniswap_one_passes() public {
        (SafeBatchDecodedLib.Tx[] memory txs, ConvertToStEth.Route chosen) =
            harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Uniswap, 10);
        assertEq(uint8(chosen), uint8(ConvertToStEth.Route.Uniswap));
        assertEq(txs.length, 6);
        assertEq(bytes4(txs[2].data), bytes4(0x04e45aaf));
        for (uint256 i; i < 6; i++) {
            assertEq(txs[i].value, 0);
        }
    }

    function testFork_auto_zeroSlippage_picksUniswap() public {
        // fork block quote beats Lido by ~1.56 bps
        (, ConvertToStEth.Route chosen) = harness.exposed_buildAndSimulate(50, ConvertToStEth.Route.Auto, 0);
        assertEq(uint8(chosen), uint8(ConvertToStEth.Route.Uniswap));
    }

    function testFork_lidoPaused_auto_picksUniswap() public {
        vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
        (, ConvertToStEth.Route chosen) = harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Auto, 10);
        assertEq(uint8(chosen), uint8(ConvertToStEth.Route.Uniswap));
    }

    function testFork_stakeLimit_auto_picksUniswap() public {
        vm.mockCall(STETH, abi.encodeWithSignature("getCurrentStakeLimit()"), abi.encode(uint256(0.5 ether)));
        (, ConvertToStEth.Route chosen) = harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Auto, 10);
        assertEq(uint8(chosen), uint8(ConvertToStEth.Route.Uniswap));
    }

    function testFork_uniswap_zeroQuote_reverts() public {
        vm.mockCall(
            QUOTER,
            abi.encodePacked(bytes4(keccak256("quoteExactInputSingle((address,address,uint256,uint24,uint160))"))),
            abi.encode(uint256(0), uint160(0), uint32(0), uint256(0))
        );
        vm.expectRevert(bytes("ConvertToStEth: Uniswap minWst == 0"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Uniswap, 10);
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

    function _quote(uint256 amt) internal returns (uint256 q) {
        (q,,,) =
            IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(WETH, WSTETH, amt, 100, 0));
    }

    function _args(bytes memory d) internal pure returns (bytes memory a) {
        a = new bytes(d.length - 4);
        for (uint256 i; i < a.length; i++) {
            a[i] = d[i + 4];
        }
    }

    function testFork_uniswap_batchDecodes() public {
        uint256 amt = 1 ether;
        uint256 minWst = _quote(amt) * 9990 / 10_000; // before the build: its simulated swap moves the pool
        (SafeBatchDecodedLib.Tx[] memory txs,) = harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Uniswap, 10);
        uint256 stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;

        assertEq(txs[2].to, ROUTER);
        ISwapRouter02.ExactInputSingleParams memory p =
            abi.decode(_args(txs[2].data), (ISwapRouter02.ExactInputSingleParams));
        assertEq(p.tokenIn, WETH);
        assertEq(p.tokenOut, WSTETH);
        assertEq(p.fee, 100);
        assertEq(p.recipient, SAFE);
        assertEq(p.amountIn, amt);
        assertEq(p.amountOutMinimum, minWst);
        assertEq(p.sqrtPriceLimitX96, 0);
        assertEq(txs[2].data.length, 4 + 7 * 32); // no deadline field

        assertEq(abi.decode(_args(txs[3].data), (uint256)), minWst); // unwrap
        (, uint256 appAmt) = abi.decode(_args(txs[4].data), (address, uint256));
        (, uint256 mintAmt,) = abi.decode(_args(txs[5].data), (address, uint256, address));
        assertEq(appAmt, stMint);
        assertEq(mintAmt, stMint);
        assertGe(mintAmt, amt * 9990 / 10_000); // par floor
    }

    function testFork_lido_batchDecodes() public {
        (SafeBatchDecodedLib.Tx[] memory txs,) = harness.exposed_buildAndSimulate(50, ConvertToStEth.Route.Lido, 10);
        assertEq(txs[2].to, STETH);
        assertEq(txs[2].value, 50 ether);
        (, uint256 mintAmt,) = abi.decode(_args(txs[4].data), (address, uint256, address));
        assertEq(mintAmt, 50 ether - 2);
    }

    function testFork_checkBatch_zeroMinimum_reverts() public {
        uint256 minWst = _quote(1 ether) * 9990 / 10_000;
        uint256 stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_uniTxs(1 ether, 0, stMint);
        vm.expectRevert(bytes("ConvertToStEth batch: swap amountOutMinimum != minWst"));
        harness.exposed_checkBatch(txs, ConvertToStEth.Route.Uniswap, 1 ether, minWst, 10);
    }

    function testFork_checkBatch_untrustedTarget_reverts() public {
        uint256 minWst = _quote(1 ether) * 9990 / 10_000;
        uint256 stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_uniTxs(1 ether, minWst, stMint);
        txs[3].to = address(0xdead);
        vm.expectRevert(bytes("ConvertToStEth batch: tx not allowlisted"));
        harness.exposed_checkBatch(txs, ConvertToStEth.Route.Uniswap, 1 ether, minWst, 10);
    }

    function testFork_checkBatch_wrongMintAmount_reverts() public {
        uint256 minWst = _quote(1 ether) * 9990 / 10_000;
        uint256 stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_uniTxs(1 ether, minWst, stMint + 1);
        vm.expectRevert(bytes("ConvertToStEth batch: approve args"));
        harness.exposed_checkBatch(txs, ConvertToStEth.Route.Uniswap, 1 ether, minWst, 10);
    }

    function _mockLowQuote() internal {
        // 0.5 wstETH ~ 0.6 stETH for 1 ETH in: far below par
        vm.mockCall(
            QUOTER,
            abi.encodePacked(bytes4(keccak256("quoteExactInputSingle((address,address,uint256,uint24,uint160))"))),
            abi.encode(uint256(0.5 ether), uint160(0), uint32(0), uint256(0))
        );
    }

    function testFork_uniswap_belowPar_reverts() public {
        _mockLowQuote();
        vm.expectRevert(bytes("ConvertToStEth: Uniswap stMint below par floor"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Uniswap, 10);
    }

    function testFork_lidoPaused_auto_belowPar_reverts() public {
        _mockLowQuote();
        vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
        vm.expectRevert(bytes("ConvertToStEth: Uniswap stMint below par floor"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Auto, 10);
    }

    function testFork_manipulatedRate_belowPar_reverts() public {
        // pool quote honest, wstETH rate source says wstETH is worth only 0.5 stETH
        vm.mockCall(WSTETH, abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector), abi.encode(uint256(0.5 ether)));
        vm.expectRevert(bytes("ConvertToStEth: Uniswap stMint below par floor"));
        harness.exposed_buildAndSimulate(1, ConvertToStEth.Route.Uniswap, 10);
    }
}
