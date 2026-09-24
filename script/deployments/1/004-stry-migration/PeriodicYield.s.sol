// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {StakedStrat} from "src/StakedStrat.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
/// schedule. The per-period amount is computed from the recorded airdrop total
/// (deploymentAddresses.json .earn-airdrop-supply, written once by Distribute.run()) and
/// settings.json's basisPriceUsd/annualDividendRatioX100. Later EARN mints by the redemption Safe
/// (e.g. the LP's EARN) do not change the base: it is the recorded airdrop total, not live supply.
///
/// Never broadcasts: the payer is the redemption Safe. Each run emits a Safe Transaction Builder
/// batch -- USDS.transfer(stakedEarn, amount), StakedStrat.syncRewards() -- funding the existing
/// StakedStrat instance's 28-day reward stream. No approve() step: transfer, not transferFrom.
contract PeriodicYield is Script {
    /// @dev Fat-finger guard on settings.json's annualDividendRatioX100 -- nothing upstream of
    /// this function validates that config value. Caps at 30% annual.
    uint256 internal constant MAX_ANNUAL_DIVIDEND_RATIO_X100 = 3000;

    function run() external virtual {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        address stakedEarn = ConfigLib.addr("deploymentAddresses.json", ".staked-earn");

        uint256 airdropSupply = ConfigLib.num("deploymentAddresses.json", ".earn-airdrop-supply");

        SafeBatchLib.Tx[] memory txs = periodicYield(safe, usds, stakedEarn, airdropSupply);

        SafeBatchLib.write(
            safe,
            "004-stry-migration",
            _firstFreeBatchIndex(safe),
            "28-day EARN yield",
            "Transfers USDS to the StakedStrat contract and calls syncRewards() to start a new 28-day reward stream. Execute the transactions in the order listed.",
            txs
        );
    }

    /// @dev Pure guarded math, split out from periodicYieldAmount so it is testable without
    /// touching the committed settings.json file: test/unit/PeriodicYieldTest.sol calls this
    /// directly with crafted ratios to pin the guard's boundary, and calls periodicYieldAmount
    /// separately to confirm it reads the real config correctly.
    function _periodicYieldAmountPure(uint256 supplyBase, uint256 basisPriceUsd, uint256 annualDividendRatioX100)
        internal
        pure
        returns (uint256)
    {
        require(
            annualDividendRatioX100 > 0 && annualDividendRatioX100 <= MAX_ANNUAL_DIVIDEND_RATIO_X100,
            "PeriodicYield: implausible annualDividendRatioX100"
        );
        // Annual target sliced to the exact 28-day period (28/365 of a year), not /12: this
        // script runs every 28 days (matching REWARD_DURATION exactly), not every calendar
        // month. All four multiplications happen before any of the three divisions, so this is
        // exactly equal to a single /3,650,000 division -- no extra truncation loss.
        return supplyBase * basisPriceUsd * annualDividendRatioX100 * 28 / 100 / 100 / 365;
    }

    function periodicYieldAmount(uint256 airdropSupply) internal view returns (uint256) {
        require(airdropSupply > 0, "PeriodicYield: airdropSupply == 0");
        uint256 basisPriceUsd = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");
        uint256 annualDividendRatioX100 = ConfigLib.num("settings.json", ".espnv3.annualDividendRatioX100");
        return _periodicYieldAmountPure(airdropSupply, basisPriceUsd, annualDividendRatioX100);
    }

    /// @dev Pure computation plus live pre-condition reads. Writes no file -- run() alone does --
    /// so `yarn verify:migration`, which calls this directly, leaves `git status` clean.
    ///
    /// require(totalStaked() > 0) is a hard revert, first thing -- the whole reason this script
    /// builds a batch rather than emitting a bare transfer. _currentRewardsPerShare() returns
    /// early when totalStaked == 0 (src/StakedStrat.sol:137), but syncRewards() has already
    /// folded the deposit into totalNotifiedRewards and started the clock. Every second elapsed
    /// with zero stakers accrues to nobody, and those tokens can never be re-notified -- a later
    /// syncRewards() sees totalDeposited <= totalNotifiedRewards and early-returns. Funding
    /// before anyone has staked permanently destroys the deposit.
    function periodicYield(address safe, address usds, address stakedEarnAddr, uint256 airdropSupply)
        internal
        view
        returns (SafeBatchLib.Tx[] memory txs)
    {
        StakedStrat stakedEarn = StakedStrat(stakedEarnAddr);
        uint256 amount = periodicYieldAmount(airdropSupply);
        require(
            stakedEarn.totalStaked() > 0,
            "PeriodicYield: totalStaked() == 0 -- funding now permanently destroys the deposit, see src/StakedStrat.sol syncRewards()"
        );
        require(IERC20(usds).balanceOf(safe) >= amount, "PeriodicYield: Safe USDS balance < computed amount");

        txs = new SafeBatchLib.Tx[](2);
        txs[0] = SafeBatchLib.Tx({to: usds, data: abi.encodeCall(IERC20.transfer, (stakedEarnAddr, amount))});
        txs[1] = SafeBatchLib.Tx({to: stakedEarnAddr, data: abi.encodeCall(StakedStrat.syncRewards, ())});

        console2.log("USDS transferred to StakedStrat:", amount);
        console2.log("StakedStrat address:", stakedEarnAddr);
    }

    /// @dev This is a repeatable batch producer, and SafeBatchLib.write ends in vm.writeFile,
    /// which overwrites silently. A stale index would rewrite a previous period's batch in
    /// place with no error, and a batch mid-signature-collection in the Safe UI would stop
    /// matching what the next signer diffs against. So there is no index env var and no manual
    /// counter: 001 is taken by StopEspnYield.s.sol, so start at 2 and take the first free
    /// index. Redoing a period whose batch was generated but not signed means deleting that
    /// file first -- a deliberate act on a named path.
    function _firstFreeBatchIndex(address safe) internal view returns (uint256 index) {
        for (index = 2;; ++index) {
            if (!vm.exists(SafeBatchLib.path(safe, "004-stry-migration", index))) return index;
        }
    }
}
