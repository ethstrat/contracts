// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MintableBurnableToken} from "../src/MintableBurnableToken.sol";
import {esETH} from "../src/esETH.sol";
import {SafeBatchLib} from "./lib/SafeBatchLib.sol";

/// @notice Writes a Safe Transaction Builder JSON batch that mints desETH, mints esETH backed by
///         that desETH, then redeems the esETH back out for stETH — all run as SAFE, which is a
///         registered minter on both desETH and esETH, and esETH's treasuryManager.
///
///         forge script script/DesEthEsEthCycle.s.sol --rpc-url <rpc>
contract DesEthEsEthCycle is Script {
    address constant DESETH_TOKEN = 0x2e65e2Fa50E8338d2CC81821D15364cF9516145f;
    address constant ESETH_TOKEN = 0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb;
    address constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant SAFE = 0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1;

    function run() external {
        uint256 amount = vm.envOr("AMOUNT", uint256(1500 ether));

        (esETH.TokenType desEthType,,,) = esETH(ESETH_TOKEN).tokenConfigs(DESETH_TOKEN);
        require(desEthType == esETH.TokenType.ERC20, "desETH tokenConfig: unexpected tokenType, refusing to guess");
        (esETH.TokenType stEthType,,,) = esETH(ESETH_TOKEN).tokenConfigs(STETH_TOKEN);
        require(stEthType == esETH.TokenType.ERC20, "stETH tokenConfig: unexpected tokenType, refusing to guess");

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](4);
        uint256 n = 0;

        {
            SafeBatchLib.Input[] memory inputs = new SafeBatchLib.Input[](2);
            inputs[0] =
                SafeBatchLib.Input({name: "to", typ: "address", internalTyp: "address", value: vm.toString(SAFE)});
            inputs[1] = SafeBatchLib.Input({
                name: "amount", typ: "uint256", internalTyp: "uint256", value: vm.toString(amount)
            });
            txs[n++] = SafeBatchLib.Tx({
                to: DESETH_TOKEN,
                data: abi.encodeCall(MintableBurnableToken.mint, (SAFE, amount)),
                method: "mint",
                inputs: inputs
            });
        }

        {
            SafeBatchLib.Input[] memory inputs = new SafeBatchLib.Input[](2);
            inputs[0] = SafeBatchLib.Input({
                name: "spender", typ: "address", internalTyp: "address", value: vm.toString(ESETH_TOKEN)
            });
            inputs[1] =
                SafeBatchLib.Input({name: "value", typ: "uint256", internalTyp: "uint256", value: vm.toString(amount)});
            txs[n++] = SafeBatchLib.Tx({
                to: DESETH_TOKEN,
                data: abi.encodeCall(IERC20.approve, (ESETH_TOKEN, amount)),
                method: "approve",
                inputs: inputs
            });
        }

        {
            SafeBatchLib.Input[] memory inputs = new SafeBatchLib.Input[](3);
            inputs[0] = SafeBatchLib.Input({
                name: "token", typ: "address", internalTyp: "address", value: vm.toString(DESETH_TOKEN)
            });
            inputs[1] = SafeBatchLib.Input({
                name: "tokenAmount", typ: "uint256", internalTyp: "uint256", value: vm.toString(amount)
            });
            inputs[2] = SafeBatchLib.Input({
                name: "receiver", typ: "address", internalTyp: "address", value: vm.toString(SAFE)
            });
            txs[n++] = SafeBatchLib.Tx({
                to: ESETH_TOKEN,
                data: abi.encodeCall(esETH.mint, (DESETH_TOKEN, amount, SAFE)),
                method: "mint",
                inputs: inputs
            });
        }

        {
            SafeBatchLib.Input[] memory inputs = new SafeBatchLib.Input[](3);
            inputs[0] = SafeBatchLib.Input({
                name: "token", typ: "address", internalTyp: "address", value: vm.toString(STETH_TOKEN)
            });
            inputs[1] = SafeBatchLib.Input({
                name: "tokenAmount", typ: "uint256", internalTyp: "uint256", value: vm.toString(amount)
            });
            inputs[2] = SafeBatchLib.Input({
                name: "receiver", typ: "address", internalTyp: "address", value: vm.toString(SAFE)
            });
            txs[n++] = SafeBatchLib.Tx({
                to: ESETH_TOKEN,
                data: abi.encodeCall(esETH.redeem, (STETH_TOKEN, amount, SAFE)),
                method: "redeem",
                inputs: inputs
            });
        }

        for (uint256 i = 0; i < txs.length; i++) {
            SafeBatchLib.verify(txs[i], i);
        }

        SafeBatchLib.write(
            SAFE,
            "desETH-esETH-stETH-cycle",
            1,
            "multisig",
            "desETH -> esETH -> stETH mint/redeem cycle",
            "Mints 1500 desETH, mints 1500 esETH backed by that desETH, then redeems 1500 stETH worth of esETH back out. All three calls run as the Safe (0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1), which is both a registered minter on desETH and esETH's treasuryManager.",
            txs
        );
        console2.log("Wrote Safe batch to script/multisig/desETH-esETH-stETH-cycle/");
    }
}
