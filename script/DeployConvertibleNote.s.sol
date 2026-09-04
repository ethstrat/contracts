// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {EthStrategyConvertibleNote} from "../src/EthStrategyConvertibleNote.sol";
import {ITripwireController} from "../src/interfaces/ITripwireController.sol";

/// @notice One-shot mainnet deployment of EthStrategyConvertibleNote.
/// @dev Minter grants for CDT/STRAT/esETH must be proposed separately via the Gnosis Safe
///      (0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8) — this script only deploys the contract.
contract DeployConvertibleNote is Script {
    address constant CDT_TOKEN = 0xD4598307B5507A2b04d0502FCC9b68bbcA9275F3;
    address constant STRAT_TOKEN = 0x14cF922aa1512Adfc34409b63e18D391e4a86A2f;
    address constant ESETH_TOKEN = 0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb;
    address constant UNENCUMBERED_HOLDINGS = 0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1;
    address constant ENCUMBERED_HOLDINGS = 0x1b005A566983721bc736b57D7D3B1EE028782362;
    address constant ETH_USD_ORACLE = 0x10674C8C1aE2072d4a75FE83f1E159425fd84E1D;
    address constant OWNER = 0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8;
    address constant CONTROLLER = 0x328aED8F7a01f45A959c187F3cb97eC508064854;
    address constant GUARDIAN = 0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8;

    function run() external returns (EthStrategyConvertibleNote note) {
        vm.startBroadcast();
        note = new EthStrategyConvertibleNote(
            CDT_TOKEN,
            STRAT_TOKEN,
            ESETH_TOKEN,
            UNENCUMBERED_HOLDINGS,
            ENCUMBERED_HOLDINGS,
            ETH_USD_ORACLE,
            OWNER,
            ITripwireController(CONTROLLER),
            GUARDIAN
        );
        vm.stopBroadcast();

        console2.log("EthStrategyConvertibleNote deployed at:", address(note));
    }
}
