// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {MintableBurnableToken} from "src/MintableBurnableToken.sol";
import {UltraPresale} from "src/UltraPresale.sol";
import {SafeBatchLib} from "../../1/lib/SafeBatchLib.sol";
import {RobinhoodBatchWriter} from "../lib/RobinhoodBatchWriter.sol";
import {PRESALE_008_DIR} from "./PresaleOrderBase.sol";

/// @notice Builds the Safe batch that grants the ULTRA presale collector minter rights on pULTRA -- the step
/// Deploy.s.sol only describes in a comment ("NEXT: Safe tx receipt.manageMinter(presale, true) before
/// PRESALE_START"). Never broadcasts; the owner is the Safe. Simulates the batch as the Safe on the fork before
/// writing it. Run this before Close.s.sol / Finish.s.sol in the same multisig directory.
///
/// Env: OWNER (the Safe), ROBINHOOD_CHAIN_ID, RECEIPT (UltraPresaleToken), PRESALE (UltraPresale).
///
/// forge script script/deployments/robinhood/008-ultra-presale/GrantMinter.s.sol:GrantMinter \
///   --fork-url $ROBINHOOD_RPC
///
/// Output: script/deployments/robinhood/multisig/008-ultra-presale/000-grant-minter-<safe>-multisig.json.
contract GrantMinter is RobinhoodBatchWriter {
    struct Params {
        address safe;
        MintableBurnableToken receipt;
        UltraPresale presale;
    }

    function _dir() internal pure override returns (string memory) {
        return PRESALE_008_DIR;
    }

    function run() external {
        require(block.chainid == vm.envUint("ROBINHOOD_CHAIN_ID"), "wrong chain: block.chainid != ROBINHOOD_CHAIN_ID");
        Params memory p = Params({
            safe: vm.envAddress("OWNER"),
            receipt: MintableBurnableToken(vm.envAddress("RECEIPT")),
            presale: UltraPresale(vm.envAddress("PRESALE"))
        });

        SafeBatchLib.Tx[] memory txs = build(p);
        simulate(p, txs);

        _writeBatch(
            _file("000-grant-minter", p.safe),
            p.safe,
            "ULTRA presale: grant collector minter rights",
            "Grants the UltraPresale collector minter rights on pULTRA. Must run before PRESALE_START.",
            txs
        );
    }

    /// @dev All preflight requires live here. Public so tests can build the batch without env.
    function build(Params memory p) public view returns (SafeBatchLib.Tx[] memory txs) {
        require(p.safe.code.length > 0, "GrantMinter: OWNER has no code");
        require(p.receipt.owner() == p.safe, "GrantMinter: Safe does not own receipt");
        require(p.presale.safe() == p.safe, "GrantMinter: presale.safe != OWNER");
        require(address(p.presale.receipt()) == address(p.receipt), "GrantMinter: presale/receipt mismatch");
        require(block.timestamp < p.presale.start(), "GrantMinter: presale already started");
        require(!p.receipt.minters(address(p.presale)), "GrantMinter: collector already a minter");

        txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({
            to: address(p.receipt), data: abi.encodeCall(MintableBurnableToken.manageMinter, (address(p.presale), true))
        });
    }

    /// @dev Executes `txs` as the Safe on the current fork and requires the end state.
    function simulate(Params memory p, SafeBatchLib.Tx[] memory txs) public {
        SafeBatchLib.execute(p.safe, txs);
        require(p.receipt.minters(address(p.presale)), "GrantMinter sim: minter not granted");
    }
}
