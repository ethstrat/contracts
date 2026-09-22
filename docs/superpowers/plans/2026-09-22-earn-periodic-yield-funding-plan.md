# EARN 28-Day Yield Funding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `StakedStrat.REWARD_DURATION` from 7 to 28 days, make the per-period USDS yield amount a deterministic function of on-chain EARN supply plus a new `annualDividendRatioX100` config value instead of a manually-typed env var, and rename `WeeklyYield.s.sol` to `PeriodicYield.s.sol` to match — closing the real gap this feature exists for: no fast, no-fork unit test exists today for the amount formula or the Safe-batch construction.

**Architecture:** One constant change (`src/StakedStrat.sol`), one config addition (`settings.json`), one script rename+rewrite (`WeeklyYield.s.sol` → `PeriodicYield.s.sol`, `amount` computed instead of read from `WEEKLY_YIELD_AMOUNT`), every downstream consumer of the old name/duration updated to match (`Verify.s.sol`, `SafeBatchLib.sol`, `Deploy.s.sol`), and a new fast unit-test file (`test/unit/PeriodicYieldTest.sol`) giving the formula and the batch construction real coverage without a mainnet fork.

**Tech Stack:** Foundry + forge-std (`forge test`, `forge script`), OpenZeppelin `IERC20` (vendored), existing repo libs `ConfigLib`/`SafeBatchLib`.

**Spec:** [`../specs/2026-09-22-earn-monthly-yield-funding-design.md`](../specs/2026-09-22-earn-monthly-yield-funding-design.md)

## Global Constraints

- `annualDividendRatioX100` uses the file's existing x100 fixed-point convention (matches `redemptionRatioX100`), not a new basis-points convention: `1500` = ratio `15.00` = 15.00%.
- Guard: `require(annualDividendRatioX100 > 0 && annualDividendRatioX100 <= 3000, ...)` — fat-finger cap at 30% annual, boundary inclusive at `3000`.
- Formula: `totalSupply * basisPriceUsd * annualDividendRatioX100 * 28 / 100 / 100 / 365` — all four multiplications happen before any of the three divisions (nested-floor-division identity: this is exactly equal to a single `/3,650,000` division, order of the three divisors doesn't matter, but multiplication must precede division).
- `WEEKLY_YIELD_AMOUNT` env var is removed entirely — no per-run manual amount, ever.
- No automation/cron — `PeriodicYield.s.sol` stays manually triggered, same as `WeeklyYield.s.sol` was.
- `_firstFreeBatchIndex` still starts at `2` — index `1` stays reserved for `StopEspnYield.s.sol`. Unchanged.
- `forge fmt --check` must stay clean (enforced CI gate).
- Unit test command: `forge test` / `yarn test` (`forge test --fuzz-runs 20`), runs `test/unit`, no fork.
- Fork command: `SNAPSHOT_BLOCK=25800912 yarn verify:migration` (per `docs/ESPNv3_Runbook.md`'s documented snapshot).
- Commit subjects go through husky + `@commitlint/config-conventional` — lowercase verb, conventional-commit `type(scope): subject`.
- **Out of scope, do not touch:** `Distribute.s.sol`'s EARN supply-sizing formula, the Track A/B overstatement risk, `StakedStrat`'s `staked[user]/totalStaked` reward-split proportionality, any cron/automation for running the script, and `docs/ESPNv3_Runbook.md`'s Merkl-vs-staking staleness (already fixed in a separate prior pass — do not re-touch that file's Merkl wording).

## Deviations from the spec's literal wording, with reasons

Two, both forced by details the spec's touch-point list glossed over but its own Components/Architecture sections settle unambiguously. Recorded here so a reviewer does not read them as scope creep.

1. **`Verify.s.sol` computes `amount` locally instead of keeping a `PERIOD_DEPOSIT` constant passed into `periodicYield(...)`.** The spec's touch-point item 6 says to rename `WEEKLY_DEPOSIT` → `PERIOD_DEPOSIT` "alongside the literal changes (mechanical, not a design decision)," which reads as if `periodicYield(...)` still takes a 4th `amount` argument like `weeklyYield(...)` did. But the spec's own **Components** section (the literal code block) defines `function periodicYield(address safe, address usds, address stakedEarnAddr)` — three arguments, no amount — with `amount` computed inside via `periodicYieldAmount(stakedEarn)`. The Components signature is authoritative (Architecture, Rounding note, and Testing Strategy all agree with it); the touch-point list is loose paraphrase. Task 3 below drops the `WEEKLY_DEPOSIT`/`PERIOD_DEPOSIT` constant entirely and has `Verify.s.sol` call `periodicYieldAmount(stakedStrat)` itself to size its `deal()` calls and assertions. Item 8's "second, smaller top-up" no longer applies once the amount is a deterministic function of fixed inputs — both calls now transfer the same computed amount, so Item 8 becomes "call `periodicYield` a second time and assert the blend," not "call it with half the amount."
2. **`periodicYieldAmount`'s guard + math is split into an internal `pure` helper (`_periodicYieldAmountPure`).** `ConfigLib.num` always reads the real, committed `script/deployments/1/config/settings.json` file (confirmed while writing this plan — no override hook exists). Exercising the `annualDividendRatioX100` guard at values other than the committed `1500` (`0`, `3000`, `3001`) without mutating a committed file on disk during a test run requires a pure entry point that takes the ratio as a parameter. `periodicYieldAmount(StakedStrat)`'s external signature and behavior — named in the spec's Components section — is unchanged; this only splits its internals.

## Review Focus

1. **`annualDividendRatioX100` guard boundary.** `3000` must succeed (boundary inclusive), `3001` and `0` must revert. Covered in Task 2 (`test_periodicYieldAmount_succeedsAtRatioCeiling`, `_revertsAboveRatioCeiling`, `_revertsBelowRatioFloor`).
2. **`totalStaked() == 0` guard must still fire before any Safe-batch tx is built.** The condition is unchanged from `WeeklyYield.s.sol`, but the message text changes with the rename — a typo there could silently change the revert condition instead of just its wording. Covered in Task 2 (`test_periodicYield_revertsWhenNoStakers`).
3. **Safe USDS balance guard boundary.** The guard is `>=`, so `balanceOf(safe) == amount` exactly must succeed, not revert; one wei under must revert. Covered in Task 2 (`test_periodicYield_revertsWhenSafeBalanceBelowAmount` uses `amount - 1`; `test_periodicYield_returnsExactTwoTxBatch` mints exactly `amount` and must succeed).
4. **Truncation exactness on a non-round supply.** A wrong single-combined-divisor refactor, or a reordered multiply/divide, would only surface on a magnitude that doesn't divide evenly by 3,650,000 — a round number would pass either way. Covered in Task 2 (`test_periodicYieldAmount_exact_nonRoundSupply`, supply = `7_777_777e18 + 1`).
5. **`Verify.s.sol`'s 28-day / `PeriodicYield` literals are invisible to `forge test`/`yarn test`.** Only the mainnet-fork run exercises them; a missed literal (a stray `7 days`, a stale `weeklyYield(...)` call) would ship undetected by the default CI test command since `Verify.s.sol` isn't part of the `test/unit` suite. Covered in Task 3, Step 16: running `SNAPSHOT_BLOCK=25800912 yarn verify:migration` is an explicit, required step, not an optional one.

---

## Task dependency order

```
Task 1 (REWARD_DURATION 7->28: src/StakedStrat.sol + test/unit/StakedStratTest.sol)          -- independent
Task 2 (settings.json config + PeriodicYieldTest.sol (TDD) + WeeklyYield.s.sol rename/rewrite  -- independent of Task 1
        + Verify.s.sol import/inherit/override fix, minimal, to keep forge build green)
Task 3 (finish Verify.s.sol + propagate rename+cadence: SafeBatchLib.sol, Deploy.s.sol)         -- needs Task 1 AND Task 2
Task 4 (docs/RELEASE-NOTES.md bullet)                                                          -- independent, any time
```

Tasks 1 and 2 are fully parallel: disjoint file lists, and neither imports the other. Task 3 cannot start before both land — it finishes `Verify.s.sol` (whose import/inherit/override list Task 2 already renamed, minimally, so Task 2's own build check passes) and asserts `28 days` (from Task 1) in the same file.

---

## Task 1: `StakedStrat.REWARD_DURATION` 7 days → 28 days

**Files:**
- Modify: `src/StakedStrat.sol:36` (constant), `:18` (class NatSpec), `:160` (dev comment)
- Modify: `test/unit/StakedStratTest.sol:28` (local constant), `:280-282`, `:687`, `:694-696`, `:815`, `:899-900` (prose worked examples)

**Interfaces:**
- Consumes: nothing new.
- Produces: `StakedStrat.REWARD_DURATION == 28 days` — every other task in this plan (`PeriodicYield.s.sol`'s comments, `Verify.s.sol`'s assertions) is written against this value.

---

- [x] **Step 1: Edit `test/unit/StakedStratTest.sol` — bump the local constant and its worked-example prose to 28 days (this is the RED step; production is still 7 days)**

  Change the constant:

  ```solidity
  uint256 public constant REWARD_DURATION = 7 days;
  ```
  to:
  ```solidity
  uint256 public constant REWARD_DURATION = 28 days;
  ```

  In `test_SyncRewards_BlendsOnSecondCall` (around line 280), change:
  ```solidity
          // Weighted-average duration: remainingTime (6 days) < REWARD_DURATION (7 days),
          // so the new period is shorter than a fresh REWARD_DURATION window.
  ```
  to:
  ```solidity
          // Weighted-average duration: remainingTime (27 days) < REWARD_DURATION (28 days),
          // so the new period is shorter than a fresh REWARD_DURATION window.
  ```

  In `test_Streaming_BlendExtendsWindow` (around lines 687, 694-696), change:
  ```solidity
          // Capture the original 7-day period end directly from contract state
  ```
  to:
  ```solidity
          // Capture the original 28-day period end directly from contract state
  ```
  and change:
  ```solidity
          // Weighted-average duration: remaining ≈ REWARD_AMOUNT_2 and remainingTime = 3.5 days,
          // so newDuration = (3.5 days + 7 days) / 2 = 5.25 days.
          // periodFinish is extended beyond the original 7-day end but shorter than a fresh window.
  ```
  to:
  ```solidity
          // Weighted-average duration: remaining ≈ REWARD_AMOUNT_2 and remainingTime = 14 days,
          // so newDuration = (14 days + 28 days) / 2 = 21 days.
          // periodFinish is extended beyond the original 28-day end but shorter than a fresh window.
  ```

  In `test_GriefingMitigation_DustDepositBarelyPerturbsStream`'s NatSpec (around line 815), change:
  ```solidity
       *      periodFinish = now + 7 days and rewardRate = remaining/7days (≈rate/2 at midpoint),
  ```
  to:
  ```solidity
       *      periodFinish = now + 28 days and rewardRate = remaining/28days (≈rate/2 at midpoint),
  ```

  In `test_FrontrunAttack_PartialTimeCapture`'s NatSpec (around line 899), change:
  ```solidity
       * @dev Patient attacker who holds for 1 day captures only ~1/7 of their proportional
  ```
  to:
  ```solidity
       * @dev Patient attacker who holds for 1 day captures only ~1/28 of their proportional
  ```

- [x] **Step 2: Run the tests to verify they now fail**

  ```
  forge test --match-path test/unit/StakedStratTest.sol -vv
  ```

  Expected: multiple failures — e.g. `test_SyncRewards_StartsStream` asserts `periodFinish() == block.timestamp + REWARD_DURATION` where the local constant is now 28 days but production still streams over 7, so the assertion fails. This is the proof the test suite actually tracks the constant's value rather than silently testing the wrong duration.

- [x] **Step 3: Edit `src/StakedStrat.sol` — bump the production constant and its two prose mentions**

  Change the constant:
  ```solidity
      uint256 public constant REWARD_DURATION = 7 days;
  ```
  to:
  ```solidity
      uint256 public constant REWARD_DURATION = 28 days;
  ```

  In the contract-level NatSpec, change:
  ```
   *      When reward tokens are sent to this contract, syncRewards() detects the balance increase
   *      and begins a REWARD_DURATION (7-day) linear drip rather than distributing immediately.
  ```
  to:
  ```
   *      When reward tokens are sent to this contract, syncRewards() detects the balance increase
   *      and begins a REWARD_DURATION (28-day) linear drip rather than distributing immediately.
  ```

  In `syncRewards()`'s dev comment, change:
  ```
       *      The new period length is a value-weighted average of the remaining stream time and
       *      REWARD_DURATION. A full-size batch gets close to a 7-day window (anti-frontrunning),
       *      while a dust deposit barely perturbs the ongoing stream (griefing mitigation).
  ```
  to:
  ```
       *      The new period length is a value-weighted average of the remaining stream time and
       *      REWARD_DURATION. A full-size batch gets close to a 28-day window (anti-frontrunning),
       *      while a dust deposit barely perturbs the ongoing stream (griefing mitigation).
  ```

- [x] **Step 4: Run the tests to verify they pass, and check formatting**

  ```
  forge test --match-path test/unit/StakedStratTest.sol -vv
  forge fmt --check
  ```

  Expected: full suite green (`Suite result: ok. ... passed; 0 failed`), `forge fmt --check` prints nothing.

- [x] **Step 5: Commit**

  ```bash
  git add src/StakedStrat.sol test/unit/StakedStratTest.sol
  git commit -m "feat(staked-strat): move REWARD_DURATION from 7 to 28 days

  Aligns the reward-streaming window with the 28-day funding cadence
  from the EARN periodic-yield-funding design. Zero migration cost:
  neither StakedStrat nor EARN is deployed yet. Test constant and its
  worked-example comments move together so the suite keeps testing the
  real duration rather than silently drifting.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 2: config key, the amount formula/guard, and the `WeeklyYield.s.sol` → `PeriodicYield.s.sol` rename

**Files:**
- Modify: `script/deployments/1/config/settings.json` (add `.espnv3.annualDividendRatioX100`)
- Create (TDD, written first): `test/unit/PeriodicYieldTest.sol`
- Rename+rewrite: `script/deployments/1/004-stry-migration/WeeklyYield.s.sol` → `script/deployments/1/004-stry-migration/PeriodicYield.s.sol`
- Modify (partial — import/inherit/override list only, so `forge build` stays green; the rest — `7 days` literals, prose, `PERIOD_DEPOSIT`, call-site updates — is Task 3): `script/deployments/1/004-stry-migration/Verify.s.sol`

**Interfaces:**
- Consumes: `ConfigLib.num(string,string) → uint256` (existing), `SafeBatchLib.Tx{address to; bytes data;}` / `SafeBatchLib.write(...)` / `SafeBatchLib.path(...)` (existing), `StakedStrat.stratToken()/totalStaked()/syncRewards()` (existing).
- Produces, for Task 3:
  - `PeriodicYield.periodicYieldAmount(StakedStrat stakedEarn) internal view returns (uint256)`
  - `PeriodicYield._periodicYieldAmountPure(uint256 totalSupply_, uint256 basisPriceUsd, uint256 annualDividendRatioX100) internal pure returns (uint256)`
  - `PeriodicYield.periodicYield(address safe, address usds, address stakedEarnAddr) internal view returns (SafeBatchLib.Tx[] memory txs)`
  - Revert strings, asserted verbatim by Task 3's fork check: `"PeriodicYield: implausible annualDividendRatioX100"`, `"PeriodicYield: totalStaked() == 0 -- funding now permanently destroys the deposit, see src/StakedStrat.sol syncRewards()"`, `"PeriodicYield: Safe USDS balance < computed amount"`.
- Removes: `WeeklyYield` contract, `weeklyYield(...)`, the `WEEKLY_YIELD_AMOUNT` env read.

---

- [x] **Step 6: Add `annualDividendRatioX100` to `script/deployments/1/config/settings.json`**

  Change:
  ```json
  {
    "espnv3": {
      "targetRedemptionUsd": "700000000000000000000000",
      "redemptionRatioX100": 504,
      "fillGrid": 1000000000,
      "basisPriceUsd": 100,
      "expectedSeaportCounter": 0,
      "orderStartTime": "1789606800",
      "orderEndTime": "1790211600",
      "orderSalt": "espnv3-redemption-1",
      "finalYieldAmount": "0",
      "excludedAddresses": [
        "0x000000000004444c5dc75cB358380D2e3dE08A90",
        "0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D"
      ],
      "merkl": {
        "campaignType": 18,
        "duration": "604800",
        "blacklist": []
      }
    }
  }
  ```
  to (only the new key is added, right after `basisPriceUsd`; everything else is untouched, including the pre-existing `merkl` block, which is out of scope for this feature):
  ```json
  {
    "espnv3": {
      "targetRedemptionUsd": "700000000000000000000000",
      "redemptionRatioX100": 504,
      "fillGrid": 1000000000,
      "basisPriceUsd": 100,
      "annualDividendRatioX100": 1500,
      "expectedSeaportCounter": 0,
      "orderStartTime": "1789606800",
      "orderEndTime": "1790211600",
      "orderSalt": "espnv3-redemption-1",
      "finalYieldAmount": "0",
      "excludedAddresses": [
        "0x000000000004444c5dc75cB358380D2e3dE08A90",
        "0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D"
      ],
      "merkl": {
        "campaignType": 18,
        "duration": "604800",
        "blacklist": []
      }
    }
  }
  ```

- [x] **Step 7: Write the failing test file `test/unit/PeriodicYieldTest.sol`**

  Complete file:

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import {Test} from "forge-std/Test.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {StryToken} from "../../src/StryToken.sol";
  import {StakedStrat} from "../../src/StakedStrat.sol";
  import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
  import {TripwireController} from "../../src/lib/TripwireController.sol";
  import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
  import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
  import {PeriodicYield} from "../../script/deployments/1/004-stry-migration/PeriodicYield.s.sol";

  /// @dev periodicYield/periodicYieldAmount/_periodicYieldAmountPure are `internal` on the
  /// PeriodicYield Script contract -- a plain forge-std Test can't call them across instances.
  /// This harness inherits PeriodicYield and re-exports what the tests need as `external`
  /// wrappers. No fork, no Script/Test diamond-inheritance risk.
  contract PeriodicYieldHarness is PeriodicYield {
      function exposedAmountPure(uint256 totalSupply_, uint256 basisPriceUsd, uint256 annualDividendRatioX100)
          external
          pure
          returns (uint256)
      {
          return _periodicYieldAmountPure(totalSupply_, basisPriceUsd, annualDividendRatioX100);
      }

      function exposedAmount(StakedStrat stakedEarn) external view returns (uint256) {
          return periodicYieldAmount(stakedEarn);
      }

      function exposedYield(address safe, address usds, address stakedEarnAddr)
          external
          view
          returns (SafeBatchLib.Tx[] memory)
      {
          return periodicYield(safe, usds, stakedEarnAddr);
      }
  }

  contract PeriodicYieldTest is Test {
      // Mirrors settings.json's real .espnv3.basisPriceUsd / .annualDividendRatioX100 -- kept in
      // sync by test_periodicYieldAmount_matchesRealConfig, the one test allowed to depend on the
      // committed file.
      uint256 internal constant BASIS_PRICE_USD = 100;
      uint256 internal constant ANNUAL_DIVIDEND_RATIO_X100 = 1500;

      PeriodicYieldHarness internal harness;
      StakedStrat internal stakedStrat;
      StryToken internal earn;
      MintableBurnableToken internal usds;
      ITripwireController internal ctrl;

      address internal guardian = address(0x9);
      address internal safe = address(0xA11CE);
      address internal holder = address(0xB0B);

      function setUp() public {
          harness = new PeriodicYieldHarness();
          ctrl = ITripwireController(address(new TripwireController()));
          usds = new MintableBurnableToken("USDS stand-in", "USDS", address(this), ctrl, address(this));
          usds.manageMinter(address(this), true);
      }

      function _deployStakedStrat(uint256 totalSupply_) internal {
          earn = new StryToken(address(this));
          address[] memory to = new address[](1);
          to[0] = holder;
          uint256[] memory amounts = new uint256[](1);
          amounts[0] = totalSupply_;
          earn.mintBatch(to, amounts);

          stakedStrat = new StakedStrat(address(earn), address(usds), ctrl, guardian);
      }

      function _stakeAll() internal {
          uint256 balance = earn.balanceOf(holder);
          vm.startPrank(holder);
          earn.approve(address(stakedStrat), balance);
          stakedStrat.stake(balance);
          vm.stopPrank();
      }

      // ---------------------------------------------------------------------
      // Amount formula
      // ---------------------------------------------------------------------

      function test_periodicYieldAmount_exact_roundSupply() public {
          _deployStakedStrat(1_000_000e18);
          uint256 expected = 1_000_000e18 * BASIS_PRICE_USD * ANNUAL_DIVIDEND_RATIO_X100 * 28 / 100 / 100 / 365;
          assertEq(
              harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100), expected
          );
      }

      function test_periodicYieldAmount_exact_nonRoundSupply() public {
          // Not a multiple of 3,650,000 -- exercises real truncation in the chained divisions,
          // not just a magnitude that happens to divide evenly.
          uint256 totalSupply_ = 7_777_777e18 + 1;
          _deployStakedStrat(totalSupply_);
          uint256 expected = totalSupply_ * BASIS_PRICE_USD * ANNUAL_DIVIDEND_RATIO_X100 * 28 / 100 / 100 / 365;
          assertEq(
              harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100), expected
          );
      }

      function test_periodicYieldAmount_matchesRealConfig() public {
          _deployStakedStrat(1_000_000e18);
          assertEq(
              harness.exposedAmount(stakedStrat),
              harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100)
          );
      }

      function test_periodicYieldAmount_revertsBelowRatioFloor() public {
          vm.expectRevert(bytes("PeriodicYield: implausible annualDividendRatioX100"));
          harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, 0);
      }

      function test_periodicYieldAmount_revertsAboveRatioCeiling() public {
          vm.expectRevert(bytes("PeriodicYield: implausible annualDividendRatioX100"));
          harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, 3001);
      }

      function test_periodicYieldAmount_succeedsAtRatioCeiling() public view {
          // Boundary is inclusive -- 3000 itself must not revert.
          harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, 3000);
      }

      // ---------------------------------------------------------------------
      // Safe-batch construction
      // ---------------------------------------------------------------------

      function test_periodicYield_revertsWhenNoStakers() public {
          _deployStakedStrat(1_000_000e18);
          usds.mint(safe, 1_000_000_000e18);
          vm.expectRevert(
              bytes(
                  "PeriodicYield: totalStaked() == 0 -- funding now permanently destroys the deposit, see src/StakedStrat.sol syncRewards()"
              )
          );
          harness.exposedYield(safe, address(usds), address(stakedStrat));
      }

      function test_periodicYield_revertsWhenSafeBalanceBelowAmount() public {
          _deployStakedStrat(1_000_000e18);
          _stakeAll();
          uint256 amount = harness.exposedAmount(stakedStrat);
          usds.mint(safe, amount - 1);
          vm.expectRevert(bytes("PeriodicYield: Safe USDS balance < computed amount"));
          harness.exposedYield(safe, address(usds), address(stakedStrat));
      }

      function test_periodicYield_returnsExactTwoTxBatch() public {
          _deployStakedStrat(1_000_000e18);
          _stakeAll();
          uint256 amount = harness.exposedAmount(stakedStrat);
          usds.mint(safe, amount); // exactly the guard boundary -- must succeed, not revert

          SafeBatchLib.Tx[] memory txs = harness.exposedYield(safe, address(usds), address(stakedStrat));

          assertEq(txs.length, 2, "expected exactly 2 transactions");
          assertEq(txs[0].to, address(usds));
          assertEq(txs[0].data, abi.encodeCall(IERC20.transfer, (address(stakedStrat), amount)));
          assertEq(txs[1].to, address(stakedStrat));
          assertEq(txs[1].data, abi.encodeCall(StakedStrat.syncRewards, ()));
      }
  }
  ```

- [x] **Step 8: Run the tests to verify they fail to compile**

  ```
  forge test --match-path test/unit/PeriodicYieldTest.sol
  ```

  Expected: `Source "script/deployments/1/004-stry-migration/PeriodicYield.s.sol" not found` — the file is still named `WeeklyYield.s.sol` and exposes `WeeklyYield`/`weeklyYield`, not `PeriodicYield`/`periodicYield`.

  Note: this is an interface-first TDD variant — the RED here is a compile error (`Source ... not found`) because the target file doesn't exist yet, not a failing runtime assertion. Don't read this as a broken step; it's the expected RED before Step 9 creates the file.

- [x] **Step 9: Rename and rewrite `WeeklyYield.s.sol` → `PeriodicYield.s.sol`**

  ```bash
  git mv script/deployments/1/004-stry-migration/WeeklyYield.s.sol \
         script/deployments/1/004-stry-migration/PeriodicYield.s.sol
  ```

  Replace the file's contents entirely with:

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {StakedStrat} from "src/StakedStrat.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

  /// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
  /// schedule. The per-period amount is computed from EARN's total supply and settings.json's
  /// basisPriceUsd/annualDividendRatioX100 -- not an env var, since EARN's supply is fixed forever
  /// after mintBatch + renounceOwnership() and the rate/basis price are fixed config.
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

          SafeBatchLib.Tx[] memory txs = periodicYield(safe, usds, stakedEarn);

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
      function _periodicYieldAmountPure(uint256 totalSupply_, uint256 basisPriceUsd, uint256 annualDividendRatioX100)
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
          return totalSupply_ * basisPriceUsd * annualDividendRatioX100 * 28 / 100 / 100 / 365;
      }

      function periodicYieldAmount(StakedStrat stakedEarn) internal view returns (uint256) {
          uint256 totalSupply_ = stakedEarn.stratToken().totalSupply();
          uint256 basisPriceUsd = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");
          uint256 annualDividendRatioX100 = ConfigLib.num("settings.json", ".espnv3.annualDividendRatioX100");
          return _periodicYieldAmountPure(totalSupply_, basisPriceUsd, annualDividendRatioX100);
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
      function periodicYield(address safe, address usds, address stakedEarnAddr)
          internal
          view
          returns (SafeBatchLib.Tx[] memory txs)
      {
          StakedStrat stakedEarn = StakedStrat(stakedEarnAddr);
          uint256 amount = periodicYieldAmount(stakedEarn);
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
  ```

  Also make the minimal fix to `script/deployments/1/004-stry-migration/Verify.s.sol` needed to keep it compiling: its import, inheritance list, and `override(...)` list all still name `WeeklyYield`, which no longer exists after this step's rename. Foundry compiles the whole project graph on `forge build`/`forge test` — scripts included, no profile excludes them by default — so without this fix Step 10's build check fails on `Verify.s.sol`, not on anything this step touched. This is the import/inherit/override rename only; the rest of `Verify.s.sol` (`7 days` literals, prose comments, `WEEKLY_DEPOSIT`→`PERIOD_DEPOSIT`, `weeklyYield(...)`→`periodicYield(...)` call sites) is unchanged here and lands in Task 3, Step 14.

  Change:
  ```solidity
  import {WeeklyYield} from "./WeeklyYield.s.sol";
  ```
  to:
  ```solidity
  import {PeriodicYield} from "./PeriodicYield.s.sol";
  ```

  Change:
  ```solidity
  contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, Deploy, WeeklyYield {
  ```
  to:
  ```solidity
  contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, Deploy, PeriodicYield {
  ```

  Change:
  ```solidity
      function run() external override(StopEspnYield, Distribute, Deploy, WeeklyYield) {
  ```
  to:
  ```solidity
      function run() external override(StopEspnYield, Distribute, Deploy, PeriodicYield) {
  ```

- [x] **Step 10: Run the tests to verify they pass**

  ```
  forge build
  forge test --match-path test/unit/PeriodicYieldTest.sol -vv
  forge fmt --check
  ```

  Expected: `forge build` succeeds (including the now-fixed `Verify.s.sol`, which the project-wide build graph pulls in); all 9 `PeriodicYieldTest` functions pass; `forge fmt --check` prints nothing.

- [x] **Step 11: Commit**

  ```bash
  git add script/deployments/1/config/settings.json \
          script/deployments/1/004-stry-migration/PeriodicYield.s.sol \
          script/deployments/1/004-stry-migration/Verify.s.sol \
          test/unit/PeriodicYieldTest.sol
  git status --porcelain script/deployments/1/004-stry-migration/WeeklyYield.s.sol  # must print nothing (renamed, not duplicated)
  git commit -m "feat(004-stry-migration): rename WeeklyYield to PeriodicYield, compute amount from config

  Adds .espnv3.annualDividendRatioX100 = 1500 (x100 fixed point, matching
  redemptionRatioX100). WEEKLY_YIELD_AMOUNT is removed: the per-period
  amount is now EARN.totalSupply() * basisPriceUsd * annualDividendRatioX100
  * 28 / 100 / 100 / 365, guarded to 0 < annualDividendRatioX100 <= 3000.
  Also retargets Verify.s.sol's import/inherit/override list to
  PeriodicYield -- the minimal fix needed to keep forge build green now
  that WeeklyYield.s.sol is gone; the rest of Verify.s.sol's rename
  (literals, prose, call sites) follows in Task 3.
  Closes the real gap this feature exists for -- fast, no-fork unit
  coverage for the formula and the 2-tx Safe-batch construction, via a
  pure _periodicYieldAmountPure helper plus a small test harness.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 3: propagate the rename and the 28-day cadence to every remaining call site

**Files:**
- Modify: `script/deployments/1/lib/SafeBatchLib.sol` (2 NatSpec mentions of `WeeklyYield.s.sol`)
- Modify: `script/deployments/1/004-stry-migration/Deploy.s.sol` (1 `console2.log` doc line)
- Finish (whole-file rewrite; import/inherit/override list already renamed in Task 2, Step 9, to keep `forge build` green): `script/deployments/1/004-stry-migration/Verify.s.sol`

**Interfaces:**
- Consumes: `PeriodicYield.periodicYieldAmount(StakedStrat)`, `PeriodicYield.periodicYield(address,address,address)` (from Task 2); `StakedStrat.REWARD_DURATION == 28 days` (from Task 1).
- Produces: nothing new for later tasks — this is a leaf task.

---

- [x] **Step 12: Edit `script/deployments/1/lib/SafeBatchLib.sol` — rename the two `WeeklyYield.s.sol` mentions**

  Change:
  ```solidity
  /// @notice Writes Safe Transaction Builder JSON batches using the raw-calldata transaction form
  /// (no ABI-descriptor introspection). Used by BuildOrder.s.sol, Cancel.s.sol, StopEspnYield.s.sol
  /// and WeeklyYield.s.sol.
  ```
  to:
  ```solidity
  /// @notice Writes Safe Transaction Builder JSON batches using the raw-calldata transaction form
  /// (no ABI-descriptor introspection). Used by BuildOrder.s.sol, Cancel.s.sol, StopEspnYield.s.sol
  /// and PeriodicYield.s.sol.
  ```

  Change:
  ```solidity
      /// @dev The exact path `write` writes to. Exposed so a repeatable batch producer
      /// (004-stry-migration/WeeklyYield.s.sol) can scan for the first free index using the same
      /// derivation as the writer -- `write` ends in vm.writeFile, which overwrites silently.
  ```
  to:
  ```solidity
      /// @dev The exact path `write` writes to. Exposed so a repeatable batch producer
      /// (004-stry-migration/PeriodicYield.s.sol) can scan for the first free index using the same
      /// derivation as the writer -- `write` ends in vm.writeFile, which overwrites silently.
  ```

- [x] **Step 13: Edit `script/deployments/1/004-stry-migration/Deploy.s.sol` — fix the stale cadence in the operator doc line**

  Change:
  ```solidity
          console2.log("- REWARD_DURATION = 7 days; syncRewards() is permissionless.");
  ```
  to:
  ```solidity
          console2.log("- REWARD_DURATION = 28 days; syncRewards() is permissionless.");
  ```

- [x] **Step 14: Rewrite `script/deployments/1/004-stry-migration/Verify.s.sol` in full**

  Per the "Deviations" section above, `amount` is computed locally via `periodicYieldAmount(stakedStrat)` — there is no `PERIOD_DEPOSIT` constant, and the second call in Item 8 reuses the same computed `amount` rather than a hardcoded half. The import, inheritance list, and `override(...)` list below already match Task 2's Step 9 fix (`WeeklyYield` → `PeriodicYield`); this step's full-file replacement is what changes the remaining `7 days` literals, prose, `WEEKLY_DEPOSIT`→`PERIOD_DEPOSIT`, and `weeklyYield(...)`→`periodicYield(...)` call sites. Complete file:

  ```solidity
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
  import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
  import {StopEspnYield} from "./StopEspnYield.s.sol";
  import {Distribute} from "./Distribute.s.sol";
  import {Deploy} from "./Deploy.s.sol";
  import {PeriodicYield} from "./PeriodicYield.s.sol";

  /// @notice Track B mainnet-fork Verify script. Same harness as Track A: vm.startPrank, not
  /// vm.startBroadcast, so no config or Safe batch file is written. Calls the other scripts'
  /// internal entry points, never their run()s. PeriodicYield's batch is exercised by building it
  /// via periodicYield() and then executing the returned txs as calls from the Safe under prank --
  /// the same shape a Safe signer's execution would take, without ever writing a batch file.
  contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, Deploy, PeriodicYield {
      uint256 internal constant ZERO_STAKER_DEPOSIT = 1_000e18;
      uint256 internal constant CLAIM_TOLERANCE = 1e6;

      function run() external override(StopEspnYield, Distribute, Deploy, PeriodicYield) {
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

          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
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

          // Item 6: PeriodicYield, including its totalStaked > 0 guard. periodicYield() builds the
          // same Tx[] batch run() would write to a Safe Transaction Builder file; _executeBatch runs
          // it as calls from the redemption Safe under prank, mirroring what a Safe signer's
          // execution would do. amount is computed, not passed in -- see periodicYieldAmount().
          uint256 amount = periodicYieldAmount(stakedStrat);
          if (IERC20(usds).balanceOf(safe) < amount) deal(usds, safe, amount);
          uint256 notifiedBeforePeriod = stakedStrat.totalNotifiedRewards();
          SafeBatchLib.Tx[] memory periodTxs = periodicYield(safe, usds, address(stakedStrat));
          uint256 syncGasBefore = gasleft();
          _executeBatch(safe, periodTxs);
          uint256 syncGas = syncGasBefore - gasleft();
          assertEq(
              stakedStrat.periodFinish(),
              block.timestamp + 28 days,
              "Verify: periodFinish does not describe a 28-day stream"
          );
          assertEq(
              stakedStrat.rewardRate(),
              amount / 28 days,
              "Verify: rewardRate does not describe a 28-day stream of the deposit"
          );
          assertEq(
              stakedStrat.totalNotifiedRewards(),
              notifiedBeforePeriod + amount,
              "Verify: totalNotifiedRewards did not increase by the deposit"
          );

          // Item 7: warp 28 days -> claim. Sole staker => the full period's deposit, minus stream
          // rounding dust.
          vm.warp(block.timestamp + 28 days);
          uint256 usdsBeforeClaim = IERC20(usds).balanceOf(holder);
          vm.prank(holder);
          uint256 claimGasBefore = gasleft();
          stakedStrat.claim();
          uint256 claimGas = claimGasBefore - gasleft();
          uint256 claimedFull = IERC20(usds).balanceOf(holder) - usdsBeforeClaim;
          assertApproxEqAbs(
              claimedFull, amount, CLAIM_TOLERANCE, "Verify: claimed reward far from the full period's deposit"
          );

          // Item 8: unstake the full staked balance -> STRY returned and the auto-claim runs. Item 7
          // just claimed everything as of periodFinish, so unstaking immediately after would
          // auto-claim zero and never exercise unstake's `if (claimable > 0)` branch
          // (src/StakedStrat.sol:228). Fund and run a second PeriodicYield period, then warp
          // partway through it, so real rewards are pending at unstake time.
          if (IERC20(usds).balanceOf(safe) < amount) deal(usds, safe, amount);
          SafeBatchLib.Tx[] memory secondTxs = periodicYield(safe, usds, address(stakedStrat));
          _executeBatch(safe, secondTxs);
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
          console2.log("periodicYield execution gas:", syncGas);
          console2.log("claim execution gas:", claimGas);
          console2.log("unstake execution gas:", unstakeGas);
      }

      /// @dev Executes a Safe Transaction Builder batch's txs, in order, as calls from `safe` --
      /// the same shape a Safe signer's execution would take once the emitted JSON is imported and
      /// run. startPrank's two-argument form also sets tx.origin, matching how the other Verify
      /// scripts in this repo simulate Safe execution.
      function _executeBatch(address safe, SafeBatchLib.Tx[] memory txs) internal {
          vm.startPrank(safe, safe);
          for (uint256 i = 0; i < txs.length; i++) {
              (bool ok, bytes memory ret) = txs[i].to.call(txs[i].data);
              if (!ok) {
                  if (ret.length > 0) {
                      assembly {
                          revert(add(ret, 32), mload(ret))
                      }
                  }
                  revert("Verify: batch tx reverted with no reason");
              }
          }
          vm.stopPrank();
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
  ```

- [x] **Step 15: Run the fast checks**

  ```
  forge build
  forge test
  forge fmt --check
  ```

  Expected: `forge build` succeeds; the full `test/unit` suite passes (including Tasks 1 and 2's changes); `forge fmt --check` prints nothing. This does not yet exercise `Verify.s.sol` itself — it isn't part of `test/unit` and needs a fork (Step 16).

- [x] **Step 16: Run the mainnet-fork check — required, not skippable (Review Focus item 5)**

  ```
  SNAPSHOT_BLOCK=25800912 yarn verify:migration
  ```

  Expected: passes end to end through all 9 items, printing `periodicYield execution gas:` (not `weeklyYield`) and asserting the `28 days` figures. This is the only check that exercises `Verify.s.sol`'s literals at all — `forge test`/`yarn test` never runs this file. If this step cannot run in the current environment (no fork RPC egress), say so explicitly rather than treating Step 15's green result as sufficient; hand off to a reviewer or CI run that has network access before merging.

- [x] **Step 17: Commit**

  ```bash
  git add script/deployments/1/lib/SafeBatchLib.sol \
          script/deployments/1/004-stry-migration/Deploy.s.sol \
          script/deployments/1/004-stry-migration/Verify.s.sol
  git commit -m "fix(004-stry-migration): retarget Verify.s.sol and remaining docs to PeriodicYield/28 days

  Verify.s.sol now inherits PeriodicYield and computes amount via
  periodicYieldAmount(stakedStrat) instead of passing a fixed test
  constant -- periodicYield(...) no longer takes an amount argument.
  periodFinish/rewardRate/totalNotifiedRewards assertions and the claim
  warp move from 7 to 28 days. SafeBatchLib.sol's two WeeklyYield.s.sol
  NatSpec mentions and Deploy.s.sol's operator-facing REWARD_DURATION
  doc line are updated to match.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 4: customer-facing release note

**Files:**
- Modify: `docs/RELEASE-NOTES.md`

**Interfaces:** none — pure doc change, no code dependency.

---

- [x] **Step 18: Add a bullet for the periodic-cadence dividend feature**

  This is an *additional* bullet, not an edit to the existing weekly-yield bullet — that bullet's Merkl-vs-staking wording was already corrected in a separate prior pass today and is not touched here. No how-to link: this changes the rate/cadence of an existing action (staking to earn), not a new action, and the existing bullet already links the how-to for that action.

  Change:
  ```markdown
  # Release Notes

  ## Pending

  - Added the ability for ESPN holders to redeem their ESPN and redemption-token balances for USDS.
  - Added STRY, a new token airdropped to ESPN holders that replaces ESPN going forward.
  - Added weekly USDS yield for EARN holders who stake — stake your EARN to start earning, then claim directly from the staking contract. [How to earn EARN yield](help/claim-earn-yield.md)
  ```
  to:
  ```markdown
  # Release Notes

  ## Pending

  - Added the ability for ESPN holders to redeem their ESPN and redemption-token balances for USDS.
  - Added STRY, a new token airdropped to ESPN holders that replaces ESPN going forward.
  - Added weekly USDS yield for EARN holders who stake — stake your EARN to start earning, then claim directly from the staking contract. [How to earn EARN yield](help/claim-earn-yield.md)
  - Added a fixed 15% annual USDS dividend for EARN stakers, funded every 28 days.
  ```

- [x] **Step 19: Commit**

  ```bash
  git add docs/RELEASE-NOTES.md
  git commit -m "docs: add release note for the 28-day EARN dividend cadence

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Definition of done

- `forge build` succeeds.
- `forge test` / `yarn test` green, including all 9 new `PeriodicYieldTest` assertions and the updated `StakedStratTest` suite.
- `forge fmt --check` clean.
- `SNAPSHOT_BLOCK=25800912 yarn verify:migration` passes end to end, printing `periodicYield execution gas:` and asserting the `28 days` figures — no accepted early exit.
- `docs/RELEASE-NOTES.md`'s `## Pending` section has a new bullet for the 28-day dividend cadence, and the pre-existing weekly-yield bullet is otherwise untouched.
- `git grep -n "WeeklyYield\|weeklyYield\|WEEKLY_YIELD_AMOUNT\|WEEKLY_DEPOSIT"` — under `src/`, `script/`, `test/` — returns nothing.
- `git grep -n "7 days\|7-day" src/StakedStrat.sol test/unit/StakedStratTest.sol script/deployments/1/004-stry-migration/Verify.s.sol script/deployments/1/004-stry-migration/Deploy.s.sol` — returns nothing.
- `Distribute.s.sol`'s EARN supply-sizing formula, `StakedStrat`'s `staked[user]/totalStaked` split, and `docs/ESPNv3_Runbook.md`'s Merkl wording are untouched (`git diff --stat main` should show none of these files).
- `package.json` unchanged — confirmed while writing the spec that no script references `WeeklyYield` by name.
