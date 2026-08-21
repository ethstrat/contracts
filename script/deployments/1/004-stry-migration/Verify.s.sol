// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
import {StryToken} from "src/StryToken.sol";
import {StakedStrat} from "src/StakedStrat.sol";
import {TripwireController} from "src/lib/TripwireController.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {HoldersLib} from "../lib/HoldersLib.sol";
import {StopEspnYield} from "./StopEspnYield.s.sol";
import {Distribute} from "./Distribute.s.sol";
import {Deploy} from "./Deploy.s.sol";
import {WeeklyYield} from "./WeeklyYield.s.sol";

/// @notice Track B mainnet-fork Verify script. Same harness as Track A: vm.startPrank, not
/// vm.startBroadcast, so no config or Safe batch file is written. Calls the other scripts'
/// internal entry points, never their run()s.
contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, Deploy, WeeklyYield {
    uint256 internal constant ZERO_STAKER_DEPOSIT = 1_000e18;
    uint256 internal constant WEEKLY_DEPOSIT = 1_000e18;
    uint256 internal constant CLAIM_TOLERANCE = 1e6;

    function run() external override(StopEspnYield, Distribute, Deploy, WeeklyYield) {
        // Same derivation as 003-espn-redemption/Verify.s.sol: the holders file is named after the
        // snapshot block, so SNAPSHOT_BLOCK alone pins both the fork and the snapshot.
        uint256 snapshotBlockTarget = vm.envUint("SNAPSHOT_BLOCK");
        string memory holdersFile =
            string.concat("script/deployments/1/config/espn-holders-", vm.toString(snapshotBlockTarget), ".json");
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);

        // Item 0: fork block check.
        require(block.number >= snapshot.snapshotBlock, "Verify: fork block is behind snapshotBlock");
        if (block.number != snapshot.snapshotBlock) {
            console2.log("WARNING: fork block != snapshotBlock; export SNAPSHOT_BLOCK to fix:");
            console2.log(snapshot.snapshotBlock);
        }

        (address holder,) = _pickLargestHolder(snapshot);
        require(holder != address(0), "Verify: no non-contract, non-excluded holder in snapshot");

        // Item 1: StopEspnYield -- the third-party outflow must be visible in test output, not
        // merely pass.
        (address usds, address espnAddr, address payer, uint256 finalYieldAmount) = _preconditions();
        EthStrategyPerpetualNote espn = EthStrategyPerpetualNote(espnAddr);
        uint256 totalAssetsBefore = espn.totalAssets();
        uint256 managerBalanceBefore = IERC20(usds).balanceOf(espn.manager());
        if (IERC20(usds).balanceOf(payer) < finalYieldAmount) {
            deal(usds, payer, finalYieldAmount);
        }
        vm.startPrank(payer);
        IERC20(usds).approve(espnAddr, finalYieldAmount);
        vm.expectEmit(true, false, false, true, espnAddr);
        emit EthStrategyPerpetualNote.AssetsPerShareIncreased(
            payer, totalAssetsBefore + finalYieldAmount, finalYieldAmount
        );
        espn.increaseAssetsPerShare(finalYieldAmount);
        vm.stopPrank();
        assertEq(
            espn.totalAssets(), totalAssetsBefore + finalYieldAmount, "Verify: totalAssets delta != finalYieldAmount"
        );
        assertEq(
            IERC20(usds).balanceOf(espn.manager()),
            managerBalanceBefore + finalYieldAmount,
            "Verify: USDS did not land at ESPN.manager()"
        );

        // Item 2: Distribute STRY (single mintBatch).
        address stryDeployer = makeAddr("stryDeployer");
        vm.startPrank(stryDeployer);
        StryToken stry = distribute(stryDeployer, holdersFile);
        vm.stopPrank();
        assertEq(stry.owner(), address(0), "Verify: STRY ownership not renounced");

        // Item 3: deploy a TripwireController locally and pass it to Deploy's internal deploy().
        // TripwireGuard's constructor calls controller.register() itself, permissionlessly -- no
        // controller-owner transaction is needed.
        address guardian = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.tripwire-guardian");
        TripwireController controller = new TripwireController();
        StakedStrat stakedStrat = deploy(address(stry), address(controller), guardian);

        uint256 holderStryBalance = stry.balanceOf(holder);

        // Item 4: zero-staker permanent-loss case, before the happy path. Snapshot state first so
        // this can be reverted afterwards.
        uint256 preLossSnapshot = vm.snapshotState();
        {
            address zeroStakerDepositor = makeAddr("zeroStakerDepositor");
            deal(usds, zeroStakerDepositor, ZERO_STAKER_DEPOSIT);
            vm.startPrank(zeroStakerDepositor);
            IERC20(usds).transfer(address(stakedStrat), ZERO_STAKER_DEPOSIT);
            stakedStrat.syncRewards();
            vm.stopPrank();

            vm.warp(block.timestamp + 1 days);

            vm.startPrank(holder);
            stry.approve(address(stakedStrat), holderStryBalance);
            stakedStrat.stake(holderStryBalance);
            vm.stopPrank();

            vm.warp(stakedStrat.periodFinish());

            uint256 usdsBefore = IERC20(usds).balanceOf(holder);
            vm.prank(holder);
            stakedStrat.claim();
            uint256 claimed = IERC20(usds).balanceOf(holder) - usdsBefore;
            assertLt(
                claimed, ZERO_STAKER_DEPOSIT, "Verify: zero-staker-case claim should be strictly less than the deposit"
            );

            uint256 notifiedBefore = stakedStrat.totalNotifiedRewards();
            stakedStrat.syncRewards();
            assertEq(
                stakedStrat.totalNotifiedRewards(),
                notifiedBefore,
                "Verify: second syncRewards() after a fully-streamed period should be a no-op"
            );

            console2.log("Zero-staker loss case -- deposited:", ZERO_STAKER_DEPOSIT);
            console2.log("Zero-staker loss case -- claimed (permanently lost the rest):", claimed);
        }
        vm.revertToState(preLossSnapshot);

        // Item 5: happy path -- stake. Approve STRY, never the position token (position-token
        // approve reverts TransferDisabled()).
        vm.startPrank(holder);
        stry.approve(address(stakedStrat), holderStryBalance);
        uint256 stakeGasBefore = gasleft();
        stakedStrat.stake(holderStryBalance);
        uint256 stakeGas = stakeGasBefore - gasleft();
        vm.stopPrank();

        // Item 6: WeeklyYield, including its totalStaked > 0 guard.
        address weeklyOperator = makeAddr("weeklyYieldOperator");
        deal(usds, weeklyOperator, WEEKLY_DEPOSIT);
        uint256 notifiedBeforeWeekly = stakedStrat.totalNotifiedRewards();
        vm.startPrank(weeklyOperator);
        uint256 syncGasBefore = gasleft();
        weeklyYield(address(stakedStrat), usds, WEEKLY_DEPOSIT);
        uint256 syncGas = syncGasBefore - gasleft();
        vm.stopPrank();
        assertEq(
            stakedStrat.periodFinish(),
            block.timestamp + 7 days,
            "Verify: periodFinish does not describe a 7-day stream"
        );
        assertEq(
            stakedStrat.rewardRate(),
            WEEKLY_DEPOSIT / 7 days,
            "Verify: rewardRate does not describe a 7-day stream of the deposit"
        );
        assertEq(
            stakedStrat.totalNotifiedRewards(),
            notifiedBeforeWeekly + WEEKLY_DEPOSIT,
            "Verify: totalNotifiedRewards did not increase by the deposit"
        );

        // Item 7: warp 7 days -> claim. Sole staker => the full week's deposit, minus stream
        // rounding dust.
        vm.warp(block.timestamp + 7 days);
        uint256 usdsBeforeClaim = IERC20(usds).balanceOf(holder);
        vm.prank(holder);
        uint256 claimGasBefore = gasleft();
        stakedStrat.claim();
        uint256 claimGas = claimGasBefore - gasleft();
        uint256 claimedFull = IERC20(usds).balanceOf(holder) - usdsBeforeClaim;
        assertApproxEqAbs(
            claimedFull, WEEKLY_DEPOSIT, CLAIM_TOLERANCE, "Verify: claimed reward far from the full week's deposit"
        );

        // Item 8: unstake the full staked balance -> STRY returned and the auto-claim runs. Item 7
        // just claimed everything as of periodFinish, so unstaking immediately after would
        // auto-claim zero and never exercise unstake's `if (claimable > 0)` branch
        // (src/StakedStrat.sol:228). Notify a second reward and warp partway through its stream
        // first so real rewards are pending at unstake time.
        uint256 secondYieldAmount = WEEKLY_DEPOSIT / 2;
        deal(usds, weeklyOperator, secondYieldAmount);
        vm.startPrank(weeklyOperator);
        weeklyYield(address(stakedStrat), usds, secondYieldAmount);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);

        uint256 stakedBalance = stakedStrat.staked(holder);
        uint256 stryBefore = stry.balanceOf(holder);
        uint256 usdsBeforeUnstake = IERC20(usds).balanceOf(holder);
        vm.prank(holder);
        uint256 unstakeGasBefore = gasleft();
        stakedStrat.unstake(stakedBalance);
        uint256 unstakeGas = unstakeGasBefore - gasleft();
        assertEq(stry.balanceOf(holder), stryBefore + stakedBalance, "Verify: STRY not returned on unstake");
        uint256 unstakeAutoClaimed = IERC20(usds).balanceOf(holder) - usdsBeforeUnstake;
        assertGt(unstakeAutoClaimed, 0, "Verify: unstake auto-claim paid zero -- claimable > 0 branch not exercised");
        console2.log("unstake auto-claim paid:", unstakeAutoClaimed);

        // Item 9: gas (informational).
        console2.log("stake execution gas:", stakeGas);
        console2.log("weeklyYield execution gas:", syncGas);
        console2.log("claim execution gas:", claimGas);
        console2.log("unstake execution gas:", unstakeGas);
    }

    /// @dev Picks the largest non-contract, non-excluded holder from the committed snapshot at
    /// runtime, rather than hardcoding an address that may have moved.
    function _pickLargestHolder(HoldersLib.Snapshot memory snapshot)
        internal
        pure
        returns (address holder, uint256 balance)
    {
        for (uint256 i; i < snapshot.holders.length; ++i) {
            HoldersLib.Holder memory h = snapshot.holders[i];
            if (h.excluded || h.isContract) continue;
            uint256 bal = vm.parseUint(h.balance);
            if (bal > balance) {
                balance = bal;
                holder = h.addr;
            }
        }
    }
}
