// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {StratPresale} from "../src/StratPresale.sol";

contract PresaleMint is Script {
    function run() public {
        vm.startBroadcast();

        uint256 ethAmount = 0.001 ether;
        address sender = msg.sender;

        console2.log("\n");
        console2.log("Sending", ethAmount, "ETH from", sender);
        StratPresale stratPresale = StratPresale(vm.envAddress("STRAT_PRESALE"));
        stratPresale.mint{value: ethAmount}();
        console2.log("> Completed");

        vm.stopBroadcast();
    }
}
