// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TickMath} from "./lib/TickMath.sol";
import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";

/// @notice EARN/USDS v4 LP batch builder. This task adds the pure tick and liquidity math only;
/// buildBatch, the fork simulation and run() land in the next task.
contract ProposeLp is Script {
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
}
