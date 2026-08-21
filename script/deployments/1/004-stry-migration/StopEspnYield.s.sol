// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice One-time, and first in the global operational sequence -- it changes NAV, and every
/// later formula must read the final NAV. Never broadcasts; emits a Safe batch for the redemption
/// multisig to execute: USDS.approve(ESPN, finalYieldAmount) then ESPN.increaseAssetsPerShare.
///
/// This "stop" is a policy, not an on-chain state change: increaseAssetsPerShare is external with
/// no access control, so anyone can keep raising NAV afterwards, including while the redemption
/// order is live (Assumption 3). The order's amounts are fixed at validate time and do not follow
/// NAV.
contract StopEspnYield is Script {
    /// @dev ESPN.manager() -- a contract, not the redemption multisig. finalYieldAmount USDS
    /// leaves the treasury and lands here: a real outflow to a third party, not a round trip, and
    /// it must be an intentional, budgeted decision (Assumption 3). manager() is owner-settable,
    /// so this is asserted as a hard equality, not merely != address(0).
    address internal constant EXPECTED_MANAGER = 0x823EfFFA08f946233D2a502a1B073C5E16Fea16b;

    function run() external virtual {
        (address usds, address espnAddr, address payer, uint256 finalYieldAmount) = _preconditions();

        console2.log("This 'stop' is a POLICY, not an on-chain state change: increaseAssetsPerShare is");
        console2.log("external with no access control, so anyone can keep raising NAV afterwards, including");
        console2.log("while the redemption order is live (Assumption 3). The order's amounts are fixed at");
        console2.log("validate time and do not follow NAV.");

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](2);
        txs[0] = SafeBatchLib.Tx({to: usds, data: abi.encodeCall(IERC20.approve, (espnAddr, finalYieldAmount))});
        txs[1] = SafeBatchLib.Tx({
            to: espnAddr, data: abi.encodeCall(EthStrategyPerpetualNote.increaseAssetsPerShare, (finalYieldAmount))
        });

        SafeBatchLib.write(
            payer,
            "004-stry-migration",
            1,
            "Stop ESPN yield",
            "Final USDS top-up to ESPN before the STRY migration. Policy stop only -- increaseAssetsPerShare has no access control and stays callable by anyone afterwards.",
            txs
        );
    }

    /// @dev Pre-asserts and returns the values both run() (Safe-batch building) and Verify.s.sol
    /// (real execution under prank) need. Never calls approve/increaseAssetsPerShare itself --
    /// this contract never broadcasts.
    function _preconditions()
        internal
        view
        returns (address usds, address espnAddr, address payer, uint256 finalYieldAmount)
    {
        usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        espnAddr = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
        payer = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        finalYieldAmount = ConfigLib.num("settings.json", ".espnv3.finalYieldAmount");

        EthStrategyPerpetualNote espn = EthStrategyPerpetualNote(espnAddr);
        require(espn.asset() == usds, "StopEspnYield: ESPN.asset() != USDS");
        require(
            IERC20(usds).balanceOf(payer) >= finalYieldAmount, "StopEspnYield: payer USDS balance < finalYieldAmount"
        );
        require(
            espn.manager() == EXPECTED_MANAGER,
            "StopEspnYield: manager changed from the recorded address -- re-confirm Assumption 3 (who receives finalYieldAmount) before updating this constant."
        );

        console2.log("ESPN.manager() (finalYieldAmount recipient -- a contract, not the redemption multisig):");
        console2.log(espn.manager());
    }
}
