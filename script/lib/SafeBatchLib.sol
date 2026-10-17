// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Writes Safe Transaction Builder JSON batches using the DECODED transaction form
/// (contractMethod/contractInputsValues), so a human signer in the Safe UI sees the function name
/// and argument values instead of opaque calldata.
///
/// @dev Schema confirmed against the real safe-global/safe-wallet-monorepo source
///      (apps/tx-builder/src/typings/models.ts, fetched 2026-08-26):
///        BatchTransaction { to, value, data?, contractMethod?, contractInputsValues? }
///        ContractMethod   { inputs: ContractInput[], name, payable }
///        ContractInput    { internalType, name, type, components? }
///        contractInputsValues: { [paramName: string]: string }
///      Value string conventions (not in that file; standard Safe tx-builder convention,
///      could not independently confirm the encoder source — GitHub code search / raw fetches of
///      morpho-org/gnosis-tx-builder and safe-react-apps 404'd from this sandbox):
///        address -> checksummed hex string, bool -> "true"/"false", uint256/enum -> decimal string.
library SafeBatchLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Input {
        string name;
        string typ; // ABI "type", e.g. "address", "bool", "uint256", "uint8"
        string internalTyp; // ABI "internalType", e.g. "enum esETH.TokenType" for an enum param
        string value; // pre-stringified value, see conventions above
    }

    struct Tx {
        address to;
        bytes data; // raw calldata, kept for the self-check and for MODE=fork execution
        string method; // function name, e.g. "manageMinter"
        Input[] inputs;
    }

    /// @notice Re-derives calldata from (method name, input types, stringified values) and checks
    ///         it byte-for-byte matches `t.data` (already computed via abi.encodeCall at the call
    ///         site). Reverts loudly, naming the tx index and method, on any mismatch — this is
    ///         the proof that the decoded descriptor written to the Safe JSON is not silently
    ///         inconsistent with the calldata that will actually execute on-chain.
    function verify(Tx memory t, uint256 index) internal pure {
        string memory sig = string.concat(t.method, "(");
        for (uint256 i = 0; i < t.inputs.length; i++) {
            sig = i == 0 ? string.concat(sig, t.inputs[i].typ) : string.concat(sig, ",", t.inputs[i].typ);
        }
        sig = string.concat(sig, ")");
        bytes4 selector = bytes4(keccak256(bytes(sig)));

        bytes memory reencoded = abi.encodePacked(selector);
        for (uint256 i = 0; i < t.inputs.length; i++) {
            bytes32 typHash = keccak256(bytes(t.inputs[i].typ));
            if (typHash == keccak256("address")) {
                reencoded = bytes.concat(reencoded, abi.encode(vm.parseAddress(t.inputs[i].value)));
            } else if (typHash == keccak256("bool")) {
                reencoded = bytes.concat(reencoded, abi.encode(vm.parseBool(t.inputs[i].value)));
            } else if (typHash == keccak256("uint256") || typHash == keccak256("uint8")) {
                reencoded = bytes.concat(reencoded, abi.encode(vm.parseUint(t.inputs[i].value)));
            } else {
                revert(string.concat("SafeBatchLib.verify: unhandled input type for tx ", vm.toString(index)));
            }
        }

        if (keccak256(reencoded) != keccak256(t.data)) {
            revert(
                string.concat(
                    "SafeBatchLib.verify: decoded descriptor mismatch for tx ", vm.toString(index), " (", t.method, ")"
                )
            );
        }
    }

    function write(
        address safe,
        string memory operation,
        uint256 index,
        string memory label,
        string memory name,
        string memory description,
        Tx[] memory txs
    ) internal {
        string memory dir = string.concat("script/multisig/", operation, "/");
        vm.createDir(dir, true);

        string memory path = string.concat(dir, _pad3(index), "-", _slice10(vm.toString(safe)), "-", label, ".json");

        string memory transactions = "";
        for (uint256 i = 0; i < txs.length; i++) {
            string memory entry = string.concat(
                "{\"to\":\"",
                vm.toString(txs[i].to),
                "\",\"value\":\"0\",\"data\":null,\"contractMethod\":",
                _contractMethod(txs[i]),
                ",\"contractInputsValues\":",
                _contractInputsValues(txs[i]),
                "}"
            );
            transactions = i == 0 ? entry : string.concat(transactions, ",", entry);
        }

        string memory json = string.concat(
            "{\"version\":\"1.0\",\"chainId\":\"1\",\"createdAt\":",
            vm.toString(block.timestamp * 1000),
            ",\"meta\":{\"name\":\"",
            name,
            "\",\"description\":\"",
            description,
            "\",\"txBuilderVersion\":\"2.0.1\",\"createdFromSafeAddress\":\"",
            vm.toString(safe),
            "\",\"createdFromOwnerAddress\":\"\",\"checksum\":null},\"transactions\":[",
            transactions,
            "]}"
        );

        vm.writeFile(path, json);
    }

    function _contractMethod(Tx memory t) private pure returns (string memory) {
        string memory inputs = "";
        for (uint256 i = 0; i < t.inputs.length; i++) {
            string memory entry = string.concat(
                "{\"internalType\":\"",
                t.inputs[i].internalTyp,
                "\",\"name\":\"",
                t.inputs[i].name,
                "\",\"type\":\"",
                t.inputs[i].typ,
                "\"}"
            );
            inputs = i == 0 ? entry : string.concat(inputs, ",", entry);
        }
        return string.concat("{\"inputs\":[", inputs, "],\"name\":\"", t.method, "\",\"payable\":false}");
    }

    function _contractInputsValues(Tx memory t) private pure returns (string memory) {
        string memory values = "";
        for (uint256 i = 0; i < t.inputs.length; i++) {
            string memory entry = string.concat("\"", t.inputs[i].name, "\":\"", t.inputs[i].value, "\"");
            values = i == 0 ? entry : string.concat(values, ",", entry);
        }
        return string.concat("{", values, "}");
    }

    function _pad3(uint256 index) private pure returns (string memory) {
        if (index < 10) return string.concat("00", vm.toString(index));
        if (index < 100) return string.concat("0", vm.toString(index));
        return vm.toString(index);
    }

    function _slice10(string memory hexAddr) private pure returns (string memory) {
        bytes memory b = bytes(hexAddr);
        bytes memory out = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            out[i] = b[i];
        }
        return string(out);
    }
}
