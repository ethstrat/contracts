// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {StakedStrat} from "src/StakedStrat.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
/// schedule. The per-period amount is computed from the yield base -- live EARN totalSupply minus
/// the EARN minted into the LP (deploymentAddresses.json .earn-lp-supply), i.e. the supply
/// assuming everything except the LP is staked -- and settings.json's
/// basisPriceUsd/annualDividendRatioX100. Other EARN mints by the redemption Safe raise the base.
///
/// Never broadcasts: the payer is the earn-yield Safe (.protocol.multisigs.earnYield). Each run emits a Safe
/// Transaction Builder batch -- USDS.transfer(stakedEarn, amount), StakedStrat.syncRewards() -- funding the existing
/// StakedStrat instance's 28-day reward stream. No approve() step: transfer, not transferFrom.
contract PeriodicYield is Script {
    /// @dev Fat-finger guard on settings.json's annualDividendRatioX100 -- nothing upstream of
    /// this function validates that config value. Caps at 30% annual.
    uint256 internal constant MAX_ANNUAL_DIVIDEND_RATIO_X100 = 3000;

    function run() external virtual {
        address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.earnYield");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        address stakedEarn = ConfigLib.addr("deploymentAddresses.json", ".staked-earn");

        address earn = ConfigLib.addr("deploymentAddresses.json", ".stry");

        SafeBatchLib.Tx[] memory txs = periodicYield(safe, usds, stakedEarn, yieldBase(earn));

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

    /// @dev Live EARN supply minus the LP's EARN.
    function yieldBase(address earn) internal view returns (uint256) {
        uint256 lpSupply = ConfigLib.num("deploymentAddresses.json", ".earn-lp-supply");
        uint256 supply = IERC20(earn).totalSupply();
        require(supply > lpSupply, "PeriodicYield: totalSupply <= LP supply");
        return supply - lpSupply;
    }

    function periodicYieldAmount(uint256 base) internal view returns (uint256) {
        require(base > 0, "PeriodicYield: yield base == 0");
        uint256 basisPriceUsd = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");
        uint256 annualDividendRatioX100 = ConfigLib.num("settings.json", ".espnv3.annualDividendRatioX100");
        return _periodicYieldAmountPure(base, basisPriceUsd, annualDividendRatioX100);
    }

    /// Caller must confirm sEARN totalStaked() > 0 immediately before executing: USDS streamed while it is 0 is
    /// permanently lost.
    function periodicYield(address safe, address usds, address stakedEarnAddr, uint256 base)
        internal
        view
        returns (SafeBatchLib.Tx[] memory txs)
    {
        uint256 amount = periodicYieldAmount(base);
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
