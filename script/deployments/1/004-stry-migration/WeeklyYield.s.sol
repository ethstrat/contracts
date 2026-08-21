// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {StakedStrat} from "src/StakedStrat.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";

/// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
/// schedule. Amount per run comes from env WEEKLY_YIELD_AMOUNT (plain decimal wei), not
/// settings.json, because it changes every run.
contract WeeklyYield is Script {
    function run() external virtual {
        address stakedStratAddr = ConfigLib.addr("deploymentAddresses.json", ".staked-stry");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        uint256 amount = vm.envUint("WEEKLY_YIELD_AMOUNT");

        vm.startBroadcast();
        weeklyYield(stakedStratAddr, usds, amount);
        vm.stopBroadcast();
    }

    /// @dev require(totalStaked() > 0) is a hard revert, first thing -- the whole reason this
    /// script exists rather than two `cast` calls. _currentRewardsPerShare() returns early when
    /// totalStaked == 0 (src/StakedStrat.sol:137), but syncRewards() has already folded the
    /// deposit into totalNotifiedRewards and started the clock. Every second elapsed with zero
    /// stakers accrues to nobody, and those tokens can never be re-notified -- a later
    /// syncRewards() sees totalDeposited <= totalNotifiedRewards and early-returns. Depositing
    /// before anyone stakes permanently destroys the deposit.
    function weeklyYield(address stakedStratAddr, address usds, uint256 amount) internal {
        StakedStrat stakedStrat = StakedStrat(stakedStratAddr);
        require(
            stakedStrat.totalStaked() > 0,
            "WeeklyYield: totalStaked() == 0 -- depositing now permanently destroys the deposit, see src/StakedStrat.sol syncRewards()"
        );

        uint256 periodFinishBefore = stakedStrat.periodFinish();
        uint256 notifiedBefore = stakedStrat.totalNotifiedRewards();

        IERC20(usds).transfer(stakedStratAddr, amount);
        stakedStrat.syncRewards();

        require(stakedStrat.periodFinish() > periodFinishBefore, "WeeklyYield: periodFinish did not move");
        require(
            stakedStrat.totalNotifiedRewards() == notifiedBefore + amount,
            "WeeklyYield: totalNotifiedRewards did not increase by amount"
        );

        console2.log("rewardRate:", stakedStrat.rewardRate());
        console2.log("periodFinish:", stakedStrat.periodFinish());
    }
}
