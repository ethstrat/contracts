// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {UltraToken} from "src/UltraToken.sol";
import {TripwireController} from "src/lib/TripwireController.sol";
import {ITripwireController} from "src/interfaces/ITripwireController.sol";

/// @notice Deploys the ULTRA token on Robinhood Chain. Owner and tripwire guardian are both OWNER
/// (the multisig) from block zero; no initial mint, no minters (owner grants them later via manageMinter).
///
/// Env: OWNER (required, the multisig, must already have code on this chain); ROBINHOOD_CHAIN_ID
/// (required, must equal block.chainid); TRIPWIRE_CONTROLLER (optional; if unset a fresh
/// TripwireController is deployed in the same broadcast). Logs only; writes no config.
///
/// forge script script/deployments/robinhood/006-ultra-token/Deploy.s.sol \
///   --rpc-url $ROBINHOOD_RPC --account <keystore> --broadcast --verify \
///   --verifier-url $ROBINHOOD_VERIFIER_URL --chain $ROBINHOOD_CHAIN_ID
contract Deploy is Script {
    function run() external {
        deploy(vm.envAddress("OWNER"), vm.envOr("TRIPWIRE_CONTROLLER", address(0)), vm.envUint("ROBINHOOD_CHAIN_ID"));
    }

    function deploy(address owner, address controller, uint256 expectedChainId) public {
        require(block.chainid == expectedChainId, "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        require(owner != address(0), "OWNER unset or zero");
        require(owner.code.length > 0, "OWNER has no code: deploy/confirm the multisig on this chain first");
        if (controller != address(0)) require(controller.code.length > 0, "TRIPWIRE_CONTROLLER has no code");

        console2.log("CONFIRM OWNER IS THE MULTISIG (owner + tripwire guardian, irreversible w/o 2-step transfer):");
        console2.log(owner);

        vm.startBroadcast();
        if (controller == address(0)) controller = address(new TripwireController());
        UltraToken token = new UltraToken(owner, ITripwireController(controller), owner);
        vm.stopBroadcast();

        require(token.owner() == owner, "owner mismatch");
        require(token.totalSupply() == 0, "unexpected supply");
        require(ITripwireController(controller).guardian(address(token)) == owner, "guardian mismatch");

        console2.log("TripwireController:");
        console2.log(controller);
        console2.log("UltraToken:");
        console2.log(address(token));
    }
}
