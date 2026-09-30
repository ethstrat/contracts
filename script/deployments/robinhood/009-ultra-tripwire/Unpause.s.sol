// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ITripwireController} from "src/interfaces/ITripwireController.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";
import {RobinhoodBatchWriter} from "../lib/RobinhoodBatchWriter.sol";

/// @notice Incident-response batch: globally resets the tripwire on all three ULTRA suite contracts sharing one
/// TripwireController -- UltraToken (006), the pULTRA receipt token (008), and the UltraPresale collector (008).
/// Never broadcasts; simulates the batch as the Safe on the fork before writing it.
///
/// Env: OWNER (the Safe), ROBINHOOD_CHAIN_ID, TRIPWIRE_CONTROLLER, ULTRA_TOKEN, RECEIPT, PRESALE.
///
/// forge script script/deployments/robinhood/009-ultra-tripwire/Unpause.s.sol:Unpause --fork-url $ROBINHOOD_RPC
///
/// Output: script/deployments/robinhood/multisig/009-ultra-tripwire/unpause-<safe>-multisig.json.
contract Unpause is RobinhoodBatchWriter {
    function _dir() internal pure override returns (string memory) {
        return "script/deployments/robinhood/multisig/009-ultra-tripwire/";
    }

    function run() external {
        require(block.chainid == vm.envUint("ROBINHOOD_CHAIN_ID"), "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        address safe = vm.envAddress("OWNER");
        ITripwireController ctrl = ITripwireController(vm.envAddress("TRIPWIRE_CONTROLLER"));
        address[3] memory targets = [vm.envAddress("ULTRA_TOKEN"), vm.envAddress("RECEIPT"), vm.envAddress("PRESALE")];

        SafeBatchLib.Tx[] memory txs = build(safe, ctrl, targets);
        simulate(safe, ctrl, targets, txs);

        _writeBatch(
            _file("unpause", safe),
            safe,
            "ULTRA suite: global tripwire unpause",
            "Globally resets the tripwire on UltraToken, pULTRA and the UltraPresale collector.",
            txs
        );
    }

    /// @dev All preflight requires live here. Public so tests can build the batch without env.
    function build(address safe, ITripwireController ctrl, address[3] memory targets)
        public
        view
        returns (SafeBatchLib.Tx[] memory txs)
    {
        require(safe.code.length > 0, "Unpause: OWNER has no code");
        require(address(ctrl).code.length > 0, "Unpause: TRIPWIRE_CONTROLLER has no code");
        require(
            targets[0] != targets[1] && targets[0] != targets[2] && targets[1] != targets[2],
            "Unpause: duplicate target"
        );
        txs = new SafeBatchLib.Tx[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            require(ctrl.guardian(targets[i]) == safe, "Unpause: guardian mismatch");
            txs[i] = SafeBatchLib.Tx({
                to: address(ctrl), data: abi.encodeCall(ITripwireController.resetGlobal, (targets[i]))
            });
        }
    }

    /// @dev Executes `txs` as the Safe on the current fork and requires the end state.
    function simulate(address safe, ITripwireController ctrl, address[3] memory targets, SafeBatchLib.Tx[] memory txs)
        public
    {
        SafeBatchLib.execute(safe, txs);
        for (uint256 i = 0; i < targets.length; i++) {
            require(!ctrl.isGloballyTripped(targets[i]), "Unpause sim: still tripped");
        }
    }
}
