// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UltraPresaleToken} from "src/UltraPresaleToken.sol";
import {UltraPresale} from "src/UltraPresale.sol";
import {IERC20MintableBurnable} from "src/interfaces/IERC20.sol";
import {ITripwireController} from "src/interfaces/ITripwireController.sol";

/// @notice Deploys the ULTRA presale receipt token (pULTRA) and the UltraPresale collector on Robinhood Chain.
/// OWNER (the multisig) is receipt owner, both tripwire guardians, and the recipient of every contribution.
/// The collector cannot mint until OWNER calls `receipt.manageMinter(presale, true)` (Safe tx, before START).
///
/// Env: OWNER (required, the multisig, must already have code on this chain); ROBINHOOD_CHAIN_ID (required, must
/// equal block.chainid); TRIPWIRE_CONTROLLER (required, the one deployed with ULTRA in 006); WETH (required);
/// PRESALE_START, PRESALE_END (unix seconds); PRESALE_CAP (wei). Logs only; writes no config.
///
/// forge script script/deployments/robinhood/008-ultra-presale/Deploy.s.sol \
///   --rpc-url $ROBINHOOD_RPC --account <keystore> --broadcast --verify \
///   --verifier-url $ROBINHOOD_VERIFIER_URL --chain $ROBINHOOD_CHAIN_ID
contract Deploy is Script {
    struct Params {
        address owner;
        address controller;
        address weth;
        uint256 start;
        uint256 end;
        uint256 cap;
    }

    function run() external {
        deploy(
            Params({
                owner: vm.envAddress("OWNER"),
                controller: vm.envAddress("TRIPWIRE_CONTROLLER"),
                weth: vm.envAddress("WETH"),
                start: vm.envUint("PRESALE_START"),
                end: vm.envUint("PRESALE_END"),
                cap: vm.envUint("PRESALE_CAP")
            }),
            vm.envUint("ROBINHOOD_CHAIN_ID")
        );
    }

    function deploy(Params memory p, uint256 expectedChainId) public returns (UltraPresaleToken, UltraPresale) {
        require(block.chainid == expectedChainId, "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        require(p.owner.code.length > 0, "OWNER has no code: deploy/confirm the multisig on this chain first");
        require(p.controller.code.length > 0, "TRIPWIRE_CONTROLLER has no code");
        require(p.weth.code.length > 0, "WETH has no code");

        console2.log("CONFIRM OWNER IS THE MULTISIG (receipt owner, guardian, and recipient of all funds):");
        console2.log(p.owner);

        vm.startBroadcast();
        UltraPresaleToken receipt = new UltraPresaleToken(p.owner, ITripwireController(p.controller), p.owner);
        UltraPresale presale = new UltraPresale(
            IERC20MintableBurnable(address(receipt)),
            IERC20(p.weth),
            p.owner,
            p.start,
            p.end,
            p.cap,
            ITripwireController(p.controller),
            p.owner
        );
        vm.stopBroadcast();

        require(receipt.owner() == p.owner, "owner mismatch");
        require(receipt.totalSupply() == 0, "unexpected supply");
        require(ITripwireController(p.controller).guardian(address(receipt)) == p.owner, "receipt guardian mismatch");
        require(ITripwireController(p.controller).guardian(address(presale)) == p.owner, "presale guardian mismatch");
        require(presale.safe() == p.owner, "safe mismatch");

        console2.log("UltraPresaleToken:");
        console2.log(address(receipt));
        console2.log("UltraPresale:");
        console2.log(address(presale));
        console2.log("NEXT: Safe tx receipt.manageMinter(presale, true) before PRESALE_START");
        return (receipt, presale);
    }
}
