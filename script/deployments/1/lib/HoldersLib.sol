// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Reads the ESPN holder snapshot artifact produced by the snapshot script and hands the
/// distribute scripts arrays they can pass straight to `mintBatch`.
library HoldersLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Field order matches JSON-key alphabetical order (address, balance, excluded, isContract) —
    // `vm.parseJson`'s abi.decode emits fields in that order regardless of declaration intent.
    // Declaring the two bools in the other order silently swaps them on decode.
    struct Holder {
        address addr;
        string balance;
        bool excluded;
        bool isContract;
    }

    struct Snapshot {
        uint256 snapshotBlock;
        uint256 totalSupply;
        Holder[] holders;
    }

    function load(string memory path) internal view returns (Snapshot memory snapshot) {
        string memory json = vm.readFile(path);

        snapshot.snapshotBlock = vm.parseJsonUint(json, ".snapshotBlock");
        snapshot.totalSupply = vm.parseJsonUint(json, ".totalSupply");

        // balance is decoded as `string` (not `uint256`) — the snapshot writes amounts as quoted
        // decimal strings, and `vm.parseJson` ABI-encodes a JSON string as `string`. A `uint256`
        // field here reverts on decode.
        Holder[] memory holders = abi.decode(vm.parseJson(json, ".holders"), (Holder[]));
        snapshot.holders = holders;

        uint256 fileNameBlock = _blockFromFileName(path);
        require(
            fileNameBlock == snapshot.snapshotBlock,
            string.concat(
                "HoldersLib: snapshotBlock mismatch, filename=",
                vm.toString(fileNameBlock),
                " body=",
                vm.toString(snapshot.snapshotBlock)
            )
        );
    }

    function included(Snapshot memory snapshot)
        internal
        pure
        returns (address[] memory addrs, uint256[] memory balances, uint256 includedCount, uint256 excludedCount)
    {
        uint256 total = snapshot.holders.length;
        addrs = new address[](total);
        balances = new uint256[](total);

        for (uint256 i = 0; i < total; i++) {
            Holder memory holder = snapshot.holders[i];
            if (holder.excluded) {
                excludedCount++;
                continue;
            }
            addrs[includedCount] = holder.addr;
            balances[includedCount] = vm.parseUint(holder.balance);
            includedCount++;
        }

        assembly {
            mstore(addrs, includedCount)
            mstore(balances, includedCount)
        }
    }

    function sum(uint256[] memory balances) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < balances.length; i++) {
            total += balances[i];
        }
    }

    /// @dev Extracts the block number embedded in a filename of the form
    /// ".../espn-holders-<block>.json".
    function _blockFromFileName(string memory path) private pure returns (uint256) {
        bytes memory pathBytes = bytes(path);
        bytes memory marker = bytes("espn-holders-");

        int256 markerStart = -1;
        for (uint256 i = 0; i + marker.length <= pathBytes.length; i++) {
            bool matches = true;
            for (uint256 j = 0; j < marker.length; j++) {
                if (pathBytes[i + j] != marker[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                markerStart = int256(i);
                break;
            }
        }
        require(markerStart >= 0, "HoldersLib: filename missing 'espn-holders-' marker");

        uint256 numStart = uint256(markerStart) + marker.length;
        uint256 numEnd = numStart;
        while (numEnd < pathBytes.length && pathBytes[numEnd] != ".") {
            numEnd++;
        }

        bytes memory numBytes = new bytes(numEnd - numStart);
        for (uint256 i = 0; i < numBytes.length; i++) {
            numBytes[i] = pathBytes[numStart + i];
        }

        return vm.parseUint(string(numBytes));
    }
}
