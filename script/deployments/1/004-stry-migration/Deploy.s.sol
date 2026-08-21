// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakedStrat} from "src/StakedStrat.sol";
import {ITripwireController} from "src/interfaces/ITripwireController.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";

/// @notice Deploys a new StakedStrat instance staking STRY, paying out USDS rewards.
/// src/StakedStrat.sol gets ZERO code changes -- its constructor is already generic.
contract Deploy is Script {
    function run() external virtual {
        address stratToken = ConfigLib.addr("deploymentAddresses.json", ".stry");
        address controller = ConfigLib.addr("internalAddresses.json", ".protocol.tripwire.controller");
        address guardian = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.tripwire-guardian");

        // Assumption 4: no deployed TripwireController is recorded anywhere in this repo.
        // TripwireGuard's constructor reverts a bare InvalidController() on a zero-or-codeless
        // controller, which is opaque -- fail with something the operator can act on instead.
        // This guards the mainnet broadcast only; it does not gate fork verification, which
        // deploys its own TripwireController (see Verify.s.sol).
        require(
            controller.code.length > 0,
            string.concat(
                "Assumption 4 unresolved: no TripwireController deployed at ",
                vm.toString(controller),
                ". Track B cannot be BROADCAST until one exists. Deploying a controller is unscoped work. (yarn verify:migration is unaffected -- it deploys its own controller on the fork.)"
            )
        );

        vm.startBroadcast();
        StakedStrat stakedStrat = deploy(stratToken, controller, guardian);
        vm.stopBroadcast();

        ConfigLib.writeDeployedAddress(".staked-stry", address(stakedStrat));

        console2.log("New StakedStrat (STRY/USDS) deployed:");
        console2.log(address(stakedStrat));
        console2.log("Facts of the unmodified contract (accepted, zero-code-change constraint):");
        console2.log("- name/symbol are hardcoded 'Staked STRAT v2' / 'sSTRAT-v2' despite staking STRY (cosmetic).");
        console2.log("- REWARD_DURATION = 7 days; syncRewards() is permissionless.");
        console2.log("- The staked position token is non-transferable: transfer/transferFrom/approve all revert.");
        console2.log("  Holders approve STRY for the staking contract, never the position token.");
        console2.log("- unstake() is whenNotTripped: a trip locks stakers' STRY in until untripped.");
    }

    /// @dev `stratToken` and `controller` are explicit arguments -- not read from committed config
    /// inside this function -- so Verify.s.sol can pass the fork-fresh, uncommitted STRY mint and a
    /// fork-local TripwireController without ever writing to deploymentAddresses.json. The
    /// mainnet-broadcast pre-condition on Assumption 4 lives in run() above, not here.
    function deploy(address stratToken, address controller, address guardian)
        internal
        returns (StakedStrat stakedStrat)
    {
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        stakedStrat = new StakedStrat(stratToken, usds, ITripwireController(controller), guardian);
    }
}
