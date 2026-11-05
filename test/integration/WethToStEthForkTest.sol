// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {esETH} from "../../src/esETH.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
import {SafeBatchDecodedLib} from "../../script/deployments/1/lib/SafeBatchDecodedLib.sol";
import {
    WethToStEth,
    ILido,
    IQuoterV2,
    ISwapRouter02,
    IWstETH
} from "../../script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol";

contract WethToStEthHarness is WethToStEth {
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

    function exposed_lidoTxs(uint256 amt) external view returns (SafeBatchDecodedLib.Tx[] memory) {
        return _lidoTxs(amt);
    }

    function exposed_simulate(SafeBatchDecodedLib.Tx[] memory txs) external {
        _simulate(txs);
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

    function exposed_firstFreeIndex(string memory op) external view returns (uint256) {
        return _firstFreeIndex(op);
    }
}

/// @dev Builders emit a batch only `_checkBatch` rejects; proves `buildAndSimulate` invokes it on each route.
contract WethToStEthTampered is WethToStEthHarness {
    function _lidoTxs(uint256 amt) internal view override returns (SafeBatchDecodedLib.Tx[] memory txs) {
        txs = super._lidoTxs(amt);
        txs[2].data = abi.encodeCall(ILido.submit, (address(1))); // referral: the simulation does not care
    }

    function _uniTxs(uint256 amt, uint256 minWst, uint256 stMint)
        internal
        view
        override
        returns (SafeBatchDecodedLib.Tx[] memory txs)
    {
        txs = super._uniTxs(amt, minWst, stMint);
        txs[2].data = abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (ISwapRouter02.ExactInputSingleParams(WETH_, WSTETH_, 100, SAFE_, amt, minWst - 1, 0))
        ); // looser minimum: the simulation does not care
    }

    address internal constant WETH_ = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH_ = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant SAFE_ = 0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1;
}

/// @notice Fork test for WethToStEth. Run: yarn test:integration --match-contract WethToStEthForkTest -vv
contract WethToStEthForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26345235;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant SAFE = 0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1;
    address internal constant ESETH = 0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb;
    uint256 internal constant AMT = 1 ether;

    WethToStEthHarness internal harness;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        require(block.chainid == 1, "Must be on mainnet fork");
        harness = new WethToStEthHarness();
    }

    function testFork_lido_fifty_passes() public {
        (SafeBatchDecodedLib.Tx[] memory txs, WethToStEth.Route chosen) =
            harness.exposed_buildAndSimulate(50, WethToStEth.Route.Lido, 10);
        assertEq(uint8(chosen), uint8(WethToStEth.Route.Lido));
        assertEq(txs.length, 5);
        assertEq(txs[2].value, 50 ether);
    }

    function testFork_auto_defaultSlippage_picksLido() public {
        (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(50, WethToStEth.Route.Auto, 10);
        assertEq(uint8(chosen), uint8(WethToStEth.Route.Lido));
    }

    function testFork_uniswap_one_passes() public {
        (SafeBatchDecodedLib.Tx[] memory txs, WethToStEth.Route chosen) =
            harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
        assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
        assertEq(txs.length, 6);
        assertEq(bytes4(txs[2].data), bytes4(0x04e45aaf));
        for (uint256 i; i < 6; i++) {
            assertEq(txs[i].value, 0);
        }
    }

    function testFork_auto_zeroSlippage_picksUniswap() public {
        // fork block quote beats Lido by ~1.56 bps
        (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(50, WethToStEth.Route.Auto, 0);
        assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
    }

    function testFork_lidoPaused_auto_picksUniswap() public {
        vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
        (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(1, WethToStEth.Route.Auto, 10);
        assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
    }

    function testFork_stakeLimit_auto_picksUniswap() public {
        vm.mockCall(STETH, abi.encodeWithSignature("getCurrentStakeLimit()"), abi.encode(uint256(0.5 ether)));
        (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(1, WethToStEth.Route.Auto, 10);
        assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
    }

    function testFork_uniswap_zeroQuote_reverts() public {
        vm.mockCall(
            QUOTER,
            abi.encodePacked(bytes4(keccak256("quoteExactInputSingle((address,address,uint256,uint24,uint160))"))),
            abi.encode(uint256(0), uint160(0), uint32(0), uint256(0))
        );
        vm.expectRevert(bytes("WethToStEth: Uniswap minWst == 0"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    function testFork_zero_reverts() public {
        vm.expectRevert(bytes("Rebalance: AMOUNT must be > 0"));
        harness.exposed_buildAndSimulate(0, WethToStEth.Route.Lido, 10);
    }

    function testFork_slippageAbove100_reverts() public {
        vm.expectRevert(bytes("WethToStEth: SLIPPAGE_BPS > 100"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 101);
    }

    function testFork_lidoPaused_forcedLido_reverts() public {
        vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
        vm.expectRevert(bytes("WethToStEth: Lido staking paused"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_stakeLimit_forcedLido_reverts() public {
        vm.mockCall(STETH, abi.encodeWithSignature("getCurrentStakeLimit()"), abi.encode(uint256(0.5 ether)));
        vm.expectRevert(bytes("WethToStEth: AMOUNT > Lido stake limit"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function test_parseRoute_unknownReverts() public {
        vm.expectRevert(bytes("WethToStEth: ROUTE must be auto|lido|uniswap"));
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
        (SafeBatchDecodedLib.Tx[] memory txs,) = harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
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
        (SafeBatchDecodedLib.Tx[] memory txs,) = harness.exposed_buildAndSimulate(50, WethToStEth.Route.Lido, 10);
        assertEq(txs[2].to, STETH);
        assertEq(txs[2].value, 50 ether);
        (, uint256 mintAmt,) = abi.decode(_args(txs[4].data), (address, uint256, address));
        assertEq(mintAmt, 50 ether - 2);
    }

    function testFork_checkBatch_zeroMinimum_reverts() public {
        uint256 minWst = _quote(1 ether) * 9990 / 10_000;
        uint256 stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_uniTxs(1 ether, 0, stMint);
        vm.expectRevert(bytes("WethToStEth batch: swap amountOutMinimum != minWst"));
        harness.exposed_checkBatch(txs, WethToStEth.Route.Uniswap, 1 ether, minWst, 10);
    }

    function testFork_checkBatch_untrustedTarget_reverts() public {
        uint256 minWst = _quote(1 ether) * 9990 / 10_000;
        uint256 stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;
        SafeBatchDecodedLib.Tx[] memory txs = harness.exposed_uniTxs(1 ether, minWst, stMint);
        txs[3].to = address(0xdead);
        vm.expectRevert(bytes("Rebalance batch: wrong target/selector"));
        harness.exposed_checkBatch(txs, WethToStEth.Route.Uniswap, 1 ether, minWst, 10);
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
        vm.expectRevert(bytes("WethToStEth: Uniswap stMint below par floor"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    function testFork_lidoPaused_auto_belowPar_reverts() public {
        _mockLowQuote();
        vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
        vm.expectRevert(bytes("WethToStEth: Uniswap stMint below par floor"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Auto, 10);
    }

    function testFork_manipulatedRate_belowPar_reverts() public {
        // pool quote honest, wstETH rate source says wstETH is worth only 0.5 stETH
        vm.mockCall(WSTETH, abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector), abi.encode(uint256(0.5 ether)));
        vm.expectRevert(bytes("WethToStEth: Uniswap stMint below par floor"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    // ---- _checkBatch negative tests: one tampered field per test ----

    function _uni() internal returns (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, uint256 stMint) {
        minWst = _quote(AMT) * 9990 / 10_000;
        stMint = IWstETH(WSTETH).getStETHByWstETH(minWst) - 2;
        txs = harness.exposed_uniTxs(AMT, minWst, stMint);
    }

    function _lido() internal view returns (SafeBatchDecodedLib.Tx[] memory) {
        return harness.exposed_lidoTxs(AMT);
    }

    function _expectUni(SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        harness.exposed_checkBatch(txs, WethToStEth.Route.Uniswap, AMT, minWst, 10);
    }

    function _expectLido(SafeBatchDecodedLib.Tx[] memory txs, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        harness.exposed_checkBatch(txs, WethToStEth.Route.Lido, AMT, 0, 10);
    }

    function _redeem(address token, uint256 amt, address receiver) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(esETH.redeem.selector, token, amt, receiver);
    }

    function _mint(address token, uint256 amt, address receiver) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(esETH.mint.selector, token, amt, receiver);
    }

    function _swapParams(SafeBatchDecodedLib.Tx[] memory txs)
        internal
        pure
        returns (ISwapRouter02.ExactInputSingleParams memory)
    {
        return abi.decode(_args(txs[2].data), (ISwapRouter02.ExactInputSingleParams));
    }

    function _setSwap(SafeBatchDecodedLib.Tx[] memory txs, ISwapRouter02.ExactInputSingleParams memory p)
        internal
        pure
    {
        txs[2].data = abi.encodeCall(ISwapRouter02.exactInputSingle, (p));
    }

    /// @dev Sets approve and mint (last two txs) to `amt` so only the amount bound can trip.
    function _setStMint(SafeBatchDecodedLib.Tx[] memory txs, uint256 amt) internal pure {
        uint256 n = txs.length;
        txs[n - 2].data = abi.encodeCall(ILido.approve, (ESETH, amt));
        txs[n - 1].data = _mint(STETH, amt, SAFE);
    }

    function testFork_checkBatch_routeUnresolved_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        vm.expectRevert(bytes("WethToStEth batch: route unresolved"));
        harness.exposed_checkBatch(txs, WethToStEth.Route.Auto, AMT, 0, 10);
    }

    function testFork_checkBatch_uniTxsOnLidoRoute_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs,,) = _uni();
        _expectLido(txs, "WethToStEth batch: tx count");
    }

    function testFork_checkBatch_lidoTxsOnUniRoute_reverts() public {
        (, uint256 minWst,) = _uni();
        _expectUni(_lido(), minWst, "WethToStEth batch: tx count");
    }

    function testFork_checkBatch_lidoSubmitValueZero_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        txs[2].value = 0;
        _expectLido(txs, "WethToStEth batch: unexpected tx value");
    }

    function testFork_checkBatch_lidoApproveValue_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        txs[3].value = AMT;
        _expectLido(txs, "WethToStEth batch: unexpected tx value");
    }

    function testFork_checkBatch_lidoRedeemValue_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        txs[0].value = 1;
        _expectLido(txs, "WethToStEth batch: unexpected tx value");
    }

    function testFork_checkBatch_uniSwapValue_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[2].value = AMT;
        _expectUni(txs, minWst, "WethToStEth batch: unexpected tx value");
    }

    function testFork_checkBatch_wrongSelector_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[3].data = abi.encodeWithSelector(bytes4(0xdeadbeef), minWst);
        _expectUni(txs, minWst, "Rebalance batch: wrong target/selector");
    }

    function testFork_checkBatch_redeemToken_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[0].data = _redeem(STETH, AMT, SAFE);
        _expectUni(txs, minWst, "WethToStEth batch: redeem args");
    }

    function testFork_checkBatch_redeemAmount_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[0].data = _redeem(WETH, AMT + 1, SAFE);
        _expectUni(txs, minWst, "WethToStEth batch: redeem args");
    }

    function testFork_checkBatch_redeemReceiver_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[0].data = _redeem(WETH, AMT, address(1));
        _expectUni(txs, minWst, "WethToStEth batch: redeem args");
    }

    function testFork_checkBatch_mintToken_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, uint256 stMint) = _uni();
        txs[5].data = _mint(WETH, stMint, SAFE);
        _expectUni(txs, minWst, "WethToStEth batch: mint args");
    }

    function testFork_checkBatch_mintReceiver_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, uint256 stMint) = _uni();
        txs[5].data = _mint(STETH, stMint, address(1));
        _expectUni(txs, minWst, "WethToStEth batch: mint args");
    }

    function testFork_checkBatch_approveSpender_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, uint256 stMint) = _uni();
        txs[4].data = abi.encodeCall(ILido.approve, (address(1), stMint));
        _expectUni(txs, minWst, "WethToStEth batch: approve args");
    }

    function testFork_checkBatch_approveAmountNeqMint_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, uint256 stMint) = _uni();
        txs[4].data = abi.encodeCall(ILido.approve, (ESETH, stMint + 1));
        _expectUni(txs, minWst, "WethToStEth batch: approve args");
    }

    function testFork_checkBatch_wethApproveSpender_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[1].data = abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), address(1), AMT);
        _expectUni(txs, minWst, "WethToStEth batch: WETH approve args");
    }

    function testFork_checkBatch_wethApproveAmount_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[1].data = abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), ROUTER, AMT + 1);
        _expectUni(txs, minWst, "WethToStEth batch: WETH approve args");
    }

    function testFork_checkBatch_swapCalldataLength_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[2].data = bytes.concat(txs[2].data, bytes32(0)); // e.g. a deadline field
        _expectUni(txs, minWst, "WethToStEth batch: swap calldata length");
    }

    function testFork_checkBatch_swapTokenIn_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        ISwapRouter02.ExactInputSingleParams memory p = _swapParams(txs);
        p.tokenIn = STETH;
        _setSwap(txs, p);
        _expectUni(txs, minWst, "WethToStEth batch: swap params");
    }

    function testFork_checkBatch_swapTokenOut_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        ISwapRouter02.ExactInputSingleParams memory p = _swapParams(txs);
        p.tokenOut = STETH;
        _setSwap(txs, p);
        _expectUni(txs, minWst, "WethToStEth batch: swap params");
    }

    function testFork_checkBatch_swapFee_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        ISwapRouter02.ExactInputSingleParams memory p = _swapParams(txs);
        p.fee = 500;
        _setSwap(txs, p);
        _expectUni(txs, minWst, "WethToStEth batch: swap params");
    }

    function testFork_checkBatch_swapRecipient_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        ISwapRouter02.ExactInputSingleParams memory p = _swapParams(txs);
        p.recipient = address(1);
        _setSwap(txs, p);
        _expectUni(txs, minWst, "WethToStEth batch: swap params");
    }

    function testFork_checkBatch_swapAmountIn_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        ISwapRouter02.ExactInputSingleParams memory p = _swapParams(txs);
        p.amountIn = AMT + 1;
        _setSwap(txs, p);
        _expectUni(txs, minWst, "WethToStEth batch: swap params");
    }

    function testFork_checkBatch_swapSqrtPriceLimit_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        ISwapRouter02.ExactInputSingleParams memory p = _swapParams(txs);
        p.sqrtPriceLimitX96 = 1;
        _setSwap(txs, p);
        _expectUni(txs, minWst, "WethToStEth batch: swap params");
    }

    function testFork_checkBatch_unwrapAboveMinWst_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[3].data = abi.encodeCall(IWstETH.unwrap, (minWst + 1));
        _expectUni(txs, minWst, "WethToStEth batch: unwrap > minWst");
    }

    function testFork_checkBatch_unwrapShortOfMint_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        txs[3].data = abi.encodeCall(IWstETH.unwrap, (minWst - 10));
        _expectUni(txs, minWst, "WethToStEth batch: unwrap short of mint");
    }

    function testFork_checkBatch_mintAboveUnwrap_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst, uint256 stMint) = _uni();
        _setStMint(txs, stMint + 1);
        _expectUni(txs, minWst, "WethToStEth batch: unwrap short of mint");
    }

    function testFork_checkBatch_belowParFloor_reverts() public {
        (SafeBatchDecodedLib.Tx[] memory txs, uint256 minWst,) = _uni();
        _setStMint(txs, AMT * 9990 / 10_000 - 1);
        _expectUni(txs, minWst, "WethToStEth: Uniswap stMint below par floor");
    }

    function testFork_checkBatch_lidoWithdrawAmount_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        txs[1].data = abi.encodeWithSelector(bytes4(keccak256("withdraw(uint256)")), AMT + 1);
        _expectLido(txs, "WethToStEth batch: withdraw amount");
    }

    function testFork_checkBatch_lidoReferral_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        txs[2].data = abi.encodeCall(ILido.submit, (address(1)));
        _expectLido(txs, "WethToStEth batch: submit referral");
    }

    function testFork_checkBatch_lidoMintTooLow_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        _setStMint(txs, AMT - 3);
        _expectLido(txs, "WethToStEth batch: Lido stMint range");
    }

    function testFork_checkBatch_lidoMintTooHigh_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        _setStMint(txs, AMT + 1);
        _expectLido(txs, "WethToStEth batch: Lido stMint range");
    }

    function testFork_checkBatch_lidoWrongTarget_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = _lido();
        txs[2].to = address(0xdead);
        _expectLido(txs, "Rebalance batch: wrong target/selector");
    }

    // ---- buildAndSimulate invokes _checkBatch on both routes ----

    function testFork_lido_buildRunsCheckBatch() public {
        WethToStEthTampered t = new WethToStEthTampered();
        vm.expectRevert(bytes("WethToStEth batch: submit referral"));
        t.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_uniswap_buildRunsCheckBatch() public {
        WethToStEthTampered t = new WethToStEthTampered();
        vm.expectRevert(bytes("WethToStEth batch: swap amountOutMinimum != minWst"));
        t.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    // ---- buildAndSimulate pre-checks and post-simulation asserts ----

    function _mockCfg(address token, uint8 tokenType, uint256 minted) internal {
        vm.mockCall(
            ESETH, abi.encodeWithSignature("tokenConfigs(address)", token), abi.encode(tokenType, true, true, minted)
        );
    }

    function testFork_stethTokenTypeNotErc20_reverts() public {
        _mockCfg(STETH, 0, 0);
        vm.expectRevert(bytes("WethToStEth: stETH tokenType != ERC20"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_uniswap_zeroStMint_reverts() public {
        vm.mockCall(WSTETH, abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector), abi.encode(uint256(1)));
        vm.expectRevert(bytes("WethToStEth: Uniswap stMint == 0"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    function testFork_sim_wethDelta_reverts() public {
        vm.mockCall(WETH, abi.encodeWithSignature("balanceOf(address)", ESETH), abi.encode(uint256(1000 ether)));
        vm.expectRevert(bytes("WethToStEth sim: esETH WETH delta != amt"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_stethDelta_reverts() public {
        vm.mockCall(STETH, abi.encodeWithSignature("balanceOf(address)", ESETH), abi.encode(uint256(1000 ether)));
        vm.expectRevert(bytes("WethToStEth sim: esETH stETH delta < stMint - 2"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_totalMintedDelta_reverts() public {
        _mockCfg(STETH, 1, 1000 ether);
        vm.expectRevert(bytes("WethToStEth sim: stETH totalMinted delta != stMint"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_supplyDelta_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1_000_000 ether)));
        vm.expectRevert(bytes("WethToStEth sim: esETH supply delta"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_safeEsEthDelta_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("balanceOf(address)", SAFE), abi.encode(uint256(1000 ether)));
        vm.expectRevert(bytes("WethToStEth sim: Safe esETH delta"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_safeStethStock_reverts() public {
        bytes[] memory rets = new bytes[](2);
        rets[0] = abi.encode(uint256(100 ether)); // _before
        rets[1] = abi.encode(uint256(0)); // after the simulation
        vm.mockCalls(STETH, abi.encodeWithSignature("balanceOf(address)", SAFE), rets);
        vm.expectRevert(bytes("WethToStEth sim: mint drew on Safe stETH stock"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_lidoReceived_reverts() public {
        vm.mockCall(STETH, abi.encodeWithSelector(ILido.getPooledEthByShares.selector), abi.encode(uint256(0)));
        vm.expectRevert(bytes("WethToStEth sim: Lido stETH received < amt - 2"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_sim_routerAllowanceLeft_reverts() public {
        vm.mockCall(WETH, abi.encodeWithSignature("allowance(address,address)", SAFE, ROUTER), abi.encode(uint256(1)));
        vm.expectRevert(bytes("WethToStEth sim: router allowance left"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    function testFork_sim_safeWstethFell_reverts() public {
        bytes[] memory rets = new bytes[](2);
        rets[0] = abi.encode(uint256(10 ether)); // before the simulation
        rets[1] = abi.encode(uint256(0)); // after
        vm.mockCalls(WSTETH, abi.encodeWithSignature("balanceOf(address)", SAFE), rets);
        vm.expectRevert(bytes("WethToStEth sim: Safe wstETH fell"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    }

    // ---- _simulate ----

    function testFork_simulate_wethStranded_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](1);
        txs[0] = _lido()[0]; // redeem only: WETH lands in the Safe and stays
        vm.expectRevert(bytes("Rebalance sim: WETH stranded in Safe"));
        harness.exposed_simulate(txs);
    }

    function testFork_simulate_ethStranded_reverts() public {
        SafeBatchDecodedLib.Tx[] memory l = _lido();
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](2);
        txs[0] = l[0];
        txs[1] = l[1]; // redeem + withdraw: ETH lands in the Safe and stays
        vm.expectRevert(bytes("Rebalance sim: ETH stranded in Safe"));
        harness.exposed_simulate(txs);
    }

    function testFork_simulate_execReturnsFalse_reverts() public {
        SafeBatchDecodedLib.Tx[] memory txs = new SafeBatchDecodedLib.Tx[](1);
        txs[0] = _lido()[0];
        bytes4 exec = bytes4(
            keccak256("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)")
        );
        vm.mockCall(SAFE, abi.encodePacked(exec), abi.encode(false));
        vm.expectRevert(bytes("Rebalance sim: execTransaction returned false"));
        harness.exposed_simulate(txs);
    }

    // ---- shared RebalanceBase checks (_checkCommon, threshold override, index scan) ----

    function testFork_thresholdAboveOne_passes() public {
        vm.store(SAFE, bytes32(uint256(4)), bytes32(uint256(2)));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_aboveWethBalance_reverts() public {
        uint256 over = IERC20(WETH).balanceOf(ESETH) / 1e18 + 1;
        vm.expectRevert(bytes("Rebalance: AMOUNT > WETH.balanceOf(esETH)"));
        harness.exposed_buildAndSimulate(over, WethToStEth.Route.Lido, 10);
    }

    function testFork_weiPassedByMistake_reverts() public {
        vm.expectRevert(bytes("Rebalance: AMOUNT > WETH.balanceOf(esETH)"));
        harness.exposed_buildAndSimulate(50000000000000000000, WethToStEth.Route.Lido, 10);
    }

    function testFork_aboveTotalMinted_reverts() public {
        (,,, uint256 totalMinted) = esETH(payable(ESETH)).tokenConfigs(WETH);
        deal(WETH, ESETH, totalMinted + 5 ether);
        vm.expectRevert(bytes("Rebalance: AMOUNT > esETH WETH totalMinted"));
        harness.exposed_buildAndSimulate(totalMinted / 1e18 + 1, WethToStEth.Route.Lido, 10);
    }

    function testFork_safeEsEthZero_reverts() public {
        deal(ESETH, SAFE, 0);
        vm.expectRevert(bytes("Rebalance: AMOUNT + 1 > esETH.balanceOf(Safe)"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_treasuryManagerNotSafe_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("treasuryManager()"), abi.encode(address(1)));
        vm.expectRevert(bytes("Rebalance: esETH.treasuryManager() != Safe"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_safeNotMinter_reverts() public {
        vm.mockCall(ESETH, abi.encodeWithSignature("isMinter(address)", SAFE), abi.encode(false));
        vm.expectRevert(bytes("Rebalance: Safe is not an esETH minter"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function testFork_wethTokenTypeNotErc20_reverts() public {
        vm.mockCall(
            ESETH, abi.encodeWithSignature("tokenConfigs(address)", WETH), abi.encode(uint8(0), true, true, uint256(0))
        );
        vm.expectRevert(bytes("Rebalance: WETH tokenType != ERC20"));
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }

    function test_firstFreeIndex_skipsExisting() public {
        string memory op = "999-test-fixture-index";
        assertEq(harness.exposed_firstFreeIndex(op), 1);
        vm.createDir(string.concat("script/deployments/1/multisig/", op), true);
        vm.writeFile(SafeBatchLib.path(SAFE, op, 1), "{}");
        assertEq(harness.exposed_firstFreeIndex(op), 2);
        vm.removeDir(string.concat("script/deployments/1/multisig/", op), true);
    }

    function testFork_lido_doesNotNeedUniswapQuote() public {
        vm.mockCallRevert(
            QUOTER,
            abi.encodePacked(bytes4(keccak256("quoteExactInputSingle((address,address,uint256,uint24,uint160))"))),
            "no pool"
        );
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Lido, 10);
    }
}
