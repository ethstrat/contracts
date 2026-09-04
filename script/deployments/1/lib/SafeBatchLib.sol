// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Writes Safe Transaction Builder JSON batches using the raw-calldata transaction form
/// (no ABI-descriptor introspection). Used by BuildOrder.s.sol, Cancel.s.sol and
/// StopEspnYield.s.sol.
library SafeBatchLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Tx {
        address to;
        bytes data;
    }

    function write(
        address safe,
        string memory operation,
        uint256 index,
        string memory name,
        string memory description,
        Tx[] memory txs
    ) internal {
        vm.createDir(string.concat("script/deployments/1/multisig/", operation, "/"), true);

        string memory filePath = path(safe, operation, index);

        string memory transactions = "";
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

    /// @dev The exact path `write` writes to. Exposed so a repeatable batch producer
    /// (004-stry-migration/WeeklyYield.s.sol) can scan for the first free index using the same
    /// derivation as the writer -- `write` ends in vm.writeFile, which overwrites silently.
    function path(address safe, string memory operation, uint256 index) internal pure returns (string memory) {
        return string.concat(
            "script/deployments/1/multisig/",
            operation,
            "/",
            _pad3(index),
            "-",
            _slice10(vm.toString(safe)),
            "-multisig.json"
        );
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
