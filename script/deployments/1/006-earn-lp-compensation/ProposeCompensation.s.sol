// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StryToken} from "src/StryToken.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice One-off redemption-Safe batch: mints the EARN a claimant's Uniswap V3 ESPN positions
/// (tokenIds 1357744, 1357745; 105 ESPN combined at the block 26043909 snapshot) missed, because V3
/// pools were not excluded from the snapshot and their EARN went to the pool contracts instead.
/// AMOUNT = floor(105e18 * totalAssets / (totalSupply * 100)) at that snapshot. Never broadcasts.
/// Run with --fork-url mainnet: run() executes the exact batch as the Safe on the latest-block fork
/// and asserts the claimant's EARN balance rose by exactly AMOUNT before it writes the file.
contract ProposeCompensation is Script {
    address internal constant CLAIMANT = 0x4e99F5Af29c39CC100E21477f72ff2984087d19F;
    uint256 internal constant AMOUNT = 117298466316155585413;

    function run() external virtual {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address earn = ConfigLib.addr("deploymentAddresses.json", ".stry");
        require(
            !vm.exists(SafeBatchLib.path(safe, "006-earn-lp-compensation", 1)),
            "ProposeCompensation: batch 001 already exists; delete it deliberately to regenerate"
        );
        require(earn.code.length > 0, "ProposeCompensation: .stry has no code");
        require(StryToken(earn).owner() == safe, "ProposeCompensation: EARN.owner() != redemption Safe");

        SafeBatchLib.Tx[] memory txs = buildBatch(earn);
        _simulateAndCheck(safe, earn, txs);

        SafeBatchLib.write(
            safe,
            "006-earn-lp-compensation",
            1,
            "EARN LP compensation mint",
            "Mints the EARN missed by the claimant's Uniswap V3 ESPN positions (tokenIds 1357744, 1357745; 105 ESPN combined at the block 26043909 snapshot) directly to the claimant, since V3 pools were not excluded from the snapshot and their EARN went to the pool contracts instead.",
            txs
        );
        console2.log("Simulation passed; batch written:", SafeBatchLib.path(safe, "006-earn-lp-compensation", 1));
    }

    function buildBatch(address earn) internal pure returns (SafeBatchLib.Tx[] memory txs) {
        address[] memory to = new address[](1);
        to[0] = CLAIMANT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;

        txs = new SafeBatchLib.Tx[](1);
        txs[0] = SafeBatchLib.Tx({to: earn, data: abi.encodeCall(StryToken.mintBatch, (to, amounts))});
    }

    /// @dev The one check this batch needs: fork-simulate it as the Safe and assert the claimant's
    /// EARN balance rose by exactly AMOUNT, no more, no less.
    function _simulateAndCheck(address safe, address earn, SafeBatchLib.Tx[] memory txs) internal {
        uint256 balBefore = StryToken(earn).balanceOf(CLAIMANT);
        SafeBatchLib.execute(safe, txs);
        require(
            StryToken(earn).balanceOf(CLAIMANT) == balBefore + AMOUNT,
            "ProposeCompensation sim: EARN balance delta != AMOUNT"
        );
    }
}
