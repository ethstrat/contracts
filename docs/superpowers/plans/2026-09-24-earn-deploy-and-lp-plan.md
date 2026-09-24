# EARN Deploy + Uniswap V4 EARN/USDS LP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make EARN ownable by the redemption Safe with a recorded, immutable airdrop-supply yield base, and produce one fork-simulated redemption-Safe batch that mints 2,500 EARN, initializes the EARN/USDS v4 pool at 100 USDS per EARN, and mints a full-range position and a 50–100 USDS/EARN bid wall owned by the Safe.

**Architecture:** `004-stry-migration` changes in place: `Distribute` transfers ownership to the Safe and records `.earn-airdrop-supply` once; `PeriodicYield` takes that value as its base; `Verify` uses the live TripwireController. A new `005-earn-lp` directory holds `ProposeLp.s.sol` (preflight, tick/liquidity math, 6-tx batch, pre-write fork simulation), minimal v4 interfaces, seven vendored MIT Uniswap math libraries, and a fork `Verify.s.sol` that runs both currency orderings, the squatted-pool revert, and a swap check. `SafeBatchLib` gains `execute`, moved out of 004's Verify so ProposeLp can use it.

**Tech Stack:** Foundry v1.8.0 (`forge test`, `forge script`, `cast`), forge-std, OpenZeppelin (vendored), Uniswap v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` and v4-periphery `9969eec44cfdf07e24b41de47f40276a58401976` library sources (vendored, MIT), existing repo libs `ConfigLib`/`HoldersLib`/`SafeBatchLib`.

**Spec:** [`../specs/2026-09-24-earn-deploy-and-lp-design.md`](../specs/2026-09-24-earn-deploy-and-lp-design.md). Sign-offs SO1–SO6 accepted by the user on 2026-09-24; Safe address confirmed (SO6).

## Execution rules (from the user's standing instructions)

- Every task that writes or edits code (Tasks 1–6) is run by a subagent with **`/ponytail:ponytail` active** (the dispatch prompt says "invoke /ponytail:ponytail" or "ponytail mode").
- The controller pins code tasks to **Sonnet 5, high effort** (dispatch through `Workflow` `agent()`, which honors `model`). Review gates run on Opus 5, high effort.
- **The controller, not the implementers, ticks this file's checkboxes**, after a task passes both spec-compliance and code-quality review, and commits the ticks (folded into the task's last commit, or `chore(plan): mark task N complete`). Implementers never edit this file.
- **No `git push` anywhere in this plan.** The user says go before any push.
- **No agent broadcasts anything.** No `--broadcast`, no `yarn safe:propose`, no Safe UI action. Task 8 is a checklist the human operator runs.
- **Never read `.env` or any secret file.** `yarn safe:propose` loads `.env` itself; only the operator runs it.
- Commit subjects: lowercase conventional commits, checked by husky + `@commitlint/config-conventional`. Never `--no-verify`. Header ≤ 100 chars, body lines ≤ 100 chars.
- Implementer commits end with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.

## Global Constraints

- Foundry pinned `v1.8.0` (`forge --version` must print `forge Version: 1.8.0`).
- `forge fmt --check` clean after every task (CI gate). Vendored `005-earn-lp/lib/*.sol` are excluded via `foundry.toml` `[profile.default.fmt] ignore` (Task 5).
- Unit tests: `yarn test` (= `forge test --fuzz-runs 20`, `test/unit`, no fork). Must be green after every task.
- Fork runs use the `package.json` default RPC: `${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}`. Snapshot block `26043909` (`SNAPSHOT_BLOCK=26043909`).
- Redemption Safe `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` (`internalAddresses.json` `.protocol.multisigs.redemption`), confirmed by the user (SO6). Safe 1.4.1, 1-of-1, owner = main multisig `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`.
- EARN initial price = `settings.json` `.espnv3.basisPriceUsd` = `100` (unscaled). Not duplicated in `lp`.
- `lp` block: `fullRangeUsds "250000000000000000000000"`, `singleSidedUsds "250000000000000000000000"`, `bandLowerUsd 50`, `bandUpperUsd 100`, `fee 3000`, `tickSpacing 60`. `fullRangeEarn = fullRangeUsds / basisPriceUsd` (2,500e18), derived.
- Pool key: `(min(EARN,USDS), max(EARN,USDS), fee 3000, tickSpacing 60, hooks address(0))`. Currency order decided at runtime.
- v4 mainnet addresses: PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`, PositionManager `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, StateView `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227`. Written to `externalAddresses.json` only after the V0 `cast` checks pass (Task 2).
- Live TripwireController `0x328aED8F7a01f45A959c187F3cb97eC508064854` (`internalAddresses.json` `.protocol.tripwire.controller`).
- Permit2 `expiration = type(uint48).max`; `modifyLiquidities` `deadline = type(uint256).max`. Exact approve amounts, never max.
- Action constants: `MINT_POSITION = 0x02`, `SETTLE_PAIR = 0x0d`.
- Dust tolerance `1e12` wei (USDS spent vs 500,000e18, EARN left on Safe, Permit2 residual allowances).
- `.earn-airdrop-supply`: quoted decimal wei string in `deploymentAddresses.json`, placeholder `"0"`, written only by `Distribute.run()`, refused if already nonzero.
- **Do not modify:** `src/StryToken.sol`, `src/StakedStrat.sol`, `004-stry-migration/StopEspnYield.s.sol`, `lib/*` (git submodules), `script/safe/*`, anything under `003-espn-redemption/`, `test/unit/StryTokenTest.sol` (spec O5: renounce test kept).
- Out of scope (D21): ETH pairs, hooks, staking LP, frontend, Track A, LP fee collection.

## Deviations from the spec's literal wording, with reasons

All code in this plan was prototyped in a scratch copy of the repo before the plan was written: `yarn test` (309 pass), `forge fmt --check`, `yarn verify:migration` and `yarn verify:lp` at block 26043909, and `ProposeLp.run()` on a latest-block fork all passed. The deviations below come from that run.

1. **Excluded-holder check (D23) is a `require` inside `Distribute.distribute()`, not two `assertEq` loops in the two Verify files.** Both Verify scripts call `distribute()` before anything else, so both still check it before the LP batch, and the check also guards the real mainnet broadcast. One loop instead of two.
2. **`buildBatch(address earn)` returns `(SafeBatchLib.Tx[] txs, LpPlan p)` and reads config itself; `_simulateAndCheck(LpPlan p, Tx[] txs)`.** `LpPlan` carries every derived value (key, poolId, ticks, liquidity, amounts) so the simulation and Verify assert against the same numbers the batch was built from.
3. **`liqFull` reference value is `25000e18 + 135` in both orderings, not `25000e18` / `25000e18 − 1` (spec N7).** Measured with the pinned TickMath/LiquidityAmounts. Settled amounts are still ≤ the configured ones: full range takes 2,499.999999999999998655 EARN and 249,999.999999999999999992 USDS; the bid wall takes exactly 250,000 USDS (`liqBand = 85830483191952473195169`). No `liq -= 1` needed.
4. **Swap check (V2 step 15) uses a 30-line `V4SwapSanity` unlock-callback contract in `Verify.s.sol`, not v4-core's `PoolSwapTest`.** `PoolSwapTest` pulls in ~10 more v4 files; the spec's own skip clause allows this.
5. **Step 13 (buildBatch refuses an initialized pool) uses a `BuildBatchProbe` contract.** forge refuses `this.f()` in a script ("Usage of `address(this)` detected in script contract").
6. **Step 14 (squatted pool) executes txs 1–5, then calls tx 6 directly and checks the revert selector.** Avoids a self-call. In the real batch, `propose-batch.mjs` produces one MultiSend, which reverts atomically.
7. **EARN dust check is `earn.balanceOf(safe) <= earnBefore + 1e12`, not `<= 1e12`.** A third party sending EARN to the Safe before step 5 cannot block ProposeLp.
8. **Extra preflight `PositionManager.permit2() == permit2`** (spec V0 check 2 as a runtime require; the interface already lists `permit2()`).
9. **Vendored libraries stay byte-identical:** `LiquidityAmounts.sol` imports `@uniswap/v4-core/src/libraries/...`; a one-line remapping resolves it, and `foundry.toml` excludes the directory from `forge fmt` (forge fmt would rewrap their comments under `wrap_comments = true`, and lint-staged runs `forge fmt` on commit).
10. **`verify:lp` passes `--tc Verify`:** `005-earn-lp/Verify.s.sol` holds three contracts.
11. **`SafeBatchLib.execute` no-reason revert string is `"SafeBatchLib: batch tx reverted with no reason"`** (was `"Verify: ..."`). Body otherwise unchanged.
12. **`test/unit/ScriptLibsTest.sol` `test_ConfigLib_addrArray_excludedAddresses` is updated to 3 addresses.** Committing the pending Seaport exclusion breaks it otherwise.
13. **Protocol fee:** at block 26043909 a freshly initialized 3000/60 key had `slot0.protocolFee == 0`. The swap check reads `slot0` and applies whatever value is there (spec R12/S6 unchanged in substance).
14. **Verify order:** both `deployCodeTo` orderings and both squat tests run on state snapshots *before* the real batch executes, so the Safe still holds ≥ 500,000 USDS for each.
15. **Runbook section 2 gets rows `4a`/`4b`** instead of renumbering, so the step numbers other sections cite (1, 5, 7, 8) stay valid.

## Review Focus

1. **A dry run of `Distribute.s.sol` (no `--broadcast`) writes `.stry` and `.earn-airdrop-supply` into `deploymentAddresses.json`,** so the real broadcast then refuses with "airdrop supply already recorded". Confirmed in the prototype. Expected: the operator restores the file (`git checkout -- script/deployments/1/config/deploymentAddresses.json`) before the broadcast. Pinned by Task 4 Step 9 (fork smoke: first run writes, second run refuses) and stated in Task 8.
2. **Mainnet EARN's address is unknown until step 3, so the pool may be Case A or Case B.** Expected: both work. Pinned by Task 5's unit tests (reference table for both cases) and Task 6's `_checkOrderingAt` at `0x10000` (Case A) and `type(uint160).max - 0xffff` (Case B), each running the full batch and all V2 step 6–12 checks.
3. **Someone initializes the `(EARN, USDS, 3000, 60, 0)` key at a wrong price between step 3 and step 7.** Expected: the batch reverts `MaximumAmountExceeded`, nothing is minted, no funds move. Pinned by Task 6 `_assertSquatReverts` at 2× and 0.5×.
4. **ProposeLp is re-run after the batch file exists or after the pool is live.** Expected: refuse, never overwrite a batch mid-signature. Pinned by Task 6 Step 7 (second smoke run refuses on the existing file) and Verify step 13 (probe refuses with "ProposeLp: pool already initialized").
5. **PeriodicYield is run before Distribute has recorded the supply (placeholder `"0"`).** Expected: hard revert, no zero-amount batch. Pinned by Task 3 `test_periodicYield_revertsOnZeroAirdropSupply`.

---

## Task dependency order

```
Task 1 (commit pending config: snapshot, Seaport exclusion, live controller; fix ScriptLibsTest)  -- first
Task 2 (V0 on-chain checks -> externalAddresses.json uniswap-v4; settings.json lp block)            -- after Task 1 (settings.json)
Task 3 (PeriodicYield airdrop-supply base + tests + 004 Verify call sites)                           -- after Task 1
Task 4 (Distribute ownership + supply record + excluded require; 004 Verify; SafeBatchLib.execute)   -- after Task 3
Task 5 (vendored v4 libs, IV4Minimal, ProposeLp math + unit tests)                                   -- after Task 1
Task 6 (ProposeLp buildBatch/simulate/run + 005 Verify + verify:lp)                                  -- after Tasks 2, 4, 5
Task 7 (docs: runbook, old spec, help, how-to, release notes)                                        -- after Task 6
Task 8 (operator checklist: human-run mainnet steps, no agent action)                                -- after Task 7 and user go
```

Run tasks sequentially in number order. Tasks 2, 3 and 5 touch disjoint files, but one controller and one commit stream is simpler.

---

## Task 1: commit the pending config edits

**Files:**
- Commit (already edited in the working tree): `script/deployments/1/config/settings.json` (Seaport added to `.espnv3.excludedAddresses`), `script/deployments/1/config/internalAddresses.json` (`.protocol.tripwire.controller`), `script/deployments/1/config/espn-holders-26043909.json` (untracked snapshot)
- Modify: `test/unit/ScriptLibsTest.sol:36-41`

**Interfaces:**
- Consumes: nothing.
- Produces: committed `.protocol.tripwire.controller = 0x328aED8F7a01f45A959c187F3cb97eC508064854` (Task 4), committed snapshot file `espn-holders-26043909.json` (Tasks 4, 6), `excludedAddresses` of length 3 (Task 4's `distribute()` require).

- [ ] **Step 1: Confirm the three pending edits are exactly what the spec says**

  ```bash
  git diff script/deployments/1/config/settings.json script/deployments/1/config/internalAddresses.json
  git status --porcelain script/deployments/1/config/
  ```

  Expected: `settings.json` adds only `"0x0000000000000068F116a894984e2DB1123eB395"` as the third `excludedAddresses` entry; `internalAddresses.json` changes only `.protocol.tripwire.controller` from the zero address to `0x328aED8F7a01f45A959c187F3cb97eC508064854`; `?? script/deployments/1/config/espn-holders-26043909.json`. Anything else: stop and report to the controller.

- [ ] **Step 2: Confirm the live controller has code at the snapshot block**

  ```bash
  cast code 0x328aED8F7a01f45A959c187F3cb97eC508064854 --rpc-url "${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}" -b 26043909 | wc -c
  ```

  Expected: a number well above `3` (non-empty bytecode).

- [ ] **Step 3: Run the unit tests to see the expected failure**

  ```bash
  yarn test --match-test test_ConfigLib_addrArray_excludedAddresses
  ```

  Expected: FAIL `assertion failed: 3 != 2` (the test still pins the old 2-address list).

- [ ] **Step 4: Update the test in `test/unit/ScriptLibsTest.sol`**

  Change:
  ```solidity
          assertEq(excluded.length, 2);
          assertEq(excluded[0], 0x000000000004444c5dc75cB358380D2e3dE08A90); // V4 PoolManager singleton
          assertEq(excluded[1], 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D); // redemption Safe/treasury
  ```
  to:
  ```solidity
          assertEq(excluded.length, 3);
          assertEq(excluded[0], 0x000000000004444c5dc75cB358380D2e3dE08A90); // V4 PoolManager singleton
          assertEq(excluded[1], 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D); // redemption Safe/treasury
          assertEq(excluded[2], 0x0000000000000068F116a894984e2DB1123eB395); // Seaport 1.6
  ```

- [ ] **Step 5: Run the checks**

  ```bash
  yarn test
  forge fmt --check
  ```

  Expected: all unit tests pass; `forge fmt --check` prints nothing.

- [ ] **Step 6: Commit**

  ```bash
  git add script/deployments/1/config/settings.json \
          script/deployments/1/config/internalAddresses.json \
          script/deployments/1/config/espn-holders-26043909.json \
          test/unit/ScriptLibsTest.sol
  git commit -m "chore(config): commit snapshot 26043909, seaport exclusion and live tripwire controller

  Snapshot taken at block 26043909 (2026-09-24 11:00 Sydney). Seaport holds 0 ESPN
  at the snapshot and is excluded going forward. The tripwire controller is the live
  0x328aED8F7a01f45A959c187F3cb97eC508064854, which has code at the snapshot block.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 2: verify the Uniswap v4 addresses on-chain, then add them and the `lp` settings block

**Files:**
- Modify: `script/deployments/1/config/externalAddresses.json` (add `uniswap-v4` block)
- Modify: `script/deployments/1/config/settings.json` (add top-level `lp` block)

**Interfaces:**
- Consumes: nothing.
- Produces, read by Task 6 via `ConfigLib`: `externalAddresses.json` `.uniswap-v4.poolManager`, `.uniswap-v4.positionManager`, `.uniswap-v4.permit2`, `.uniswap-v4.stateView`; `settings.json` `.lp.fullRangeUsds`, `.lp.singleSidedUsds` (quoted wei strings), `.lp.bandLowerUsd`, `.lp.bandUpperUsd`, `.lp.fee`, `.lp.tickSpacing` (integers).

- [ ] **Step 1: Run the V0 checks (read-only `cast`) and save the output (spec section 8, V0). Do not edit any file before every check passes.**

  ```bash
  RPC="${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}"
  BLOCK=$(cast block-number --rpc-url "$RPC")
  echo "V0 block: $BLOCK"
  for a in 0x000000000004444c5dc75cB358380D2e3dE08A90 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e \
           0x000000000022D473030F116dDEE9F6B43aC78BA3 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227; do
    echo "$a code bytes: $(cast code $a --rpc-url "$RPC" -b $BLOCK | wc -c)"
  done
  cast call 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e "poolManager()(address)" --rpc-url "$RPC" -b $BLOCK
  cast call 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227 "poolManager()(address)" --rpc-url "$RPC" -b $BLOCK
  cast call 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e "permit2()(address)" --rpc-url "$RPC" -b $BLOCK
  cast call 0x000000000022D473030F116dDEE9F6B43aC78BA3 "DOMAIN_SEPARATOR()(bytes32)" --rpc-url "$RPC" -b $BLOCK
  ```

  Expected, all of:
  - every `code bytes` value well above `3`;
  - both `poolManager()` calls print `0x000000000004444c5dc75cB358380D2e3dE08A90`;
  - `permit2()` prints `0x000000000022D473030F116dDEE9F6B43aC78BA3`;
  - `DOMAIN_SEPARATOR()` prints a nonzero `bytes32`.

  Any mismatch: stop, write nothing, report to the controller. Keep `$BLOCK` and the outputs for the commit message.

- [ ] **Step 2: Add the `uniswap-v4` block to `script/deployments/1/config/externalAddresses.json`**, between `eth-strategy` and `merkl`:

  Change:
  ```json
    "eth-strategy": {
      "espn": "0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE"
    },
    "merkl": {
  ```
  to:
  ```json
    "eth-strategy": {
      "espn": "0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE"
    },
    "uniswap-v4": {
      "poolManager": "0x000000000004444c5dc75cB358380D2e3dE08A90",
      "positionManager": "0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e",
      "permit2": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
      "stateView": "0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227"
    },
    "merkl": {
  ```

- [ ] **Step 3: Add the top-level `lp` block to `script/deployments/1/config/settings.json`**, after the closing brace of `espnv3`:

  Change the end of the file:
  ```json
      "merkl": {
        "campaignType": 18,
        "duration": "604800",
        "blacklist": []
      }
    }
  }
  ```
  to:
  ```json
      "merkl": {
        "campaignType": 18,
        "duration": "604800",
        "blacklist": []
      }
    },
    "lp": {
      "fullRangeUsds": "250000000000000000000000",
      "singleSidedUsds": "250000000000000000000000",
      "bandLowerUsd": 50,
      "bandUpperUsd": 100,
      "fee": 3000,
      "tickSpacing": 60
    }
  }
  ```

- [ ] **Step 4: Check the files parse and nothing else moved**

  ```bash
  node -e 'for (const f of ["externalAddresses","settings"]) JSON.parse(require("fs").readFileSync(`script/deployments/1/config/${f}.json`))' && echo JSON-OK
  git diff --stat
  yarn test
  forge fmt --check
  ```

  Expected: `JSON-OK`; diff shows only the two JSON files; tests pass; fmt prints nothing.

- [ ] **Step 5: Commit, recording the V0 block and results (spec V0 step 3)**

  Replace `<V0 block>` with the `$BLOCK` value printed in Step 1 before running the command.

  ```bash
  git add script/deployments/1/config/externalAddresses.json script/deployments/1/config/settings.json
  git commit -m "chore(config): add verified uniswap v4 addresses and lp settings

  V0 checks at mainnet block <V0 block>:
  - PoolManager, PositionManager, Permit2, StateView: non-empty code
  - PositionManager.poolManager() == StateView.poolManager() == 0x0000...4444c5dc75cB358380D2e3dE08A90
  - PositionManager.permit2() == 0x000000000022D473030F116dDEE9F6B43aC78BA3
  - Permit2.DOMAIN_SEPARATOR() nonzero
  lp block: 250k USDS + 2.5k EARN full range, 250k USDS bid wall 50-100 USDS/EARN, fee 3000,
  tickSpacing 60.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 3: PeriodicYield yield base = recorded airdrop supply (D22)

**Files:**
- Modify (TDD, test first): `test/unit/PeriodicYieldTest.sol`
- Modify: `script/deployments/1/004-stry-migration/PeriodicYield.s.sol`
- Modify (call sites only, to keep `forge build` green): `script/deployments/1/004-stry-migration/Verify.s.sol`

**Interfaces:**
- Consumes: `ConfigLib.num(string,string) returns (uint256)` (existing).
- Produces, for Tasks 4 and 6:
  - `PeriodicYield.periodicYieldAmount(uint256 airdropSupply) internal view returns (uint256)` — reverts `"PeriodicYield: airdropSupply == 0 -- .earn-airdrop-supply not recorded"` on 0.
  - `PeriodicYield.periodicYield(address safe, address usds, address stakedEarnAddr, uint256 airdropSupply) internal view returns (SafeBatchLib.Tx[] memory)`.
  - `PeriodicYield._periodicYieldAmountPure(uint256 supplyBase, uint256 basisPriceUsd, uint256 annualDividendRatioX100) internal pure returns (uint256)` (renamed first argument only).
  - `PeriodicYield.run()` reads `deploymentAddresses.json` `.earn-airdrop-supply` (the key is added by Task 4).

- [ ] **Step 1: Replace `test/unit/PeriodicYieldTest.sol` with the complete file below**

  Changes vs. the current file: harness wrappers take `airdropSupply`; `test_periodicYieldAmount_matchesRealConfig` passes an explicit base; new `test_periodicYield_revertsOnZeroAirdropSupply` and `test_periodicYieldAmount_ignoresPostAirdropMint`. The base is passed as the literal `1_000_000e18`, never as `earn.totalSupply()` inside a call that follows `vm.expectRevert` — that external call would consume the expectRevert.

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
      function exposedAmountPure(uint256 supplyBase, uint256 basisPriceUsd, uint256 annualDividendRatioX100)
          external
          pure
          returns (uint256)
      {
          return _periodicYieldAmountPure(supplyBase, basisPriceUsd, annualDividendRatioX100);
      }

      function exposedAmount(uint256 airdropSupply) external view returns (uint256) {
          return periodicYieldAmount(airdropSupply);
      }

      function exposedYield(address safe, address usds, address stakedEarnAddr, uint256 airdropSupply)
          external
          view
          returns (SafeBatchLib.Tx[] memory)
      {
          return periodicYield(safe, usds, stakedEarnAddr, airdropSupply);
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
          assertEq(harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100), expected);
      }

      function test_periodicYieldAmount_exact_nonRoundSupply() public {
          // Not a multiple of 3,650,000 -- exercises real truncation in the chained divisions,
          // not just a magnitude that happens to divide evenly.
          uint256 totalSupply_ = 7_777_777e18 + 1;
          _deployStakedStrat(totalSupply_);
          uint256 expected = totalSupply_ * BASIS_PRICE_USD * ANNUAL_DIVIDEND_RATIO_X100 * 28 / 100 / 100 / 365;
          assertEq(harness.exposedAmountPure(earn.totalSupply(), BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100), expected);
      }

      function test_periodicYieldAmount_matchesRealConfig() public view {
          assertEq(
              harness.exposedAmount(1_000_000e18),
              harness.exposedAmountPure(1_000_000e18, BASIS_PRICE_USD, ANNUAL_DIVIDEND_RATIO_X100)
          );
      }

      function test_periodicYield_revertsOnZeroAirdropSupply() public {
          _deployStakedStrat(1_000_000e18);
          _stakeAll();
          usds.mint(safe, 1_000_000_000e18);
          vm.expectRevert(bytes("PeriodicYield: airdropSupply == 0 -- .earn-airdrop-supply not recorded"));
          harness.exposedYield(safe, address(usds), address(stakedStrat), 0);
      }

      function test_periodicYieldAmount_ignoresPostAirdropMint() public {
          _deployStakedStrat(1_000_000e18);
          _stakeAll();
          uint256 airdropSupply = earn.totalSupply();
          uint256 amount = harness.exposedAmount(airdropSupply);
          usds.mint(safe, amount);

          // The owner mints more EARN after the airdrop (the LP's 2,500, or any later Safe mint).
          address[] memory to = new address[](1);
          to[0] = safe;
          uint256[] memory amounts = new uint256[](1);
          amounts[0] = 2_500e18;
          earn.mintBatch(to, amounts);
          assertEq(earn.totalSupply(), airdropSupply + 2_500e18);

          SafeBatchLib.Tx[] memory txs = harness.exposedYield(safe, address(usds), address(stakedStrat), airdropSupply);
          assertEq(txs[0].data, abi.encodeCall(IERC20.transfer, (address(stakedStrat), amount)));
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
          harness.exposedYield(safe, address(usds), address(stakedStrat), 1_000_000e18);
      }

      function test_periodicYield_revertsWhenSafeBalanceBelowAmount() public {
          _deployStakedStrat(1_000_000e18);
          _stakeAll();
          uint256 amount = harness.exposedAmount(1_000_000e18);
          usds.mint(safe, amount - 1);
          vm.expectRevert(bytes("PeriodicYield: Safe USDS balance < computed amount"));
          harness.exposedYield(safe, address(usds), address(stakedStrat), 1_000_000e18);
      }

      function test_periodicYield_returnsExactTwoTxBatch() public {
          _deployStakedStrat(1_000_000e18);
          _stakeAll();
          uint256 amount = harness.exposedAmount(1_000_000e18);
          usds.mint(safe, amount); // exactly the guard boundary -- must succeed, not revert

          SafeBatchLib.Tx[] memory txs = harness.exposedYield(safe, address(usds), address(stakedStrat), 1_000_000e18);

          assertEq(txs.length, 2, "expected exactly 2 transactions");
          assertEq(txs[0].to, address(usds));
          assertEq(txs[0].data, abi.encodeCall(IERC20.transfer, (address(stakedStrat), amount)));
          assertEq(txs[1].to, address(stakedStrat));
          assertEq(txs[1].data, abi.encodeCall(StakedStrat.syncRewards, ()));
      }
  }
  ```

- [ ] **Step 2: Run the tests to verify they fail to compile**

  ```bash
  forge test --match-path test/unit/PeriodicYieldTest.sol
  ```

  Expected: compile error — `periodicYieldAmount` takes a `StakedStrat` and `periodicYield` takes 3 arguments.

- [ ] **Step 3: Replace `script/deployments/1/004-stry-migration/PeriodicYield.s.sol` with the complete file below**

  Changes: the lines 10–13 comment no longer says "fixed forever after mintBatch + renounceOwnership()"; `run()` reads `.earn-airdrop-supply`; `periodicYieldAmount`/`periodicYield` take `airdropSupply`, require it > 0, and no longer read `stratToken().totalSupply()`; `_periodicYieldAmountPure`'s first argument is renamed `supplyBase`.

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {StakedStrat} from "src/StakedStrat.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

  /// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
  /// schedule. The per-period amount is computed from the recorded airdrop total
  /// (deploymentAddresses.json .earn-airdrop-supply, written once by Distribute.s.sol) and
  /// settings.json's basisPriceUsd/annualDividendRatioX100 -- not an env var, and not live
  /// totalSupply(): the redemption Safe owns EARN and can mint more (the 2,500 LP EARN, any later
  /// mint), and those mints do not change the yield base.
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
          require(airdropSupply > 0, "PeriodicYield: airdropSupply == 0 -- .earn-airdrop-supply not recorded");
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
  ```

- [ ] **Step 4: Update the call sites in `script/deployments/1/004-stry-migration/Verify.s.sol` (minimal, so the build compiles; Task 4 finishes this file)**

  After:
  ```solidity
          assertEq(stry.owner(), address(0), "Verify: STRY ownership not renounced");
  ```
  add:
  ```solidity
          uint256 airdropSupply = stry.totalSupply();
  ```

  Change:
  ```solidity
          uint256 amount = periodicYieldAmount(stakedStrat);
  ```
  to:
  ```solidity
          uint256 amount = periodicYieldAmount(airdropSupply);
  ```

  Change:
  ```solidity
          SafeBatchLib.Tx[] memory periodTxs = periodicYield(safe, usds, address(stakedStrat));
  ```
  to:
  ```solidity
          SafeBatchLib.Tx[] memory periodTxs = periodicYield(safe, usds, address(stakedStrat), airdropSupply);
  ```

  Change:
  ```solidity
          SafeBatchLib.Tx[] memory secondTxs = periodicYield(safe, usds, address(stakedStrat));
  ```
  to:
  ```solidity
          SafeBatchLib.Tx[] memory secondTxs = periodicYield(safe, usds, address(stakedStrat), airdropSupply);
  ```

- [ ] **Step 5: Run the tests to verify they pass**

  ```bash
  forge build
  forge test --match-path test/unit/PeriodicYieldTest.sol -vv
  yarn test
  forge fmt --check
  ```

  Expected: build succeeds; all 11 `PeriodicYieldTest` tests pass (9 existing + 2 new); full suite green; fmt prints nothing.

- [ ] **Step 6: Commit**

  ```bash
  git add test/unit/PeriodicYieldTest.sol \
          script/deployments/1/004-stry-migration/PeriodicYield.s.sol \
          script/deployments/1/004-stry-migration/Verify.s.sol
  git commit -m "feat(004-stry-migration): size periodic yield on the recorded airdrop supply

  The 28-day amount is computed from deploymentAddresses.json .earn-airdrop-supply
  instead of live EARN totalSupply(). The redemption Safe will own EARN and can mint
  (the 2,500 LP EARN, later mints); those mints no longer change the yield. A zero
  base (placeholder not yet recorded) reverts before any batch is built.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 4: EARN ownership to the Safe, record the airdrop supply once, live controller in Verify

**Files:**
- Modify: `script/deployments/1/004-stry-migration/Distribute.s.sol` (whole file below)
- Modify: `script/deployments/1/config/deploymentAddresses.json` (placeholder)
- Modify: `script/deployments/1/lib/SafeBatchLib.sol` (add `execute`)
- Modify: `script/deployments/1/004-stry-migration/Verify.s.sol`
- Modify (comments and one require message, no logic): `script/deployments/1/004-stry-migration/Deploy.s.sol`

**Interfaces:**
- Consumes: `periodicYieldAmount(uint256)`, `periodicYield(address,address,address,uint256)` (Task 3); `.protocol.tripwire.controller`, 3-entry `excludedAddresses` (Task 1).
- Produces:
  - `SafeBatchLib.execute(address safe, SafeBatchLib.Tx[] memory txs) internal` — `vm.startPrank(safe, safe)`, calls each tx in order, bubbles the revert data, `vm.stopPrank()`. Used by Task 6.
  - `Distribute.distribute(address deployer, string memory holdersFile) internal returns (StryToken)` — signature unchanged; now ends with `owner() == redemption Safe` and requires every `excludedAddresses` entry to hold 0 EARN. Used by Task 6.
  - `Distribute.run()` refuses when `.earn-airdrop-supply != 0`, writes `.stry` and `.earn-airdrop-supply` after broadcast.
  - `deploymentAddresses.json` key `earn-airdrop-supply` = `"0"`.

- [ ] **Step 1: Add the placeholder to `script/deployments/1/config/deploymentAddresses.json`**

  Change:
  ```json
    "stry": "0x0000000000000000000000000000000000000000"
  }
  ```
  to:
  ```json
    "stry": "0x0000000000000000000000000000000000000000",
    "earn-airdrop-supply": "0"
  }
  ```

- [ ] **Step 2: Move `_executeBatch` into `script/deployments/1/lib/SafeBatchLib.sol` as `execute`**

  Insert immediately before the line `    /// @dev The exact path \`write\` writes to. Exposed so a repeatable batch producer`:

  ```solidity
      /// @dev Executes a batch's txs, in order, as calls from `safe` -- the same shape a Safe signer's
      /// execution takes once the emitted JSON is imported and run. startPrank's two-argument form
      /// also sets tx.origin. Fork-only: used by the Verify scripts and ProposeLp's pre-write
      /// simulation. Moved unchanged from 004-stry-migration/Verify.s.sol's _executeBatch.
      function execute(address safe, Tx[] memory txs) internal {
          vm.startPrank(safe, safe);
          for (uint256 i = 0; i < txs.length; i++) {
              (bool ok, bytes memory ret) = txs[i].to.call(txs[i].data);
              if (!ok) {
                  if (ret.length > 0) {
                      assembly {
                          revert(add(ret, 32), mload(ret))
                      }
                  }
                  revert("SafeBatchLib: batch tx reverted with no reason");
              }
          }
          vm.stopPrank();
      }

  ```

- [ ] **Step 3: Update `script/deployments/1/004-stry-migration/Verify.s.sol` first (this is the RED side: it asserts the new owner)**

  Delete the import line:
  ```solidity
  import {TripwireController} from "src/lib/TripwireController.sol";
  ```

  Change (this block includes the `airdropSupply` line Task 3 added):
  ```solidity
          // Item 2: Distribute STRY (single mintBatch).
          address stryDeployer = makeAddr("stryDeployer");
          vm.startPrank(stryDeployer);
          StryToken stry = distribute(stryDeployer, holdersFile);
          vm.stopPrank();
          assertEq(stry.owner(), address(0), "Verify: STRY ownership not renounced");
          uint256 airdropSupply = stry.totalSupply();

          // Item 3: deploy a TripwireController locally and pass it to Deploy's internal deploy().
          // TripwireGuard's constructor calls controller.register() itself, permissionlessly -- no
          // controller-owner transaction is needed.
          address guardian = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.tripwire-guardian");
          TripwireController controller = new TripwireController();
          StakedStrat stakedStrat = deploy(address(stry), address(controller), guardian);

          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          uint256 holderStryBalance = stry.balanceOf(holder);
  ```
  to:
  ```solidity
          // Item 2: Distribute STRY (single mintBatch). distribute() itself requires that no
          // excludedAddresses entry received EARN (D23).
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          address stryDeployer = makeAddr("stryDeployer");
          vm.startPrank(stryDeployer);
          StryToken stry = distribute(stryDeployer, holdersFile);
          vm.stopPrank();
          assertEq(stry.owner(), safe, "Verify: EARN owner is not the redemption Safe");
          uint256 airdropSupply = stry.totalSupply();

          // D22: a post-airdrop Safe mint does not change the PeriodicYield amount. Also proves the
          // Safe can mint as owner.
          uint256 amountBeforeMint = periodicYieldAmount(airdropSupply);
          address[] memory mintTo = new address[](1);
          mintTo[0] = safe;
          uint256[] memory mintAmounts = new uint256[](1);
          mintAmounts[0] = 1e18;
          vm.prank(safe);
          stry.mintBatch(mintTo, mintAmounts);
          assertEq(periodicYieldAmount(airdropSupply), amountBeforeMint, "Verify: yield amount moved with a Safe mint");

          // Item 3: deploy against the live TripwireController (D13). TripwireGuard's constructor
          // calls controller.register() itself, permissionlessly -- no controller-owner transaction.
          address guardian = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.tripwire-guardian");
          address controller = ConfigLib.addr("internalAddresses.json", ".protocol.tripwire.controller");
          require(controller.code.length > 0, "Verify: live TripwireController has no code at this fork block");
          StakedStrat stakedStrat = deploy(address(stry), controller, guardian);

          uint256 holderStryBalance = stry.balanceOf(holder);
  ```

  Change:
  ```solidity
          // same Tx[] batch run() would write to a Safe Transaction Builder file; _executeBatch runs
  ```
  to:
  ```solidity
          // same Tx[] batch run() would write to a Safe Transaction Builder file; SafeBatchLib.execute runs
  ```

  Replace both `_executeBatch(safe, periodTxs);` and `_executeBatch(safe, secondTxs);` with `SafeBatchLib.execute(safe, periodTxs);` and `SafeBatchLib.execute(safe, secondTxs);`.

  Delete the whole `_executeBatch` function and its 4-line `/// @dev` comment (the block starting `/// @dev Executes a Safe Transaction Builder batch's txs` and ending with the function's closing brace).

- [ ] **Step 4: Run the fork check to verify it fails**

  ```bash
  SNAPSHOT_BLOCK=26043909 yarn verify:migration
  ```

  Expected: FAIL at `Verify: EARN owner is not the redemption Safe` (Distribute still renounces).

- [ ] **Step 5: Replace `script/deployments/1/004-stry-migration/Distribute.s.sol` with the complete file below**

  Changes: `run()` refuses when `.earn-airdrop-supply` is already nonzero and writes it after `.stry`; `distribute()` requires the Safe to be a deployed contract, calls `transferOwnership(safe)` instead of `renounceOwnership()`, and requires every `excludedAddresses` entry to hold 0 EARN. `distribute()` keeps its signature.

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {StryToken} from "src/StryToken.sol";
  import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {HoldersLib} from "../lib/HoldersLib.sol";

  /// @notice Deploys STRY and mints it to the same snapshot holders as Track A, in one mintBatch,
  /// sized so totalSupply(STRY) * basisPriceUsd == the included holders' share of ESPN's live USDS
  /// backing. $100/STRY is a nominal basis price, not a redemption guarantee (Assumption 7/option 2)
  /// -- both tracks lay claim to the same ESPN backing.
  contract Distribute is Script {
      function run() external virtual {
          string memory holdersFile = vm.envString("HOLDERS_FILE");
          // D22: the airdrop total is the PeriodicYield base, recorded exactly once.
          require(
              ConfigLib.num("deploymentAddresses.json", ".earn-airdrop-supply") == 0,
              "Distribute: airdrop supply already recorded; refusing to overwrite"
          );

          address deployer = msg.sender;
          vm.startBroadcast();
          StryToken stry = distribute(deployer, holdersFile);
          vm.stopBroadcast();

          // Only mintBatch has minted at this point: ownership moved to the Safe after it, and the
          // Safe cannot act inside this script.
          uint256 airdropSupply = stry.totalSupply();
          ConfigLib.writeDeployedAddress(".stry", address(stry));
          vm.writeJson(
              string.concat('"', vm.toString(airdropSupply), '"'),
              string.concat(ConfigLib.configRoot(), "deploymentAddresses.json"),
              ".earn-airdrop-supply"
          );
      }

      /// @dev Items 1-3 and the calibration assertion. `writeDeployedAddress` stays out of here and
      /// only runs from run(), so Verify.s.sol never dirties the committed deploymentAddresses.json.
      /// `deployer` is taken as an argument (not read via msg.sender) so Verify.s.sol can prank as
      /// whichever address it likes and pass the same address through as the constructor owner.
      /// `holdersFile` is likewise an argument, not an env read, so Verify.s.sol can pass the path it
      /// already derived from SNAPSHOT_BLOCK (same shape as 003-espn-redemption/Distribute.s.sol).
      function distribute(address deployer, string memory holdersFile) internal returns (StryToken stry) {
          // D8/D9: EARN ownership goes to the redemption Safe. StryToken is single-step Ownable, so a
          // wrong target is unrecoverable -- refuse anything that is not a deployed contract.
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          require(safe != address(0) && safe.code.length > 0, "Distribute: redemption Safe has no code");

          HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);
          (address[] memory addrs, uint256[] memory espnBalances, uint256 includedCount,) = HoldersLib.included(snapshot);

          address espnAddr = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
          EthStrategyPerpetualNote espn = EthStrategyPerpetualNote(espnAddr);
          uint256 totalAssets_ = espn.totalAssets();
          uint256 totalSupply_ = espn.totalSupply();
          uint256 basisPriceUsd = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");

          uint256[] memory stryAmounts = new uint256[](includedCount);
          for (uint256 i; i < includedCount; ++i) {
              stryAmounts[i] = espnBalances[i] * totalAssets_ / (totalSupply_ * basisPriceUsd);
          }

          stry = new StryToken(deployer);

          uint256 gasBefore = gasleft();
          stry.mintBatch(addrs, stryAmounts);
          uint256 executionGas = gasBefore - gasleft();
          uint256 calldataGasEstimate = 21000 + includedCount * 20 * 16;
          console2.log("mintBatch execution gas:", executionGas);
          console2.log(
              "mintBatch total estimated (execution + 21000 intrinsic + calldata):", executionGas + calldataGasEstimate
          );

          stry.transferOwnership(safe);

          // D23: no address in settings.json .espnv3.excludedAddresses receives airdrop EARN.
          address[] memory excluded = ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses");
          for (uint256 i; i < excluded.length; ++i) {
              require(stry.balanceOf(excluded[i]) == 0, "Distribute: excluded address received EARN");
          }

          // Calibration -- each per-holder division truncates up to 1 wei of STRY; multiplied back
          // by basisPriceUsd, that is up to basisPriceUsd wei of USDS per holder. Truncation only
          // undershoots, never overshoots.
          uint256 espnBackingRepresented = HoldersLib.sum(espnBalances) * totalAssets_ / totalSupply_;
          require(
              stry.totalSupply() * basisPriceUsd <= espnBackingRepresented, "Distribute: STRY oversized vs ESPN backing"
          );
          require(
              espnBackingRepresented - stry.totalSupply() * basisPriceUsd <= includedCount * basisPriceUsd,
              "Distribute: STRY undersized beyond truncation tolerance"
          );

          console2.log("STRY distributed to included holders:", includedCount);
          console2.log("NOTE: basisPriceUsd is a nominal basis price, not a redemption guarantee. Both tracks");
          console2.log("lay claim to the same ESPN backing snapshot: Track A pays out up to 700,000 USDS of");
          console2.log("it, Track B mints STRY nominally claiming the full amount -- an overstatement of ~18%");
          console2.log("if both ship off one snapshot.");
      }
  }
  ```

- [ ] **Step 6: Comment-only edits to `script/deployments/1/004-stry-migration/Deploy.s.sol` (spec N6, no logic change)**

  Change:
  ```solidity
          // Assumption 4: no deployed TripwireController is recorded anywhere in this repo.
          // TripwireGuard's constructor reverts a bare InvalidController() on a zero-or-codeless
          // controller, which is opaque -- fail with something the operator can act on instead.
          // This guards the mainnet broadcast only; it does not gate fork verification, which
          // deploys its own TripwireController (see Verify.s.sol).
  ```
  to:
  ```solidity
          // TripwireGuard's constructor reverts a bare InvalidController() on a zero-or-codeless
          // controller, which is opaque -- fail with something the operator can act on instead.
          // internalAddresses.json .protocol.tripwire.controller is the live controller; fork
          // verification (Verify.s.sol) uses the same address.
  ```

  Change:
  ```solidity
                  ". Track B cannot be BROADCAST until one exists. Deploying a controller is unscoped work. (yarn verify:migration is unaffected -- it deploys its own controller on the fork.)"
  ```
  to:
  ```solidity
                  ". Track B cannot be BROADCAST until one exists. Deploying a controller is unscoped work."
  ```

  Change:
  ```solidity
      /// inside this function -- so Verify.s.sol can pass the fork-fresh, uncommitted STRY mint and a
      /// fork-local TripwireController without ever writing to deploymentAddresses.json. The
      /// mainnet-broadcast pre-condition on Assumption 4 lives in run() above, not here.
  ```
  to:
  ```solidity
      /// inside this function -- so Verify.s.sol can pass the fork-fresh, uncommitted STRY mint
      /// without ever writing to deploymentAddresses.json. The controller-has-code pre-condition
      /// lives in run() above, not here.
  ```

- [ ] **Step 7: Run the fast checks**

  ```bash
  forge build
  yarn test
  forge fmt --check
  ```

  Expected: build succeeds; full unit suite green (`StryTokenTest` unchanged and passing); fmt prints nothing.

- [ ] **Step 8: Run the fork check — required**

  ```bash
  SNAPSHOT_BLOCK=26043909 yarn verify:migration
  ```

  Expected: `Script ran successfully.`; logs include `STRY distributed to included holders: 112` and `USDS transferred to StakedStrat: 33791207369120688986940` (~33,791 USDS per period, spec R8). If the RPC is unreachable, say so explicitly; do not treat Step 7 as sufficient.

- [ ] **Step 9: Fork smoke of `Distribute.run()` write-once behaviour (Review Focus 1). Nothing from this step is committed.**

  ```bash
  RPC="${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}"
  H=script/deployments/1/config/espn-holders-26043909.json
  HOLDERS_FILE=$H forge script script/deployments/1/004-stry-migration/Distribute.s.sol --fork-url "$RPC" --fork-block-number 26043909
  grep -n 'stry\|earn-airdrop-supply' script/deployments/1/config/deploymentAddresses.json
  HOLDERS_FILE=$H forge script script/deployments/1/004-stry-migration/Distribute.s.sol --fork-url "$RPC" --fork-block-number 26043909 2>&1 | grep '^Error'
  git checkout -- script/deployments/1/config/deploymentAddresses.json
  git status --porcelain script/deployments/1/config/deploymentAddresses.json
  ```

  Expected: first run succeeds and the file now holds a nonzero `.stry` and `"earn-airdrop-supply": "29366168308878694000555"` (a quoted string); the second run prints `Error: script failed: Distribute: airdrop supply already recorded; refusing to overwrite`; after `git checkout` the last command prints nothing. No `--broadcast` anywhere. If `git status --porcelain` shows `broadcast/` files, they are under the gitignored `dry-run/` path; leave them.

- [ ] **Step 10: Commit**

  ```bash
  git add script/deployments/1/004-stry-migration/Distribute.s.sol \
          script/deployments/1/004-stry-migration/Verify.s.sol \
          script/deployments/1/004-stry-migration/Deploy.s.sol \
          script/deployments/1/lib/SafeBatchLib.sol \
          script/deployments/1/config/deploymentAddresses.json
  git commit -m "feat(004-stry-migration): transfer earn ownership to the redemption safe

  Distribute now calls transferOwnership(redemption Safe) instead of renounceOwnership(),
  after requiring the Safe is a deployed contract (single-step Ownable: a wrong target is
  unrecoverable). It records the airdrop total once in .earn-airdrop-supply and refuses to
  run again once recorded, and requires that no excluded address received EARN.
  Verify.s.sol asserts owner == Safe, deploys sEARN against the live TripwireController,
  and proves a post-airdrop Safe mint leaves the yield amount unchanged. _executeBatch
  moves to SafeBatchLib.execute for reuse by the LP batch.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 5: vendored v4 math, minimal v4 interfaces, and the tick/liquidity derivation

**Files:**
- Create (vendored, byte-identical): `script/deployments/1/005-earn-lp/lib/{TickMath,FullMath,FixedPoint96,BitMath,CustomRevert,SafeCast,LiquidityAmounts}.sol`
- Modify: `remappings.txt` (one line), `foundry.toml` (fmt ignore)
- Create: `script/deployments/1/005-earn-lp/interfaces/IV4Minimal.sol`
- Create (TDD, test first): `test/unit/ProposeLpTest.sol`
- Create: `script/deployments/1/005-earn-lp/ProposeLp.s.sol` (math functions only; Task 6 replaces the whole file)

**Interfaces:**
- Consumes: OpenZeppelin `Math.sqrt(uint256) returns (uint256)` (floor).
- Produces, for Task 6:
  - `ProposeLp.deriveTicks(bool earnIsC0, uint256 basis, uint256 lo, uint256 hi, int24 s) internal pure returns (uint160 sqrtPriceX96, int24 currentTick, int24 bandLower, int24 bandUpper)`
  - `ProposeLp.deriveLiquidity(bool earnIsC0, uint160 sqrtPriceX96, int24 bandLower, int24 bandUpper, int24 s, uint256 fullRangeUsds, uint256 fullRangeEarn, uint256 singleSidedUsds) internal pure returns (uint128 liqFull, uint128 liqBand)`
  - `ProposeLp.floorToSpacing(int24 t, int24 s) internal pure returns (int24)`, `ProposeLp.ceilToSpacing(int24 t, int24 s) internal pure returns (int24)`
  - `IV4Minimal.sol`: `struct PoolKey`, `struct SwapParams`, `error MaximumAmountExceeded(uint128,uint128)`, `library Actions { MINT_POSITION = 0x02; SETTLE_PAIR = 0x0d }`, `interface IPositionManager`, `IPermit2`, `IStateView`, `IPoolManagerMinimal`.
  - Revert strings: `"ProposeLp: bid wall would hold EARN (case A)"`, `"ProposeLp: bid wall would hold EARN (case B)"`, `"ProposeLp: empty band after rounding"`.

- [ ] **Step 1: Download the seven library files at the pinned commits and check the hashes**

  ```bash
  L=script/deployments/1/005-earn-lp/lib
  mkdir -p $L
  CORE=https://raw.githubusercontent.com/Uniswap/v4-core/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries
  PERI=https://raw.githubusercontent.com/Uniswap/v4-periphery/9969eec44cfdf07e24b41de47f40276a58401976/src/libraries
  for f in TickMath FullMath FixedPoint96 BitMath CustomRevert SafeCast; do curl -fsS -o $L/$f.sol $CORE/$f.sol; done
  curl -fsS -o $L/LiquidityAmounts.sol $PERI/LiquidityAmounts.sol
  shasum -a 256 $L/*.sol
  grep -H "SPDX-License-Identifier" $L/*.sol
  ```

  Expected hashes (any mismatch: stop and report):
  ```
  e8a45eb3d57f9427fc47bbb2543c1a6a5f394113b378123ac7ca9f113a7502b4  BitMath.sol
  9d3dbe6b742cb1ac30f57df89d879ade9649389de1165fc637114bd062d39fca  CustomRevert.sol
  66ee26d4fb3ac639124bdfa27d3256d196970997fa127c09e9bf7154e30d4590  FixedPoint96.sol
  a9607255a6fd604d9c92f6b7416811c38b9d86e5dfdb0c345a494ebd35f7a4a3  FullMath.sol
  02d6eaaa62d45ac8170b3668e92a31808d2003b0f8eb821581cb4a028b175b45  LiquidityAmounts.sol
  c1a815a41607be5b4c86ca588a951f368156da8ee21bdfc18b5d51b58a0f27be  SafeCast.sol
  272d4f6d3ff9ae33596ebcdb84a71a3c2d4542ae8fb5c88ddf1aca8043f5d06b  TickMath.sol
  ```
  Every SPDX line must read `MIT` (compatible with the repo's GPL-2.0-or-later). Any `BUSL-1.1`: stop and ask the controller (spec N5).

- [ ] **Step 2: Resolve `LiquidityAmounts.sol`'s upstream import path and keep the files out of `forge fmt`**

  Append to `remappings.txt`:
  ```
  @uniswap/v4-core/src/libraries/=script/deployments/1/005-earn-lp/lib/
  ```

  In `foundry.toml`, change:
  ```toml
  [profile.default.fmt]
  wrap_comments = true
  ```
  to:
  ```toml
  [profile.default.fmt]
  wrap_comments = true
  # Vendored Uniswap v4 libraries, kept byte-identical to upstream.
  ignore = ["script/deployments/1/005-earn-lp/lib/*.sol"]
  ```

  Without the ignore, `forge fmt --check` reports diffs in `BitMath.sol`, `CustomRevert.sol`, `FullMath.sol` and `TickMath.sol`, and lint-staged would rewrite them on commit.

- [ ] **Step 3: Create `script/deployments/1/005-earn-lp/interfaces/IV4Minimal.sol`**

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  /// @notice Minimal Uniswap v4 surface used by 005-earn-lp. v4's `Currency`/`IHooks`/`PoolId` types
  /// are ABI-identical to `address`/`address`/`bytes32`, so selectors match the deployed contracts.
  /// Values copied from v4-core 46c6834 / v4-periphery 9969eec; the ProposeLp fork simulation fails
  /// on any mismatch.
  struct PoolKey {
      address currency0;
      address currency1;
      uint24 fee;
      int24 tickSpacing;
      address hooks;
  }

  /// @dev v4-core PoolOperation.sol SwapParams. Used only by 005-earn-lp/Verify.s.sol's swap check.
  struct SwapParams {
      bool zeroForOne;
      int256 amountSpecified;
      uint160 sqrtPriceLimitX96;
  }

  /// @dev v4-periphery SlippageCheck.sol. Raised when a mint needs more than amount0Max/amount1Max.
  error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);

  /// @dev v4-periphery Actions.sol.
  library Actions {
      uint256 internal constant MINT_POSITION = 0x02;
      uint256 internal constant SETTLE_PAIR = 0x0d;
  }

  interface IPositionManager {
      function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
      function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
      function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
      function ownerOf(uint256 id) external view returns (address);
      function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
      function poolManager() external view returns (address);
      function nextTokenId() external view returns (uint256);
      function permit2() external view returns (address);
  }

  interface IPermit2 {
      function approve(address token, address spender, uint160 amount, uint48 expiration) external;
      function allowance(address user, address token, address spender)
          external
          view
          returns (uint160 amount, uint48 expiration, uint48 nonce);
  }

  interface IStateView {
      function getSlot0(bytes32 poolId)
          external
          view
          returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
      function poolManager() external view returns (address);
  }

  /// @dev Used only by 005-earn-lp/Verify.s.sol's swap check. swap() returns a packed BalanceDelta:
  /// amount0 in the upper 128 bits, amount1 in the lower 128 bits.
  interface IPoolManagerMinimal {
      function unlock(bytes calldata data) external returns (bytes memory);
      function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
      function sync(address currency) external;
      function settle() external payable returns (uint256);
      function take(address currency, address to, uint256 amount) external;
  }
  ```

- [ ] **Step 4: Write the failing test file `test/unit/ProposeLpTest.sol`**

  Reference values were computed with the pinned libraries (spec section 6 table; `liqFull` corrected per Deviation 3).

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import {Test} from "forge-std/Test.sol";
  import {ProposeLp} from "../../script/deployments/1/005-earn-lp/ProposeLp.s.sol";

  /// @dev deriveTicks/deriveLiquidity/floorToSpacing/ceilToSpacing are `internal` on the ProposeLp
  /// Script contract; this harness re-exports them as `external`. Same pattern as PeriodicYieldTest.
  contract ProposeLpHarness is ProposeLp {
      function exposedDeriveTicks(bool earnIsC0, uint256 basis, uint256 lo, uint256 hi, int24 s)
          external
          pure
          returns (uint160, int24, int24, int24)
      {
          return deriveTicks(earnIsC0, basis, lo, hi, s);
      }

      function exposedDeriveLiquidity(bool earnIsC0, uint160 sqrtPriceX96, int24 bandLower, int24 bandUpper, int24 s)
          external
          pure
          returns (uint128, uint128)
      {
          return deriveLiquidity(earnIsC0, sqrtPriceX96, bandLower, bandUpper, s, 250_000e18, 2_500e18, 250_000e18);
      }

      function exposedFloor(int24 t, int24 s) external pure returns (int24) {
          return floorToSpacing(t, s);
      }

      function exposedCeil(int24 t, int24 s) external pure returns (int24) {
          return ceilToSpacing(t, s);
      }
  }

  contract ProposeLpTest is Test {
      ProposeLpHarness internal harness;

      function setUp() public {
          harness = new ProposeLpHarness();
      }

      // Spec section 6 reference table, B = Hi = 100, Lo = 50, s = 60.

      function test_deriveTicks_caseA_referenceTable() public view {
          (uint160 sqrtP, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(true, 100, 50, 100, 60);
          assertEq(sqrtP, 792281625142643375935439503360);
          assertEq(tick, 46054);
          assertEq(lower, 39120);
          assertEq(upper, 46020);
      }

      function test_deriveTicks_caseB_referenceTable() public view {
          (uint160 sqrtP, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(false, 100, 50, 100, 60);
          assertEq(sqrtP, 7922816251426433759354395033);
          assertEq(tick, -46055);
          assertEq(lower, -46020);
          assertEq(upper, -39120);
      }

      // Equality case (spec V3): with s = 1 every tick is a spacing multiple, so the near band edge
      // lands exactly on currentTick. Case A keeps it (currentTick >= upper is still USDS-only);
      // Case B must move it up one spacing (currentTick == lower would be in range).

      function test_deriveTicks_caseA_upperEqualsCurrentTickStays() public view {
          (, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(true, 100, 50, 100, 1);
          assertEq(tick, 46054);
          assertEq(upper, 46054);
          assertEq(lower, 39122);
      }

      function test_deriveTicks_caseB_lowerEqualsCurrentTickMovesUp() public view {
          (, int24 tick, int24 lower, int24 upper) = harness.exposedDeriveTicks(false, 100, 50, 100, 1);
          assertEq(tick, -46055);
          assertEq(lower, -46054);
          assertEq(upper, -39123);
      }

      // Hi < B (spec N4): the same rounding rule covers it; no extra spacing is added.

      function test_deriveTicks_bandUpperBelowBasis() public view {
          (,, int24 lowerA, int24 upperA) = harness.exposedDeriveTicks(true, 100, 50, 90, 60);
          assertEq(lowerA, 39120);
          assertEq(upperA, 45000);
          (,, int24 lowerB, int24 upperB) = harness.exposedDeriveTicks(false, 100, 50, 90, 60);
          assertEq(lowerB, -45000);
          assertEq(upperB, -39120);
      }

      // A band above the pool price would hold EARN. buildBatch rejects Hi > B first; this pins
      // deriveTicks' own guard for both orderings.

      function test_deriveTicks_caseA_revertsWhenBandAbovePrice() public {
          vm.expectRevert(bytes("ProposeLp: bid wall would hold EARN (case A)"));
          harness.exposedDeriveTicks(true, 100, 50, 200, 60);
      }

      function test_deriveTicks_caseB_revertsWhenBandAbovePrice() public {
          vm.expectRevert(bytes("ProposeLp: bid wall would hold EARN (case B)"));
          harness.exposedDeriveTicks(false, 100, 50, 200, 60);
      }

      // Liquidity: both orderings give the same values, and the amounts they settle are <= the
      // configured amounts (checked by the fork runs; values here pin the math).

      function test_deriveLiquidity_bothCases() public view {
          (uint160 sqrtA,, int24 lowerA, int24 upperA) = harness.exposedDeriveTicks(true, 100, 50, 100, 60);
          (uint128 fullA, uint128 bandA) = harness.exposedDeriveLiquidity(true, sqrtA, lowerA, upperA, 60);
          (uint160 sqrtB,, int24 lowerB, int24 upperB) = harness.exposedDeriveTicks(false, 100, 50, 100, 60);
          (uint128 fullB, uint128 bandB) = harness.exposedDeriveLiquidity(false, sqrtB, lowerB, upperB, 60);
          assertEq(fullA, 25_000e18 + 135);
          assertEq(fullB, 25_000e18 + 135);
          assertEq(bandA, 85_830_483_191_952_473_195_169);
          assertEq(bandB, 85_830_483_191_952_473_195_169);
      }

      // Sign handling (spec N3): Solidity `/` truncates toward zero.

      function test_floorToSpacing_signs() public view {
          assertEq(harness.exposedFloor(61, 60), 60);
          assertEq(harness.exposedFloor(60, 60), 60);
          assertEq(harness.exposedFloor(0, 60), 0);
          assertEq(harness.exposedFloor(-1, 60), -60);
          assertEq(harness.exposedFloor(-60, 60), -60);
          assertEq(harness.exposedFloor(-61, 60), -120);
      }

      function test_ceilToSpacing_signs() public view {
          assertEq(harness.exposedCeil(61, 60), 120);
          assertEq(harness.exposedCeil(60, 60), 60);
          assertEq(harness.exposedCeil(0, 60), 0);
          assertEq(harness.exposedCeil(-1, 60), 0);
          assertEq(harness.exposedCeil(-60, 60), -60);
          assertEq(harness.exposedCeil(-61, 60), -60);
      }
  }
  ```

- [ ] **Step 5: Run the tests to verify they fail**

  ```bash
  forge test --match-path test/unit/ProposeLpTest.sol
  ```

  Expected: compile error, `Source "script/deployments/1/005-earn-lp/ProposeLp.s.sol" not found`.

- [ ] **Step 6: Create `script/deployments/1/005-earn-lp/ProposeLp.s.sol` with the math functions only**

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
  import {TickMath} from "./lib/TickMath.sol";
  import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";

  /// @notice EARN/USDS v4 LP batch builder. This task adds the pure tick and liquidity math only;
  /// buildBatch, the fork simulation and run() land in the next task.
  contract ProposeLp is Script {
      /// @dev Spec section 6. Case A: EARN is currency0, pool price = USDS per EARN, the bid wall
      /// holds currency1 and needs currentTick >= bandUpper. Case B: USDS is currency0, pool price =
      /// EARN per USDS, the bid wall holds currency0 and needs currentTick < bandLower (strict). The
      /// band edge nearest the pool price rounds away from it; the far edge rounds outward. No log
      /// in Solidity: every tick comes from TickMath.getTickAtSqrtPrice on an integer sqrt.
      function deriveTicks(bool earnIsC0, uint256 basis, uint256 lo, uint256 hi, int24 s)
          internal
          pure
          returns (uint160 sqrtPriceX96, int24 currentTick, int24 bandLower, int24 bandUpper)
      {
          if (earnIsC0) {
              sqrtPriceX96 = uint160(Math.sqrt(basis << 192));
              currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
              bandLower = floorToSpacing(_tickAtPriceX192(lo << 192), s);
              bandUpper = floorToSpacing(_tickAtPriceX192(hi << 192), s);
              require(currentTick >= bandUpper, "ProposeLp: bid wall would hold EARN (case A)");
          } else {
              sqrtPriceX96 = uint160(Math.sqrt((uint256(1) << 192) / basis));
              currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
              bandLower = ceilToSpacing(_tickAtPriceX192((uint256(1) << 192) / hi), s);
              if (bandLower <= currentTick) bandLower += s;
              bandUpper = ceilToSpacing(_tickAtPriceX192((uint256(1) << 192) / lo), s);
              require(currentTick < bandLower, "ProposeLp: bid wall would hold EARN (case B)");
          }
          require(bandLower < bandUpper, "ProposeLp: empty band after rounding");
      }

      /// @dev getLiquidityForAmount* round liquidity down, so the settled amounts never exceed the
      /// configured ones (spec S2). If the simulation ever shows a 1-wei round-up revert, the fix is
      /// liquidity -= 1, not a larger amountMax.
      function deriveLiquidity(
          bool earnIsC0,
          uint160 sqrtPriceX96,
          int24 bandLower,
          int24 bandUpper,
          int24 s,
          uint256 fullRangeUsds,
          uint256 fullRangeEarn,
          uint256 singleSidedUsds
      ) internal pure returns (uint128 liqFull, uint128 liqBand) {
          (uint256 amount0, uint256 amount1) = earnIsC0 ? (fullRangeEarn, fullRangeUsds) : (fullRangeUsds, fullRangeEarn);
          liqFull = LiquidityAmounts.getLiquidityForAmounts(
              sqrtPriceX96,
              TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(s)),
              TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(s)),
              amount0,
              amount1
          );
          uint160 sqrtLower = TickMath.getSqrtPriceAtTick(bandLower);
          uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(bandUpper);
          liqBand = earnIsC0
              ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, singleSidedUsds)
              : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, singleSidedUsds);
      }

      /// @dev Solidity `/` truncates toward zero, so a plain t / s * s is a ceiling for negative t.
      function floorToSpacing(int24 t, int24 s) internal pure returns (int24) {
          int24 q = t / s;
          if (t % s != 0 && t < 0) q--;
          return q * s;
      }

      function ceilToSpacing(int24 t, int24 s) internal pure returns (int24) {
          int24 q = t / s;
          if (t % s != 0 && t > 0) q++;
          return q * s;
      }

      function _tickAtPriceX192(uint256 priceX192) private pure returns (int24) {
          return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(priceX192)));
      }
  }
  ```

- [ ] **Step 7: Run the tests to verify they pass**

  ```bash
  forge build
  forge test --match-path test/unit/ProposeLpTest.sol -vv
  yarn test
  forge fmt --check
  ```

  Expected: all 10 `ProposeLpTest` tests pass; full suite green; fmt prints nothing.

- [ ] **Step 8: Commit**

  ```bash
  git add remappings.txt foundry.toml \
          script/deployments/1/005-earn-lp/lib \
          script/deployments/1/005-earn-lp/interfaces/IV4Minimal.sol \
          script/deployments/1/005-earn-lp/ProposeLp.s.sol \
          test/unit/ProposeLpTest.sol
  git commit -m "feat(005-earn-lp): add v4 tick and liquidity math for the earn lp

  Vendors TickMath, LiquidityAmounts and their imports (MIT) byte-identical from
  v4-core 46c6834 / v4-periphery 9969eec, with a remapping for the upstream import path
  and a forge fmt ignore. Adds minimal v4 interfaces and the pure derivation of
  sqrtPriceX96, the bid-wall ticks for both currency orderings (incl. the equality
  case) and position liquidity, pinned by unit tests against the spec's reference table.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 6: ProposeLp batch + pre-write simulation, 005 Verify, `verify:lp`

**Files:**
- Replace (whole file): `script/deployments/1/005-earn-lp/ProposeLp.s.sol`
- Create: `script/deployments/1/005-earn-lp/Verify.s.sol`
- Modify: `package.json` (add `verify:lp`)

**Interfaces:**
- Consumes: Task 2 config keys; `SafeBatchLib.execute` and `Distribute.distribute` (Task 4); `PeriodicYield.periodicYieldAmount(uint256)` (Task 3); `deriveTicks`, `deriveLiquidity`, `IV4Minimal.sol` (Task 5).
- Produces:
  - `ProposeLp.LpPlan` struct (fields: `safe, earn, usds, poolManager, posm, permit2, stateView, earnIsC0, key, poolId, sqrtPriceX96, currentTick, fullLower, fullUpper, bandLower, bandUpper, liqFull, liqBand, fullRangeUsds, fullRangeEarn, singleSidedUsds`).
  - `ProposeLp.buildBatch(address earn) internal view returns (SafeBatchLib.Tx[] memory txs, LpPlan memory p)` — every preflight require; reverts `"ProposeLp: pool already initialized"` when `slot0.sqrtPriceX96 != 0`.
  - `ProposeLp._simulateAndCheck(LpPlan memory p, SafeBatchLib.Tx[] memory txs) internal` — executes as the Safe, requires spec V2 steps 6–12.
  - `ProposeLp.run()` — refuses if `multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json` exists; writes it only after `_simulateAndCheck` passes.
  - `yarn verify:lp`.

- [ ] **Step 1: Add `verify:lp` to `package.json`** (after `verify:migration`):

  ```json
      "verify:lp": "forge script script/deployments/1/005-earn-lp/Verify.s.sol --tc Verify --fork-url ${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat} --fork-block-number ${SNAPSHOT_BLOCK:?Set SNAPSHOT_BLOCK to the block encoded in the espn-holders snapshot filename} -vvv",
  ```

- [ ] **Step 2: Create `script/deployments/1/005-earn-lp/Verify.s.sol` (the fork test, written before the code it exercises)**

  Covers spec V2 steps 1–15 and S7. `_simulateAndCheck` (Step 4) carries steps 5–12.

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {StdCheats} from "forge-std/StdCheats.sol";
  import {StdAssertions} from "forge-std/StdAssertions.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {StryToken} from "src/StryToken.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
  import {Distribute} from "../004-stry-migration/Distribute.s.sol";
  import {PeriodicYield} from "../004-stry-migration/PeriodicYield.s.sol";
  import {ProposeLp} from "./ProposeLp.s.sol";
  import {TickMath} from "./lib/TickMath.sol";
  import {PoolKey, SwapParams, MaximumAmountExceeded, IPoolManagerMinimal} from "./interfaces/IV4Minimal.sol";

  /// @notice Exact-input swap through the v4 PoolManager for the informational swap check (spec V2
  /// step 15). Replaces v4-core's PoolSwapTest, whose transitive imports are far larger than this.
  contract V4SwapSanity {
      IPoolManagerMinimal internal immutable pm;

      constructor(address poolManager) {
          pm = IPoolManagerMinimal(poolManager);
      }

      function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256) {
          return abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender)), (uint256));
      }

      function unlockCallback(bytes calldata data) external returns (bytes memory) {
          require(msg.sender == address(pm), "V4SwapSanity: not PoolManager");
          (PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
              abi.decode(data, (PoolKey, bool, uint256, address));
          int256 delta = pm.swap(
              key,
              SwapParams({
                  zeroForOne: zeroForOne,
                  amountSpecified: -int256(amountIn),
                  sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
              }),
              ""
          );
          (address tokenIn, address tokenOut) =
              zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
          uint256 amountOut = uint256(int256(zeroForOne ? int128(delta) : int128(delta >> 128)));
          pm.sync(tokenIn);
          IERC20(tokenIn).transferFrom(payer, address(pm), amountIn);
          pm.settle();
          pm.take(tokenOut, payer, amountOut);
          return abi.encode(amountOut);
      }
  }

  /// @notice External entry to ProposeLp.buildBatch so Verify can try/catch it. forge forbids a script
  /// calling itself through `this`.
  contract BuildBatchProbe is ProposeLp {
      function probe(address earn) external view {
          buildBatch(earn);
      }
  }

  /// @notice 005-earn-lp mainnet-fork Verify (spec V2). Deploys EARN on the fork via Distribute's
  /// internal distribute(), builds the LP batch with ProposeLp.buildBatch, and executes it as the Safe.
  /// Writes no file. Both currency orderings run on every invocation via deployCodeTo (spec S7).
  contract Verify is Script, StdCheats, StdAssertions, ProposeLp, Distribute, PeriodicYield {
      function run() external override(ProposeLp, Distribute, PeriodicYield) {
          uint256 snapshotBlockTarget = vm.envUint("SNAPSHOT_BLOCK");
          string memory holdersFile =
              string.concat("script/deployments/1/config/espn-holders-", vm.toString(snapshotBlockTarget), ".json");
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
          uint256 totalUsds =
              ConfigLib.num("settings.json", ".lp.fullRangeUsds") + ConfigLib.num("settings.json", ".lp.singleSidedUsds");

          // Step 1: EARN on the fork. distribute() requires the excluded-holder zero balances (D23)
          // before anything below runs.
          address deployer = makeAddr("earnDeployer");
          vm.startPrank(deployer);
          StryToken earn = distribute(deployer, holdersFile);
          vm.stopPrank();
          uint256 airdropSupply = earn.totalSupply();
          uint256 yieldBefore = periodicYieldAmount(airdropSupply);

          // Step 2: the mainnet preflight is a hard require; the fork tops up and says so.
          if (IERC20(usds).balanceOf(safe) < totalUsds) {
              console2.log("WARNING: Safe USDS below the LP total at this fork block; dealing the shortfall.");
              deal(usds, safe, totalUsds);
          }

          // S7: both currency orderings, each on a state snapshot. USDS is 0xdC03..., so the low
          // address is Case A (EARN = currency0) and the high one Case B.
          _checkOrderingAt(address(0x10000), true);
          _checkOrderingAt(address(type(uint160).max - 0xffff), false);

          // Step 3.
          (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildBatch(address(earn));
          assertEq(txs.length, 6, "Verify: batch is not 6 txs");
          assertEq(txs[0].to, address(earn), "Verify: tx 1 is not to EARN");
          assertEq(bytes4(txs[0].data), StryToken.mintBatch.selector, "Verify: tx 1 is not mintBatch");
          // Step 4.
          (uint160 priceBefore,,,) = p.stateView.getSlot0(p.poolId);
          assertEq(priceBefore, 0, "Verify: pool initialized before the batch");

          // Step 14 (S1): a squatter initializes the key at 2x and at 0.5x the intended price; the
          // batch must revert on amountMax and mint nothing.
          _assertSquatReverts(p, txs, uint160(uint256(p.sqrtPriceX96) * 1414213562 / 1e9));
          _assertSquatReverts(p, txs, uint160(uint256(p.sqrtPriceX96) * 1e9 / 1414213562));

          // Steps 5-12.
          _simulateAndCheck(p, txs);
          assertEq(earn.totalSupply(), airdropSupply + p.fullRangeEarn, "Verify: supply != airdrop + LP EARN");
          assertEq(periodicYieldAmount(airdropSupply), yieldBefore, "Verify: LP mint moved the yield amount");

          // Step 13: buildBatch refuses an initialized pool.
          BuildBatchProbe probe = new BuildBatchProbe();
          try probe.probe(address(earn)) {
              revert("Verify: buildBatch did not refuse an initialized pool");
          } catch Error(string memory reason) {
              assertEq(reason, "ProposeLp: pool already initialized");
          }

          // Step 15: swap sanity, informational.
          _swapSanity(p);

          console2.log(p.earnIsC0 ? "Fork EARN hit Case A" : "Fork EARN hit Case B");
      }

      function _checkOrderingAt(address where, bool expectEarnIsC0) internal {
          uint256 snap = vm.snapshotState();
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          deployCodeTo("StryToken.sol:StryToken", abi.encode(safe), where);
          (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildBatch(where);
          assertEq(p.earnIsC0, expectEarnIsC0, "Verify: unexpected currency ordering");
          assertEq(txs.length, 6, "Verify: batch is not 6 txs");
          _simulateAndCheck(p, txs);
          console2.log(expectEarnIsC0 ? "Case A ordering passed at" : "Case B ordering passed at", where);
          vm.revertToState(snap);
      }

      function _assertSquatReverts(LpPlan memory p, SafeBatchLib.Tx[] memory txs, uint160 wrongSqrtPriceX96) internal {
          uint256 snap = vm.snapshotState();
          uint256 nextId = p.posm.nextTokenId();
          address squatter = makeAddr("squatter");
          vm.prank(squatter);
          p.posm.initializePool(p.key, wrongSqrtPriceX96);

          // Txs 1-5 succeed; tx 6 must revert. In the real MultiSend that reverts the whole batch.
          SafeBatchLib.Tx[] memory firstFive = new SafeBatchLib.Tx[](5);
          for (uint256 i; i < 5; ++i) {
              firstFive[i] = txs[i];
          }
          SafeBatchLib.execute(p.safe, firstFive);
          vm.prank(p.safe);
          (bool ok, bytes memory ret) = txs[5].to.call(txs[5].data);
          assertFalse(ok, "Verify: batch succeeded against a squatted pool");
          assertEq(bytes4(ret), MaximumAmountExceeded.selector, "Verify: squat revert is not MaximumAmountExceeded");
          try p.posm.ownerOf(nextId) returns (address) {
              revert("Verify: a position was minted against a squatted pool");
          } catch {}
          vm.revertToState(snap);
      }

      function _swapSanity(LpPlan memory p) internal {
          address trader = makeAddr("trader");
          deal(p.usds, trader, 1_000e18);
          V4SwapSanity swapper = new V4SwapSanity(p.poolManager);
          bool zeroForOne = !p.earnIsC0; // USDS in
          vm.startPrank(trader);
          IERC20(p.usds).approve(address(swapper), 1_000e18);
          uint256 earnOut = swapper.swapExactIn(p.key, zeroForOne, 1_000e18);
          vm.stopPrank();

          (,, uint24 protocolFee, uint24 lpFee) = p.stateView.getSlot0(p.poolId);
          // v4 ProtocolFeeLibrary: lower 12 bits = zeroForOne fee, upper 12 bits = oneForZero fee,
          // combined swap fee = pf + lpFee - pf * lpFee / 1e6 (pips).
          uint256 pf = zeroForOne ? protocolFee & 0xfff : protocolFee >> 12;
          uint256 swapFee = pf + lpFee - pf * lpFee / 1e6;
          uint256 expected = 1_000e18 * p.fullRangeEarn / p.fullRangeUsds * (1e6 - swapFee) / 1e6;
          console2.log("swap: protocolFee / lpFee / EARN out:", protocolFee, lpFee, earnOut);
          assertApproxEqRel(earnOut, expected, 0.01e18, "Verify: swap output off by more than 1%");
      }
  }
  ```

- [ ] **Step 3: Run the build to verify it fails**

  ```bash
  forge build
  ```

  Expected: compile errors — `buildBatch`, `LpPlan` and `_simulateAndCheck` are not defined on `ProposeLp`.

- [ ] **Step 4: Replace `script/deployments/1/005-earn-lp/ProposeLp.s.sol` with the complete file below**

  Adds `LpPlan`, `run()`, `buildBatch` (all preflight requires, spec N1), `_txs` (the 6-tx batch, spec section 5), `_simulateAndCheck` and `_log`. The math functions are unchanged from Task 5.

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
  import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
  import {StryToken} from "src/StryToken.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
  import {TickMath} from "./lib/TickMath.sol";
  import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";
  import {PoolKey, Actions, IPositionManager, IPermit2, IStateView} from "./interfaces/IV4Minimal.sol";

  /// @notice Builds the 6-tx redemption-Safe batch that mints the 2,500 LP EARN, initializes the
  /// EARN/USDS v4 pool at basisPriceUsd, and mints a full-range position plus a USDS-only bid wall.
  /// Never broadcasts. Run with --fork-url mainnet: run() executes the exact batch as the Safe on the
  /// latest-block fork and asserts the outcome before it writes the file (spec B1).
  contract ProposeLp is Script {
      /// @dev 1e-6 of a token. Rounding leaves at most a few wei per position.
      uint256 internal constant DUST = 1e12;

      struct LpPlan {
          address safe;
          address earn;
          address usds;
          address poolManager;
          IPositionManager posm;
          address permit2;
          IStateView stateView;
          bool earnIsC0;
          PoolKey key;
          bytes32 poolId;
          uint160 sqrtPriceX96;
          int24 currentTick;
          int24 fullLower;
          int24 fullUpper;
          int24 bandLower;
          int24 bandUpper;
          uint128 liqFull;
          uint128 liqBand;
          uint256 fullRangeUsds;
          uint256 fullRangeEarn;
          uint256 singleSidedUsds;
      }

      function run() external virtual {
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          address earn = ConfigLib.addr("deploymentAddresses.json", ".stry");
          require(
              !vm.exists(SafeBatchLib.path(safe, "005-earn-lp", 1)),
              "ProposeLp: batch 001 already exists; delete it deliberately to regenerate"
          );
          require(earn.code.length > 0, "ProposeLp: .stry has no code -- run Distribute.s.sol first");

          (SafeBatchLib.Tx[] memory txs, LpPlan memory p) = buildBatch(earn);
          _simulateAndCheck(p, txs);

          SafeBatchLib.write(
              safe,
              "005-earn-lp",
              1,
              "EARN/USDS V4 LP",
              "Mints 2,500 EARN to this Safe, approves USDS and EARN to Permit2 and PositionManager, initializes the EARN/USDS v4 pool at 100 USDS per EARN, and mints a full-range position plus a 50-100 USDS/EARN bid wall owned by this Safe. Execute the transactions in the order listed.",
              txs
          );
          console2.log("Simulation passed; batch written:", SafeBatchLib.path(safe, "005-earn-lp", 1));
      }

      /// @dev Every preflight require lives here (spec N1), so nothing is simulated or written on a
      /// bad config or state. Reads config; `earn` is the only argument so Verify.s.sol can point it
      /// at a fork-local EARN.
      function buildBatch(address earn) internal view returns (SafeBatchLib.Tx[] memory txs, LpPlan memory p) {
          p.safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          p.earn = earn;
          p.usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
          p.poolManager = ConfigLib.addr("externalAddresses.json", ".uniswap-v4.poolManager");
          p.posm = IPositionManager(ConfigLib.addr("externalAddresses.json", ".uniswap-v4.positionManager"));
          p.permit2 = ConfigLib.addr("externalAddresses.json", ".uniswap-v4.permit2");
          p.stateView = IStateView(ConfigLib.addr("externalAddresses.json", ".uniswap-v4.stateView"));

          uint256 basis = ConfigLib.num("settings.json", ".espnv3.basisPriceUsd");
          uint256 lo = ConfigLib.num("settings.json", ".lp.bandLowerUsd");
          uint256 hi = ConfigLib.num("settings.json", ".lp.bandUpperUsd");
          uint256 fee = ConfigLib.num("settings.json", ".lp.fee");
          uint256 spacing = ConfigLib.num("settings.json", ".lp.tickSpacing");
          p.fullRangeUsds = ConfigLib.num("settings.json", ".lp.fullRangeUsds");
          p.singleSidedUsds = ConfigLib.num("settings.json", ".lp.singleSidedUsds");

          require(basis > 0 && p.fullRangeUsds % basis == 0, "ProposeLp: fullRangeUsds not a multiple of basisPriceUsd");
          require(lo > 0 && lo < hi && hi <= basis, "ProposeLp: need 0 < bandLowerUsd < bandUpperUsd <= basisPriceUsd");
          require(fee > 0 && fee < 1_000_000, "ProposeLp: bad lp.fee");
          require(spacing > 0 && spacing <= 32767, "ProposeLp: bad lp.tickSpacing");
          p.fullRangeEarn = p.fullRangeUsds / basis;

          require(
              IERC20Metadata(earn).decimals() == 18 && IERC20Metadata(p.usds).decimals() == 18,
              "ProposeLp: EARN and USDS must both have 18 decimals"
          );
          require(p.posm.poolManager() == p.poolManager, "ProposeLp: PositionManager.poolManager() mismatch");
          require(p.stateView.poolManager() == p.poolManager, "ProposeLp: StateView.poolManager() mismatch");
          require(p.posm.permit2() == p.permit2, "ProposeLp: PositionManager.permit2() mismatch");

          p.earnIsC0 = earn < p.usds;
          p.key = PoolKey({
              currency0: p.earnIsC0 ? earn : p.usds,
              currency1: p.earnIsC0 ? p.usds : earn,
              fee: uint24(fee),
              tickSpacing: int24(int256(spacing)),
              hooks: address(0)
          });
          p.poolId = keccak256(abi.encode(p.key));
          (uint160 livePrice,,,) = p.stateView.getSlot0(p.poolId);
          require(livePrice == 0, "ProposeLp: pool already initialized");

          require(StryToken(earn).owner() == p.safe, "ProposeLp: EARN.owner() != redemption Safe");
          require(
              IERC20(p.usds).balanceOf(p.safe) >= p.fullRangeUsds + p.singleSidedUsds,
              "ProposeLp: Safe USDS balance < fullRangeUsds + singleSidedUsds"
          );

          (p.sqrtPriceX96, p.currentTick, p.bandLower, p.bandUpper) =
              deriveTicks(p.earnIsC0, basis, lo, hi, p.key.tickSpacing);
          p.fullLower = TickMath.minUsableTick(p.key.tickSpacing);
          p.fullUpper = TickMath.maxUsableTick(p.key.tickSpacing);
          (p.liqFull, p.liqBand) = deriveLiquidity(
              p.earnIsC0,
              p.sqrtPriceX96,
              p.bandLower,
              p.bandUpper,
              p.key.tickSpacing,
              p.fullRangeUsds,
              p.fullRangeEarn,
              p.singleSidedUsds
          );

          txs = _txs(p);
          _log(p, txs);
      }

      function _txs(LpPlan memory p) private pure returns (SafeBatchLib.Tx[] memory txs) {
          uint256 totalUsds = p.fullRangeUsds + p.singleSidedUsds;
          address[] memory to = new address[](1);
          to[0] = p.safe;
          uint256[] memory amounts = new uint256[](1);
          amounts[0] = p.fullRangeEarn;

          // amountMax = the configured amount per currency, 0 for the currency a position must not
          // take. It is also the price guard: at any pool price other than the intended one, the
          // full-range position's fixed liquidity needs more than its max of one currency and the
          // whole batch reverts MaximumAmountExceeded (spec R6).
          (uint128 full0, uint128 full1) = p.earnIsC0
              ? (uint128(p.fullRangeEarn), uint128(p.fullRangeUsds))
              : (uint128(p.fullRangeUsds), uint128(p.fullRangeEarn));
          (uint128 band0, uint128 band1) =
              p.earnIsC0 ? (uint128(0), uint128(p.singleSidedUsds)) : (uint128(p.singleSidedUsds), uint128(0));

          bytes[] memory params = new bytes[](3);
          params[0] = abi.encode(p.key, p.fullLower, p.fullUpper, uint256(p.liqFull), full0, full1, p.safe, bytes(""));
          params[1] = abi.encode(p.key, p.bandLower, p.bandUpper, uint256(p.liqBand), band0, band1, p.safe, bytes(""));
          params[2] = abi.encode(p.key.currency0, p.key.currency1);
          bytes memory actions =
              abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

          bytes[] memory calls = new bytes[](2);
          calls[0] = abi.encodeCall(IPositionManager.initializePool, (p.key, p.sqrtPriceX96));
          // deadline max: calldata is generated before signing and can sit in the Safe queue.
          calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), type(uint256).max));

          txs = new SafeBatchLib.Tx[](6);
          txs[0] = SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(StryToken.mintBatch, (to, amounts))});
          txs[1] = SafeBatchLib.Tx({to: p.usds, data: abi.encodeCall(IERC20.approve, (p.permit2, totalUsds))});
          txs[2] = SafeBatchLib.Tx({to: p.earn, data: abi.encodeCall(IERC20.approve, (p.permit2, p.fullRangeEarn))});
          // expiration max for the same queue reason; Permit2 decrements the amount on spend.
          txs[3] = SafeBatchLib.Tx({
              to: p.permit2,
              data: abi.encodeCall(IPermit2.approve, (p.usds, address(p.posm), uint160(totalUsds), type(uint48).max))
          });
          txs[4] = SafeBatchLib.Tx({
              to: p.permit2,
              data: abi.encodeCall(
                  IPermit2.approve, (p.earn, address(p.posm), uint160(p.fullRangeEarn), type(uint48).max)
              )
          });
          txs[5] = SafeBatchLib.Tx({to: address(p.posm), data: abi.encodeCall(IPositionManager.multicall, (calls))});
      }

      /// @dev Spec section 6. Case A: EARN is currency0, pool price = USDS per EARN, the bid wall
      /// holds currency1 and needs currentTick >= bandUpper. Case B: USDS is currency0, pool price =
      /// EARN per USDS, the bid wall holds currency0 and needs currentTick < bandLower (strict). The
      /// band edge nearest the pool price rounds away from it; the far edge rounds outward. No log
      /// in Solidity: every tick comes from TickMath.getTickAtSqrtPrice on an integer sqrt.
      function deriveTicks(bool earnIsC0, uint256 basis, uint256 lo, uint256 hi, int24 s)
          internal
          pure
          returns (uint160 sqrtPriceX96, int24 currentTick, int24 bandLower, int24 bandUpper)
      {
          if (earnIsC0) {
              sqrtPriceX96 = uint160(Math.sqrt(basis << 192));
              currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
              bandLower = floorToSpacing(_tickAtPriceX192(lo << 192), s);
              bandUpper = floorToSpacing(_tickAtPriceX192(hi << 192), s);
              require(currentTick >= bandUpper, "ProposeLp: bid wall would hold EARN (case A)");
          } else {
              sqrtPriceX96 = uint160(Math.sqrt((uint256(1) << 192) / basis));
              currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
              bandLower = ceilToSpacing(_tickAtPriceX192((uint256(1) << 192) / hi), s);
              if (bandLower <= currentTick) bandLower += s;
              bandUpper = ceilToSpacing(_tickAtPriceX192((uint256(1) << 192) / lo), s);
              require(currentTick < bandLower, "ProposeLp: bid wall would hold EARN (case B)");
          }
          require(bandLower < bandUpper, "ProposeLp: empty band after rounding");
      }

      /// @dev getLiquidityForAmount* round liquidity down, so the settled amounts never exceed the
      /// configured ones (spec S2). If the simulation ever shows a 1-wei round-up revert, the fix is
      /// liquidity -= 1, not a larger amountMax.
      function deriveLiquidity(
          bool earnIsC0,
          uint160 sqrtPriceX96,
          int24 bandLower,
          int24 bandUpper,
          int24 s,
          uint256 fullRangeUsds,
          uint256 fullRangeEarn,
          uint256 singleSidedUsds
      ) internal pure returns (uint128 liqFull, uint128 liqBand) {
          (uint256 amount0, uint256 amount1) = earnIsC0 ? (fullRangeEarn, fullRangeUsds) : (fullRangeUsds, fullRangeEarn);
          liqFull = LiquidityAmounts.getLiquidityForAmounts(
              sqrtPriceX96,
              TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(s)),
              TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(s)),
              amount0,
              amount1
          );
          uint160 sqrtLower = TickMath.getSqrtPriceAtTick(bandLower);
          uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(bandUpper);
          liqBand = earnIsC0
              ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, singleSidedUsds)
              : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, singleSidedUsds);
      }

      /// @dev Solidity `/` truncates toward zero, so a plain t / s * s is a ceiling for negative t.
      function floorToSpacing(int24 t, int24 s) internal pure returns (int24) {
          int24 q = t / s;
          if (t % s != 0 && t < 0) q--;
          return q * s;
      }

      function ceilToSpacing(int24 t, int24 s) internal pure returns (int24) {
          int24 q = t / s;
          if (t % s != 0 && t > 0) q++;
          return q * s;
      }

      function _tickAtPriceX192(uint256 priceX192) private pure returns (int24) {
          return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(priceX192)));
      }

      /// @dev Executes `txs` as the Safe on the current fork and requires the end state (spec V2 steps
      /// 6-12). Used by run() on the latest-block fork before writing, and by Verify.s.sol.
      function _simulateAndCheck(LpPlan memory p, SafeBatchLib.Tx[] memory txs) internal {
          StryToken earn = StryToken(p.earn);
          uint256 supplyBefore = earn.totalSupply();
          uint256 usdsBefore = IERC20(p.usds).balanceOf(p.safe);
          uint256 earnBefore = earn.balanceOf(p.safe);
          uint256 tokenId = p.posm.nextTokenId();

          uint256 gasBefore = gasleft();
          SafeBatchLib.execute(p.safe, txs);
          console2.log("LP batch execution gas:", gasBefore - gasleft());

          require(
              earn.totalSupply() == supplyBefore + p.fullRangeEarn, "ProposeLp sim: EARN supply delta != fullRangeEarn"
          );
          (uint160 sqrtPriceX96, int24 tick,,) = p.stateView.getSlot0(p.poolId);
          require(sqrtPriceX96 == p.sqrtPriceX96, "ProposeLp sim: pool sqrtPriceX96 != intended");
          require(tick == p.currentTick, "ProposeLp sim: pool tick != intended");
          require(p.posm.ownerOf(tokenId) == p.safe, "ProposeLp sim: full-range NFT not owned by Safe");
          require(p.posm.ownerOf(tokenId + 1) == p.safe, "ProposeLp sim: bid-wall NFT not owned by Safe");
          require(p.posm.getPositionLiquidity(tokenId) == p.liqFull, "ProposeLp sim: full-range liquidity mismatch");
          require(p.posm.getPositionLiquidity(tokenId + 1) == p.liqBand, "ProposeLp sim: bid-wall liquidity mismatch");

          uint256 totalUsds = p.fullRangeUsds + p.singleSidedUsds;
          uint256 usdsSpent = usdsBefore - IERC20(p.usds).balanceOf(p.safe);
          require(usdsSpent <= totalUsds && totalUsds - usdsSpent <= DUST, "ProposeLp sim: USDS spent not ~total");
          // The Safe minted exactly fullRangeEarn and the bid wall's EARN max is 0, so any EARN left
          // beyond dust means position 1 did not take it all or position 2 took some.
          require(earn.balanceOf(p.safe) <= earnBefore + DUST, "ProposeLp sim: EARN left on Safe beyond dust");
          (uint160 usdsAllowance,,) = IPermit2(p.permit2).allowance(p.safe, p.usds, address(p.posm));
          (uint160 earnAllowance,,) = IPermit2(p.permit2).allowance(p.safe, p.earn, address(p.posm));
          require(usdsAllowance <= DUST && earnAllowance <= DUST, "ProposeLp sim: Permit2 allowance left beyond dust");

          console2.log("Simulated position token ids:", tokenId, tokenId + 1);
          console2.log("USDS spent:", usdsSpent);
      }

      function _log(LpPlan memory p, SafeBatchLib.Tx[] memory txs) private pure {
          console2.log(p.earnIsC0 ? "Case A: EARN is currency0" : "Case B: USDS is currency0");
          console2.log("EARN:", p.earn);
          console2.log("Safe:", p.safe);
          console2.log("fee / tickSpacing:", p.key.fee, uint256(int256(p.key.tickSpacing)));
          console2.log("sqrtPriceX96:", p.sqrtPriceX96);
          console2.log("currentTick:", p.currentTick);
          console2.log("full range lower tick:", p.fullLower);
          console2.log("full range upper tick:", p.fullUpper);
          console2.log("bid wall lower tick:", p.bandLower);
          console2.log("bid wall upper tick:", p.bandUpper);
          console2.log("liqFull / liqBand:", p.liqFull, p.liqBand);
          console2.log("mint EARN / USDS approve:", p.fullRangeEarn, p.fullRangeUsds + p.singleSidedUsds);
          for (uint256 i; i < txs.length; ++i) {
              console2.log("tx", i, txs[i].to);
              console.logBytes4(bytes4(txs[i].data));
          }
      }
  }
  ```

- [ ] **Step 5: Run the fast checks**

  ```bash
  forge build
  yarn test
  forge fmt --check
  ```

  Expected: build succeeds; full unit suite green (including `ProposeLpTest`); fmt prints nothing.

- [ ] **Step 6: Run the LP fork verification — required**

  ```bash
  SNAPSHOT_BLOCK=26043909 yarn verify:lp
  ```

  Expected: `Script ran successfully.` Logs include, in order: `Case A ordering passed at 0x0000000000000000000000000000000000010000`; `Case B ordering passed at 0xfFfffFFFfffFFfFFFFffFFFFffffFfFFFFff0000`; for each run `sqrtPriceX96: 792281625142643375935439503360` (Case A) or `7922816251426433759354395033` (Case B), `liqFull / liqBand: 25000000000000000000135 85830483191952473195169`, `USDS spent: 499999999999999999999992`; a `swap: protocolFee / lpFee / EARN out:` line; and `Fork EARN hit Case A` or `Case B`. If the RPC is unreachable, say so explicitly.

- [ ] **Step 7: Smoke `ProposeLp.run()` on a latest-block fork (Review Focus 4). Nothing from this step is committed.**

  EARN does not exist on mainnet yet, so a throwaway script etches a StryToken owned by the Safe at `0x10000` and points `.stry` at it.

  ```bash
  mkdir -p script/smoke-tmp
  cat > script/smoke-tmp/Smoke.s.sol <<'EOF'
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {StdCheats} from "forge-std/StdCheats.sol";
  import {ProposeLp} from "../deployments/1/005-earn-lp/ProposeLp.s.sol";

  contract Smoke is Script, StdCheats {
      function run() external {
          deployCodeTo(
              "StryToken.sol:StryToken", abi.encode(0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D), address(0x10000)
          );
          new ProposeLp().run();
      }
  }
  EOF
  sed -i.bak 's/"stry": "0x0000000000000000000000000000000000000000"/"stry": "0x0000000000000000000000000000000000010000"/' \
    script/deployments/1/config/deploymentAddresses.json
  RPC="${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}"
  forge script script/smoke-tmp/Smoke.s.sol --fork-url "$RPC" 2>&1 | grep -E 'Simulation passed|^Error'
  node -e 'const b=require("./script/deployments/1/multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json"); console.log(b.meta.name, b.transactions.length)'
  forge script script/smoke-tmp/Smoke.s.sol --fork-url "$RPC" 2>&1 | grep '^Error'
  rm -rf script/smoke-tmp script/deployments/1/multisig/005-earn-lp script/deployments/1/config/deploymentAddresses.json.bak
  git checkout -- script/deployments/1/config/deploymentAddresses.json
  git status --porcelain
  ```

  Expected: first run prints `Simulation passed; batch written: script/deployments/1/multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json`; `node` prints `EARN/USDS V4 LP 6`; second run prints `Error: script failed: ProposeLp: batch 001 already exists; delete it deliberately to regenerate`; final `git status --porcelain` shows only this task's three files (`package.json`, `ProposeLp.s.sol`, `Verify.s.sol`). If the Safe's live USDS balance is below 500,000e18 the first run instead fails with `ProposeLp: Safe USDS balance < fullRangeUsds + singleSidedUsds`; report that to the controller as a fact for the operator (spec R5), not a code failure.

- [ ] **Step 8: Commit**

  ```bash
  git add package.json \
          script/deployments/1/005-earn-lp/ProposeLp.s.sol \
          script/deployments/1/005-earn-lp/Verify.s.sol
  git commit -m "feat(005-earn-lp): build, simulate and verify the earn/usds lp safe batch

  ProposeLp builds the 6-tx redemption-Safe batch (mint 2,500 EARN, exact approvals via
  Permit2, initializePool at 100 USDS/EARN, full-range + 50-100 bid-wall mints owned by
  the Safe), executes it as the Safe on the RPC fork and asserts the end state before it
  writes the batch file. yarn verify:lp runs both currency orderings, the squatted-pool
  revert at 2x and 0.5x, the initialized-pool refusal, and a swap fee check.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## Task 7: docs — runbook, superseded note, help, how-to, release notes

**Files:**
- Modify: `docs/ESPNv3_Runbook.md`
- Modify: `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md` (one header line)
- Modify: `docs/help/claim-earn-yield.md`
- Create: `docs/help/trade-earn-usds.md`
- Modify: `docs/RELEASE-NOTES.md`

**Interfaces:** none — doc changes only. Facts used: batch path `script/deployments/1/multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json`, `yarn verify:lp`, `.earn-airdrop-supply`, the 6-tx order from Task 6.

- [ ] **Step 1: Runbook Assumption 10 (`docs/ESPNv3_Runbook.md`, section 1)**

  Change:
  ```markdown
  - [ ] 10. `renounceOwnership()` after `mintBatch` for both tokens — no future mint possible. Confirm no further mint is wanted.
  ```
  to:
  ```markdown
  - [x] 10. EARN: `transferOwnership(redemption Safe)`; the Safe (1-of-1, owned by main multisig `0xC53C…20b8`) can mint without limit. REDEMPTION: renounced (unchanged).
  ```

- [ ] **Step 2: Runbook section 2 table — add the sEARN deploy and LP steps**

  Change:
  ```markdown
  | 4 | Track B `Distribute.s.sol` | B |
  | 5 | Track A `BuildOrder.s.sol` (Safe batch: approve + validate) | A |
  ```
  to:
  ```markdown
  | 4 | Track B `Distribute.s.sol` (EARN owner = redemption Safe; records `.earn-airdrop-supply`) | B |
  | 4a | Track B `Deploy.s.sol` (sEARN, live TripwireController) | B |
  | 4b | `005-earn-lp/ProposeLp.s.sol` (Safe batch: mint 2,500 EARN + v4 pool + 2 positions), then propose and sign | B |
  | 5 | Track A `BuildOrder.s.sol` (Safe batch: approve + validate) | A |
  ```

- [ ] **Step 3: Runbook section 6 — batch file list, PeriodicYield base, batch order, signing**

  Change (the PeriodicYield bullet's amount sentence):
  ```markdown
  `PeriodicYield.s.sol` takes **no env vars** — the transfer amount is computed on-chain from EARN's total supply and `settings.json`'s `basisPriceUsd`/`annualDividendRatioX100` (the 28-day slice of the annual dividend rate), not passed in.
  ```
  to:
  ```markdown
  `PeriodicYield.s.sol` takes **no env vars** — the transfer amount is computed from the airdrop total recorded once in `deploymentAddresses.json` `.earn-airdrop-supply` and `settings.json`'s `basisPriceUsd`/`annualDividendRatioX100` (the 28-day slice of the annual dividend rate), not passed in. EARN minted later by the Safe, including the LP's 2,500, does not change it.
  ```

  After that bullet (the last `- script/deployments/1/multisig/...` bullet), add:
  ```markdown
  - `script/deployments/1/multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json` — `005-earn-lp/ProposeLp.s.sol`, written once. Run it with `--fork-url` mainnet and **without** `--broadcast`: it executes the exact batch as the Safe on a fork of the latest block and writes the file only if every check passes. It refuses if the file already exists or the pool is already initialized.
  ```

  After ordered item `4.` (`**\`PeriodicYield.s.sol\` batch:** ...`), add:
  ```markdown
  5. **`ProposeLp.s.sol` batch:** `EARN.mintBatch([Safe], [2,500 EARN])`, `USDS.approve(Permit2, 500,000)`,
     `EARN.approve(Permit2, 2,500)`, `Permit2.approve(USDS, PositionManager, 500,000, max)`,
     `Permit2.approve(EARN, PositionManager, 2,500, max)`, then `PositionManager.multicall([initializePool,
     modifyLiquidities])`. Six transactions, one MultiSend. If anyone initialized the pool key at another
     price first, the last call reverts and the whole batch reverts; nothing moves.

  **Signing the LP batch (nested Safe).** The redemption Safe is 1-of-1 and its owner is the main multisig.
  Main-multisig signers approve the redemption Safe's inner transaction hash through the Safe UI nested-Safe
  flow and see only that hash approval. Before signing: (1) run the Safe UI Tenderly simulation of the inner
  batch; (2) compare the decoded values with the `ProposeLp` log (`sqrtPriceX96`, ticks, liquidity, amounts);
  (3) re-check `StateView.getSlot0(poolId).sqrtPriceX96 == 0`.
  ```

- [ ] **Step 4: Runbook section 7 — `verify:lp` and the ProposeLp command**

  Directly after the fenced block that ends with `yarn verify:migration`, add:
  ```markdown
  `SNAPSHOT_BLOCK=26043909 yarn verify:lp` runs the EARN LP fork check against `espn-holders-26043909.json`.
  ```

  At the end of section 7 (after the paragraph that ends `never moves USDS itself.`), add:
  ```markdown
  `005-earn-lp/ProposeLp.s.sol` needs no env var and never broadcasts:
  `forge script script/deployments/1/005-earn-lp/ProposeLp.s.sol --fork-url "${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}" -vvv`.
  ```

- [ ] **Step 5: Runbook section 8 — airdrop-supply base and the Distribute dry-run hazard**

  Append at the end of section 8:
  ```markdown
  `deploymentAddresses.json` ships `earn-airdrop-supply = "0"`. Track B `Distribute.s.sol` writes the real
  airdrop total there once, next to `.stry`, and refuses to run again once it is nonzero. `PeriodicYield.s.sol`
  reads it as the yield base and reverts while it is `0`. **Any run of `Distribute.s.sol`, including one
  without `--broadcast`, writes both keys.** After a dry run, restore the file with
  `git checkout -- script/deployments/1/config/deploymentAddresses.json` before the broadcast run.
  ```

- [ ] **Step 6: Superseded line in `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md`**

  After the line `- **Superseded (in part):** Track B's staking design is superseded by ...`, add:
  ```markdown
  - **Superseded (in part):** Assumption 10 for EARN (now `transferOwnership(redemption Safe)`) and the out-of-scope LP item are superseded by [`2026-09-24-earn-deploy-and-lp-design.md`](2026-09-24-earn-deploy-and-lp-design.md).
  ```
  No other edits to that file.

- [ ] **Step 7: Add the spec's four lines to `docs/help/claim-earn-yield.md`**

  Append at the end of the file:
  ```markdown

  ## Supply and the EARN/USDS pool

  - EARN supply is not fixed. The redemption Safe, controlled by the main multisig, can mint additional EARN; any mint dilutes existing holders.
  - The 28-day yield is sized on the original airdrop supply. EARN minted later, including the pool's EARN, does not change the yield amount.
  - EARN held in the Uniswap V4 pool positions is not staked and earns no sEARN yield.
  - Swaps in the EARN/USDS pool pay a 0.30% pool fee plus a Uniswap protocol fee of up to 0.05%.
  ```

- [ ] **Step 8: Create the how-to `docs/help/trade-earn-usds.md`**

  ```markdown
  # Trading EARN for USDS

  EARN trades against USDS in a Uniswap V4 pool.

  ## What it does

  The pool opens at 100 USDS per EARN. It holds liquidity across the full price range, plus USDS that buys EARN between 50 and 100 USDS per EARN. Every swap pays a 0.30% pool fee plus a Uniswap protocol fee of up to 0.05%. Pool fees go to the pool's liquidity positions, which the redemption Safe owns.

  ## How to get to it

  Use any interface that routes Uniswap V4 swaps. Select EARN and USDS as the pair. The pool is the EARN/USDS V4 pool with a 0.30% fee tier and no hook.

  ## Steps

  1. Connect your wallet on Ethereum mainnet.
  2. Choose EARN as the token to sell and USDS as the token to receive, or the reverse.
  3. Check that the route uses the EARN/USDS V4 pool at the 0.30% fee tier.
  4. Enter the amount, review the price and fees, and confirm the swap.

  EARN you keep in your wallet or sell earns no yield. Only staked EARN earns yield — see [How to earn EARN yield](claim-earn-yield.md).
  ```

- [ ] **Step 9: Release notes (`docs/RELEASE-NOTES.md`)**

  Change:
  ```markdown
  - Added STRY, a new token airdropped to ESPN holders that replaces ESPN going forward.
  ```
  to:
  ```markdown
  - Launched EARN, a new token airdropped to ESPN holders that replaces ESPN going forward.
  ```

  Append at the end of the `## Pending` list:
  ```markdown
  - Added an EARN/USDS trading pool on Uniswap V4, opening at 100 USDS per EARN. [How to trade EARN for USDS](help/trade-earn-usds.md)
  - EARN supply is not fixed: the treasury can mint additional EARN.
  - EARN staking yield is sized on the original airdrop supply; EARN minted later does not change it.
  ```

- [ ] **Step 10: Check links and commit**

  ```bash
  ls docs/help/trade-earn-usds.md docs/help/claim-earn-yield.md docs/superpowers/specs/2026-09-24-earn-deploy-and-lp-design.md
  git diff --stat
  git add docs/ESPNv3_Runbook.md \
          docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md \
          docs/help/claim-earn-yield.md docs/help/trade-earn-usds.md docs/RELEASE-NOTES.md
  git commit -m "docs: document earn mint authority, lp pool and airdrop-supply yield base

  Runbook: Assumption 10 reversed for EARN, sEARN deploy and LP steps in the sequence,
  the 005-earn-lp batch, nested-Safe signing checks, verify:lp, and the Distribute
  dry-run hazard. Help and release notes: EARN supply is mintable, yield is sized on
  the airdrop supply, and the new EARN/USDS pool with a how-to.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

  Expected: `ls` lists all three files; the diff touches only the five doc files.

---

## Task 8: operator checklist — human-run mainnet steps (no agent action)

**Agents do not run any step in this task.** No `--broadcast`, no `yarn safe:propose`, no Safe UI action, no `git push`. The controller hands this list to the user after Tasks 1–7 pass review and the user has approved. The user ticks these boxes.

**Pre-conditions:** Tasks 1–7 merged or on the branch the operator runs from; `SNAPSHOT_BLOCK=26043909 yarn verify:migration` and `yarn verify:lp` pass; `git status` clean; `deploymentAddresses.json` shows `"stry": "0x0000000000000000000000000000000000000000"` and `"earn-airdrop-supply": "0"`. `$RPC_URL` = a mainnet RPC. Signer flag = the operator's usual one (for example `--ledger`).

- [ ] **Op 1: StopEspnYield (runbook step 1).** `forge script script/deployments/1/004-stry-migration/StopEspnYield.s.sol --rpc-url $RPC_URL`. It writes `multisig/004-stry-migration/001-0x0cbe9bDD-multisig.json`. `finalYieldAmount` is `"0"`, so the batch is a no-op unless the amount is set first (spec O7). Propose with `yarn safe:propose <file>`, sign in the Safe UI.
- [ ] **Op 2: Snapshot.** Already taken: `espn-holders-26043909.json` (committed in Task 1). No action.
- [ ] **Op 3: Distribute EARN (deployer EOA).** Do not dry-run first, or restore `deploymentAddresses.json` with `git checkout --` after any dry run. `HOLDERS_FILE=script/deployments/1/config/espn-holders-26043909.json forge script script/deployments/1/004-stry-migration/Distribute.s.sol --rpc-url $RPC_URL --broadcast <signer flag>`. Check on-chain: `cast call <EARN> "owner()(address)"` = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`; `cast call <EARN> "totalSupply()(uint256)"` = the `.earn-airdrop-supply` value written to `deploymentAddresses.json` (~29,366 EARN). Commit `deploymentAddresses.json` (`chore(config): record earn address and airdrop supply`). Do not push without the user's go.
- [ ] **Op 4: Deploy sEARN (deployer EOA).** `forge script script/deployments/1/004-stry-migration/Deploy.s.sol --rpc-url $RPC_URL --broadcast <signer flag>`. Writes `.staked-earn`. Commit it.
- [ ] **Op 5: Build + simulate the LP batch (no broadcast).** `forge script script/deployments/1/005-earn-lp/ProposeLp.s.sol --fork-url "${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat}" -vvv`. Must print `Simulation passed; batch written: script/deployments/1/multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json`. Keep the log (Case A/B, `sqrtPriceX96`, ticks, `liqFull / liqBand`, amounts). Commit the batch file.
- [ ] **Op 6: Propose.** `yarn safe:propose script/deployments/1/multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json`.
- [ ] **Op 7: Safe sign + execute (main multisig signers, nested Safe).** Before signing: run the Safe UI Tenderly simulation of the inner batch; compare decoded values with the Op 5 log; re-check `StateView.getSlot0(poolId).sqrtPriceX96 == 0` and Safe USDS ≥ 500,000. After execution: both position NFTs owned by the Safe; Safe USDS down by ~500,000; ~115,087 USDS left for PeriodicYield (spec SO1). If the pool key was squatted (batch reverts), follow SO3: set `lp.tickSpacing` to 30, delete the 005 batch file, re-run Op 5.

---

## Definition of done

- `forge --version` = 1.8.0; `forge build` succeeds; `yarn test` green (adds 2 `PeriodicYieldTest` and 10 `ProposeLpTest` tests); `forge fmt --check` clean.
- `SNAPSHOT_BLOCK=26043909 yarn verify:migration` passes with EARN owner = Safe and the live TripwireController.
- `SNAPSHOT_BLOCK=26043909 yarn verify:lp` passes: both orderings, both squat reverts, initialized-pool refusal, swap check.
- `git grep -n "renounceOwnership" script/deployments/1/004-stry-migration/` returns nothing.
- `git grep -n "stratToken().totalSupply()" script/` returns nothing.
- `git diff --stat main -- src/ lib/ script/safe/ script/deployments/1/003-espn-redemption/ script/deployments/1/004-stry-migration/StopEspnYield.s.sol test/unit/StryTokenTest.sol` is empty.
- `shasum -a 256 script/deployments/1/005-earn-lp/lib/*.sol` matches Task 5 Step 1.
- `docs/RELEASE-NOTES.md` `## Pending` has the EARN launch, pool (with how-to link), mintable-supply and yield-base bullets.
- No commit was pushed; no agent broadcast anything.
