// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {StratOption} from "../src/StratOption.sol";
import {StratPresale} from "../src/StratPresale.sol";
import {PresaleTokenRenderer} from "../src/lib/PresaleTokenRenderer.sol";

contract DeployCore is Script {
    address public constant DEFAULT_DEPLOYER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function _validateDeployer() internal view {
        // Validate that the caller is not the default deployer
        if (msg.sender == DEFAULT_DEPLOYER) {
            revert("Cannot use the default foundry deployer address, specify using --sender");
        }
        console2.log("Deployer:", msg.sender);
    }

    function run() public {
        address owner = vm.envAddress("OWNER");
        address presaleMultisig = vm.envAddress("PRESALE_MULTISIG");

        vm.startBroadcast();
        _validateDeployer();

        address deployer = msg.sender;

        // StratOption
        console2.log("\n");
        console2.log("Deploying StratOption...");
        console2.log("  Initial owner:", deployer);

        StratOption stratOption = new StratOption(deployer);

        console2.log("> StratOption deployed at", address(stratOption));

        // StratPresale
        console2.log("\n");
        console2.log("Deploying StratPresale...");
        console2.log("  StratOption:", address(stratOption));
        console2.log("  Presale Multisig:", presaleMultisig);

        StratPresale stratPresale = new StratPresale(address(stratOption), presaleMultisig);

        console2.log("> StratPresale deployed at", address(stratPresale));

        // Add StratPresale as minter
        console2.log("\n");
        console2.log("Adding StratPresale as minter to StratOption...");
        stratOption.manageMinter(address(stratPresale), true);
        console2.log("> StratPresale added as minter to StratOption");

        // Deploy and manage the renderer
        _deployPresaleRenderer(stratOption);

        // Transfer ownership of StratOption to final owner
        console2.log("\n");
        console2.log("Transferring StratOption ownership to final owner...");
        console2.log("  Current owner:", deployer);
        console2.log("  New owner:", owner);
        if (owner != deployer) {
            stratOption.transferOwnership(owner);
            console2.log("> Transfer complete");
        } else {
            console2.log("> Skipping transfer, owner is the deployer");
        }
        vm.stopBroadcast();
    }

    function _deployPresaleRenderer(StratOption stratOption) internal {
        // Deploy the renderer
        console2.log("\n");
        console2.log("Deploying PresaleTokenRenderer...");

        PresaleTokenRenderer presaleTokenRenderer = new PresaleTokenRenderer();

        console2.log("> PresaleTokenRenderer deployed at", address(presaleTokenRenderer));

        // Set the renderer
        console2.log("\n");
        console2.log("Setting PresaleTokenRenderer as renderer for StratOption...");
        stratOption.managerRenderer(address(presaleTokenRenderer));
        console2.log("> PresaleTokenRenderer set as renderer for StratOption");
    }

    /// @dev Should be run as the owner of the StratOption contract
    function deployPresaleRenderer() public {
        vm.startBroadcast();
        _validateDeployer();

        address stratOption = vm.envAddress("STRAT_OPTION");

        // Deploy and manage the renderer
        _deployPresaleRenderer(StratOption(stratOption));

        vm.stopBroadcast();
    }
}
