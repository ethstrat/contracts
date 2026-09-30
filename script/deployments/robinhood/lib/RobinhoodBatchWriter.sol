// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";

/// @notice Shared Safe Transaction Builder JSON writer for the Robinhood Chain scripts. Same schema as
/// SafeBatchLib.write (script/deployments/1/lib/SafeBatchLib.sol), which hardcodes the chain-1 output path --
/// this is the local reimplementation for the script/deployments/robinhood/ tree. Concrete scripts supply their
/// own output directory via `_dir()`.
abstract contract RobinhoodBatchWriter is Script {
    function _dir() internal pure virtual returns (string memory);

    function _writeBatch(
        string memory file,
        address safe,
        string memory name,
        string memory description,
        SafeBatchLib.Tx[] memory txs
    ) internal {
        require(!vm.exists(file), string.concat(file, " already exists; delete it deliberately to regenerate"));
        vm.createDir(_dir(), true);
        vm.writeFile(file, _json(safe, name, description, txs));
        console2.log("Simulation passed; batch written:", file);
    }

    /// @dev Same Safe Transaction Builder schema as SafeBatchLib.write, which hardcodes chain 1.
    function _json(address safe, string memory name, string memory description, SafeBatchLib.Tx[] memory txs)
        internal
        view
        returns (string memory)
    {
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
    }

    function _file(string memory prefix, address safe) internal pure returns (string memory) {
        bytes memory full = bytes(vm.toString(safe));
        bytes memory short = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            short[i] = full[i];
        }
        return string.concat(_dir(), prefix, "-", string(short), "-multisig.json");
    }
}
