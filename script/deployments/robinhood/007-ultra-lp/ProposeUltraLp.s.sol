// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {UltraToken} from "src/UltraToken.sol";
import {MintableBurnableToken} from "src/MintableBurnableToken.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";
import {ProposeLp} from "../../1/005-earn-lp/ProposeLp.s.sol";
import {TickMath} from "../../1/005-earn-lp/lib/TickMath.sol";
import {LiquidityAmounts} from "../../1/005-earn-lp/lib/LiquidityAmounts.sol";
import {PoolKey, Actions, IPositionManager, IPermit2, IStateView} from "../../1/005-earn-lp/interfaces/IV4Minimal.sol";

/// @notice Builds the 8-tx Safe batch that mints the LP ULTRA, initializes the ULTRA/WETH v4 pool at
/// basisPrice, and mints a single full-range position. Reuses the EARN LP script
/// (005-earn-lp/ProposeLp) for the LpPlan struct and DUST; LpPlan.earn holds the ULTRA address and
/// LpPlan.usds / fullRangeUsds hold the quote token (WETH) and its amount here (struct is inherited,
/// "usds" in its names means quote). Prices are 18-decimal wei (quote wei per 1 ULTRA). Never
/// broadcasts: the fork run executes the batch as the Safe and asserts the outcome before writing
/// the file.
///
/// Prerequisites: 006-ultra-token deployed; the Safe (OWNER) is the ULTRA owner and holds
/// >= fullRangeQuote of WETH on Robinhood Chain (wrap ETH first); script/deployments/robinhood/
/// config/lp.json fully filled (every zero placeholder is rejected).
///
/// Env: OWNER (the Safe, same var as 006 deploy), ULTRA_TOKEN (deployed token),
/// ROBINHOOD_CHAIN_ID (must equal block.chainid).
///
/// forge script script/deployments/robinhood/007-ultra-lp/ProposeUltraLp.s.sol:ProposeUltraLp \
///   --fork-url $ROBINHOOD_RPC
///
/// Output: script/deployments/robinhood/multisig/007-ultra-lp/001-<safe>-multisig.json (import in
/// the Safe Transaction Builder; execute in order). Delete it deliberately to regenerate.
contract ProposeUltraLp is ProposeLp {
    string internal constant CONFIG = "script/deployments/robinhood/config/lp.json";
    string internal constant DIR = "script/deployments/robinhood/multisig/007-ultra-lp/";

    function run() external override {
        require(block.chainid == vm.envUint("ROBINHOOD_CHAIN_ID"), "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        address safe = vm.envAddress("OWNER");
        address ultra = vm.envAddress("ULTRA_TOKEN");
        string memory file = string.concat(DIR, "001-", _slice10(vm.toString(safe)), "-multisig.json");
        require(!vm.exists(file), "ProposeUltraLp: batch 001 already exists; delete it deliberately to regenerate");

        (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildUltraBatch(safe, ultra, vm.readFile(CONFIG));
        _simulate(p, txs);

        vm.createDir(DIR, true);
        vm.writeFile(file, _json(safe, txs));
        console2.log("Simulation passed; batch written:", file);
        console2.log("poolId (StateView.getSlot0 argument):");
        console2.logBytes32(p.poolId);
        console2.log("sqrtPriceX96:", p.sqrtPriceX96);
        console2.log("currentTick:", p.currentTick);
        console2.log("mint ULTRA / WETH approve:", p.fullRangeEarn, p.fullRangeUsds);
    }

    /// @dev All preflight requires live here; `cfg` is the lp.json contents so tests can pass their own.
    function buildUltraBatch(address safe, address ultra, string memory cfg)
        internal
        view
        returns (SafeBatchLib.Tx[] memory txs, LpPlan memory p)
    {
        p.safe = safe;
        p.earn = ultra;
        p.usds = _addr(cfg, ".quote");
        p.poolManager = _addr(cfg, ".poolManager");
        p.posm = IPositionManager(_addr(cfg, ".positionManager"));
        p.permit2 = _addr(cfg, ".permit2");
        p.stateView = IStateView(_addr(cfg, ".stateView"));
        require(safe.code.length > 0, "ProposeUltraLp: OWNER has no code");
        require(ultra.code.length > 0, "ProposeUltraLp: ULTRA_TOKEN has no code");

        uint256 basis = _num(cfg, ".basisPrice");
        uint256 fee = _num(cfg, ".fee");
        uint256 spacing = _num(cfg, ".tickSpacing");
        p.fullRangeUsds = _num(cfg, ".fullRangeQuote");

        require(fee < 1_000_000, "ProposeUltraLp: bad fee");
        require(spacing <= 32767, "ProposeUltraLp: bad tickSpacing");
        // ULTRA minted rounds down; the quote it leaves unpaired must stay within DUST (the sim
        // check's tolerance). Dust is about basis / 1e18 wei, so this only trips on absurd prices.
        p.fullRangeEarn = Math.mulDiv(p.fullRangeUsds, 1e18, basis);
        require(p.fullRangeEarn > 0, "ProposeUltraLp: fullRangeQuote too small for basisPrice");
        require(
            p.fullRangeUsds - Math.mulDiv(p.fullRangeEarn, basis, 1e18) <= DUST,
            "ProposeUltraLp: fullRangeQuote / basisPrice rounding dust > DUST"
        );

        require(
            IERC20Metadata(ultra).decimals() == 18 && IERC20Metadata(p.usds).decimals() == 18,
            "ProposeUltraLp: ULTRA and quote token must both have 18 decimals"
        );
        require(p.posm.poolManager() == p.poolManager, "ProposeUltraLp: PositionManager.poolManager() mismatch");
        require(p.stateView.poolManager() == p.poolManager, "ProposeUltraLp: StateView.poolManager() mismatch");
        require(p.posm.permit2() == p.permit2, "ProposeUltraLp: PositionManager.permit2() mismatch");

        p.earnIsC0 = ultra < p.usds;
        p.key = PoolKey({
            currency0: p.earnIsC0 ? ultra : p.usds,
            currency1: p.earnIsC0 ? p.usds : ultra,
            fee: uint24(fee),
            tickSpacing: int24(int256(spacing)),
            hooks: address(0)
        });
        p.poolId = keccak256(abi.encode(p.key));
        (uint160 livePrice,,,) = p.stateView.getSlot0(p.poolId);
        require(livePrice == 0, "ProposeUltraLp: pool already initialized");

        require(UltraToken(ultra).owner() == safe, "ProposeUltraLp: ULTRA.owner() != OWNER");
        require(
            IERC20(p.usds).balanceOf(safe) >= p.fullRangeUsds,
            "ProposeUltraLp: Safe quote (WETH) balance < fullRangeQuote -- wrap ETH to WETH first"
        );

        (p.sqrtPriceX96, p.currentTick) = deriveSqrtPriceWei(p.earnIsC0, basis);
        p.fullLower = TickMath.minUsableTick(p.key.tickSpacing);
        p.fullUpper = TickMath.maxUsableTick(p.key.tickSpacing);
        (uint256 amount0, uint256 amount1) =
            p.earnIsC0 ? (p.fullRangeEarn, p.fullRangeUsds) : (p.fullRangeUsds, p.fullRangeEarn);
        p.liqFull = LiquidityAmounts.getLiquidityForAmounts(
            p.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(p.fullLower),
            TickMath.getSqrtPriceAtTick(p.fullUpper),
            amount0,
            amount1
        );
        require(p.liqFull > 0, "ProposeUltraLp: zero liquidity");
        txs = buildTxs(p);
    }

    /// @dev Prices are 18-decimal wei (quote wei per 1 ULTRA): priceX192 = price * 2**192 / 1e18 via
    /// mulDiv, so there is no 2**64 input cap. ULTRA is currency0: pool price = quote per ULTRA. Quote
    /// is currency0: pool price = ULTRA per quote = 1e18 / price. Both orderings covered by UltraLpTest.
    function deriveSqrtPriceWei(bool ultraIsC0, uint256 basis)
        internal
        pure
        returns (uint160 sqrtPriceX96, int24 tick)
    {
        uint256 one = uint256(1) << 192;
        sqrtPriceX96 = uint160(Math.sqrt(ultraIsC0 ? Math.mulDiv(basis, one, 1e18) : Math.mulDiv(1e18, one, basis)));
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @dev EARN's 6 txs with the mint replaced by manageMinter(safe,true) / mint / manageMinter(safe,false),
    /// and a single full-range MINT_POSITION. amountMax = the configured amount per currency, so any
    /// pool price other than the intended one reverts the batch (MaximumAmountExceeded).
    function buildTxs(LpPlan memory p) internal pure returns (SafeBatchLib.Tx[] memory txs) {
        (uint128 full0, uint128 full1) = p.earnIsC0
            ? (SafeCast.toUint128(p.fullRangeEarn), SafeCast.toUint128(p.fullRangeUsds))
            : (SafeCast.toUint128(p.fullRangeUsds), SafeCast.toUint128(p.fullRangeEarn));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(p.key, p.fullLower, p.fullUpper, uint256(p.liqFull), full0, full1, p.safe, bytes(""));
        params[1] = abi.encode(p.key.currency0, p.key.currency1);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.initializePool, (p.key, p.sqrtPriceX96));
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), type(uint256).max));

        txs = new SafeBatchLib.Tx[](8);
        txs[0] = SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(MintableBurnableToken.manageMinter, (p.safe, true))});
        txs[1] =
            SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(MintableBurnableToken.mint, (p.safe, p.fullRangeEarn))});
        txs[2] =
            SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(MintableBurnableToken.manageMinter, (p.safe, false))});
        txs[3] = SafeBatchLib.Tx({to: p.usds, data: abi.encodeCall(IERC20.approve, (p.permit2, p.fullRangeUsds))});
        txs[4] = SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(IERC20.approve, (p.permit2, p.fullRangeEarn))});
        txs[5] = SafeBatchLib.Tx({
            to: p.permit2,
            data: abi.encodeCall(
                IPermit2.approve, (p.usds, address(p.posm), SafeCast.toUint160(p.fullRangeUsds), type(uint48).max)
            )
        });
        txs[6] = SafeBatchLib.Tx({
            to: p.permit2,
            data: abi.encodeCall(
                IPermit2.approve, (p.earn, address(p.posm), SafeCast.toUint160(p.fullRangeEarn), type(uint48).max)
            )
        });
        txs[7] = SafeBatchLib.Tx({to: address(p.posm), data: abi.encodeCall(IPositionManager.multicall, (calls))});
    }

    /// @dev Executes `txs` as the Safe on the current fork and requires the end state. Replaces the
    /// inherited _simulateAndCheck, which asserts a second (bid-wall) position.
    function _simulate(LpPlan memory p, SafeBatchLib.Tx[] memory txs) internal {
        IERC20 ultra = IERC20(p.earn);
        IERC20 quote = IERC20(p.usds);
        uint256 supplyBefore = ultra.totalSupply();
        uint256 quoteBefore = quote.balanceOf(p.safe);
        uint256 ultraBefore = ultra.balanceOf(p.safe);
        uint256 tokenId = p.posm.nextTokenId();

        SafeBatchLib.execute(p.safe, txs);

        require(ultra.totalSupply() == supplyBefore + p.fullRangeEarn, "ProposeUltraLp sim: ULTRA supply delta != mint");
        (uint160 sqrtPriceX96, int24 tick,,) = p.stateView.getSlot0(p.poolId);
        require(sqrtPriceX96 == p.sqrtPriceX96 && tick == p.currentTick, "ProposeUltraLp sim: pool price != basisPrice");
        require(p.posm.ownerOf(tokenId) == p.safe, "ProposeUltraLp sim: position NFT not owned by Safe");
        require(p.posm.getPositionLiquidity(tokenId) == p.liqFull, "ProposeUltraLp sim: liquidity mismatch");

        uint256 quoteSpent = quoteBefore - quote.balanceOf(p.safe);
        require(
            quoteSpent <= p.fullRangeUsds && p.fullRangeUsds - quoteSpent <= DUST,
            "ProposeUltraLp sim: WETH spent not ~fullRangeQuote"
        );
        require(ultra.balanceOf(p.safe) <= ultraBefore + DUST, "ProposeUltraLp sim: ULTRA left on Safe beyond dust");
        require(!UltraToken(p.earn).minters(p.safe), "ProposeUltraLp sim: Safe still a minter");
        console2.log("Simulated position token id:", tokenId);
        console2.log("WETH spent:", quoteSpent);
    }

    function _addr(string memory cfg, string memory key) internal view returns (address a) {
        a = vm.parseJsonAddress(cfg, key);
        require(a != address(0), string.concat("ProposeUltraLp: lp.json ", key, " is zero -- fill it"));
        require(a.code.length > 0, string.concat("ProposeUltraLp: lp.json ", key, " has no code on this chain"));
    }

    function _num(string memory cfg, string memory key) internal pure returns (uint256 n) {
        n = vm.parseJsonUint(cfg, key);
        require(n > 0, string.concat("ProposeUltraLp: lp.json ", key, " is zero -- fill it"));
    }

    /// @dev Same Safe Transaction Builder schema as SafeBatchLib.write, which hardcodes the chain-1 path.
    function _json(address safe, SafeBatchLib.Tx[] memory txs) internal view returns (string memory) {
        string memory transactions;
        for (uint256 i = 0; i < txs.length; i++) {
            string memory entry = string.concat(
                "{\"to\":\"",
                vm.toString(txs[i].to),
                "\",\"value\":\"0\",\"data\":\"",
                vm.toString(txs[i].data),
                "\",\"contractMethod\":null,\"contractInputsValues\":null}"
            );
            transactions = i == 0 ? entry : string.concat(transactions, ",", entry);
        }
        return string.concat(
            "{\"version\":\"1.0\",\"chainId\":\"",
            vm.toString(block.chainid),
            "\",\"createdAt\":",
            vm.toString(block.timestamp * 1000),
            ",\"meta\":{\"name\":\"ULTRA/WETH V4 LP\",\"description\":\"Grants the Safe minter, mints the LP ULTRA, revokes minter, approves WETH and ULTRA to Permit2 and PositionManager, initializes the ULTRA/WETH v4 pool, and mints a full-range ULTRA/WETH position owned by this Safe. Execute in the order listed.\",\"txBuilderVersion\":\"2.0.1\",\"createdFromSafeAddress\":\"",
            vm.toString(safe),
            "\",\"createdFromOwnerAddress\":\"\",\"checksum\":null},\"transactions\":[",
            transactions,
            "]}"
        );
    }

    function _slice10(string memory hexAddr) private pure returns (string memory) {
        bytes memory out = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            out[i] = bytes(hexAddr)[i];
        }
        return string(out);
    }
}
