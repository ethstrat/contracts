// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {esETH} from "src/esETH.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchDecodedLib} from "../lib/SafeBatchDecodedLib.sol";
import {RebalanceBase, IWETH9} from "./RebalanceBase.s.sol";
import {RebalanceParams} from "./Params.sol";

interface ILido {
    function submit(address referral) external payable returns (uint256);
    function isStakingPaused() external view returns (bool);
    function getCurrentStakeLimit() external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function getPooledEthByShares(uint256 shares) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWstETH {
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
}

/// @notice Unencumbered-Safe batch, run each fortnight: redeems AMOUNT (whole ETH) of WETH from esETH,
/// converts it to stETH, mints the stETH into esETH. Route (`RebalanceParams.ROUTE` = auto|lido|uniswap,
/// env `ROUTE` overrides):
/// Lido `submit` (1:1 ETH->stETH, no price impact; needs staking not paused and amt <= stake limit) or
/// Uniswap v3 WETH/wstETH 0.01% + `wstETH.unwrap`. `auto` picks Uniswap only if its post-slippage stETH
/// mint is strictly greater than Lido's `amt - 2`, or Lido is unavailable. esETH receives exactly the
/// minted `stMint`; Lido rounding leaves 1 wei under-backed per run, left to `burnExcess`. Never broadcasts.
/// Pipeline: `[AMOUNT=<ETH>] [ROUTE=..] [SLIPPAGE_BPS=..] forge script ... --fork-url $RPC_URL` ->
/// `yarn safe:hash <raw> --write [--nonce N]` -> `yarn safe:simulate <raw>` -> `yarn safe:propose <raw>`.
contract WethToStEth is RebalanceBase {
    string internal constant OPERATION = "009-eseth-weth-rebalance/steth";
    uint24 internal constant POOL_FEE = 100; // v3 WETH/wstETH 0.01%, best Uniswap WETH->stETH liquidity (spec A5)

    enum Route {
        Auto,
        Lido,
        Uniswap
    }

    struct Before {
        uint256 wethEsEth;
        uint256 stEsEth;
        uint256 stMinted;
        uint256 supply;
        uint256 safeEsEth;
        uint256 safeSt;
        uint256 lidoShares; // sharesOf(Safe) + sharesOf(esETH)
    }

    function steth() internal view returns (address) {
        return ConfigLib.addr("externalAddresses.json", ".lido.stETH");
    }

    function wsteth() internal view returns (address) {
        return ConfigLib.addr("externalAddresses.json", ".lido.wstETH");
    }

    function swapRouter02() internal view returns (address) {
        return ConfigLib.addr("externalAddresses.json", ".uniswap-v3.swapRouter02");
    }

    function quoterV2() internal view returns (address) {
        return ConfigLib.addr("externalAddresses.json", ".uniswap-v3.quoterV2");
    }

    function run() external {
        uint256 amountEth = vm.envOr("AMOUNT", RebalanceParams.AMOUNT);
        (SafeBatchDecodedLib.Tx[] memory txs, Route chosen) =
            buildAndSimulate(amountEth, _route(), vm.envOr("SLIPPAGE_BPS", RebalanceParams.SLIPPAGE_BPS));
        _write(
            OPERATION,
            "esETH WETH -> stETH rebalance",
            string.concat(
                "Redeems ",
                vm.toString(amountEth),
                " ETH of WETH from esETH, converts to stETH via ",
                chosen == Route.Lido ? "Lido submit" : "Uniswap v3 WETH/wstETH 0.01% + unwrap",
                ", mints the stETH into esETH."
            ),
            txs
        );
    }

    function _route() internal view returns (Route) {
        return _parseRoute(vm.envOr("ROUTE", RebalanceParams.ROUTE));
    }

    function _parseRoute(string memory s) internal pure returns (Route) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("auto")) return Route.Auto;
        if (h == keccak256("lido")) return Route.Lido;
        if (h == keccak256("uniswap")) return Route.Uniswap;
        revert("WethToStEth: ROUTE must be auto|lido|uniswap");
    }

    function buildAndSimulate(uint256 amountEth, Route route, uint256 slippageBps)
        internal
        returns (SafeBatchDecodedLib.Tx[] memory txs, Route chosen)
    {
        uint256 amt = _amountWei(amountEth);
        require(slippageBps <= RebalanceParams.MAX_SLIPPAGE_BPS, "WethToStEth: SLIPPAGE_BPS > 100");
        _checkCommon(amt);
        (esETH.TokenType tokenType,,,) = esETH(payable(eseth())).tokenConfigs(steth());
        require(tokenType == esETH.TokenType.ERC20, "WethToStEth: stETH tokenType != ERC20");
        _logNonce();

        uint256 lidoMint = amt - 2;
        bool lidoOk = !ILido(steth()).isStakingPaused() && amt <= ILido(steth()).getCurrentStakeLimit();
        uint256 minWst;
        uint256 stMintUni;
        if (route != Route.Lido) (, minWst, stMintUni) = _quoteUni(amt, slippageBps);
        chosen = route;
        if (route == Route.Auto) chosen = (stMintUni > lidoMint || !lidoOk) ? Route.Uniswap : Route.Lido;
        console2.log("Lido mint (wei)", lidoMint);
        console2.log("Uniswap mint (wei)", stMintUni);
        console2.log("route (1 lido, 2 uniswap)", uint256(chosen));

        Before memory b = _before();
        if (chosen == Route.Lido) {
            require(!ILido(steth()).isStakingPaused(), "WethToStEth: Lido staking paused");
            require(amt <= ILido(steth()).getCurrentStakeLimit(), "WethToStEth: AMOUNT > Lido stake limit");
            txs = _lidoTxs(amt);
            _checkBatch(txs, chosen, amt, 0, slippageBps);
            _simulate(txs);
            _assertConverted(amt, lidoMint, b);
            require(
                ILido(steth()).getPooledEthByShares(_lidoShares() - b.lidoShares) >= lidoMint,
                "WethToStEth sim: Lido stETH received < amt - 2"
            );
        } else {
            require(minWst > 0, "WethToStEth: Uniswap minWst == 0");
            require(stMintUni > 0, "WethToStEth: Uniswap stMint == 0");
            txs = _uniTxs(amt, minWst, stMintUni);
            _checkBatch(txs, chosen, amt, minWst, slippageBps);
            uint256 wstBefore = IERC20(wsteth()).balanceOf(safe());
            _simulate(txs);
            _assertConverted(amt, stMintUni, b);
            require(IERC20(weth()).allowance(safe(), swapRouter02()) == 0, "WethToStEth sim: router allowance left");
            require(IERC20(wsteth()).balanceOf(safe()) >= wstBefore, "WethToStEth sim: Safe wstETH fell");
        }
    }

    /// @dev QuoterV2 is state-changing ABI (revert-based quote); fine on a fork, nothing is broadcast.
    function _quoteUni(uint256 amt, uint256 slippageBps)
        internal
        returns (uint256 quoteWst, uint256 minWst, uint256 stMintUni)
    {
        (quoteWst,,,) = IQuoterV2(quoterV2())
            .quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(weth(), wsteth(), amt, POOL_FEE, 0));
        minWst = quoteWst * (10_000 - slippageBps) / 10_000;
        stMintUni = _stMintFor(minWst);
        console2.log("Uniswap quote (wstETH)", quoteWst);
        console2.log("Uniswap minWst", minWst);
        console2.log("Uniswap stMint", stMintUni);
    }

    /// @dev stETH minted for `minWst` wstETH, rate from wstETH itself (not the pool quote), less 2 wei rounding.
    function _stMintFor(uint256 minWst) internal view returns (uint256) {
        uint256 st = IWstETH(wsteth()).getStETHByWstETH(minWst);
        return st < 2 ? 0 : st - 2;
    }

    /// @dev Decodes the built batch and asserts it matches intent, before simulation and before any file is
    /// written. `stMint` is read back from the batch's mint tx and bounded against independent values (amt,
    /// wstETH's own rate, the par floor), not recomputed the way the builder does. `minWst` is the quote-derived
    /// minimum (Uniswap only). On Uniswap the minted stETH must also be >= par (`amt * (10000 - slippageBps) /
    /// 10000`), rate from wstETH, so a skewed pool fails closed.
    function _checkBatch(
        SafeBatchDecodedLib.Tx[] memory txs,
        Route chosen,
        uint256 amt,
        uint256 minWst,
        uint256 slippageBps
    ) internal view {
        bool uni = chosen == Route.Uniswap;
        require(uni || chosen == Route.Lido, "WethToStEth batch: route unresolved");
        uint256 n = txs.length;
        require(n == (uni ? 6 : 5), "WethToStEth batch: tx count");
        for (uint256 i; i < n; i++) {
            require(txs[i].value == (!uni && i == 2 ? amt : 0), "WethToStEth batch: unexpected tx value");
        }

        (address t, uint256 a, address r) =
            abi.decode(_at(txs[0], eseth(), esETH.redeem.selector), (address, uint256, address));
        require(t == weth() && a == amt && r == safe(), "WethToStEth batch: redeem args");

        (t, a, r) = abi.decode(_at(txs[n - 1], eseth(), esETH.mint.selector), (address, uint256, address));
        require(t == steth() && r == safe(), "WethToStEth batch: mint args");
        uint256 stMint = a;
        (r, a) = abi.decode(_at(txs[n - 2], steth(), ILido.approve.selector), (address, uint256));
        require(r == eseth() && a == stMint, "WethToStEth batch: approve args");

        if (uni) {
            _checkSwap(txs, amt, minWst, stMint);
            require(stMint >= amt * (10_000 - slippageBps) / 10_000, "WethToStEth: Uniswap stMint below par floor");
        } else {
            a = abi.decode(_at(txs[1], weth(), IWETH9.withdraw.selector), (uint256));
            require(a == amt, "WethToStEth batch: withdraw amount");
            r = abi.decode(_at(txs[2], steth(), ILido.submit.selector), (address));
            require(r == address(0), "WethToStEth batch: submit referral");
            require(stMint + 2 >= amt && stMint <= amt, "WethToStEth batch: Lido stMint range");
        }
    }

    function _checkSwap(SafeBatchDecodedLib.Tx[] memory txs, uint256 amt, uint256 minWst, uint256 stMint)
        internal
        view
    {
        (address g, uint256 w) = abi.decode(_at(txs[1], weth(), IWETH9.approve.selector), (address, uint256));
        require(g == swapRouter02() && w == amt, "WethToStEth batch: WETH approve args");

        bytes memory sa = _at(txs[2], swapRouter02(), ISwapRouter02.exactInputSingle.selector);
        require(sa.length == 7 * 32, "WethToStEth batch: swap calldata length"); // no deadline field
        ISwapRouter02.ExactInputSingleParams memory p = abi.decode(sa, (ISwapRouter02.ExactInputSingleParams));
        require(p.amountOutMinimum == minWst, "WethToStEth batch: swap amountOutMinimum != minWst");
        require(
            p.tokenIn == weth() && p.tokenOut == wsteth() && p.fee == POOL_FEE && p.recipient == safe()
                && p.amountIn == amt && p.sqrtPriceLimitX96 == 0,
            "WethToStEth batch: swap params"
        );

        uint256 u = abi.decode(_at(txs[3], wsteth(), IWstETH.unwrap.selector), (uint256));
        require(u <= minWst, "WethToStEth batch: unwrap > minWst");
        // unwrap must cover the mint plus the 2 wei stETH transfer rounding
        require(IWstETH(wsteth()).getStETHByWstETH(u) >= stMint + 2, "WethToStEth batch: unwrap short of mint");
    }

    function _uniTxs(uint256 amt, uint256 minWst, uint256 stMint)
        internal
        view
        virtual
        returns (SafeBatchDecodedLib.Tx[] memory txs)
    {
        address w = weth();
        address router = swapRouter02();
        txs = new SafeBatchDecodedLib.Tx[](6);
        txs[0] = _redeemTx(amt);

        SafeBatchDecodedLib.Input[] memory in1 = new SafeBatchDecodedLib.Input[](2);
        in1[0] = _in("guy", "address", vm.toString(router));
        in1[1] = _in("wad", "uint256", vm.toString(amt));
        txs[1] = SafeBatchDecodedLib.Tx(w, 0, abi.encodeCall(IWETH9.approve, (router, amt)), "approve", in1);

        // Tuple arg: raw-data fallback (empty method), decoded view shows only calldata.
        txs[2] = SafeBatchDecodedLib.Tx(
            router,
            0,
            abi.encodeCall(
                ISwapRouter02.exactInputSingle,
                (ISwapRouter02.ExactInputSingleParams(w, wsteth(), POOL_FEE, safe(), amt, minWst, 0))
            ),
            "",
            new SafeBatchDecodedLib.Input[](0)
        );

        SafeBatchDecodedLib.Input[] memory in3 = new SafeBatchDecodedLib.Input[](1);
        in3[0] = _in("_wstETHAmount", "uint256", vm.toString(minWst));
        txs[3] = SafeBatchDecodedLib.Tx(wsteth(), 0, abi.encodeCall(IWstETH.unwrap, (minWst)), "unwrap", in3);

        txs[4] = _approveTx(stMint);
        txs[5] = _mintTx(stMint);
    }

    function _lidoTxs(uint256 amt) internal view virtual returns (SafeBatchDecodedLib.Tx[] memory txs) {
        address w = weth();
        address st = steth();
        uint256 stMint = amt - 2;
        txs = new SafeBatchDecodedLib.Tx[](5);
        txs[0] = _redeemTx(amt);

        SafeBatchDecodedLib.Input[] memory in1 = new SafeBatchDecodedLib.Input[](1);
        in1[0] = _in("wad", "uint256", vm.toString(amt));
        txs[1] = SafeBatchDecodedLib.Tx(w, 0, abi.encodeCall(IWETH9.withdraw, (amt)), "withdraw", in1);

        SafeBatchDecodedLib.Input[] memory in2 = new SafeBatchDecodedLib.Input[](1);
        in2[0] = _in("_referral", "address", vm.toString(address(0)));
        txs[2] = SafeBatchDecodedLib.Tx(st, amt, abi.encodeCall(ILido.submit, (address(0))), "submit", in2);

        txs[3] = _approveTx(stMint);
        txs[4] = _mintTx(stMint);
    }

    function _redeemTx(uint256 amt) internal view returns (SafeBatchDecodedLib.Tx memory) {
        address s = safe();
        address w = weth();
        SafeBatchDecodedLib.Input[] memory ins = new SafeBatchDecodedLib.Input[](3);
        ins[0] = _in("token", "address", vm.toString(w));
        ins[1] = _in("tokenAmount", "uint256", vm.toString(amt));
        ins[2] = _in("receiver", "address", vm.toString(s));
        return SafeBatchDecodedLib.Tx(eseth(), 0, abi.encodeCall(esETH.redeem, (w, amt, s)), "redeem", ins);
    }

    function _approveTx(uint256 stMint) internal view returns (SafeBatchDecodedLib.Tx memory) {
        address e = eseth();
        SafeBatchDecodedLib.Input[] memory ins = new SafeBatchDecodedLib.Input[](2);
        ins[0] = _in("_spender", "address", vm.toString(e));
        ins[1] = _in("_amount", "uint256", vm.toString(stMint));
        return SafeBatchDecodedLib.Tx(steth(), 0, abi.encodeCall(ILido.approve, (e, stMint)), "approve", ins);
    }

    function _mintTx(uint256 stMint) internal view returns (SafeBatchDecodedLib.Tx memory) {
        address s = safe();
        address st = steth();
        SafeBatchDecodedLib.Input[] memory ins = new SafeBatchDecodedLib.Input[](3);
        ins[0] = _in("token", "address", vm.toString(st));
        ins[1] = _in("tokenAmount", "uint256", vm.toString(stMint));
        ins[2] = _in("receiver", "address", vm.toString(s));
        return SafeBatchDecodedLib.Tx(eseth(), 0, abi.encodeCall(esETH.mint, (st, stMint, s)), "mint", ins);
    }

    function _lidoShares() internal view returns (uint256) {
        return ILido(steth()).sharesOf(safe()) + ILido(steth()).sharesOf(eseth());
    }

    function _before() internal view returns (Before memory b) {
        address e = eseth();
        address s = safe();
        (,,, b.stMinted) = esETH(payable(e)).tokenConfigs(steth());
        b.wethEsEth = IERC20(weth()).balanceOf(e);
        b.stEsEth = IERC20(steth()).balanceOf(e);
        b.supply = IERC20(e).totalSupply();
        b.safeEsEth = IERC20(e).balanceOf(s);
        b.safeSt = IERC20(steth()).balanceOf(s);
        b.lidoShares = _lidoShares();
    }

    function _assertConverted(uint256 amt, uint256 stMint, Before memory b) internal view {
        address e = eseth();
        address s = safe();
        (,,, uint256 mintedAfter) = esETH(payable(e)).tokenConfigs(steth());
        require(IERC20(weth()).balanceOf(e) + amt == b.wethEsEth, "WethToStEth sim: esETH WETH delta != amt");
        require(
            IERC20(steth()).balanceOf(e) + 2 >= b.stEsEth + stMint, "WethToStEth sim: esETH stETH delta < stMint - 2"
        );
        require(mintedAfter == b.stMinted + stMint, "WethToStEth sim: stETH totalMinted delta != stMint");
        require(IERC20(e).totalSupply() + amt + 1 == b.supply + stMint, "WethToStEth sim: esETH supply delta");
        require(IERC20(e).balanceOf(s) + amt + 1 == b.safeEsEth + stMint, "WethToStEth sim: Safe esETH delta");
        require(IERC20(steth()).balanceOf(s) >= b.safeSt, "WethToStEth sim: mint drew on Safe stETH stock");
    }
}
