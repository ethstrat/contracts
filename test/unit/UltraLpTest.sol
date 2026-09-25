// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UltraToken} from "src/UltraToken.sol";
import {MintableBurnableToken} from "src/MintableBurnableToken.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TickMath} from "../../script/deployments/1/005-earn-lp/lib/TickMath.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ProposeUltraLp} from "../../script/deployments/robinhood/007-ultra-lp/ProposeUltraLp.s.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
import {PoolKey, IPositionManager, IPermit2} from "../../script/deployments/1/005-earn-lp/interfaces/IV4Minimal.sol";

contract UltraLpHarness is ProposeUltraLp {
    function exposedBuild(address safe, address ultra, string memory cfg) external view returns (uint256) {
        (SafeBatchLib.Tx[] memory txs,) = buildUltraBatch(safe, ultra, cfg);
        return txs.length;
    }

    function exposedTxs(LpPlan memory p) external pure returns (SafeBatchLib.Tx[] memory) {
        return buildTxs(p);
    }

    function exposedPrice(bool ultraIsC0, uint256 basis) external pure returns (uint160, int24) {
        return deriveSqrtPriceWei(ultraIsC0, basis);
    }

    function exposedConfig() external view returns (string memory) {
        return vm.readFile(CONFIG);
    }
}

contract UltraLpTest is Test {
    UltraLpHarness internal h;

    function setUp() public {
        h = new UltraLpHarness();
    }

    /// @dev Real lp.json has an on-chain-only quote address; use address(this) (has code) for every
    /// address so the zero-price placeholders are what gets rejected.
    function test_placeholderConfigRejected() public {
        string memory a = vm.toString(address(this));
        string memory cfg = string.concat(
            '{"quote":"',
            a,
            '","poolManager":"',
            a,
            '","positionManager":"',
            a,
            '","permit2":"',
            a,
            '","stateView":"',
            a,
            '","basisPrice":"0","fee":3000,',
            '"tickSpacing":60,"fullRangeQuote":"0"}'
        );
        vm.expectRevert(bytes("ProposeUltraLp: lp.json .basisPrice is zero -- fill it"));
        h.exposedBuild(address(this), address(this), cfg);
    }

    function test_configQuoteIsWeth() public view {
        string memory cfg = h.exposedConfig();
        assertEq(vm.parseJsonAddress(cfg, ".quote"), 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    }

    /// @dev basisPrice 0.05 WETH per ULTRA round-trips through sqrtPriceX96 in both orderings.
    function test_priceRoundTrip_bothOrderings() public view {
        uint256 basis = 0.05e18;
        for (uint256 i; i < 2; i++) {
            bool ultraIsC0 = i == 0;
            (uint160 sqrtP, int24 tick) = h.exposedPrice(ultraIsC0, basis);
            // token1-per-token0 price, 18-decimal
            uint256 p1e18 = Math.mulDiv(uint256(sqrtP) * sqrtP, 1e18, uint256(1) << 192);
            // quote per ULTRA: direct if ULTRA is c0, else inverted
            uint256 quotePerUltra = ultraIsC0 ? p1e18 : Math.mulDiv(1e18, 1e18, p1e18);
            assertApproxEqRel(quotePerUltra, basis, 1e12); // 1e-6 relative
            // tick is within one tick (0.01%) of the price
            assertEq(tick, TickMath.getTickAtSqrtPrice(sqrtP));
        }
    }

    function test_txOrder() public view {
        address safe = address(0x5AFE);
        address ultra = address(0xC0DE);
        address quote = address(0xD011);
        address permit2 = address(0x9999);
        address posm = address(0x7777);
        ProposeUltraLp.LpPlan memory p;
        p.safe = safe;
        p.earn = ultra;
        p.usds = quote;
        p.permit2 = permit2;
        p.posm = IPositionManager(posm);
        p.earnIsC0 = true;
        p.key = PoolKey(ultra, quote, 3000, 60, address(0));
        p.fullRangeEarn = 2_500e18;
        p.fullRangeUsds = 250_000e18;

        SafeBatchLib.Tx[] memory t = h.exposedTxs(p);
        assertEq(t.length, 8);
        assertEq(t[0].to, ultra);
        assertEq(t[0].data, abi.encodeCall(MintableBurnableToken.manageMinter, (safe, true)));
        assertEq(t[1].data, abi.encodeCall(MintableBurnableToken.mint, (safe, 2_500e18)));
        assertEq(t[2].data, abi.encodeCall(MintableBurnableToken.manageMinter, (safe, false)));
        assertEq(t[3].to, quote);
        assertEq(t[4].to, ultra);
        assertEq(t[5].to, permit2);
        assertEq(t[6].to, permit2);
        assertEq(t[7].to, posm);
        assertEq(bytes4(t[7].data), IPositionManager.multicall.selector);
    }
}
