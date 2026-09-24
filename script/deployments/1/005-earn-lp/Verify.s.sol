// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {StryToken} from "src/StryToken.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
import {Distribute} from "../004-stry-migration/Distribute.s.sol";
import {PeriodicYield} from "../004-stry-migration/PeriodicYield.s.sol";
import {ProposeLp} from "./ProposeLp.s.sol";
import {TickMath} from "./lib/TickMath.sol";
import {PoolKey, SwapParams, MaximumAmountExceeded, IPoolManagerMinimal} from "./interfaces/IV4Minimal.sol";

/// @notice Exact-input swap through the v4 PoolManager for the informational swap check (spec V2
/// step 15). Replaces v4-core's PoolSwapTest, whose transitive imports are far larger than this.
contract V4SwapSanity {
    IPoolManagerMinimal internal immutable pm;

    constructor(address poolManager) {
        pm = IPoolManagerMinimal(poolManager);
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "V4SwapSanity: not PoolManager");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        int256 delta = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (address tokenIn, address tokenOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 amountOut = uint256(int256(zeroForOne ? int128(delta) : int128(delta >> 128)));
        pm.sync(tokenIn);
        IERC20(tokenIn).transferFrom(payer, address(pm), amountIn);
        pm.settle();
        pm.take(tokenOut, payer, amountOut);
        return abi.encode(amountOut);
    }
}

/// @notice External entry to ProposeLp.buildBatch so Verify can try/catch it. forge forbids a script
/// calling itself through `this`.
contract BuildBatchProbe is ProposeLp {
    function probe(address earn) external view {
        buildBatch(earn);
    }
}

/// @notice 005-earn-lp mainnet-fork Verify (spec V2). Deploys EARN on the fork via Distribute's
/// internal distribute(), builds the LP batch with ProposeLp.buildBatch, and executes it as the Safe.
/// Writes no file. Both currency orderings run on every invocation via deployCodeTo (spec S7).
contract Verify is Script, StdCheats, StdAssertions, ProposeLp, Distribute, PeriodicYield {
    function run() external override(ProposeLp, Distribute, PeriodicYield) {
        uint256 snapshotBlockTarget = vm.envUint("SNAPSHOT_BLOCK");
        string memory holdersFile =
            string.concat("script/deployments/1/config/espn-holders-", vm.toString(snapshotBlockTarget), ".json");
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        uint256 totalUsds =
            ConfigLib.num("settings.json", ".lp.fullRangeUsds") + ConfigLib.num("settings.json", ".lp.singleSidedUsds");

        // Step 1: EARN on the fork. distribute() requires the excluded-holder zero balances (D23)
        // before anything below runs.
        address deployer = makeAddr("earnDeployer");
        vm.startPrank(deployer);
        StryToken earn = distribute(deployer, holdersFile);
        vm.stopPrank();
        uint256 airdropSupply = earn.totalSupply();
        uint256 yieldBefore = periodicYieldAmount(airdropSupply);

        // Step 2: the mainnet preflight is a hard require; the fork tops up and says so.
        if (IERC20(usds).balanceOf(safe) < totalUsds) {
            console2.log("WARNING: Safe USDS below the LP total at this fork block; dealing the shortfall.");
            deal(usds, safe, totalUsds);
        }

        // S7: both currency orderings, each on a state snapshot. USDS is 0xdC03..., so the low
        // address is Case A (EARN = currency0) and the high one Case B.
        _checkOrderingAt(address(0x10000), true);
        _checkOrderingAt(address(type(uint160).max - 0xffff), false);

        // Step 3.
        (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildBatch(address(earn));
        assertEq(txs.length, 6, "Verify: batch is not 6 txs");
        assertEq(txs[0].to, address(earn), "Verify: tx 1 is not to EARN");
        assertEq(bytes4(txs[0].data), StryToken.mintBatch.selector, "Verify: tx 1 is not mintBatch");
        // Step 4.
        (uint160 priceBefore,,,) = p.stateView.getSlot0(p.poolId);
        assertEq(priceBefore, 0, "Verify: pool initialized before the batch");

        // Step 14 (S1): a squatter initializes the key at 2x and at 0.5x the intended price; the
        // batch must revert on amountMax and mint nothing.
        _assertSquatReverts(p, txs, uint160(uint256(p.sqrtPriceX96) * 1414213562 / 1e9));
        _assertSquatReverts(p, txs, uint160(uint256(p.sqrtPriceX96) * 1e9 / 1414213562));

        // Review Focus: EARN sent to the Safe by a third party must not block the batch; the dust
        // check is relative to the Safe's pre-batch balance. deal() leaves totalSupply unchanged.
        deal(address(earn), safe, 1e18);

        // Review Focus: a Safe holding less than the LP total is refused before anything is built.
        uint256 snap = vm.snapshotState();
        deal(usds, safe, totalUsds - 1);
        _assertBuildBatchReverts(address(earn), "ProposeLp: Safe USDS balance < fullRangeUsds + singleSidedUsds");
        vm.revertToState(snap);

        // Steps 5-12.
        _simulateAndCheck(p, txs);
        assertEq(earn.totalSupply(), airdropSupply + p.fullRangeEarn, "Verify: supply != airdrop + LP EARN");
        assertEq(periodicYieldAmount(airdropSupply), yieldBefore, "Verify: LP mint moved the yield amount");

        // Step 13: buildBatch refuses an initialized pool.
        _assertBuildBatchReverts(address(earn), "ProposeLp: pool already initialized");

        // Step 15: swap sanity, informational.
        _swapSanity(p);

        console2.log(p.earnIsC0 ? "Fork EARN hit Case A" : "Fork EARN hit Case B");
    }

    function _assertBuildBatchReverts(address earn, string memory expected) internal {
        BuildBatchProbe probe = new BuildBatchProbe();
        try probe.probe(earn) {
            revert(string.concat("Verify: buildBatch did not revert: ", expected));
        } catch Error(string memory reason) {
            assertEq(reason, expected);
        }
    }

    function _checkOrderingAt(address where, bool expectEarnIsC0) internal {
        uint256 snap = vm.snapshotState();
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        deployCodeTo("StryToken.sol:StryToken", abi.encode(safe), where);
        (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildBatch(where);
        assertEq(p.earnIsC0, expectEarnIsC0, "Verify: unexpected currency ordering");
        assertEq(txs.length, 6, "Verify: batch is not 6 txs");
        _simulateAndCheck(p, txs);
        console2.log(expectEarnIsC0 ? "Case A ordering passed at" : "Case B ordering passed at", where);
        vm.revertToState(snap);
    }

    function _assertSquatReverts(LpPlan memory p, SafeBatchLib.Tx[] memory txs, uint160 wrongSqrtPriceX96) internal {
        uint256 snap = vm.snapshotState();
        uint256 nextId = p.posm.nextTokenId();
        address squatter = makeAddr("squatter");
        vm.prank(squatter);
        p.posm.initializePool(p.key, wrongSqrtPriceX96);

        // Txs 1-5 succeed; tx 6 must revert. In the real MultiSend that reverts the whole batch.
        SafeBatchLib.Tx[] memory firstFive = new SafeBatchLib.Tx[](5);
        for (uint256 i; i < 5; ++i) {
            firstFive[i] = txs[i];
        }
        SafeBatchLib.execute(p.safe, firstFive);
        vm.prank(p.safe);
        (bool ok, bytes memory ret) = txs[5].to.call(txs[5].data);
        assertFalse(ok, "Verify: batch succeeded against a squatted pool");
        assertEq(bytes4(ret), MaximumAmountExceeded.selector, "Verify: squat revert is not MaximumAmountExceeded");
        try p.posm.ownerOf(nextId) returns (address) {
            revert("Verify: a position was minted against a squatted pool");
        } catch {}
        vm.revertToState(snap);
    }

    function _swapSanity(LpPlan memory p) internal {
        address trader = makeAddr("trader");
        deal(p.usds, trader, 1_000e18);
        V4SwapSanity swapper = new V4SwapSanity(p.poolManager);
        bool zeroForOne = !p.earnIsC0; // USDS in
        vm.startPrank(trader);
        IERC20(p.usds).approve(address(swapper), 1_000e18);
        uint256 earnOut = swapper.swapExactIn(p.key, zeroForOne, 1_000e18);
        vm.stopPrank();

        (,, uint24 protocolFee, uint24 lpFee) = p.stateView.getSlot0(p.poolId);
        // v4 ProtocolFeeLibrary: lower 12 bits = zeroForOne fee, upper 12 bits = oneForZero fee,
        // combined swap fee = pf + lpFee - pf * lpFee / 1e6 (pips).
        uint256 pf = zeroForOne ? protocolFee & 0xfff : protocolFee >> 12;
        uint256 swapFee = pf + lpFee - pf * lpFee / 1e6;
        uint256 expected = 1_000e18 * p.fullRangeEarn / p.fullRangeUsds * (1e6 - swapFee) / 1e6;
        console2.log("swap: protocolFee / lpFee / EARN out:", protocolFee, lpFee, earnOut);
        assertApproxEqRel(earnOut, expected, 0.01e18, "Verify: swap output off by more than 1%");
    }
}
