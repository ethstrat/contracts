// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Decoded Safe Transaction Builder writer with per-tx `value` (and matching `payable`), so a
/// human signer in the Safe UI sees function names and arguments for a batch that sends ETH.
/// Port of script/lib/SafeBatchLib.sol (left untouched; its Tx has no value and it hardcodes
/// `"value":"0"`, `"payable":false`). Writes to a caller-chosen path. Used by
/// 009-eseth-weth-rebalance (WethToStEth). The raw-calldata file, not this one, is what
/// gets hashed and proposed.
library SafeBatchDecodedLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Input {
        string name;
        string typ; // ABI "type" and "internalType" (identical for address/uint256), e.g. "address"
        string value; // pre-stringified value
    }

    struct Tx {
        address to;
        uint256 value; // wei sent with the call
        bytes data; // raw calldata, kept for the self-check
        string method; // function name, e.g. "submit"
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
            } else if (typHash == keccak256("uint256")) {
                reencoded = bytes.concat(reencoded, abi.encode(vm.parseUint(t.inputs[i].value)));
            } else {
                revert(string.concat("SafeBatchDecodedLib.verify: unhandled input type for tx ", vm.toString(index)));
            }
        }

        if (keccak256(reencoded) != keccak256(t.data)) {
            revert(
                string.concat(
                    "SafeBatchDecodedLib.verify: decoded descriptor mismatch for tx ",
                    vm.toString(index),
                    " (",
                    t.method,
                    ")"
                )
            );
        }
    }

    /// @dev Reverts before writing if any string holds `"` or `\` (no escaping) or a decoded tx fails
    /// `verify`. A tx with empty `method` is written as raw `data` (no descriptor, `verify` skipped).
    function write(string memory filePath, address safe, string memory name, string memory description, Tx[] memory txs)
        internal
    {
        _assertSafe(name);
        _assertSafe(description);
        for (uint256 i = 0; i < txs.length; i++) {
            _assertSafe(txs[i].method);
            for (uint256 j = 0; j < txs[i].inputs.length; j++) {
                _assertSafe(txs[i].inputs[j].name);
                _assertSafe(txs[i].inputs[j].typ);
                _assertSafe(txs[i].inputs[j].value);
            }
        }
        for (uint256 i = 0; i < txs.length; i++) {
            if (bytes(txs[i].method).length > 0) verify(txs[i], i);
        }

        string memory transactions = "";
        for (uint256 i = 0; i < txs.length; i++) {
            string memory entry = string.concat(
                "{\"to\":\"",
                vm.toString(txs[i].to),
                "\",\"value\":\"",
                vm.toString(txs[i].value),
                bytes(txs[i].method).length > 0
                    ? string.concat(
                        "\",\"data\":null,\"contractMethod\":",
                        _contractMethod(txs[i]),
                        ",\"contractInputsValues\":",
                        _contractInputsValues(txs[i])
                    )
                    : string.concat(
                        "\",\"data\":\"",
                        vm.toString(txs[i].data),
                        "\",\"contractMethod\":null,\"contractInputsValues\":null"
                    ),
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

        vm.writeFile(filePath, json);
    }

    function _assertSafe(string memory s) private pure {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            require(b[i] != 0x22 && b[i] != 0x5c, "SafeBatchDecodedLib: quote or backslash in string");
        }
    }

    // A non-payable function cannot take value, so value > 0 <=> payable.
    function _contractMethod(Tx memory t) private pure returns (string memory) {
        string memory inputs = "";
        for (uint256 i = 0; i < t.inputs.length; i++) {
            string memory entry = string.concat(
                "{\"internalType\":\"",
                t.inputs[i].typ,
                "\",\"name\":\"",
                t.inputs[i].name,
                "\",\"type\":\"",
                t.inputs[i].typ,
                "\"}"
            );
            inputs = i == 0 ? entry : string.concat(inputs, ",", entry);
        }
        return string.concat(
            "{\"inputs\":[", inputs, "],\"name\":\"", t.method, "\",\"payable\":", t.value > 0 ? "true" : "false", "}"
        );
    }

    function _contractInputsValues(Tx memory t) private pure returns (string memory) {
        string memory values = "";
        for (uint256 i = 0; i < t.inputs.length; i++) {
            string memory entry = string.concat("\"", t.inputs[i].name, "\":\"", t.inputs[i].value, "\"");
            values = i == 0 ? entry : string.concat(values, ",", entry);
        }
        return string.concat("{", values, "}");
    }
}
