# ESPNv3: ESPN Redemption + Migration to Yield-Paying Token — Design Spec

- **Date:** 2026-08-21 (revised after two independent adversarial reviews)
- **Branch:** `espn-redemption`
- **Status:** Approved design; open decisions listed in Explicit Assumptions must be closed before any non-fork broadcast
- **Chain:** Ethereum mainnet (chain id 1)

## Overview

ESPN (`EthStrategyPerpetualNote`, an ERC4626 vault over USDS) is being wound down for its ~170 holders via two tracks:

- **Track A — Capped Redemption:** airdrop a simple redemption token (1:1 with ESPN balances at a snapshot), then let holders redeem ESPN + redemption tokens for USDS through a single Seaport 1.6 `PARTIAL_OPEN` order validated by the treasury multisig. Seaport's own partial-fill math handles settlement atomically; no custom swap contract.
- **Track B — Migration to a yield-paying token:** airdrop a new token STRY ("ETH Strategy Yield") to the same snapshot holders, calibrated to a $100 basis price against ESPN's USDS backing; deploy a **new instance** of the existing, unmodified `StakedStrat` contract with `stratToken = STRY`, `rewardToken = USDS`; stop ESPN yield with one final `increaseAssetsPerShare()` call; pay weekly USDS yield into the new staking contract via a manually-run script.

Deliverables are **contracts + Foundry deploy/verify scripts + one dependency-free Node snapshot script + three small repo-hygiene fixes**. No UI, no LP deployment, no automation infrastructure (see Out of Scope).

### Confirmed on-chain facts

All values read via `cast` against mainnet at **block 25,800,591**. Values marked *(live)* move and are re-read at broadcast time; they are recorded here only to size the design.

| Fact | Value |
|---|---|
| ESPN (EthStrategyPerpetualNote, ERC4626) | `0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE` |
| ESPN `asset()` = USDS | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` |
| ESPN `owner()` | `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8` (protocol "main" multisig) |
| ESPN `manager()` | `0x823EfFFA08f946233D2a502a1B073C5E16Fea16b` (a **contract**, ~170 bytes of code) |
| ESPN `totalSupply()` *(live)* | `34795546682818036103184` (~34,795.55 ESPN, 18 dp) |
| ESPN `totalAssets()` *(live)* | `3878653235910468821362228` (~3,878,653.24 USDS, 18 dp) |
| Derived `navPerEspn` *(live)* | `111469817424243522517` (~111.4698 USDS/ESPN) |
| ESPN `depositCap` | `100000000000000000000000000` (1e26 — **deposits are wide open**, cap is ~26× current backing) |
| ESPN `withdrawalsDisabled` | **`false`** — see the correction note below |
| USDS held *by the ESPN vault itself* | `5061355799922741` (~0.00506 USDS — effectively zero) |
| USDS held by the redemption multisig | `1199676539674716233244300` (~1,199,676.5 USDS) |
| ESPN held by the redemption multisig | `3199732800000000000000` (~3,199.73 ESPN = **9.20% of supply**) |
| Seaport `getCounter(redemptionMultisig)` | `0` (no prior counter bump; validated orders from this offerer are not pre-invalidated) |
| Known ESPN holders | ~170 |
| Seaport 1.6 | `0x0000000000000068F116a894984e2DB1123eB395` |

**Correction to a previously-stated fact.** Earlier drafts of this spec (and the brainstorm it came from) asserted that ESPN's `withdrawalsDisabled` "already defaults to `true` on the deployed contract". The *source* default is `true`, but the deployed contract's storage reads **`false`** — the owner has since called `setWithdrawalsDisabled(false)`. Withdrawals are therefore **enabled** at the contract level. In practice they still fail for any non-dust amount, because `_deposit`/`increaseAssetsPerShare` forward every asset to `manager` and the vault holds ~0.005 USDS, so `super._withdraw`'s token transfer reverts on insufficient balance. This is a *liquidity* block, not a *policy* block, and it is not under this project's control: if the manager ever returns USDS to the vault, ESPN holders can withdraw at NAV and bypass both tracks. See Assumption 3.

**`totalAssets()` is bookkeeping, not a balance.** `_deposit` (line 143) and `increaseAssetsPerShare` (line 59) both `safeTransfer` the asset straight to `manager`. Every formula in this spec that reads `totalAssets()` is reading an accounting number; no script may assume the vault or any address holds a corresponding USDS balance. Where a USDS balance is actually needed (the Seaport offer), the script asserts the balance directly.

### Prior art (in this repo's git history, recoverable via `git show`)

The exact Seaport mechanism was built once before as the STRAT ragequit, then removed from main (the one-off order expired; the approach was sound):

- `6484357` "feat: add rage quit deployment and verification" — `script/deployments/1/002-rage-quit-order/{BuildOrderLib.sol, Operation.s.sol, Verify.s.sol, fork.json, interfaces/{ISeaportMinimal.sol, IStETH.sol}}`, `script/deployments/1/config/settings.json`, and the Safe batch artifact `script/deployments/1/multisig/002-rage-quit-order/001-0x0cbe9bDD-multisig.json`. The `externalAddresses.json` / `internalAddresses.json` / `deploymentAddresses.json` config layers **predate** this commit.
- `95ff244` "test: seaport ragequit tests" — `test/forge/seaport/{README.md, SeaportRateQuit.t.sol (sic — typo in the original), interfaces/ISeaportMinimal.sol, lib/SeaportOrderLib.sol}`. The README's "Numerator / denominator constraints", "UI guidance", "Public fillability" and "MEV / fill competition" sections are required reading before implementing Track A.

**Also in history and deliberately not revived:** `src/ESPNRedemptionQueue.sol` (deleted in `2d29ce6` "chore: extra tests + removed dead/unused contracts"). A queue-based ESPN redemption mechanism existed and was removed. This design does not resurrect it: the queue needed the vault to hold liquid USDS (it does not — see above), whereas the Seaport order settles directly from the treasury's own balance.

**Mandatory deviation from prior art:** the prior scripts depended on `stoke` (`git@github.com:frontier159/stoke` — `StokeOperation`/`OperationRunner`/`Context`/`Config`/`Logger`), a **private repo that is not accessible in this build**. Do **not** depend on it. Replicate the same *shape* — numbered `script/deployments/1/NNN-name/` folders, layered JSON config, a fork-based `Verify.s.sol` per operation — using **plain forge-std `Script`/`Test` only** (`vm.readFile`/`vm.parseJson` for config, `vm.prank`/`vm.startPrank`/`vm.startBroadcast`/`vm.warp`/`vm.deal`/`deal` for fork verification).

Two consequences of dropping stoke that the prior art's file contents hide:

- **stoke parsed scientific notation.** Its `Config.requiredAmount` accepted `"2900e18"`, which is why the old `settings.json` reads `{"stETH-offer-amount": "2900e18", ...}`. `vm.parseJsonUint` does **not** parse `e18` notation. All amount settings in this project's `settings.json` are **plain decimal wei strings** (e.g. `"700000000000000000000000"`). No exceptions; see Config / Parameters.
- **stoke wrapped impersonation.** `runner.startActorImpersonation(addr, ethToFund)` was a prank + `vm.deal`. Replaced with plain `vm.startPrank(addr)` + `vm.deal(addr, 1 ether)` + `deal(token, addr, amount)` from `StdCheats`.

## Prerequisites (repo changes required before any of this compiles or runs)

These are not optional cleanup; each one blocks the first command an implementer types. They are in scope.

1. **Initialize git submodules.** `git submodule status` shows all three (`lib/forge-std`, `lib/halmos-cheatcodes`, `lib/openzeppelin-contracts`) unstaged in this checkout. `forge build` fails before anything else. Run `git submodule update --init --recursive` (or `forge install`).
2. **Grant filesystem permissions in `foundry.toml`.** Current value is `fs_permissions = [{access = "write", path = "./tmp/"}]` — that grants **no read access to anything**, so every `vm.readFile` of `externalAddresses.json`, `internalAddresses.json`, `settings.json` and the holders JSON reverts, and the `deploymentAddresses.json` write reverts too. Required change:

   ```toml
   fs_permissions = [
       {access = "write", path = "./tmp/"},
       {access = "read-write", path = "./script/deployments/"},
   ]
   ```

3. **Make the `integration` profile compile.** `test/integration/ESPNRedemptionQueueIntegrationTest.sol` and `test/integration/MorphoBlueFlashLoanProviderIntegrationTest.sol` import `src/ESPNRedemptionQueue.sol` and `src/MorphoBlueFlashLoanProvider.sol`, both deleted in `2d29ce6`. `FOUNDRY_PROFILE=integration forge test` currently fails to compile. Delete the two orphaned test files (the contracts they test no longer exist). Verified missing: `src/ESPNRedemptionQueue.sol`, `src/MorphoBlueFlashLoanProvider.sol`.

## Goals

1. Give snapshot ESPN holders a route out of ESPN into USDS, at a **capped aggregate capacity of ~700,000 USDS, first-come-first-served** (Track A). This is explicitly *not* a guaranteed per-holder pro-rata entitlement — see "Capacity, and what 'pro-rata' does and does not mean".
2. Migrate holders onto STRY with USDS yield via a fresh `StakedStrat` instance (Track B).
3. Stop new ESPN yield after one final top-up (as a *policy*, not an enforceable on-chain state — see Assumption 3).
4. Every deploy/operation script has a companion mainnet-fork `Verify.s.sol` with balance-delta assertions and gas logging, runnable by a named `package.json` script, so real-world cost and behavior are sanity-checked before any real broadcast.
5. Keep new code deliberately minimal: two plain ERC20+Ownable tokens, zero changes to existing contracts.

## Non-Goals

- No UI of any kind.
- No LP-deployment script.
- No automated/cron weekly-yield system — the weekly-yield script is manually triggered.
- No merkle-claim distributor (holder count ~170 makes direct batch mint cheaper and simpler).
- No changes to `StakedStrat.sol`, `EthStrategyPerpetualNote.sol`, or any existing contract's **code**. (Calling an existing owner-only *setter*, e.g. `setDepositCap`, is a separate operational decision — see Assumption 8 — not a code change.)
- No custom Seaport zone, ContractOfferer, or swap contract — the stock Seaport 1.6 partial-fill order is the whole mechanism.
- No `MintableBurnableToken`/`TripwireGuard` machinery on the two new tokens (deliberate, per product ask).
- No new runtime JS dependency (see the snapshot script — `viem` was considered and dropped).

## Architecture

```
                         ┌────────────────────────────────┐
                         │  script/snapshot/espn-holders  │
                         │  (Node ≥18, zero deps, fetch)  │
                         │  Transfer logs → address list; │
                         │  balanceOf @block → balances   │
                         └───────────────┬────────────────┘
                                         │ holders JSON (shared by both tracks)
              ┌──────────────────────────┴─────────────────────────┐
              ▼                                                    ▼
 TRACK A (redemption)                                  TRACK B (migration)
 ┌──────────────────────────┐                          ┌──────────────────────────┐
 │ EspnRedemptionToken       │                          │ StryToken (STRY)         │
 │ (new, ERC20+Ownable)      │                          │ (new, ERC20+Ownable)     │
 │ Distribute.s.sol:         │                          │ Distribute.s.sol: $100   │
 │ one mintBatch tx, 1:1     │                          │ basis-price mintBatch    │
 │ then renounceOwnership    │                          │ then renounceOwnership   │
 └────────────┬─────────────┘                          └────────────┬─────────────┘
              ▼                                                     ▼
 ┌──────────────────────────┐                          ┌──────────────────────────┐
 │ BuildOrder.s.sol          │                          │ Deploy.s.sol: NEW        │
 │ treasury validates one    │                          │ StakedStrat instance     │
 │ Seaport PARTIAL_OPEN order│                          │ (STRY / USDS) — zero     │
 │ offer: 700k USDS, amounts │                          │ code changes             │
 │ snapped to the 1e9 grid   │                          ├──────────────────────────┤
 │ consideration per unit:   │                          │ StopEspnYield.s.sol:     │
 │ 5 REDEMPTION + 1 ESPN     │                          │ final increaseAssets-    │
 ├──────────────────────────┤                          │ PerShare() on ESPN       │
 │ Cancel.s.sol: cancel +    │                          ├──────────────────────────┤
 │ revoke USDS approval      │                          │ WeeklyYield.s.sol:       │
 └────────────┬─────────────┘                          │ USDS in + syncRewards()  │
              ▼                                        │ (repeatable, manual)     │
 holders call Seaport                                  └──────────────────────────┘
 fulfillAdvancedOrder(n, D=1e9)
 (partial fills, FCFS)
```

The two tracks share the snapshot tooling and the layered JSON config, and are **economically coupled** through ESPN's backing — see "Cross-track reconciliation". They are not independently shippable without closing Assumption 7.

### Directory layout (new files)

```
script/
  snapshot/
    espn-holders.mjs                  # Node ≥18, zero dependencies (global fetch)
  deployments/1/
    config/
      externalAddresses.json          # Seaport, USDS, ESPN  (extend the existing file)
      internalAddresses.json          # treasury multisig, tripwire controller/guardian (extend)
      deploymentAddresses.json        # REDEMPTION / STRY / new StakedStrat (extend; written by scripts)
      settings.json                   # per-operation settings (extend; see Config section)
      espn-holders-<block>.json       # snapshot output (committed for reproducibility)
    003-espn-redemption/              # Track A
      BuildOrderLib.sol
      Distribute.s.sol
      BuildOrder.s.sol
      Cancel.s.sol
      Verify.s.sol
      interfaces/ISeaportMinimal.sol  # revived from commit 6484357
    004-stry-migration/               # Track B
      Distribute.s.sol
      Deploy.s.sol
      StopEspnYield.s.sol
      WeeklyYield.s.sol
      Verify.s.sol
  multisig/
    003-espn-redemption/              # Safe Transaction Builder JSON, written by BuildOrder/Cancel
    004-stry-migration/               # Safe Transaction Builder JSON, written by StopEspnYield
src/
  EspnRedemptionToken.sol
  StryToken.sol
test/unit/
  EspnRedemptionTokenTest.sol
  StryTokenTest.sol
```

The `001`/`002` folders were deleted along with the stoke work and are **not** restored; the tree contains only `003` and `004`. Numbering continues the historical sequence for continuity with the config layer, which is still on `main`.

## Global sequencing (both tracks)

Both tracks derive amounts from ESPN's NAV, and one Track B step *changes* that NAV. Running them in a different order silently prices the two airdrops off two different NAVs. The mandated order:

| # | Step | Track | Why here |
|---|---|---|---|
| 0 | Close Assumptions 1, 4, 7, 8 with the founder | — | Addresses and the both-tracks-ship decision gate everything |
| 1 | `StopEspnYield.s.sol` — final `increaseAssetsPerShare` | B | Runs **first** so every later formula reads the final NAV. Costs `finalYieldAmount` USDS, paid by the treasury and forwarded to `manager` |
| 2 | Choose `snapshotBlock` ≥ 64 blocks behind head; run `espn-holders.mjs` | shared | Snapshot after the NAV is final |
| 3 | Track A `Distribute.s.sol` (mintBatch REDEMPTION 1:1) | A | |
| 4 | Track B `Distribute.s.sol` (mintBatch STRY at $100 basis) | B | Same NAV as step 3 because step 1 already happened |
| 5 | Track A `BuildOrder.s.sol` (Safe batch: approve + validate) | A | Order goes live only after REDEMPTION exists |
| 6 | Holders fulfil (FCFS, until `endTime` or capacity exhausted) | A | |
| 7 | Track B `Deploy.s.sol` (new `StakedStrat`) | B | |
| 8 | Holders `stake(STRY)`; **then** first `WeeklyYield.s.sol` run | B | Yield deposited with zero stakers is destroyed — see WeeklyYield |
| 9 | `Cancel.s.sol` after `endTime` (cancel + revoke USDS approval) | A | |

Effect of step 1 on step 5: `usdsOffer` is pinned at `targetRedemptionUsd` (700,000 USDS) regardless of NAV, so the treasury's *USDS* outlay is bounded and unaffected. What a higher NAV changes is `espnAsk` — the treasury reclaims **less ESPN** for the same 700k. That is the honest price, and it is the reason step 1 must precede step 5 rather than land in the middle of the redemption window.

`increaseAssetsPerShare` is `external` with **no access control** (`src/EthStrategyPerpetualNote.sol:57`). Anyone can raise NAV at any time, including after step 1 and during step 6. The order's amounts are fixed at validate time and do not follow NAV, so a later NAV rise simply makes the order's fixed price stale (favourable to fillers if NAV rose). Accepted; there is no on-chain mechanism to prevent it. See Assumption 3.

## Cross-track reconciliation (open decision — Assumption 7)

The two tracks each lay a claim against the **same** ~$3.878M of ESPN backing:

- Track A pays out up to **700,000 USDS** of that backing.
- Track B mints STRY sized so `totalSupply(STRY) × $100 == ESPN.totalAssets()`, i.e. STRY nominally claims the **full** $3.878M.

If both ship off the same snapshot, stated obligations total ~$4.578M against ~$3.878M of assets — an overstatement of ~18%. The spec must not leave this implicit. Three resolutions, in preference order:

1. **Recommended: size STRY on post-redemption backing.** Run Track B's `Distribute.s.sol` after Track A's window closes, reading `ESPN.totalAssets()` at that point (the treasury burns or holds the reclaimed ESPN per Assumption 6, and `totalAssets()` reflects reality only if the treasury *burns* — see below). Reason: keeps the $100 basis a real, backed number. Cost: Track B is delayed by the full redemption window, and the holder set must still be the step-2 snapshot (holders who redeemed have already been paid, so they should be excluded or accept a reduced STRY allocation — a further decision).
2. **Ship Track B on the step-2 snapshot and state that $100 is a nominal basis price, not a redemption guarantee.** Reason: preserves the simple "same snapshot, same holders" story. Cost: the $100 figure is marketing, not backing, from the moment the first fill lands. If chosen, the spec, the token docs and any holder communication must say so explicitly.
3. **Ship only one track.** Reason: no reconciliation needed. Cost: drops half the approved scope.

**This spec is written to support option 2 as the default** (the "same snapshot, both tracks" shape the founder described), with the nominal-basis caveat stated wherever the $100 figure appears. Selecting option 1 changes only the sequencing table and Track B's `Distribute.s.sol` inputs — no contract changes.

Note that `ESPN.totalAssets()` does **not** decrease when the treasury receives ESPN back; it only decreases if the treasury calls the public `ESPN.burn(value)` on the reclaimed shares. See Assumption 6.

## Track A — Capped Redemption

### Mechanism

1. Snapshot ESPN balances at a chosen block (off-chain script, see Components).
2. Deploy `EspnRedemptionToken` and mint it **1:1** with each holder's snapshot ESPN balance in a single `mintBatch` transaction, then `renounceOwnership()`. No claim step, no merkle tree.
3. Treasury multisig calls `Seaport.validate()` on a **single `PARTIAL_OPEN` order** (offerer = treasury). No signature needed for a validated order; no custom contract.
   - **Offer:** 700,000 USDS (`targetRedemptionUsd`), snapped down to the fill grid.
   - **Consideration (paid to treasury):** `redemptionAsk` REDEMPTION + `espnAsk` ESPN, both snapped down to the fill grid.
4. Any holder approves Seaport for ESPN + REDEMPTION and calls `fulfillAdvancedOrder()` with `denominator = FILL_GRID` and their own `numerator` (fractions are against the **original** order size, not remaining — Seaport 1.6 semantics). Seaport settles atomically: USDS out of treasury, ESPN + REDEMPTION into treasury.

### Fill fractions: the `InexactFraction` problem and the fix

**This is the mechanism's sharpest edge and the reason the "compute everything dynamically, never hardcode" rule cannot be applied naively.**

Seaport's `_getFraction(numerator, denominator, value)` reverts `InexactFraction` unless `value * numerator % denominator == 0` — for **every** offer item and **every** consideration item independently. This repo's own deleted README (`95ff244:test/forge/seaport/README.md`, "Numerator / denominator constraints") states it, and assigns the job of snapping fills to valid increments to a UI. **There is no UI in this project**, so the constraint must be discharged in the order's amounts themselves.

Raw NAV-derived amounts are ~22-digit arbitrary integers (e.g. `espnAsk = 6279726801165077551256`). For those, a holder wanting to spend exactly their balance would have to find `n/d ≤ uint120` satisfying exact divisibility for all three items simultaneously. They cannot, and almost every attempted fill would revert. The prior art avoided this by hardcoding round `e18` amounts and filling at `33/100`.

**Fix — a canonical fill grid.** Introduce `FILL_GRID = 1_000_000_000` (1e9), a `settings.json` constant, and:

- **Snap every order amount down to a multiple of `FILL_GRID` wei** in `BuildOrder.s.sol`: `amount = (raw / FILL_GRID) * FILL_GRID`.
- **Mandate `denominator = FILL_GRID` for all fills.** Publish this alongside the order hash in the operator run-book.

Why this works: if every item amount is an integer multiple of `FILL_GRID`, then `amount * n` is a multiple of `FILL_GRID` for **any** integer `n ≤ FILL_GRID`, so `_getFraction` is exact for every item at every numerator. Two consequences follow for free:

- **The final tranche is fillable.** When a fill would exceed the remainder, Seaport clamps `numerator = denominator - filledNumerator`, an integer `< FILL_GRID`. Exactness still holds, so there is no permanently-unfillable dust tail. (Without the grid, the clamped residue is an arbitrary integer and the last fills revert — which would have stranded the tail of the 700k.)
- **No uint120 cross-scaling.** Seaport rescales stored fractions (`filledNumerator *= denominator; numerator *= filledDenominator; denominator *= filledDenominator`) whenever a fulfiller supplies a denominator differing from the stored one, applying a GCD reduction only past `MaxUint120` and reverting if reduction is insufficient. With every fulfiller on the same `FILL_GRID`, no rescaling ever occurs and no fill can revert because of an earlier fulfiller's choice.

Costs of the grid, all acceptable and all stated:

- **Snapping loss:** < 1e9 wei (1 gwei-equivalent, i.e. `1e-9` tokens) per item. Negligible against 700,000e18.
- **Fill granularity:** one grid unit ≈ `espnAsk / 1e9` ≈ `6.28e12` wei ≈ `0.0000063` ESPN ≈ $0.0007. A holder with less ESPN than one grid unit cannot fill; at these numbers that is a rounding-dust holder only.
- **Residual dust:** a holder's exact balance will rarely be an exact multiple of a grid unit's ESPN cost, so each holder rounds **down** to `n = floor(myEspn × FILL_GRID / espnAsk)` and retains sub-grid ESPN dust. Stated, accepted.
- **A fulfiller who ignores the convention** and supplies a different denominator will either revert (`InexactFraction`) or, if their fraction happens to divide, trigger cross-scaling that can inconvenience later fillers. Without a zone there is no on-chain way to force the convention. Mitigation is the run-book plus the fact that the naive attempt reverts rather than succeeding badly.

**Holder run-book line (must appear in the operator hand-off, since there is no UI):**

```
denominator = 1000000000
numerator   = floor(yourEspnBalance * 1000000000 / <espnAsk logged by BuildOrder>)
you pay     : espnAsk * n / 1e9 ESPN  and  redemptionAsk * n / 1e9 REDEMPTION
you receive : usdsOffer * n / 1e9 USDS
approve Seaport (0x0000000000000068F116a894984e2DB1123eB395) for both amounts first
```

### Capacity, and what "pro-rata" does and does not mean

The earlier framing — "the 5:1 ratio is the cap, so the offer size is mere validation" — is wrong, and the numbers show why:

| Quantity | Value at block 25,800,591 |
|---|---|
| Aggregate max redeemable ESPN from the ratio (`totalSupply(REDEMPTION) / 5`) | 6,959.11 ESPN |
| …valued at NAV | **775,731 USDS** |
| Order capacity (`espnAsk` = 700,000 / navPerEspn) | 6,279.73 ESPN |
| Shortfall of offer vs. ratio | **~9.8%** |

So the **offer binds, not the ratio**, and the mechanism is **first-come-first-served**, not a guaranteed per-holder pro-rata entitlement. Two further facts sharpen this:

- **The treasury holds 9.20% of ESPN** (3,199.73 ESPN) and will be airdropped REDEMPTION on it like any other holder. Excluding the treasury's own holdings, holder-usable capacity is `(34,795.55 − 3,199.73) / 5 = 6,319.16 ESPN ≈ 704,396 USDS` — which is *just* above the 700k offer. Any ESPN held by an LP pair or other non-acting contract pushes usable capacity further down. Realistically the offer and the usable ratio cap are within a couple of percent of each other, but the offer is still the binding side.
- **REDEMPTION is a plain, freely transferable ERC20 and the order is `PARTIAL_OPEN`.** Anyone can buy REDEMPTION from apathetic holders and ESPN from the LP and consume capacity ahead of snapshot holders. The prior-art README flags this under "Public fillability" and "MEV / fill competition". Adding a zone or a restricted order type is explicitly out of scope, so this is **accepted**: capacity is public and contested.

Goal 1 is worded accordingly. If the founder wants the ratio to be the true cap (so that every snapshot holder who acts before `endTime` is guaranteed capacity), raise `targetRedemptionUsd` to **≥ 775,731 USDS** — a `settings.json` change, no code impact. Flagged as Assumption 9.

**Real `BuildOrder.s.sol` pre-conditions** (replacing the vacuous `redemptionAsk <= REDEMPTION.totalSupply()`, which passes by 5× at any plausible NAV and detects nothing):

1. `USDS.balanceOf(treasury) >= usdsOffer` — **hard revert**. The treasury currently holds ~1,199,676 USDS, comfortably above 700,000, but this must be asserted at broadcast time and never assumed: `totalAssets()` is bookkeeping and the vault holds ~0.
2. `USDS.decimals() == 18 && ESPN.decimals() == 18 && REDEMPTION.decimals() == 18` — one line each; four formulas hardcode `1e18`.
3. `Seaport.getCounter(treasury) == expectedCounter` from `settings.json` (currently `0`) — **hard revert on mismatch**. If the multisig ever increments its Seaport counter, every previously validated order silently dies; asserting the counter at build time makes that visible and is recorded in the order hash computation anyway.
4. `usdsOffer % FILL_GRID == 0 && espnAsk % FILL_GRID == 0 && redemptionAsk % FILL_GRID == 0`.
5. `block.timestamp < startTime` and `startTime < endTime` — absolute timestamps in a committed JSON go stale between authoring and broadcast.
6. **Informational, logged not reverted:** `usableRedemption = REDEMPTION.totalSupply() - REDEMPTION.balanceOf(treasury) - sum(REDEMPTION.balanceOf(x) for x in settings.excludedAddresses)`; log `usableRedemption / 5 * navPerEspn` against `usdsOffer` so the operator sees which side binds before signing.

### Dynamic amount derivation

NAV moves, so the exact token amounts are computed **at broadcast time** in `BuildOrder.s.sol` from live chain state, then snapped to the fill grid:

```
navPerEspn        = ESPN.totalAssets() * 1e18 / ESPN.totalSupply()          // USDS per ESPN, wad
usdsOffer_raw     = targetRedemptionUsd                                     // fixed; the offer IS the target
espnAsk_raw       = targetRedemptionUsd * 1e18 / navPerEspn
redemptionAsk_raw = espnAsk_raw * redemptionRatio                           // = espnAsk_raw * 5

usdsOffer         = (usdsOffer_raw     / FILL_GRID) * FILL_GRID
espnAsk           = (espnAsk_raw       / FILL_GRID) * FILL_GRID
redemptionAsk     = (redemptionAsk_raw / FILL_GRID) * FILL_GRID
```

`usdsOffer = targetRedemptionUsd` directly — the earlier `usdsOffer = espnAsk * navPerEspn / 1e18` was a redundant round-trip that recomputed the target minus a rounding error, and that error is precisely the kind that breaks fraction exactness. Cut.

`targetRedemptionUsd`, `redemptionRatio` and `FILL_GRID` are `settings.json` inputs; the three token amounts are derived, logged, and used to build the order.

### Order shape (following commit 6484357's `BuildOrderLib`)

- `orderType = PARTIAL_OPEN` (open fulfillment, partial fills allowed)
- `offerer = treasury multisig`, `zone = address(0)`, `zoneHash = bytes32(0)`, `conduitKey = bytes32(0)` (direct Seaport approvals, no conduit)
- `offer = [ERC20 USDS, usdsOffer]`
- `consideration = [ERC20 REDEMPTION, redemptionAsk, recipient=treasury], [ERC20 ESPN, espnAsk, recipient=treasury]`
- `startTime` / `endTime`: absolute unix seconds, plain decimal strings in `settings.json`, asserted to be in the future at build time.
- `salt`: **a UTF-8 string** in `settings.json` (e.g. `"espnv3-redemption-1"`), converted exactly as the prior art did — `salt: uint256(keccak256(bytes(settingsString)))`. Not a hex literal, not a number; the type is load-bearing because it feeds the order hash.
- Treasury must `approve(Seaport, usdsOffer)` on USDS. This is a **separate transaction** from `validate()`, batched in the same Safe execution (see Multisig output below).
- Post-validate assertions (as in prior art): `getOrderStatus(orderHash)` → `isValidated == true`, `isCancelled == false`, `totalFilled == 0`.

### Multisig output (deliverable, not an aside)

`BuildOrder.s.sol` and `Cancel.s.sol` cannot broadcast from a Safe. Each writes a **Safe Transaction Builder JSON** batch file, in the same format as the prior art's `script/deployments/1/multisig/002-rage-quit-order/001-0x0cbe9bDD-multisig.json`:

```json
{ "version": "1.0", "chainId": "1", "createdAt": <ms>,
  "meta": { "name": "003-espn-redemption step 1", "description": "...",
            "txBuilderVersion": "2.0.1", "createdFromSafeAddress": "0x0cbe...", "checksum": "0x..." },
  "transactions": [ { "to": "<USDS>",    "value": "0", "contractMethod": { "name": "approve", ... }, "contractInputsValues": { ... } },
                    { "to": "<Seaport>", "value": "0", "contractMethod": { "name": "validate", ... }, "contractInputsValues": { ... } } ] }
```

- `BuildOrder.s.sol` emits a **2-transaction batch**: `USDS.approve(Seaport, usdsOffer)` then `Seaport.validate([order])`.
- `Cancel.s.sol` emits a **2-transaction batch**: `Seaport.cancel([orderComponents])` then `USDS.approve(Seaport, 0)`. The USDS allowance survives order expiry and must be revoked; leaving a live 700k allowance to Seaport after the window is an unnecessary standing risk.
- Written to `script/deployments/1/multisig/<operation>/NNN-<safe-prefix>-multisig.json`. The `checksum` field is copied from the prior art's shape; if reproducing Safe's exact checksum algorithm proves fiddly, emit the batch without it — the Transaction Builder accepts batches with an absent/`null` checksum and the operator re-derives it on import. Do not block on the checksum.

## Track B — Migration to Yield-Paying Token

### Mechanism

1. Reuse the **same snapshot output** as Track A (same ~170 holders, same snapshot block) — subject to Assumption 7 / option 1 above.
2. Deploy `StryToken` (symbol `STRY`, name `ETH Strategy Yield`), mint to holders in a single `mintBatch`, then `renounceOwnership()`.
3. **Calibration — $100 basis price:** total STRY supply is sized so `totalSupply(STRY) × basisPriceUsd == ESPN's total USDS backing at snapshot`:

```
stryAmount_i = espnBalance_i * ESPN.totalAssets() / (ESPN.totalSupply() * basisPriceUsd)
```

   `basisPriceUsd` is **an unscaled integer (`100`), not a wad**, in `settings.json` — see the unit-convention rule in Config / Parameters. `navPerEspn` is read live at broadcast time, never hardcoded. At the block-25,800,591 NAV this yields ~38,786.53 STRY total (~3,878,653 USDS / $100).

   Per Assumption 7 / option 2, **$100 is a nominal basis price, not a redemption guarantee**; it is not backed to the extent Track A pays out.

4. **New `StakedStrat` instance, zero code changes.** The existing contract's constructor is already generic:

   ```solidity
   constructor(address _stratToken, address _rewardToken, ITripwireController controller_, address guardian_)
   ```

   `Deploy.s.sol` deploys it with `_stratToken = STRY`, `_rewardToken = USDS`, and controller/guardian addresses from `internalAddresses.json`. Notes (facts of the unmodified contract, accepted under the zero-code-change constraint):
   - The ERC20 name/symbol are hardcoded `"Staked STRAT v2"` / `"sSTRAT-v2"`; the new instance carries that name even though it stakes STRY. Cosmetic only.
   - `REWARD_DURATION = 7 days` is a constant; `syncRewards()` is permissionless.
   - The staked position token is non-transferable: `transfer`, `transferFrom` **and `approve`** all `revert TransferDisabled()` (`src/StakedStrat.sol:114-124`). Any integration that calls `approve` on the *position* token breaks. Holders approve the **STRY** token for the staking contract, never the position token.
   - The constructor reverts (bare `revert()`) if `_stratToken` or `_rewardToken` is zero, or if they are equal.

5. **`StopEspnYield.s.sol`:** one final `ESPN.increaseAssetsPerShare(finalYieldAmount)` call. Runs **first** in the global sequence (step 1). What it actually does, verified against `src/EthStrategyPerpetualNote.sol:57-63`:

   ```solidity
   safeTransferFrom(USDS, msg.sender, ESPN, assets);   // caller pays
   safeTransfer(USDS, manager, assets);                // ESPN immediately forwards to manager
   _totalAssets += assets;                             // bookkeeping only
   ```

   Therefore:
   - The caller must **hold and approve** `finalYieldAmount` USDS. Assert both before calling.
   - `manager()` is `0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`, a **contract, and not the redemption multisig**. So `finalYieldAmount` USDS leaves the treasury and lands at a third-party address. This is a real outflow, not a round-trip. It must be an intentional, budgeted decision. Assert `ESPN.manager() != address(0)` (the call reverts on a zero manager) and log the manager address for the signer to eyeball.
   - Post-conditions: `totalAssets()` increased by exactly `finalYieldAmount`; the `AssetsPerShareIncreased` event fired. **Beware the event's field names:** the signature is `AssetsPerShareIncreased(address indexed caller, uint256 newAssetsPerShare, uint256 delta)` but the contract passes post-increment `_totalAssets` into the `newAssetsPerShare` slot (line 62). Assertions on that field must expect **total assets**, not a per-share figure.
   - Emitted as a Safe batch (`USDS.approve(ESPN, finalYieldAmount)` + `ESPN.increaseAssetsPerShare(finalYieldAmount)`) if the payer is the multisig.

6. **`WeeklyYield.s.sol` (repeatable, NOT one-time):** transfers a given USDS amount into the new `StakedStrat` instance, then calls its permissionless `syncRewards()` to start that week's 7-day linear reward stream. Manually run by an operator each week; no cron, no keeper.

   **Hard pre-condition: `stakedStrat.totalStaked() > 0`, revert otherwise.** `_currentRewardsPerShare()` returns early when `totalStaked == 0` (`src/StakedStrat.sol:137`), but `syncRewards()` has already folded the deposit into `totalNotifiedRewards` and started the clock (lines 168-172). Every second elapsed with zero stakers accrues to nobody, and those tokens can **never** be re-notified — a later `syncRewards()` sees `totalDeposited <= totalNotifiedRewards` and early-returns (line 169). Depositing before anyone stakes permanently destroys the deposit. Track B's chronology (deploy → holders stake whenever they choose) makes a day-one loss the default failure mode, so the guard belongs in the script and the loss case belongs in `Verify.s.sol`.

## Components

### Contract: `src/EspnRedemptionToken.sol`

Plain ERC20 + Ownable — **deliberately not** the `MintableBurnableToken`/`TripwireGuard` pattern used by STRAT/CDT/desETH, per the product ask. No permit, no pausing, no burn, no minter allowlist.

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract EspnRedemptionToken is ERC20, Ownable {
    error LengthMismatch();

    constructor(address initialOwner)
        ERC20("ESPN Redemption", "ESPNR")   // name/symbol: placeholder pending founder confirmation
        Ownable(initialOwner)
    {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function mintBatch(address[] calldata to, uint256[] calldata amounts) external onlyOwner {
        if (to.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < to.length; ++i) {
            _mint(to[i], amounts[i]);
        }
    }
}
```

**Why `mintBatch` and not 170 loose `mint()` calls.** `forge script --broadcast` sends one transaction per external call, so a `mint()` loop is ~170 separate transactions. That is not atomic (any mid-batch failure leaves a partial airdrop with no idempotency or resume story), it costs ~170 × 21,000 = ~3.6M gas of pure intrinsic overhead plus per-transaction calldata on top of the real work, and — because `transferOwnership`/`renounceOwnership` follows — a partial batch could leave holders permanently unmintable. `mintBatch` is four lines, makes the airdrop a single atomic transaction, and makes the gas number meaningful. Estimated cost: ~170 × ~25k (cold balance SSTORE + log) ≈ **~4.5M gas**, comfortably inside a block. `Verify.s.sol` measures it; **if the measured figure exceeds ~15M gas, split into chunks of 100 and record the loss of atomicity in the run-book** — at the sizes above it will not.

- Events: standard ERC20 `Transfer` (mints emit `Transfer(address(0), to, amount)`); OZ `OwnershipTransferred`. One custom error, `LengthMismatch`.
- Error cases: `mint`/`mintBatch` by non-owner reverts `OwnableUnauthorizedAccount(caller)`; mint to `address(0)` reverts `ERC20InvalidReceiver(address(0))` (OZ built-ins).
- 18 decimals (OZ default), matching ESPN for the 1:1 airdrop.
- **Ownership end-state: `renounceOwnership()` immediately after `mintBatch`, in the same broadcast.** Both airdrops are one-shot, and `mintBatch` is atomic, so there is no later mint to preserve. Renouncing removes the whole key-custody question and the single-step-`transferOwnership`-to-a-mistyped-address failure mode in one line, without needing `Ownable2Step` (which every other token in this repo uses, and which plain `Ownable` lacks). Gated by Assumption 10.

### Contract: `src/StryToken.sol`

Identical shape to `EspnRedemptionToken` — same base contracts, same `mint`/`mintBatch`, same errors/events, same renounce end-state:

```solidity
contract StryToken is ERC20, Ownable {
    error LengthMismatch();
    constructor(address initialOwner) ERC20("ETH Strategy Yield", "STRY") Ownable(initialOwner) {}
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
    function mintBatch(address[] calldata to, uint256[] calldata amounts) external onlyOwner {
        if (to.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < to.length; ++i) _mint(to[i], amounts[i]);
    }
}
```

Two near-identical single-purpose files are preferred over a shared base contract — the duplication is ~14 lines and each token stays independently auditable.

### Contract: `src/StakedStrat.sol` (existing — ZERO changes)

Not modified. Track B deploys a new instance via `Deploy.s.sol`. Accurate surface summary (the implementer's contract reference):

- `stake(uint256)` — `external nonReentrant whenNotTripped`; pulls STRY via `transferFrom`, so the holder approves **STRY**, not the position token.
- `unstake(uint256)` — its own `external nonReentrant whenNotTripped` function (line 220) that auto-claims first. Not "via the claim path".
- `claim()` — `external nonReentrant whenNotTripped`.
- `migrateStake(address to, uint256 amount)` — `external nonReentrant whenNotTripped`.
- `syncRewards()` — `public whenNotTripped`, **permissionless**.
- `transfer` / `transferFrom` / **`approve`** — all `pure`, all `revert TransferDisabled()`.
- `REWARD_DURATION = 7 days` (constant); `totalStaked`, `totalNotifiedRewards`, `rewardRate`, `periodFinish`, `getPendingRewards(address)`.

**Tripwire consequences to record** (`src/lib/TripwireGuard.sol`, `src/lib/TripwireController.sol`):

- The `TripwireGuard` constructor reverts `InvalidController()` if the controller address is zero **or has no code**, and then calls `controller_.register(address(this), guardian_)`. `register` reverts `ZeroAddress()` on a zero guardian, `CallerNotGuardedContract` if not called by the guarded contract itself (it is), and `AlreadyRegistered` on a second attempt for the same address.
- Registration is **self-service and permissionless** — no controller-owner transaction is needed to onboard the new instance. Good.
- `_CONTROLLER` is `immutable` and the guardian is fixed at construction (changeable only via the controller's propose/accept flow). A wrong `internalAddresses.json` value means **redeploying** the staking contract.
- Trip state is **per guarded contract**, so the new instance does not inherit any protocol-wide trip state.
- `unstake()` is `whenNotTripped`. A trip on this instance **locks stakers' STRY in** until it is untripped. Worth stating to holders.
- **Blocking dependency:** the repo contains `src/lib/TripwireController.sol` but **no record of a deployed controller address** anywhere (`deploymentAddresses.json` lists only STRAT, convertible-note, cdt, esETH). If no `TripwireController` is deployed on mainnet, `Deploy.s.sol` reverts `InvalidController()` and **Track B is blocked** until one is deployed — which is unscoped work. Escalated as Assumption 4.

### Script: `script/snapshot/espn-holders.mjs` (Node ≥18, zero dependencies)

Off-chain holder snapshot. Since only ~170 holders exist, there is **no merkle-claim distributor contract** — the snapshot output feeds direct batch mints.

**`viem` was proposed and is dropped.** It was justified as covering "log-fetching and hashing", but there is no merkle tree so nothing needs hashing, and log-fetching is a handful of `eth_getLogs` JSON-RPC calls that Node 18's global `fetch` handles directly. Adding the repo's first-ever runtime dependency (`package.json` currently has `devDependencies` only, and `files` ships only `src/`) for that is not worth it. If a dependency were kept anyway it would belong in `devDependencies`, not `dependencies` — but none is needed.

**Balances come from `balanceOf`, not from log arithmetic.** Reconstructing `balance[holder] += value / -= value` across every `Transfer` is the error-prone part, and it is unnecessary:

1. **Address discovery:** page `eth_getLogs` for ESPN's `Transfer` topic from the deployment block to `snapshotBlock`, in **chunks of 10,000 blocks** (public and gateway RPCs commonly cap at ~10k blocks and ~10k logs per call), with a bounded retry (3 attempts, exponential backoff) and automatic chunk-halving on a range/size error. Collect the unique set of `from`/`to` addresses from topics 1 and 2. Drop `address(0)`.
2. **Balances:** one `eth_call` of `balanceOf(address)` per candidate **at `blockNumber = snapshotBlock`** (~170-400 calls; batch them as a JSON-RPC array request). This is exact by construction — no reconciliation logic to get wrong.
3. **Invariant:** `sum(balances) == ESPN.totalSupply()` at `snapshotBlock` (also read at that block). **Hard fail on mismatch.** This is a *complete* check, not a spot-check; the two were conflated in the previous draft. It catches a missed log chunk, since a holder whose only `Transfer` fell in a dropped chunk is absent from the address set and their balance is missing from the sum.
4. **Zero balances** are dropped after the invariant check (they contribute 0 to the sum either way).
5. **Exclusions.** ESPN's own NatSpec says "Withdrawals are disabled by default. Exit is via LP" (line 27), so an LP pair very likely holds a material share of supply. A pool address, or any other contract with no route to call `fulfillAdvancedOrder`/`stake`, receives tokens it can never use — dead value, and it inflates `totalSupply(REDEMPTION)` so the ratio-cap arithmetic overstates real capacity. The script therefore:
   - flags every holder with `eth_getCode != "0x"` at `snapshotBlock` as `"isContract": true` in the output;
   - reads an `excludedAddresses` array from `settings.json` (LP pairs, ESPN itself, any address the founder names) and marks those `"excluded": true`;
   - **excludes nothing by default** — exclusion is a founder decision (Assumption 5), and the distribute scripts read the flags and skip `excluded` entries. The `sum == totalSupply` invariant is checked **before** exclusions are applied.
6. **Reorg safety:** `snapshotBlock` **must be at least 64 blocks behind head** (two epochs; prefer the `finalized` tag's block number). The script hard-fails if `head - snapshotBlock < 64`. Without this, a reorged `getLogs` result silently yields a wrong holder set that the `sum == totalSupply` check still passes, because both sides are read from the same reorged view.
7. **Output:** `script/deployments/1/config/espn-holders-<block>.json`:

   ```json
   { "snapshotBlock": 25800591, "totalSupply": "34795546682818036103184", "navPerEspn": "111469817424243522517",
     "holders": [ { "address": "0x...", "balance": "...", "isContract": false, "excluded": false }, ... ] }
   ```

   Sorted by address for determinism. All amounts are plain decimal wei strings. Committed to the repo for reproducibility.

8. **Single source of truth for the snapshot block.** The block appears in the filename and in the JSON body. It does **not** appear in `settings.json`. Every consuming script takes the holders-file path as its input and reads `snapshotBlock` from the file body, asserting that the body value matches the filename. Nothing else may define it.

### Script: `script/deployments/1/003-espn-redemption/Distribute.s.sol`

Plain forge-std `Script`. Reads the holders JSON via `vm.readFile` + `vm.parseJson`. In one broadcast:

1. Deploys `EspnRedemptionToken(deployer)`.
2. Builds the `(address[], uint256[])` arrays from non-`excluded` holders and calls **`mintBatch` once** — 1:1 with snapshot ESPN balances.
3. `renounceOwnership()` (see Assumption 10).
4. Writes the deployed address into `deploymentAddresses.json`.
5. Logs total minted, holder count, excluded count, and **gas for the `mintBatch` transaction**.

In-script post-conditions: `totalSupply() == sum(included balances)`; `owner() == address(0)`; per-holder `balanceOf` verified for **every** included holder (170 view calls is free in a script).

### Script: `script/deployments/1/003-espn-redemption/BuildOrder.s.sol` (+ `BuildOrderLib.sol`)

Modeled on commit 6484357's `Operation.s.sol`/`BuildOrderLib.sol`, minus stoke. Never broadcasts as the treasury on mainnet — it **computes and emits a Safe batch** (see Multisig output). On a fork, `Verify.s.sol` executes the same library calls under `vm.startPrank(treasury)`.

1. Reads addresses + settings from the layered JSON config.
2. Reads live `ESPN.totalAssets()` / `totalSupply()`; derives and grid-snaps `usdsOffer` / `espnAsk` / `redemptionAsk`.
3. Runs the six pre-conditions listed under "Capacity" (treasury USDS balance, decimals, Seaport counter, grid alignment, timestamps, plus the informational usable-capacity log).
4. Builds the single `PARTIAL_OPEN` order (`BuildOrderLib.constructOrderParams`).
5. Computes and logs the order hash (`getOrderHash` with `getCounter(offerer)`) and the holder run-book line (`denominator`, `espnAsk`, `redemptionAsk`, `usdsOffer`).
6. Writes the 2-transaction Safe batch JSON.

`interfaces/ISeaportMinimal.sol` is revived verbatim from commit 6484357.

### Script: `script/deployments/1/003-espn-redemption/Cancel.s.sol`

Emits the 2-transaction Safe batch `Seaport.cancel([orderComponents])` + `USDS.approve(Seaport, 0)`. Rebuilds identical order components from the same config so the cancelled hash provably matches the validated one; asserts the recomputed hash equals the hash logged by `BuildOrder.s.sol` (passed in via settings or env) before emitting.

### Script: `script/deployments/1/003-espn-redemption/Verify.s.sol`

Mainnet-fork verification (see Testing Strategy for the assertion detail).

### Script: `script/deployments/1/004-stry-migration/Distribute.s.sol`

Same single-`mintBatch` pattern as Track A:

1. Deploys `StryToken(deployer)`.
2. Reads live `ESPN.totalAssets()`/`totalSupply()` and `basisPriceUsd` (unscaled `100`) from settings; computes `stryAmount_i` per included holder per the Track B formula.
3. One `mintBatch`, then `renounceOwnership()`, then writes the address to `deploymentAddresses.json`.
4. Asserts the calibration invariant with the **correct tolerance** (below); logs `mintBatch` gas.

**Calibration tolerance.** Each per-holder division truncates up to 1 wei of STRY. Multiplied back by `basisPriceUsd = 100`, that is up to **100 wei of USDS per holder**, so over ~170 holders the assertion tolerance is `holderCount * basisPriceUsd` wei ≈ **17,000 wei**, not "1 wei per holder". The assertion is therefore:

```
espnBackingRepresented = sum(includedBalances) * totalAssets / totalSupply   // excluded holders' backing is not claimed
assert(espnBackingRepresented - totalSupply(STRY) * basisPriceUsd <= holderCount * basisPriceUsd)
assert(totalSupply(STRY) * basisPriceUsd <= espnBackingRepresented)          // truncation only ever undershoots
```

### Script: `script/deployments/1/004-stry-migration/Deploy.s.sol`

Deploys `StakedStrat(STRY, USDS, tripwireController, guardian)`. Controller/guardian from `internalAddresses.json`. Pre-asserts `tripwireController.code.length > 0` with a clear error message before deploying (the constructor's `InvalidController()` revert is otherwise opaque — see Assumption 4). Writes the deployed address into `deploymentAddresses.json` for `WeeklyYield.s.sol` to read.

### Script: `script/deployments/1/004-stry-migration/StopEspnYield.s.sol`

One-time; **runs first in the global sequence**. Emits the Safe batch `USDS.approve(ESPN, finalYieldAmount)` + `ESPN.increaseAssetsPerShare(finalYieldAmount)`. Pre-asserts `ESPN.manager() != address(0)` and `USDS.balanceOf(payer) >= finalYieldAmount`; logs `ESPN.manager()` prominently so the signer sees where the USDS actually goes. Post-asserts `totalAssets()` increased by exactly `finalYieldAmount` and `AssetsPerShareIncreased` fired — expecting **total assets** in the misnamed `newAssetsPerShare` field.

### Script: `script/deployments/1/004-stry-migration/WeeklyYield.s.sol`

Repeatable operational script, manually triggered weekly. Amount supplied per run via env var (`WEEKLY_YIELD_AMOUNT`, plain decimal wei), not `settings.json`, since it changes every run:

0. **`require(stakedStrat.totalStaked() > 0)`** — refuse to deposit into an unstaked pool; the deposit would be unrecoverable (see Track B step 6).
1. `USDS.transfer(stakedStrat, amount)` from the yield payer.
2. `stakedStrat.syncRewards()` — starts/blends the 7-day linear stream.
3. Asserts `periodFinish` moved and `totalNotifiedRewards` increased by `amount`; logs the new `rewardRate` and `periodFinish`.

### Script: `script/deployments/1/004-stry-migration/Verify.s.sol`

Mainnet-fork verification (see Testing Strategy).

### Config: `script/deployments/1/config/*.json`

Same layered shape as the existing files on `main` (`externalAddresses.json` / `internalAddresses.json` / `deploymentAddresses.json` / `settings.json`), **extended, not replaced**, and read with plain `vm.readFile`/`vm.parseJson` — no stoke. Existing content confirmed on `main`:

- `externalAddresses.json` already has `.opensea.seaport`, `.sky-money.USDS`, `WETH`, Lido. Add `.eth-strategy.espn`.
- `internalAddresses.json` already has `.protocol.multisigs.redemption = 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`, `.main`, `.tripwire-guardian = 0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`. Add `.protocol.tripwire.controller` once Assumption 4 closes.
- `deploymentAddresses.json` already has STRAT / convertible-note / cdt / esETH. Scripts append `espn-redemption-token`, `stry`, `staked-stry`.

## Data Flow

### Track A (chronological)

1. Operator runs `espn-holders.mjs` at a finalized `snapshotBlock` → `espn-holders-<block>.json` (committed).
2. `Distribute.s.sol` (deployer EOA): JSON → deploy REDEMPTION → **one `mintBatch`** (1:1 ESPN) → `renounceOwnership()`.
3. `BuildOrder.s.sol`: live NAV → grid-snapped amounts → pre-conditions → Safe batch JSON (approve + validate) → multisig signs and executes → order live.
4. Holder (self-serve, no UI): approves Seaport for ESPN + REDEMPTION → `fulfillAdvancedOrder(numerator = floor(balance × 1e9 / espnAsk), denominator = 1e9)` → receives USDS; treasury receives ESPN + REDEMPTION. First-come-first-served against the shared 700k capacity.
5. Order expires at `endTime`, or the treasury runs `Cancel.s.sol`. Unredeemed capacity stays in the treasury. `Cancel.s.sol` also revokes the USDS allowance.

**Windows in which balances can move, all accepted and all stated:**

- **snapshot → distribute:** ESPN sold in this window means REDEMPTION goes to the *seller*, not the buyer. Because `mintBatch` is a single transaction, this window is minutes, not the hours a 170-transaction loop would have taken.
- **distribute → build order, and build order → expiry:** ESPN remains freely transferable throughout, and so does REDEMPTION. A buyer who acquires ESPN after the snapshot holds no REDEMPTION and cannot fill; a seller holds REDEMPTION and no ESPN and cannot fill either. Both can trade to a counterparty who then can. This is a functioning secondary market, not a bug, and it is why Goal 1 is worded as capped FCFS.
- **`ESPN.burn(uint256)` is public** (`src/EthStrategyPerpetualNote.sol:121`). A holder can burn ESPN after the snapshot and keep their REDEMPTION, which cannot then be used to fill (a fill needs both). Self-harming, no protocol impact. Note that burning also *raises* NAV for everyone else.

### Track B (chronological)

Per the global sequencing table: `StopEspnYield` (step 1) → snapshot (2) → `Distribute` (4) → `Deploy` (7) → holders `stake(STRY)` → first `WeeklyYield` (8) → weekly thereafter. `stake()`/`claim()` are holder-initiated at any time after step 7.

## Config / Parameters

**Unit convention (mandatory, and the reason a previous draft was ambiguous).** JSON has no type annotation, so every numeric setting states its unit in its key or is listed here:

- Every **token amount** is a **plain decimal wei string** — 18 decimals, no `e18` notation (`vm.parseJsonUint` cannot parse `"700000e18"`; the old stoke config's `"2900e18"` only worked because stoke had a custom parser).
- Every **ratio, count, price and grid** is an **unscaled integer**: `redemptionRatio = 5`, `basisPriceUsd = 100` (dollars, *not* a wad — writing `100e18` mints 1e18× too little STRY), `FILL_GRID = 1000000000`.
- Every **timestamp** is unix seconds as a plain decimal string.
- `salt` is a **UTF-8 string**, hashed as `uint256(keccak256(bytes(salt)))`.

| Parameter | Value / Source | Class |
|---|---|---|
| Seaport 1.6 address | `0x0000000000000068F116a894984e2DB1123eB395` | JSON — `externalAddresses.json` |
| USDS address | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` | JSON — `externalAddresses.json` |
| ESPN address | `0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE` | JSON — `externalAddresses.json` |
| Treasury / redemption / offerer multisig | `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` (**ASSUMPTION 1 — unconfirmed**) | JSON — `internalAddresses.json` |
| Tripwire controller | **UNKNOWN — no deployed address recorded; ASSUMPTION 4 blocks Track B** | JSON — `internalAddresses.json` |
| Tripwire guardian | `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8` (existing `.tripwire-guardian`, **confirm for this instance**) | JSON — `internalAddresses.json` |
| REDEMPTION / STRY / StakedStrat deployed addresses | written by the deploy scripts | JSON — `deploymentAddresses.json` |
| `targetRedemptionUsd` | `"700000000000000000000000"` (700,000 USDS, wei string) — raise to ≥ `"775731000000000000000000"` to make the ratio the true cap (Assumption 9) | JSON — `settings.json` |
| `redemptionRatio` | `5` (unscaled) | JSON — `settings.json` |
| `FILL_GRID` | `1000000000` (unscaled; 1e9) | JSON — `settings.json` |
| `basisPriceUsd` | `100` (unscaled dollars, **not a wad**) | JSON — `settings.json` |
| `expectedSeaportCounter` | `0` (asserted at build time; re-read before the run) | JSON — `settings.json` |
| Order `startTime` / `endTime` | unix-second strings; asserted `> block.timestamp` at build time | JSON — `settings.json` |
| Order `salt` | UTF-8 string, e.g. `"espnv3-redemption-1"` | JSON — `settings.json` |
| `excludedAddresses` | array of addresses to skip in both airdrops (Assumption 5) | JSON — `settings.json` |
| `finalYieldAmount` | wei string. **A policy amount the team chooses** (how much final yield to pay) — it is not NAV-derived, so it does not violate the rule below | JSON — `settings.json` |
| `snapshotBlock` | **only** in the holders JSON body + filename; never in `settings.json` | Snapshot artifact |
| Weekly yield amount | per-run env var `WEEKLY_YIELD_AMOUNT` (wei string) | Runtime input |
| `navPerEspn` (`totalAssets()/totalSupply()`) | read live at broadcast time | **Computed at broadcast time** |
| `usdsOffer`, `espnAsk`, `redemptionAsk` | derived from live NAV + settings, then grid-snapped | **Computed at broadcast time** |
| Per-holder REDEMPTION amounts (1:1) | snapshot JSON balances | **Computed at broadcast time** |
| Per-holder STRY amounts | snapshot balances × live NAV ÷ `basisPriceUsd` | **Computed at broadcast time** |
| Order hash | `Seaport.getOrderHash` + `getCounter` | **Computed at broadcast time** |
| Holder `numerator` for a fill | `floor(balance × FILL_GRID / espnAsk)`, computed by the holder | **Computed at fill time** |
| Token names/symbols (`ESPN Redemption`/`ESPNR`, `ETH Strategy Yield`/`STRY`) | constructor constants | **Hardcoded** (in contracts) |
| Token decimals (18) | OZ default; asserted, not assumed | **Hardcoded** |
| `orderType = PARTIAL_OPEN`, `zone = 0`, `conduitKey = 0` | order construction | **Hardcoded** (in BuildOrderLib) |
| `REWARD_DURATION = 7 days` | existing `StakedStrat` constant | **Hardcoded** (pre-existing) |
| StakedStrat name `"Staked STRAT v2"` / `"sSTRAT-v2"` | existing constructor | **Hardcoded** (pre-existing, cosmetic quirk) |

Rule of thumb encoded above: **addresses and policy knobs are JSON; anything NAV-dependent is computed live at broadcast time; only true constants are hardcoded.** No token amount whose value *depends on ESPN's NAV* is ever written into a file. (`targetRedemptionUsd` and `finalYieldAmount` are chosen policy sums, not NAV-derived quantities, and so are correctly in JSON.)

## Testing Strategy

Three layers. Fork verification lives in `Verify.s.sol` per operation, per the shared convention.

**Making the Verify scripts actually runnable.** `foundry.toml` sets `[profile.default] test = "test/unit"` and `[profile.integration] test = "test/integration"`; `forge test` never picks up `script/**/*.s.sol`, so nothing in `yarn test` or `yarn test:integration` would ever execute these. Each Verify script therefore gets a named `package.json` script:

```json
"verify:redemption": "forge script script/deployments/1/003-espn-redemption/Verify.s.sol --fork-url ${FORK_URL:-...} -vvv",
"verify:migration":  "forge script script/deployments/1/004-stry-migration/Verify.s.sol  --fork-url ${FORK_URL:-...} -vvv"
```

reusing the fork URL default already in `test:integration`. The scripts inherit `forge-std`'s `StdCheats` for `deal`, and use `vm.startPrank`/`vm.stopPrank` (not `vm.startBroadcast`) for impersonation — the previous draft's "`vm.startBroadcast(treasury)` after impersonation" conflated the two; broadcast signs with a key, prank does not, and only prank can act as a Safe.

### 1. Mainnet-fork `Verify.s.sol` — Track A (`003-espn-redemption/Verify.s.sol`)

1. `vm.warp` into the order window if `block.timestamp < startTime` (the prior art's Verify did this explicitly; a fork pinned before `startTime` otherwise fails at fulfillment).
2. Prank the deployer → run `Distribute` logic; assert REDEMPTION `totalSupply == sum(included snapshot balances)` and `owner() == address(0)`; **log gas for the single `mintBatch` transaction**.
3. Prank the treasury (`vm.deal(treasury, 1 ether)` for gas; `deal(USDS, treasury, usdsOffer)` **only if** the fork's real balance is short — the live balance is ~1.2M USDS, so on a current fork no funding is needed and the script asserts the real balance instead) → run `BuildOrder` logic → `USDS.approve` + `Seaport.validate`; assert `getOrderStatus` → validated, not cancelled, `totalFilled == 0`.
4. Prank a sample snapshot holder → approve Seaport for ESPN + REDEMPTION → `fulfillAdvancedOrder()` with `denominator = FILL_GRID` and a realistic derived `numerator` (e.g. `floor(holderBalance × FILL_GRID / espnAsk)`), **not** a convenient round fraction like `1/10`. A round fraction happens to divide and would mask the `InexactFraction` class of bug entirely.
5. Assert **exact balance deltas**: holder USDS `+usdsOffer*n/D`, holder ESPN `−espnAsk*n/D`, holder REDEMPTION `−redemptionAsk*n/D`, treasury mirror-image; assert `getOrderStatus` `totalFilled/totalSize` reflects the fraction.
6. A second partial fill by a second holder at a **different** numerator over the same `FILL_GRID` denominator (proves `PARTIAL_OPEN` math against original size, mirroring `95ff244`'s coverage, and proves no cross-scaling occurs).
7. **A deliberate over-large fill** (`numerator` exceeding the remainder) to prove Seaport's clamp still divides exactly on the grid — this is the regression test for the dust-tail failure the grid exists to prevent.
8. **A negative test:** a fill with a non-grid denominator (e.g. `7`) expected to revert `InexactFraction`, documenting the constraint the run-book warns about.
9. Run `Cancel` logic → assert `isCancelled == true` and `USDS.allowance(treasury, Seaport) == 0`.
10. **Log gas for a single fulfillment.**

### 2. Mainnet-fork `Verify.s.sol` — Track B (`004-stry-migration/Verify.s.sol`)

1. Run `StopEspnYield` logic first (prank the payer, `deal` USDS, approve + `increaseAssetsPerShare`); assert `totalAssets()` delta equals `finalYieldAmount` exactly, and assert the USDS landed at `ESPN.manager()` — the point being to make the third-party outflow visible in test output.
2. Distribute STRY (single `mintBatch`) → assert the calibration invariant with the `holderCount * basisPriceUsd` wei tolerance; assert `owner() == address(0)`; **log `mintBatch` gas**.
3. Deploy the new `StakedStrat(STRY, USDS, controller, guardian)`. If no controller address is configured, the script must **fail with an explicit message** naming Assumption 4 rather than reverting opaquely inside `TripwireGuard`.
4. **Zero-staker loss case (must come before the happy path):** with `totalStaked == 0`, transfer USDS in and call `syncRewards()` directly (bypassing the script's guard), warp 1 day, then have a holder stake and warp to `periodFinish`; assert the holder's claim is **less than** the deposit and that a second `syncRewards()` is a no-op — demonstrating the permanent loss the `WeeklyYield.s.sol` guard prevents. Then `vm.revertTo` a snapshot taken before this case.
5. Happy path: prank a sample holder → `STRY.approve(stakedStrat, amount)` → `stake()`.
6. Run `WeeklyYield` logic (including its `totalStaked > 0` guard) → assert `rewardRate`/`periodFinish` set for a 7-day stream and `totalNotifiedRewards` increased by the deposit.
7. `vm.warp(block.timestamp + 7 days)` → holder `claim()` → **assert claimed USDS equals the expected reward** (sole staker ⇒ ~the full week's deposit, minus stream rounding dust).
8. `unstake()` the full position → assert STRY returned and the auto-claim paid out.

### 3. Unit tests (`test/unit/`, plain forge, no fork)

- `EspnRedemptionTokenTest.sol`: owner can `mint` and `mintBatch`; non-owner reverts `OwnableUnauthorizedAccount` for both; `mintBatch` with mismatched array lengths reverts `LengthMismatch`; `mintBatch` of 170 entries produces exactly the expected balances and `totalSupply`; mint to zero address reverts `ERC20InvalidReceiver`; standard ERC20 behavior (transfer, approve/transferFrom, metadata name/symbol/**decimals == 18**); after `renounceOwnership()` both mint functions revert.
- `StryTokenTest.sol`: same shape.
- No unit tests for `StakedStrat` beyond what already exists (`test/unit/StakedStratTest.sol` covers the unchanged contract).

### Gas-cost logging (explicit deliverable)

The team needs real numbers before running for real. Both Verify scripts log, via `console2`:

- gas for the single `mintBatch` distribute transaction (both tokens) — expected ~4.5M for ~170 holders,
- gas for one `fulfillAdvancedOrder` fulfillment,
- gas for `stake` / `syncRewards` / `claim` / `unstake` (informational).

**Measurement caveat that must be honoured, not glossed.** `gasBefore - gasleft()` inside a single script frame measures *execution* gas only. It excludes each transaction's 21,000 intrinsic cost and its calldata cost. For a single `mintBatch` that understates the real figure by ~21k plus ~170 × (20 bytes × 16 gas) ≈ **~76k** — small against 4.5M, and acceptable if stated. Every logged number is therefore printed as **execution gas**, with the intrinsic + calldata overhead added explicitly in a second logged line (`totalEstimated = executionGas + 21000 + calldataGas`). Where a more exact figure is wanted, use `vm.snapshotGas` in a `Test` context or `forge script --slow` dry-run estimates. This caveat is the reason `mintBatch` replaced the 170-transaction loop: for the loop, the excluded overhead (~3.6M) would have been the *dominant* term and the deliverable would have been worthless.

## Explicit Assumptions

**Must be confirmed before any real (non-fork) deployment.** The Verify scripts run fine on these; a mainnet broadcast does not.

1. **Treasury/redemption/offerer multisig = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`** — reused from the prior STRAT ragequit, and present on `main` as `.protocol.multisigs.redemption`. **UNCONFIRMED for this project.** It currently holds ~1,199,676 USDS (enough for the 700k offer) and ~3,199.73 ESPN (9.2% of supply). If wrong, every script's offerer/recipient is wrong.
2. **Reward token for the new StakedStrat instance = USDS** (same as ESPN's `asset()`). **UNCONFIRMED.** If a different reward asset is wanted, only `Deploy.s.sol` config changes — no code changes either way.
3. **"Stop yield" semantics.** `StopEspnYield.s.sol` makes one final `increaseAssetsPerShare()` call, after which the protocol stops calling it. Three things this does **not** give you, all needing confirmation that they are acceptable:
   - `increaseAssetsPerShare` is `external` with **no access control**. Anyone can keep raising NAV afterwards, including while the redemption order is live. The stop is a **policy, not an on-chain state change**; there is no mechanism to prevent further yield.
   - The deployed `withdrawalsDisabled` is **`false`**, not `true` as previously stated. Withdrawals are enabled at the policy level and blocked only by the vault holding ~0.005 USDS. If the manager returns USDS to the vault, holders can withdraw at NAV, bypassing both tracks. Confirm whether `setWithdrawalsDisabled(true)` should be called — note this needs the **ESPN owner** (`0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`, the *main* multisig), not the redemption multisig.
   - `finalYieldAmount` USDS leaves the treasury and lands at `ESPN.manager()` = `0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`, a contract that is **not** the treasury. Confirm this outflow is intended and budgeted.
4. **Tripwire controller for the new StakedStrat instance — BLOCKING FOR TRACK B.** The constructor requires a controller **with code**; `TripwireGuard` reverts `InvalidController()` otherwise. The repo contains `src/lib/TripwireController.sol` but **no deployed address is recorded anywhere** (`deploymentAddresses.json` lists only STRAT, convertible-note, cdt, esETH), and none could be confirmed on mainnet. If no controller is deployed, **deploying one is unscoped work that blocks Track B entirely** — escalate to the founder before planning Track B. Registration itself is permissionless/self-service, so no controller-owner transaction is needed once an address exists. Guardian assumed to be the existing `.protocol.multisigs.tripwire-guardian` (`0xC53CCed...`); confirm. Both are fixed at construction — a wrong value means redeploying.
5. **Exclusion list.** ESPN's design routes exit through an LP ("Exit is via LP"), so an LP pair almost certainly holds ESPN, and the treasury demonstrably holds 9.20%. Tokens airdropped to a pool or to any non-acting contract are dead value and inflate `totalSupply(REDEMPTION)`, overstating the ratio cap. The snapshot script flags contracts and honours a founder-supplied `excludedAddresses`; it excludes **nothing by default**. Confirm which addresses (LP pairs, the treasury itself, ESPN itself) should be excluded from each airdrop.
6. **Disposition of the ESPN the treasury reclaims.** Fills send ESPN back to the treasury. `ESPN.burn(uint256)` is public. Burning raises NAV for remaining holders and reduces `totalAssets()`; holding leaves the treasury with a claim on its own backing (and, if Track B ran on the same snapshot, with STRY minted against that same ESPN). Unspecified either way — confirm burn or hold, and when.
7. **Both-tracks reconciliation — decision required.** See "Cross-track reconciliation". Ship both off one snapshot and accept that the $100 basis is nominal (default, option 2), size STRY post-redemption (option 1), or ship one track (option 3). This spec defaults to option 2 and needs sign-off.
8. **ESPN `depositCap` is wide open** (`1e26`, ~26× current backing), so anyone can mint new ESPN after the snapshot. New ESPN receives no REDEMPTION and no STRY, but it **does** change `totalSupply()`, which both tracks' broadcast-time formulas read. `setDepositCap(0)` is an existing owner-only call (ESPN owner = the main multisig, not the redemption multisig). Confirm whether to close deposits before the snapshot, or explicitly accept that leaving them open is safe for the window involved.
9. **`targetRedemptionUsd = 700,000` makes the offer, not the 5:1 ratio, the binding cap** (ratio capacity is ~775,731 USDS; ~704,396 excluding the treasury's own holdings). Redemption is therefore first-come-first-served. Confirm this is intended, or raise `targetRedemptionUsd` to ≥ 775,731 USDS to make the ratio the true cap.
10. **`renounceOwnership()` after `mintBatch`.** Recommended: both airdrops are one-shot and `mintBatch` is atomic, so renouncing removes all key-custody and mistyped-address risk in one line. Confirm no future mint is wanted. If it is, use `transferOwnership(treasury)` instead and accept plain `Ownable`'s single-step risk (or the repo's `Ownable2Step` pattern, at the cost of the "deliberately simple" constraint).
11. **`EspnRedemptionToken` name/symbol** (`"ESPN Redemption"` / `"ESPNR"`): placeholder pending confirmation. STRY's name/symbol were specified by the founder.
12. **StakedStrat naming quirk:** the new instance is named `"Staked STRAT v2"` / `"sSTRAT-v2"` (hardcoded in the unchanged contract) despite staking STRY. Accepted as cosmetic under the zero-code-change constraint; confirm the team is fine with it.
13. **Snapshot block choice** is an operational decision made at run time; it must be ≥ 64 blocks behind head, and both tracks must use the **same** block (subject to Assumption 7 option 1, which deliberately breaks this).

## Out of Scope

- **UI** — none. Holders interact with Seaport directly (Etherscan/scripts) using the run-book fraction formula; the team publishes the order hash, `espnAsk`, `redemptionAsk`, `usdsOffer` and `FILL_GRID` alongside it.
- **LP deployment** — no liquidity-pool creation or seeding script for STRY or REDEMPTION.
- **Weekly-yield automation** — no cron, keeper, Gelato, or CI schedule. `WeeklyYield.s.sol` is manually triggered; automation, if ever wanted, wraps the same script later.
- **Merkle distributor / claim flow** — deliberately replaced by a single-transaction batch mint (~170 holders).
- **Changes to any existing contract's code** (`StakedStrat`, `EthStrategyPerpetualNote`, tokens). Calling existing owner-only setters is a founder decision (Assumptions 3, 8), not part of this build unless those assumptions say otherwise.
- **A Seaport zone or restricted order type** to limit fills to snapshot holders. Consequence: capacity is publicly contested (Assumption 9, Goal 1).
- **Reviving `src/ESPNRedemptionQueue.sol`** — the deleted queue mechanism needed a liquid vault, which ESPN is not.
- **A new runtime JS dependency** — `viem` was considered and dropped; the snapshot script uses Node ≥18's global `fetch`.
- **The `stoke` framework** — private and unavailable; its shape is replicated with plain forge-std, its code is not used.
- **ESPN contract wind-down beyond the yield stop** (upgrading, self-destruct) — out of scope unless Assumption 3's confirmation says otherwise.
