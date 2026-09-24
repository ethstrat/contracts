// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {StryToken} from "src/StryToken.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
import {TickMath} from "./lib/TickMath.sol";
import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";
import {PoolKey, Actions, IPositionManager, IPermit2, IStateView} from "./interfaces/IV4Minimal.sol";

/// @notice Builds the 6-tx redemption-Safe batch that mints the 2,500 LP EARN, initializes the
/// EARN/USDS v4 pool at basisPriceUsd, and mints a full-range position plus a USDS-only bid wall.
/// Never broadcasts. Run with --fork-url mainnet: run() executes the exact batch as the Safe on the
/// latest-block fork and asserts the outcome before it writes the file (spec B1).
contract ProposeLp is Script {
    /// @dev 1e-6 of a token. Rounding leaves at most a few wei per position.
    uint256 internal constant DUST = 1e12;

    struct LpPlan {
        address safe;
        address earn;
        address usds;
        address poolManager;
        IPositionManager posm;
        address permit2;
        IStateView stateView;
        bool earnIsC0;
        PoolKey key;
        bytes32 poolId;
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 fullLower;
        int24 fullUpper;
        int24 bandLower;
        int24 bandUpper;
        uint128 liqFull;
        uint128 liqBand;
        uint256 fullRangeUsds;
        uint256 fullRangeEarn;
        uint256 singleSidedUsds;
    }

    function run() external virtual {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address earn = ConfigLib.addr("deploymentAddresses.json", ".stry");
        require(
            !vm.exists(SafeBatchLib.path(safe, "005-earn-lp", 1)),
            "ProposeLp: batch 001 already exists; delete it deliberately to regenerate"
        );
        require(earn.code.length > 0, "ProposeLp: .stry has no code -- run Distribute.s.sol first");

        (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildBatch(earn);
        _simulateAndCheck(p, txs);

        SafeBatchLib.write(
            safe,
            "005-earn-lp",
            1,
            "EARN/USDS V4 LP",
            "Mints the LP EARN to this Safe, approves USDS and EARN to Permit2 and PositionManager, initializes the EARN/USDS v4 pool, and mints a full-range position plus a USDS-only bid wall owned by this Safe. Amounts, price, ticks and poolId are in the ProposeLp log. Execute the transactions in the order listed.",
            txs
        );
        console2.log("Simulation passed; batch written:", SafeBatchLib.path(safe, "005-earn-lp", 1));
    }

    /// @dev Every preflight require lives here (spec N1), so nothing is simulated or written on a
    /// bad config or state. Reads config; `earn` is the only argument so Verify.s.sol can point it
    /// at a fork-local EARN.
    function buildBatch(address earn) internal view returns (SafeBatchLib.Tx[] memory txs, LpPlan memory p) {
        p.safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        p.earn = earn;
        p.usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        p.poolManager = ConfigLib.addr("externalAddresses.json", ".uniswap-v4.poolManager");
        p.posm = IPositionManager(ConfigLib.addr("externalAddresses.json", ".uniswap-v4.positionManager"));
        p.permit2 = ConfigLib.addr("externalAddresses.json", ".uniswap-v4.permit2");
        p.stateView = IStateView(ConfigLib.addr("externalAddresses.json", ".uniswap-v4.stateView"));

        uint256 basis = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");
        uint256 lo = ConfigLib.num("settings.json", ".lp.bandLowerUsd");
        uint256 hi = ConfigLib.num("settings.json", ".lp.bandUpperUsd");
        uint256 fee = ConfigLib.num("settings.json", ".lp.fee");
        uint256 spacing = ConfigLib.num("settings.json", ".lp.tickSpacing");
        p.fullRangeUsds = ConfigLib.num("settings.json", ".lp.fullRangeUsds");
        p.singleSidedUsds = ConfigLib.num("settings.json", ".lp.singleSidedUsds");

        require(basis > 0 && p.fullRangeUsds % basis == 0, "ProposeLp: fullRangeUsds not a multiple of basisPriceUsd");
        require(lo > 0 && lo < hi && hi <= basis, "ProposeLp: need 0 < bandLowerUsd < bandUpperUsd <= basisPriceUsd");
        require(fee > 0 && fee < 1_000_000, "ProposeLp: bad lp.fee");
        require(spacing > 0 && spacing <= 32767, "ProposeLp: bad lp.tickSpacing");
        p.fullRangeEarn = p.fullRangeUsds / basis;

        require(
            IERC20Metadata(earn).decimals() == 18 && IERC20Metadata(p.usds).decimals() == 18,
            "ProposeLp: EARN and USDS must both have 18 decimals"
        );
        require(p.posm.poolManager() == p.poolManager, "ProposeLp: PositionManager.poolManager() mismatch");
        require(p.stateView.poolManager() == p.poolManager, "ProposeLp: StateView.poolManager() mismatch");
        require(p.posm.permit2() == p.permit2, "ProposeLp: PositionManager.permit2() mismatch");

        p.earnIsC0 = earn < p.usds;
        p.key = PoolKey({
            currency0: p.earnIsC0 ? earn : p.usds,
            currency1: p.earnIsC0 ? p.usds : earn,
            fee: uint24(fee),
            tickSpacing: int24(int256(spacing)),
            hooks: address(0)
        });
        p.poolId = keccak256(abi.encode(p.key));
        (uint160 livePrice,,,) = p.stateView.getSlot0(p.poolId);
        require(livePrice == 0, "ProposeLp: pool already initialized");

        require(StryToken(earn).owner() == p.safe, "ProposeLp: EARN.owner() != redemption Safe");
        require(
            IERC20(p.usds).balanceOf(p.safe) >= p.fullRangeUsds + p.singleSidedUsds,
            "ProposeLp: Safe USDS balance < fullRangeUsds + singleSidedUsds"
        );

        (p.sqrtPriceX96, p.currentTick, p.bandLower, p.bandUpper) =
            deriveTicks(p.earnIsC0, basis, lo, hi, p.key.tickSpacing);
        p.fullLower = TickMath.minUsableTick(p.key.tickSpacing);
        p.fullUpper = TickMath.maxUsableTick(p.key.tickSpacing);
        (p.liqFull, p.liqBand) = deriveLiquidity(
            p.earnIsC0,
            p.sqrtPriceX96,
            p.bandLower,
            p.bandUpper,
            p.key.tickSpacing,
            p.fullRangeUsds,
            p.fullRangeEarn,
            p.singleSidedUsds
        );

        txs = _txs(p);
        _log(p, txs);
    }

    function _txs(LpPlan memory p) private pure returns (SafeBatchLib.Tx[] memory txs) {
        uint256 totalUsds = p.fullRangeUsds + p.singleSidedUsds;
        address[] memory to = new address[](1);
        to[0] = p.safe;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = p.fullRangeEarn;

        // amountMax = the configured amount per currency, 0 for the currency a position must not
        // take. It is also the price guard: at any pool price other than the intended one, the
        // full-range position's fixed liquidity needs more than its max of one currency and the
        // whole batch reverts MaximumAmountExceeded (spec R6).
        (uint128 full0, uint128 full1) = p.earnIsC0
            ? (uint128(p.fullRangeEarn), uint128(p.fullRangeUsds))
            : (uint128(p.fullRangeUsds), uint128(p.fullRangeEarn));
        (uint128 band0, uint128 band1) =
            p.earnIsC0 ? (uint128(0), uint128(p.singleSidedUsds)) : (uint128(p.singleSidedUsds), uint128(0));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p.key, p.fullLower, p.fullUpper, uint256(p.liqFull), full0, full1, p.safe, bytes(""));
        params[1] = abi.encode(p.key, p.bandLower, p.bandUpper, uint256(p.liqBand), band0, band1, p.safe, bytes(""));
        params[2] = abi.encode(p.key.currency0, p.key.currency1);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.initializePool, (p.key, p.sqrtPriceX96));
        // deadline max: calldata is generated before signing and can sit in the Safe queue.
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), type(uint256).max));

        txs = new SafeBatchLib.Tx[](6);
        txs[0] = SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(StryToken.mintBatch, (to, amounts))});
        txs[1] = SafeBatchLib.Tx({to: p.usds, data: abi.encodeCall(IERC20.approve, (p.permit2, totalUsds))});
        txs[2] = SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(IERC20.approve, (p.permit2, p.fullRangeEarn))});
        // expiration max for the same queue reason; Permit2 decrements the amount on spend.
        txs[3] = SafeBatchLib.Tx({
            to: p.permit2,
            data: abi.encodeCall(IPermit2.approve, (p.usds, address(p.posm), uint160(totalUsds), type(uint48).max))
        });
        txs[4] = SafeBatchLib.Tx({
            to: p.permit2,
            data: abi.encodeCall(
                IPermit2.approve, (p.earn, address(p.posm), uint160(p.fullRangeEarn), type(uint48).max)
            )
        });
        txs[5] = SafeBatchLib.Tx({to: address(p.posm), data: abi.encodeCall(IPositionManager.multicall, (calls))});
    }

    /// @dev Spec section 6. Case A: EARN is currency0, pool price = USDS per EARN, the bid wall
    /// holds currency1 and needs currentTick >= bandUpper. Case B: USDS is currency0, pool price =
    /// EARN per USDS, the bid wall holds currency0 and needs currentTick < bandLower (strict). The
    /// band edge nearest the pool price rounds away from it; the far edge rounds outward. No log
    /// in Solidity: every tick comes from TickMath.getTickAtSqrtPrice on an integer sqrt.
    function deriveTicks(bool earnIsC0, uint256 basis, uint256 lo, uint256 hi, int24 s)
        internal
        pure
        returns (uint160 sqrtPriceX96, int24 currentTick, int24 bandLower, int24 bandUpper)
    {
        if (earnIsC0) {
            sqrtPriceX96 = uint160(Math.sqrt(basis << 192));
            currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
            bandLower = floorToSpacing(_tickAtPriceX192(lo << 192), s);
            bandUpper = floorToSpacing(_tickAtPriceX192(hi << 192), s);
            require(currentTick >= bandUpper, "ProposeLp: bid wall would hold EARN (case A)");
        } else {
            sqrtPriceX96 = uint160(Math.sqrt((uint256(1) << 192) / basis));
            currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
            bandLower = ceilToSpacing(_tickAtPriceX192((uint256(1) << 192) / hi), s);
            if (bandLower <= currentTick) bandLower += s;
            bandUpper = ceilToSpacing(_tickAtPriceX192((uint256(1) << 192) / lo), s);
            require(currentTick < bandLower, "ProposeLp: bid wall would hold EARN (case B)");
        }
        require(bandLower < bandUpper, "ProposeLp: empty band after rounding");
    }

    /// @dev getLiquidityForAmount* round liquidity down, so the settled amounts never exceed the
    /// configured ones (spec S2). If the simulation ever shows a 1-wei round-up revert, the fix is
    /// liquidity -= 1, not a larger amountMax.
    function deriveLiquidity(
        bool earnIsC0,
        uint160 sqrtPriceX96,
        int24 bandLower,
        int24 bandUpper,
        int24 s,
        uint256 fullRangeUsds,
        uint256 fullRangeEarn,
        uint256 singleSidedUsds
    ) internal pure returns (uint128 liqFull, uint128 liqBand) {
        (uint256 amount0, uint256 amount1) = earnIsC0 ? (fullRangeEarn, fullRangeUsds) : (fullRangeUsds, fullRangeEarn);
        liqFull = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(s)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(s)),
            amount0,
            amount1
        );
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(bandLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(bandUpper);
        liqBand = earnIsC0
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, singleSidedUsds)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, singleSidedUsds);
    }

    /// @dev Solidity `/` truncates toward zero, so a plain t / s * s is a ceiling for negative t.
    function floorToSpacing(int24 t, int24 s) internal pure returns (int24) {
        int24 q = t / s;
        if (t % s != 0 && t < 0) q--;
        return q * s;
    }

    function ceilToSpacing(int24 t, int24 s) internal pure returns (int24) {
        int24 q = t / s;
        if (t % s != 0 && t > 0) q++;
        return q * s;
    }

    function _tickAtPriceX192(uint256 priceX192) private pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(priceX192)));
    }

    /// @dev Executes `txs` as the Safe on the current fork and requires the end state (spec V2 steps
    /// 6-12). Used by run() on the latest-block fork before writing, and by Verify.s.sol.
    function _simulateAndCheck(LpPlan memory p, SafeBatchLib.Tx[] memory txs) internal {
        StryToken earn = StryToken(p.earn);
        uint256 supplyBefore = earn.totalSupply();
        uint256 usdsBefore = IERC20(p.usds).balanceOf(p.safe);
        uint256 earnBefore = earn.balanceOf(p.safe);
        uint256 tokenId = p.posm.nextTokenId();

        uint256 gasBefore = gasleft();
        SafeBatchLib.execute(p.safe, txs);
        console2.log("LP batch execution gas:", gasBefore - gasleft());

        require(
            earn.totalSupply() == supplyBefore + p.fullRangeEarn, "ProposeLp sim: EARN supply delta != fullRangeEarn"
        );
        (uint160 sqrtPriceX96, int24 tick,,) = p.stateView.getSlot0(p.poolId);
        require(sqrtPriceX96 == p.sqrtPriceX96, "ProposeLp sim: pool sqrtPriceX96 != intended");
        require(tick == p.currentTick, "ProposeLp sim: pool tick != intended");
        require(p.posm.ownerOf(tokenId) == p.safe, "ProposeLp sim: full-range NFT not owned by Safe");
        require(p.posm.ownerOf(tokenId + 1) == p.safe, "ProposeLp sim: bid-wall NFT not owned by Safe");
        require(p.posm.getPositionLiquidity(tokenId) == p.liqFull, "ProposeLp sim: full-range liquidity mismatch");
        require(p.posm.getPositionLiquidity(tokenId + 1) == p.liqBand, "ProposeLp sim: bid-wall liquidity mismatch");

        uint256 totalUsds = p.fullRangeUsds + p.singleSidedUsds;
        uint256 usdsSpent = usdsBefore - IERC20(p.usds).balanceOf(p.safe);
        require(usdsSpent <= totalUsds && totalUsds - usdsSpent <= DUST, "ProposeLp sim: USDS spent not ~total");
        // The Safe minted exactly fullRangeEarn and the bid wall's EARN max is 0, so any EARN left
        // beyond dust means position 1 did not take it all or position 2 took some.
        require(earn.balanceOf(p.safe) <= earnBefore + DUST, "ProposeLp sim: EARN left on Safe beyond dust");
        (uint160 usdsAllowance,,) = IPermit2(p.permit2).allowance(p.safe, p.usds, address(p.posm));
        (uint160 earnAllowance,,) = IPermit2(p.permit2).allowance(p.safe, p.earn, address(p.posm));
        require(usdsAllowance <= DUST && earnAllowance <= DUST, "ProposeLp sim: Permit2 allowance left beyond dust");

        console2.log("Simulated position token ids:", tokenId, tokenId + 1);
        console2.log("USDS spent:", usdsSpent);
    }

    function _log(LpPlan memory p, SafeBatchLib.Tx[] memory txs) private pure {
        console2.log(p.earnIsC0 ? "Case A: EARN is currency0" : "Case B: USDS is currency0");
        console2.log("EARN:", p.earn);
        console2.log("Safe:", p.safe);
        console2.log("key currency0 / currency1:", p.key.currency0, p.key.currency1);
        console2.log("key fee / tickSpacing:", p.key.fee, uint256(int256(p.key.tickSpacing)));
        console2.log("key hooks:", p.key.hooks);
        console2.log("poolId (StateView.getSlot0 argument):");
        console2.logBytes32(p.poolId);
        console2.log("sqrtPriceX96:", p.sqrtPriceX96);
        console2.log("currentTick:", p.currentTick);
        console2.log("full range lower tick:", p.fullLower);
        console2.log("full range upper tick:", p.fullUpper);
        console2.log("bid wall lower tick:", p.bandLower);
        console2.log("bid wall upper tick:", p.bandUpper);
        console2.log("liqFull / liqBand:", p.liqFull, p.liqBand);
        console2.log("mint EARN / USDS approve:", p.fullRangeEarn, p.fullRangeUsds + p.singleSidedUsds);
        // amount0Max / amount1Max per position, in currency0/currency1 order as the calldata decodes.
        (uint256 full0, uint256 full1) =
            p.earnIsC0 ? (p.fullRangeEarn, p.fullRangeUsds) : (p.fullRangeUsds, p.fullRangeEarn);
        (uint256 band0, uint256 band1) = p.earnIsC0 ? (uint256(0), p.singleSidedUsds) : (p.singleSidedUsds, 0);
        console2.log("full range amount0Max / amount1Max:", full0, full1);
        console2.log("bid wall amount0Max / amount1Max:", band0, band1);
        for (uint256 i; i < txs.length; ++i) {
            console2.log("tx", i, txs[i].to);
            console.logBytes4(bytes4(txs[i].data));
        }
    }
}
