// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Thin JSON config accessors shared by every script under script/deployments/1/.
library ConfigLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function configRoot() internal pure returns (string memory) {
        return "script/deployments/1/config/";
    }

    function readJson(string memory fileName) internal view returns (string memory) {
        return vm.readFile(string.concat(configRoot(), fileName));
    }

    function addr(string memory fileName, string memory key) internal view returns (address) {
        return vm.parseJsonAddress(readJson(fileName), key);
    }

    function num(string memory fileName, string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(readJson(fileName), key);
    }

    function str(string memory fileName, string memory key) internal view returns (string memory) {
        return vm.parseJsonString(readJson(fileName), key);
    }

    function addrArray(string memory fileName, string memory key) internal view returns (address[] memory) {
        return vm.parseJsonAddressArray(readJson(fileName), key);
    }

    /// @dev Callers must keep this out of any `internal` function a `Verify.s.sol` invokes — a fork
    /// run that writes a throwaway address into the committed config is a silent corruption.
    function writeDeployedAddress(string memory key, address value) internal {
        vm.writeJson(vm.toString(value), string.concat(configRoot(), "deploymentAddresses.json"), key);
    }
}
