// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice Stops new ESPN minting ahead of the Track A redemption. Never broadcasts; emits a Safe
/// batch for the ESPN owner multisig to execute: ESPN.setDepositCap(0).
contract CloseDeposits is Script {
    function run() external virtual {
        (address espnAddr, address mainSafe) = _preconditions();

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({to: espnAddr, data: abi.encodeCall(EthStrategyPerpetualNote.setDepositCap, (0))});

        SafeBatchLib.write(
            mainSafe,
            "003-espn-redemption",
            3,
            "Close ESPN deposits",
            "ESPN.setDepositCap(0) -- stops new minting ahead of the Track A redemption.",
            txs
        );
    }

    /// @dev Pre-asserts and returns the values run() needs. Never calls setDepositCap itself --
    /// this contract never broadcasts.
    function _preconditions() internal view returns (address espnAddr, address mainSafe) {
        espnAddr = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
        mainSafe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.main");

        require(EthStrategyPerpetualNote(espnAddr).owner() == mainSafe, "CloseDeposits: ESPN.owner() != main Safe");
    }
}
