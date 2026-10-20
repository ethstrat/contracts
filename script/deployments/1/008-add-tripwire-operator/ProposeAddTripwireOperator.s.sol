// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ITripwireController} from "src/interfaces/ITripwireController.sol";
import {esETH} from "src/esETH.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice Main-Safe batch: adds OPERATOR_1/OPERATOR_2 as TripwireController operators on every
/// guardian-controlled target (skipping pairs that already are operators), then makes WETH
/// redeemable on esETH keeping its tokenType/isMintable. Never broadcasts.
/// Pipeline: forge script ... --fork-url $RPC_URL -> tx-builder JSON in multisig/008-add-tripwire-operator/
/// -> `yarn safe:hash <json> --write` (later `--check`) -> `yarn safe:simulate <json>` -> `yarn safe:propose <json>`.
/// Cross-check: script/safe/generate-add-tripwire-operator.mjs yields the same safeTxHash at the same nonce.
contract ProposeAddTripwireOperator is Script {
    address internal constant OPERATOR_1 = 0x27F60886045Eb16a2464E055d48508F46D93e306;
    address internal constant OPERATOR_2 = 0xEfa9f0766638Fc2258e13A0Ce1b9dA522412D6dF;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Keys in deploymentAddresses.json; order matches the JS generator (and so the batch hash).
    function targetKeys() internal pure returns (string[5] memory) {
        return [".convertible-note", ".desETH", ".cdt", ".esETH", ".staked-earn"];
    }

    function controller() internal view returns (ITripwireController) {
        return ITripwireController(ConfigLib.addr("internalAddresses.json", ".protocol.tripwire.controller"));
    }

    function safe() internal view returns (address) {
        return ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.main");
    }

    function targets() internal view returns (address[5] memory t) {
        string[5] memory keys = targetKeys();
        for (uint256 i = 0; i < 5; i++) {
            t[i] = ConfigLib.addr("deploymentAddresses.json", keys[i]);
        }
    }

    function run() external virtual {
        address s = safe();
        require(
            !vm.exists(SafeBatchLib.path(s, "008-add-tripwire-operator", 1)),
            "Propose: batch 001 already exists; delete it deliberately to regenerate"
        );
        SafeBatchLib.Tx[] memory txs = buildBatch(s);
        SafeBatchLib.write(
            s,
            "008-add-tripwire-operator",
            1,
            "Add tripwire operators and make WETH redeemable",
            "Adds the two tripwire operators to every guardian-controlled TripwireController target where missing, then makes WETH redeemable on esETH keeping its tokenType and isMintable. Execute the transactions in the order listed.",
            txs
        );
        console2.log("Batch written:", SafeBatchLib.path(s, "008-add-tripwire-operator", 1));
    }

    function buildBatch(address s) internal view returns (SafeBatchLib.Tx[] memory txs) {
        ITripwireController ctl = controller();
        address[5] memory t = targets();
        address[2] memory ops = [OPERATOR_1, OPERATOR_2];
        SafeBatchLib.Tx[] memory buf = new SafeBatchLib.Tx[](11);
        uint256 n;
        for (uint256 i = 0; i < 5; i++) {
            require(ctl.guardian(t[i]) == s, "Propose: guardian(target) != main Safe");
            for (uint256 j = 0; j < 2; j++) {
                if (ctl.isOperator(t[i], ops[j])) continue;
                buf[n++] =
                    SafeBatchLib.Tx(address(ctl), abi.encodeCall(ITripwireController.addOperator, (t[i], ops[j])));
            }
        }

        esETH eseth = esETH(payable(ConfigLib.addr("deploymentAddresses.json", ".esETH")));
        (esETH.TokenType tokenType, bool isMintable, bool isRedeemable,) = eseth.tokenConfigs(WETH);
        require(tokenType != esETH.TokenType.UNSUPPORTED, "Propose: WETH unsupported on esETH");
        require(!isRedeemable, "Propose: WETH already redeemable on esETH");
        buf[n++] =
            SafeBatchLib.Tx(address(eseth), abi.encodeCall(esETH.setTokenConfig, (WETH, tokenType, isMintable, true)));

        txs = new SafeBatchLib.Tx[](n);
        for (uint256 i = 0; i < n; i++) {
            txs[i] = buf[i];
        }
    }
}
