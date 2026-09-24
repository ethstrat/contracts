// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StakedStrat} from "src/StakedStrat.sol";
import {ITripwireController} from "src/interfaces/ITripwireController.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";

/// @notice Deploys a new StakedStrat instance staking STRY, paying out USDS rewards.
/// src/StakedStrat.sol gets one code change vs. the prior deployment: its constructor now names
/// the position token "Staked EARN" / "sEARN" (renamed alongside STRY -> EARN). Every other line
/// -- stake/unstake/claim/migrateStake/syncRewards, all accounting -- is unchanged.
contract Deploy is Script {
    function run() external virtual {
        address stratToken = ConfigLib.addr("deploymentAddresses.json", ".stry");
        address controller = ConfigLib.addr("internalAddresses.json", ".protocol.tripwire.controller");
        address guardian = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.tripwire-guardian");

        // TripwireGuard's constructor reverts a bare InvalidController() on a zero-or-codeless
        // controller, which is opaque -- fail with something the operator can act on instead.
        // Fork verification (Verify.s.sol) uses the same live controller.
        require(
            controller.code.length > 0,
            string.concat(
                "Assumption 4 unresolved: no TripwireController deployed at ",
                vm.toString(controller),
                ". Track B cannot be BROADCAST until one exists. Deploying a controller is unscoped work."
            )
        );
        require(
            stratToken.code.length > 0,
            "Deploy: .stry has no code -- run Distribute.s.sol first to deploy STRY before this new StakedStrat instance."
        );

        vm.startBroadcast();
        StakedStrat stakedStrat = deploy(stratToken, controller, guardian);
        vm.stopBroadcast();

        ConfigLib.writeDeployedAddress(".staked-earn", address(stakedStrat));

        console2.log("New StakedStrat (STRY/USDS) deployed:");
        console2.log(address(stakedStrat));
        console2.log("Facts of the contract:");
        console2.log("- REWARD_DURATION = 28 days; syncRewards() is permissionless.");
        console2.log("- The staked position token is non-transferable: transfer/transferFrom/approve all revert.");
        console2.log("  Holders approve STRY for the staking contract, never the position token.");
        console2.log("- Constructor reverts on a zero _stratToken/_rewardToken or on the two being equal.");
        console2.log("- Tripwire registration is self-service and permissionless: TripwireGuard's constructor");
        console2.log("  calls controller_.register(address(this), guardian_) itself; no controller-owner tx needed.");
        console2.log("- unstake() is whenNotTripped: a trip locks stakers' STRY in until untripped.");
        console2.log(
            "- _CONTROLLER is immutable and the guardian is fixed at construction; a wrong value means redeploying."
        );
    }

    /// @dev `stratToken` and `controller` are explicit arguments -- not read from committed config
    /// inside this function -- so Verify.s.sol can pass the fork-fresh, uncommitted STRY mint
    /// without ever writing to deploymentAddresses.json. The
    /// mainnet-broadcast pre-condition on Assumption 4 lives in run() above, not here.
    function deploy(address stratToken, address controller, address guardian)
        internal
        returns (StakedStrat stakedStrat)
    {
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        stakedStrat = new StakedStrat(stratToken, usds, ITripwireController(controller), guardian);
    }
}
