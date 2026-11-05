// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {esETH} from "src/esETH.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchDecodedLib} from "../lib/SafeBatchDecodedLib.sol";
import {RebalanceBase, IWETH9} from "./RebalanceBase.s.sol";

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
/// converts it to stETH, mints the stETH into esETH. Route (`ROUTE` = auto|lido|uniswap, default auto):
/// Lido `submit` (1:1 ETH->stETH, no price impact; needs staking not paused and amt <= stake limit) or
/// Uniswap v3 WETH/wstETH 0.01% + `wstETH.unwrap`. `auto` picks Uniswap only if its post-slippage stETH
/// mint is strictly greater than Lido's `amt - 2`, or Lido is unavailable. esETH receives exactly the
/// minted `stMint`; Lido rounding leaves 1 wei under-backed per run, left to `burnExcess`. Never broadcasts.
/// Pipeline: `AMOUNT=<ETH> [ROUTE=..] [SLIPPAGE_BPS=..] forge script ... --fork-url $RPC_URL` ->
/// `yarn safe:hash <raw> --write [--nonce N]` -> `yarn safe:simulate <raw>` -> `yarn safe:propose <raw>`.
contract ConvertToStEth is RebalanceBase {
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
        uint256 amountEth = vm.envUint("AMOUNT");
        (SafeBatchDecodedLib.Tx[] memory txs, Route chosen) = buildAndSimulate(
            amountEth, _parseRoute(vm.envOr("ROUTE", string("auto"))), vm.envOr("SLIPPAGE_BPS", uint256(10))
        );
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

    function _parseRoute(string memory s) internal pure returns (Route) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("auto")) return Route.Auto;
        if (h == keccak256("lido")) return Route.Lido;
        if (h == keccak256("uniswap")) return Route.Uniswap;
        revert("ConvertToStEth: ROUTE must be auto|lido|uniswap");
    }

    function buildAndSimulate(uint256 amountEth, Route route, uint256 slippageBps)
        internal
        returns (SafeBatchDecodedLib.Tx[] memory txs, Route chosen)
    {
        uint256 amt = _amountWei(amountEth);
        require(slippageBps <= 100, "ConvertToStEth: SLIPPAGE_BPS > 100");
        _checkCommon(amt);
        (esETH.TokenType tokenType,,,) = esETH(payable(eseth())).tokenConfigs(steth());
        require(tokenType == esETH.TokenType.ERC20, "ConvertToStEth: stETH tokenType != ERC20");
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
            require(!ILido(steth()).isStakingPaused(), "ConvertToStEth: Lido staking paused");
            require(amt <= ILido(steth()).getCurrentStakeLimit(), "ConvertToStEth: AMOUNT > Lido stake limit");
            txs = _lidoTxs(amt);
            _simulate(txs);
            _assertConverted(amt, lidoMint, b);
            require(
                ILido(steth()).getPooledEthByShares(_lidoShares() - b.lidoShares) >= lidoMint,
                "ConvertToStEth sim: Lido stETH received < amt - 2"
            );
        } else {
            require(minWst > 0, "ConvertToStEth: Uniswap minWst == 0");
            require(stMintUni > 0, "ConvertToStEth: Uniswap stMint == 0");
            txs = _uniTxs(amt, minWst, stMintUni);
            uint256 wstBefore = IERC20(wsteth()).balanceOf(safe());
            _simulate(txs);
            _assertConverted(amt, stMintUni, b);
            require(IERC20(weth()).allowance(safe(), swapRouter02()) == 0, "ConvertToStEth sim: router allowance left");
            require(IERC20(wsteth()).balanceOf(safe()) >= wstBefore, "ConvertToStEth sim: Safe wstETH fell");
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
        uint256 st = IWstETH(wsteth()).getStETHByWstETH(minWst);
        stMintUni = st < 2 ? 0 : st - 2;
        console2.log("Uniswap quote (wstETH)", quoteWst);
        console2.log("Uniswap minWst", minWst);
        console2.log("Uniswap stMint", stMintUni);
    }

    function _uniTxs(uint256 amt, uint256 minWst, uint256 stMint)
        internal
        view
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

    function _lidoTxs(uint256 amt) internal view returns (SafeBatchDecodedLib.Tx[] memory txs) {
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
        require(IERC20(weth()).balanceOf(e) + amt == b.wethEsEth, "ConvertToStEth sim: esETH WETH delta != amt");
        require(
            IERC20(steth()).balanceOf(e) + 2 >= b.stEsEth + stMint, "ConvertToStEth sim: esETH stETH delta < stMint - 2"
        );
        require(mintedAfter == b.stMinted + stMint, "ConvertToStEth sim: stETH totalMinted delta != stMint");
        require(IERC20(e).totalSupply() + amt + 1 == b.supply + stMint, "ConvertToStEth sim: esETH supply delta");
        require(IERC20(e).balanceOf(s) + amt + 1 == b.safeEsEth + stMint, "ConvertToStEth sim: Safe esETH delta");
        require(IERC20(steth()).balanceOf(s) >= b.safeSt, "ConvertToStEth sim: mint drew on Safe stETH stock");
    }
}
