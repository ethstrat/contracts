// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {esETH} from "src/esETH.sol";
import {SafeBatchDecodedLib} from "../lib/SafeBatchDecodedLib.sol";
import {RebalanceBase, IWETH9} from "./RebalanceBase.s.sol";

/// @notice Unencumbered-Safe batch, run each fortnight: redeems AMOUNT (whole ETH) of WETH from esETH,
/// unwraps it to ETH, deposits the ETH back into esETH via `wrapAndMint`. esETH has no native-ETH path
/// (no receive/fallback, no ETH token type); `wrapAndMint` re-wraps to WETH, so esETH's WETH balance and
/// WETH totalMinted are unchanged and the net effect is esETH supply and Safe esETH -1 wei (redeem burns
/// amt + 1, mint gives amt). Never broadcasts.
/// Pipeline: `AMOUNT=<ETH> forge script ... --fork-url $RPC_URL` -> `yarn safe:hash <raw> --write [--nonce N]`
/// -> `yarn safe:simulate <raw>` -> `yarn safe:propose <raw>`.
contract RedepositEth is RebalanceBase {
    string internal constant OPERATION = "009-eseth-weth-rebalance/eth";

    function run() external {
        uint256 amountEth = vm.envUint("AMOUNT");
        SafeBatchDecodedLib.Tx[] memory txs = buildAndSimulate(amountEth);
        _write(
            OPERATION,
            "esETH WETH -> ETH redeposit",
            string.concat(
                "Redeems ",
                vm.toString(amountEth),
                " ETH of WETH from esETH, unwraps to ETH, deposits the ETH back via wrapAndMint."
            ),
            txs
        );
    }

    function buildAndSimulate(uint256 amountEth) internal returns (SafeBatchDecodedLib.Tx[] memory txs) {
        uint256 amt = _amountWei(amountEth);
        _checkCommon(amt);
        _logNonce();

        address s = safe();
        address e = eseth();
        address w = weth();
        txs = _txs(amt);

        uint256 wethEsEthBefore = IERC20(w).balanceOf(e);
        (,,, uint256 mintedBefore) = esETH(payable(e)).tokenConfigs(w);
        uint256 supplyBefore = IERC20(e).totalSupply();
        uint256 safeEsEthBefore = IERC20(e).balanceOf(s);

        _simulate(txs);

        (,,, uint256 mintedAfter) = esETH(payable(e)).tokenConfigs(w);
        require(IERC20(w).balanceOf(e) == wethEsEthBefore, "RedepositEth sim: esETH WETH changed");
        require(mintedAfter == mintedBefore, "RedepositEth sim: WETH totalMinted changed");
        require(IERC20(e).totalSupply() + 1 == supplyBefore, "RedepositEth sim: esETH supply delta != 1");
        require(IERC20(e).balanceOf(s) + 1 == safeEsEthBefore, "RedepositEth sim: Safe esETH delta != 1");
    }

    function _txs(uint256 amt) internal view returns (SafeBatchDecodedLib.Tx[] memory txs) {
        address s = safe();
        address e = eseth();
        address w = weth();
        txs = new SafeBatchDecodedLib.Tx[](3);

        SafeBatchDecodedLib.Input[] memory in0 = new SafeBatchDecodedLib.Input[](3);
        in0[0] = _in("token", "address", vm.toString(w));
        in0[1] = _in("tokenAmount", "uint256", vm.toString(amt));
        in0[2] = _in("receiver", "address", vm.toString(s));
        txs[0] = SafeBatchDecodedLib.Tx(e, 0, abi.encodeCall(esETH.redeem, (w, amt, s)), "redeem", in0);

        SafeBatchDecodedLib.Input[] memory in1 = new SafeBatchDecodedLib.Input[](1);
        in1[0] = _in("wad", "uint256", vm.toString(amt));
        txs[1] = SafeBatchDecodedLib.Tx(w, 0, abi.encodeCall(IWETH9.withdraw, (amt)), "withdraw", in1);

        SafeBatchDecodedLib.Input[] memory in2 = new SafeBatchDecodedLib.Input[](1);
        in2[0] = _in("receiver", "address", vm.toString(s));
        txs[2] = SafeBatchDecodedLib.Tx(e, amt, abi.encodeCall(esETH.wrapAndMint, (s)), "wrapAndMint", in2);
    }
}
