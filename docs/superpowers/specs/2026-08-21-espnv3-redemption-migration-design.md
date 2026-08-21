# ESPNv3: ESPN Redemption + Migration to Yield-Paying Token — Design Spec

- **Date:** 2026-08-21
- **Branch:** `espn-redemption`
- **Status:** Approved design (interactively brainstormed with founder); ready for planning/implementation
- **Chain:** Ethereum mainnet (chain id 1)

## Overview

ESPN (`EthStrategyPerpetualNote`, an ERC4626 vault over USDS) is being wound down for its ~170 holders via two independent tracks:

- **Track A — Pro-Rata Redemption:** airdrop a simple redemption token (1:1 with ESPN balances at a snapshot), then let holders redeem ESPN + redemption tokens for USDS through a single Seaport 1.6 `PARTIAL_OPEN` order validated by the treasury multisig. Seaport's own partial-fill math handles pro-rata settlement atomically; no custom swap contract.
- **Track B — Migration to a yield-paying token:** airdrop a new token STRY ("ETH Strategy Yield") to the same snapshot holders, calibrated to a $100 basis price against ESPN's USDS backing; deploy a **new instance** of the existing, unmodified `StakedStrat` contract with `stratToken = STRY`, `rewardToken = USDS`; stop ESPN yield with one final `increaseAssetsPerShare()` call; pay weekly USDS yield into the new staking contract via a manually-run script.

Deliverables are **contracts + Foundry deploy/verify scripts + one Node snapshot script only**. No UI, no LP deployment, no automation infrastructure (see Out of Scope).

### Confirmed on-chain facts (verified via `cast` against mainnet)

| Fact | Value |
|---|---|
| ESPN (EthStrategyPerpetualNote, ERC4626) | `0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE` |
| ESPN `asset()` = USDS | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` |
| ESPN `totalSupply()` | `34795546682818036103184` (~34,795.5 ESPN, 18 decimals) |
| ESPN `totalAssets()` | `3878653235910468821362228` (~3,878,653.2 USDS) |
| Known ESPN holders | ~170 |
| Seaport 1.6 | `0x0000000000000068F116a894984e2DB1123eB395` |

### Prior art (in this repo's git history, recoverable via `git show`)

The exact Seaport mechanism was built once before as the STRAT ragequit, then removed from main (the one-off order expired; the approach was sound):

- `6484357` "feat: add rage quit deployment and verification" — `script/deployments/1/002-rage-quit-order/{BuildOrderLib.sol, Operation.s.sol, Verify.s.sol, interfaces/ISeaportMinimal.sol}` plus `script/deployments/1/config/*.json`.
- `95ff244` "test: seaport ragequit tests" — `test/forge/seaport/{README.md, SeaportRageQuit.t.sol, interfaces/ISeaportMinimal.sol, lib/SeaportOrderLib.sol}`.

**Mandatory deviation from prior art:** the prior scripts depended on `stoke` (`git@github.com:frontier159/stoke` — `StokeOperation`/`OperationRunner`/`Context`/`Config`/`Logger`), a **private repo that is not accessible in this build**. Do **not** depend on it. Replicate the same *shape* — numbered `script/deployments/1/NNN-name/` folders, layered JSON config, a fork-based `Verify.s.sol` per operation — using **plain forge-std `Script`/`Test` only** (`vm.readFile`/`vm.parseJson` for config, `vm.prank`/`vm.startBroadcast`/`vm.warp`/`vm.deal` for fork verification).

## Goals

1. Let every snapshot ESPN holder redeem pro-rata for USDS (Track A), capped at ~700,000 USDS aggregate capacity.
2. Migrate holders onto STRY with USDS yield via a fresh `StakedStrat` instance (Track B).
3. Stop new ESPN yield after one final top-up.
4. Every deploy/operation script has a companion mainnet-fork `Verify.s.sol` with balance-delta assertions and gas logging, so real-world cost and behavior are sanity-checked before any real broadcast.
5. Keep new code deliberately minimal: two plain ERC20+Ownable tokens, zero changes to existing contracts.

## Non-Goals

- No UI of any kind.
- No LP-deployment script.
- No automated/cron weekly-yield system — the weekly-yield script is manually triggered.
- No merkle-claim distributor (holder count ~170 makes direct batch mint cheaper and simpler).
- No changes to `StakedStrat.sol`, `EthStrategyPerpetualNote.sol`, or any existing contract.
- No custom Seaport zone, ContractOfferer, or swap contract — the stock Seaport 1.6 partial-fill order is the whole mechanism.
- No `MintableBurnableToken`/`TripwireGuard` machinery on the two new tokens (deliberate, per product ask).

## Architecture

```
                         ┌────────────────────────────────┐
                         │  script/snapshot/espn-holders  │
                         │  (Node + viem, off-chain)      │
                         │  ESPN Transfer logs → balances │
                         └───────────────┬────────────────┘
                                         │ holders JSON (shared by both tracks)
              ┌──────────────────────────┴─────────────────────────┐
              ▼                                                    ▼
 TRACK A (redemption)                                  TRACK B (migration)
 ┌──────────────────────────┐                          ┌──────────────────────────┐
 │ EspnRedemptionToken       │                          │ StryToken (STRY)         │
 │ (new, ERC20+Ownable)      │                          │ (new, ERC20+Ownable)     │
 │ Distribute.s.sol: 1:1     │                          │ Distribute.s.sol: $100   │
 │ batch mint to holders     │                          │ basis-price batch mint   │
 └────────────┬─────────────┘                          └────────────┬─────────────┘
              ▼                                                     ▼
 ┌──────────────────────────┐                          ┌──────────────────────────┐
 │ BuildOrder.s.sol          │                          │ Deploy.s.sol: NEW        │
 │ treasury validates one    │                          │ StakedStrat instance     │
 │ Seaport PARTIAL_OPEN order│                          │ (STRY / USDS) — zero     │
 │ offer: ~700k USDS (live   │                          │ code changes             │
 │ NAV-derived)              │                          ├──────────────────────────┤
 │ consideration per unit:   │                          │ StopEspnYield.s.sol:     │
 │ 5 REDEMPTION + 1 ESPN     │                          │ final increaseAssets-    │
 └────────────┬─────────────┘                          │ PerShare() on ESPN       │
              ▼                                        ├──────────────────────────┤
 holders call Seaport                                  │ WeeklyYield.s.sol:       │
 fulfillAdvancedOrder()                                │ USDS in + syncRewards()  │
 (partial fills, pro-rata)                             │ (repeatable, manual)     │
                                                       └──────────────────────────┘
```

The two tracks are independent: they share only the snapshot tooling and the layered JSON config. Either can ship without the other.

### Directory layout (new files)

```
script/
  snapshot/
    espn-holders.mjs                  # Node + viem snapshot script
  deployments/1/
    config/
      externalAddresses.json          # Seaport, USDS, ESPN
      internalAddresses.json          # treasury multisig (+ tripwire controller/guardian)
      settings.json                   # per-operation settings (see Config section)
      espn-holders-<block>.json       # snapshot output (committed for reproducibility)
    003-espn-redemption/              # Track A
      BuildOrderLib.sol
      Distribute.s.sol
      BuildOrder.s.sol
      Verify.s.sol
      interfaces/ISeaportMinimal.sol  # revived from commit 6484357
    004-stry-migration/               # Track B
      Distribute.s.sol
      Deploy.s.sol
      StopEspnYield.s.sol
      WeeklyYield.s.sol
      Verify.s.sol
src/
  EspnRedemptionToken.sol
  StryToken.sol
test/unit/
  EspnRedemptionTokenTest.sol
  StryTokenTest.sol
```

Numbering continues the prior art's `001`/`002` sequence.

## Track A — Pro-Rata Redemption

### Mechanism

1. Snapshot ESPN balances at a chosen block (off-chain script, see Components).
2. Deploy `EspnRedemptionToken` and batch-mint it **1:1** with each holder's snapshot ESPN balance, straight to holder addresses. No claim step, no merkle tree — ~170 direct mints.
3. Treasury multisig calls `Seaport.validate()` on a **single `PARTIAL_OPEN` order** (offerer = treasury). No signature needed for a validated order; no custom contract.
   - **Offer:** a capped USDS amount targeting ~700,000 USDS of aggregate redemption capacity.
   - **Consideration (per fill unit, paid to treasury):** 5 REDEMPTION-token units + 1 ESPN-token unit.
4. Any holder approves Seaport for ESPN + REDEMPTION and calls `fulfillAdvancedOrder()` with their own `numerator/denominator` (fractions are against the **original** order size, not remaining — Seaport 1.6 semantics). Seaport settles atomically: USDS out of treasury, ESPN + REDEMPTION into treasury.

### The 5:1 ratio is the cap

REDEMPTION is airdropped 1:1 against ESPN supply, and each redeemed ESPN unit consumes 5 REDEMPTION units. Therefore max aggregate redeemable ESPN = `totalSupply(REDEMPTION) / 5` ≈ 6,959.1 ESPN, which at current NAV (~111.47 USDS/ESPN) ≈ 775k USDS — already close to the ~700k target. The cap is enforced **naturally by the consideration ratio plus the finite USDS offer**; nothing else enforces it. The BuildOrder script *validates* that the derived amounts are mutually consistent; it does not add a separate cap mechanism.

### Dynamic amount derivation (no stale hardcodes)

NAV moves, so the exact token amounts are computed **at broadcast time** in `BuildOrder.s.sol` from live chain state:

```
navPerEspn        = ESPN.totalAssets() * 1e18 / ESPN.totalSupply()     // USDS per ESPN, wad
espnAsk           = targetRedemptionUsd * 1e18 / navPerEspn            // ESPN consideration amount
redemptionAsk     = espnAsk * redemptionRatio                          // = espnAsk * 5
usdsOffer         = espnAsk * navPerEspn / 1e18                        // ≈ targetRedemptionUsd
```

`targetRedemptionUsd` (~700,000e18) and `redemptionRatio` (5) are `settings.json` inputs; the three token amounts are derived, logged, and used to build the order. The script requires `redemptionAsk <= EspnRedemptionToken.totalSupply()` (sanity: the airdrop covers the ask).

### Order shape (following commit 6484357's `BuildOrderLib`)

- `orderType = PARTIAL_OPEN` (open fulfillment, partial fills allowed)
- `offerer = treasury multisig`, `zone = address(0)`, `zoneHash = bytes32(0)`, `conduitKey = bytes32(0)` (direct Seaport approvals, no conduit)
- `offer = [ERC20 USDS, usdsOffer]`
- `consideration = [ERC20 REDEMPTION, redemptionAsk, recipient=treasury], [ERC20 ESPN, espnAsk, recipient=treasury]`
- `startTime` / `endTime` / `salt` from `settings.json`
- Treasury must `approve(Seaport, usdsOffer)` on USDS before or as part of the validate transaction batch.
- Post-validate assertions (as in prior art): `getOrderStatus(orderHash)` → `isValidated == true`, `isCancelled == false`, `totalFilled == 0`.

## Track B — Migration to Yield-Paying Token

### Mechanism

1. Reuse the **same snapshot output** as Track A (same ~170 holders, same snapshot block).
2. Deploy `StryToken` (symbol `STRY`, name `ETH Strategy Yield`) and batch-mint to holders.
3. **Calibration — $100 basis price:** total STRY supply is sized so `totalSupply(STRY) * basisPriceUsd == ESPN's total USDS backing at snapshot`:

```
stryAmount_i = espnBalance_i * navPerEspn / (basisPriceUsd * 1e18)
             = espnBalance_i * ESPN.totalAssets() / (ESPN.totalSupply() * basisPriceUsd)
```

   `basisPriceUsd` (100) is a `settings.json` input; `navPerEspn` is read live at broadcast/snapshot time, never hardcoded. At current NAV this yields ~38,786.5 STRY total (~3.878M USDS / $100).
4. **New `StakedStrat` instance, zero code changes.** The existing contract's constructor is already generic:

   ```solidity
   constructor(address _stratToken, address _rewardToken, ITripwireController controller_, address guardian_)
   ```

   `Deploy.s.sol` deploys it with `_stratToken = STRY`, `_rewardToken = USDS`, and controller/guardian addresses from `internalAddresses.json`. Notes (facts of the unmodified contract, accepted under the zero-code-change constraint):
   - The ERC20 name/symbol are hardcoded `"Staked STRAT v2"` / `"sSTRAT-v2"`; the new instance will carry that name even though it stakes STRY. Cosmetic only.
   - The staked position token is non-transferable; `REWARD_DURATION = 7 days` is a constant; `syncRewards()` is permissionless.
5. **`StopEspnYield.s.sol`:** one final `ESPN.increaseAssetsPerShare(finalYieldAmount)` call paying the last ESPN yield. `increaseAssetsPerShare` is permissionless but pulls USDS via `safeTransferFrom(msg.sender, ...)`, so the caller (treasury/manager) must hold and approve `finalYieldAmount` USDS. After this, the protocol simply stops calling it. ESPN's `withdrawalsDisabled` already defaults to `true` in the deployed contract, so no additional state change is obviously needed — **flagged in Explicit Assumptions** since "stop yield" might mean more than "stop calling increaseAssetsPerShare".
6. **`WeeklyYield.s.sol` (repeatable, NOT one-time):** transfers a given USDS amount into the new `StakedStrat` instance, then calls its permissionless `syncRewards()` to start that week's 7-day linear reward stream. Manually run by an operator each week; no cron, no keeper.

## Components

### Contract: `src/EspnRedemptionToken.sol`

Plain ERC20 + Ownable — **deliberately not** the `MintableBurnableToken`/`TripwireGuard` pattern used by STRAT/CDT/desETH, per the product ask. No permit, no pausing, no burn, no minter allowlist.

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract EspnRedemptionToken is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("ESPN Redemption", "ESPNR")   // name/symbol: placeholder pending founder confirmation
        Ownable(initialOwner)
    {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
```

- Events: standard ERC20 `Transfer` (mints emit `Transfer(address(0), to, amount)`); OZ `OwnershipTransferred`. No custom events.
- Error cases: `mint` by non-owner reverts `OwnableUnauthorizedAccount(caller)`; mint to `address(0)` reverts `ERC20InvalidReceiver(address(0))` (both OZ built-ins). No custom errors.
- 18 decimals (OZ default), matching ESPN for the 1:1 airdrop.
- Ownership: deployer mints the airdrop, then `transferOwnership(treasury)` so no EOA retains mint power.

### Contract: `src/StryToken.sol`

Identical shape to `EspnRedemptionToken` — same base contracts, same `mint`, same errors/events:

```solidity
contract StryToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("ETH Strategy Yield", "STRY") Ownable(initialOwner) {}
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
}
```

Two near-identical single-purpose files are preferred over a shared base contract — the duplication is ~10 lines and each token stays independently auditable.

### Contract: `src/StakedStrat.sol` (existing — ZERO changes)

Not modified. Track B deploys a new instance via `Deploy.s.sol`. Relevant existing surface: `stake(uint256)`, `unstake(uint256)` (via claim path), `claim()`, `syncRewards()` (permissionless), `REWARD_DURATION = 7 days`, `TripwireGuard` gating (`whenNotTripped`), non-transferable position token.

### Script: `script/snapshot/espn-holders.mjs` (Node + viem)

Off-chain holder snapshot. Since only ~170 holders exist, there is **no merkle-claim distributor contract** — the snapshot output feeds direct batch mints.

- Fetches all ESPN `Transfer` events from the deployment block to a chosen `snapshotBlock` (`getLogs`, chunked block ranges), reconstructs `balance[holder] += value` on receipt / `-= value` on send, drops zero balances and `address(0)`.
- Cross-checks `sum(balances) == ESPN.totalSupply()` at `snapshotBlock` (via `balanceOf`/`totalSupply` multicall spot-checks); hard-fails on mismatch.
- Output: `script/deployments/1/config/espn-holders-<block>.json` — `{ "snapshotBlock": N, "totalSupply": "…", "holders": [{ "address": "0x…", "balance": "…" }, …] }`, sorted by address for determinism. Committed to the repo for reproducibility.
- **This adds `viem` as the repo's first and only runtime JS dependency** (the repo currently has devDependencies only). viem covers log-fetching and hashing; nothing else is added.

### Script: `script/deployments/1/003-espn-redemption/Distribute.s.sol`

Plain forge-std `Script`. Reads the holders JSON via `vm.readFile` + `vm.parseJson`. In one broadcast:

1. Deploys `EspnRedemptionToken(deployer)`.
2. Loops holders, `mint(holder, espnBalance)` — 1:1, ~170 mints.
3. `transferOwnership(treasury)`.
4. Logs total minted, holder count, and **total gas used for the batch** (this is a real cost the team must sanity-check before running for real).

Post-conditions asserted in-script: `totalSupply() == snapshot totalSupply`, spot-check a few holder balances.

### Script: `script/deployments/1/003-espn-redemption/BuildOrder.s.sol` (+ `BuildOrderLib.sol`)

Modeled on commit 6484357's `Operation.s.sol`/`BuildOrderLib.sol`, minus stoke. Broadcast as the treasury multisig (fork: `vm.startBroadcast(treasury)` after impersonation; real run: produces the calldata for the multisig).

1. Reads addresses + settings from the layered JSON config.
2. Reads live `ESPN.totalAssets()` / `totalSupply()`; derives `usdsOffer` / `redemptionAsk` / `espnAsk` per the formulas in Track A. Validates `redemptionAsk <= REDEMPTION.totalSupply()`.
3. Builds the single `PARTIAL_OPEN` order (`BuildOrderLib.constructOrderParams`), approves Seaport for `usdsOffer` USDS, calls `Seaport.validate(orders)`.
4. Computes and logs the order hash (`getOrderHash` with `getCounter(offerer)`); asserts `getOrderStatus` → validated, not cancelled, unfilled.

`interfaces/ISeaportMinimal.sol` is revived verbatim from commit 6484357.

### Script: `script/deployments/1/003-espn-redemption/Verify.s.sol`

Mainnet-fork verification (see Testing Strategy for the assertion detail).

### Script: `script/deployments/1/004-stry-migration/Distribute.s.sol`

Same batch-mint pattern as Track A's Distribute:

1. Deploys `StryToken(deployer)`.
2. Reads live `ESPN.totalAssets()`/`totalSupply()` and `basisPriceUsd` from settings; mints `stryAmount_i` per holder per the Track B formula.
3. `transferOwnership(treasury)`.
4. Asserts `totalSupply(STRY) * basisPriceUsd ≈ ESPN.totalAssets()` (within rounding dust of 1 wei per holder); logs batch gas.

### Script: `script/deployments/1/004-stry-migration/Deploy.s.sol`

Deploys the new `StakedStrat(STRY, USDS, tripwireController, guardian)`. Controller/guardian come from `internalAddresses.json`. Logs the deployed address into the config layer (`deployedAddresses` section) for the later scripts to read.

### Script: `script/deployments/1/004-stry-migration/StopEspnYield.s.sol`

One-time. As treasury/manager: `USDS.approve(ESPN, finalYieldAmount)` then `ESPN.increaseAssetsPerShare(finalYieldAmount)` (`finalYieldAmount` from `settings.json`). Asserts `totalAssets()` increased by exactly `finalYieldAmount` and the `AssetsPerShareIncreased` event fired.

### Script: `script/deployments/1/004-stry-migration/WeeklyYield.s.sol`

Repeatable operational script, manually triggered weekly. Amount supplied per run via env var (e.g. `WEEKLY_YIELD_AMOUNT`), not settings.json, since it changes every run:

1. `USDS.transfer(stakedStrat, amount)` from the yield payer.
2. `stakedStrat.syncRewards()` — starts/blends the 7-day linear stream.
3. Asserts `RewardsSynced` fired and `periodFinish` moved; logs new `rewardRate`.

### Script: `script/deployments/1/004-stry-migration/Verify.s.sol`

Mainnet-fork verification (see Testing Strategy).

### Config: `script/deployments/1/config/*.json`

Same layered shape as the deleted prior art (external / internal / deployed addresses + settings), read with plain `vm.readFile`/`vm.parseJson` — **no stoke**. Contents in the Config/Parameters section below.

## Data Flow

### Track A (chronological)

1. Operator runs `espn-holders.mjs` at chosen `snapshotBlock` → `espn-holders-<block>.json` (committed).
2. `Distribute.s.sol` (deployer EOA): JSON → deploy REDEMPTION → 170 mints (1:1 ESPN) → ownership to treasury.
3. `BuildOrder.s.sol` (treasury): live NAV → derived amounts → USDS approve → `Seaport.validate()` → order live.
4. Holder (self-serve, no UI): approves Seaport for ESPN + REDEMPTION → `fulfillAdvancedOrder(numerator/denominator vs original order size)` → receives pro-rata USDS; treasury receives ESPN + REDEMPTION.
5. Order expires at `endTime` (or treasury cancels); unredeemed capacity stays in the treasury.

### Track B (chronological)

1. Same snapshot JSON as Track A.
2. `Distribute.s.sol` (deployer EOA): live NAV + `basisPriceUsd` → deploy STRY → 170 calibrated mints → ownership to treasury.
3. `Deploy.s.sol`: new `StakedStrat(STRY, USDS, controller, guardian)`.
4. `StopEspnYield.s.sol` (treasury/manager): final `increaseAssetsPerShare(finalYieldAmount)`; ESPN yield stops thereafter.
5. Weekly, manually: `WeeklyYield.s.sol` → USDS into StakedStrat → `syncRewards()` → holders `stake(STRY)` / `claim()` USDS.

## Config / Parameters

Explicit split of where every value lives:

| Parameter | Value / Source | Class |
|---|---|---|
| Seaport 1.6 address | `0x0000000000000068F116a894984e2DB1123eB395` | JSON — `externalAddresses.json` |
| USDS address | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` | JSON — `externalAddresses.json` |
| ESPN address | `0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE` | JSON — `externalAddresses.json` |
| Treasury / redemption / offerer multisig | `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` (**ASSUMPTION — unconfirmed**) | JSON — `internalAddresses.json` |
| Tripwire controller + guardian (for new StakedStrat) | existing protocol instances (**needs confirmation**) | JSON — `internalAddresses.json` |
| REDEMPTION / STRY / StakedStrat deployed addresses | written after deploy | JSON — deployed-addresses layer |
| `targetRedemptionUsd` (~700,000e18) | settings | JSON — `settings.json` |
| `redemptionRatio` (5) | settings | JSON — `settings.json` |
| `basisPriceUsd` (100) | settings | JSON — `settings.json` |
| Order `startTime` / `endTime` / `salt` | settings | JSON — `settings.json` |
| `snapshotBlock` | settings | JSON — `settings.json` |
| `finalYieldAmount` (StopEspnYield) | settings | JSON — `settings.json` |
| Weekly yield amount | per-run env var (`WEEKLY_YIELD_AMOUNT`) | Runtime input |
| `navPerEspn` (`totalAssets()/totalSupply()`) | read live at broadcast time | **Computed at runtime** |
| `usdsOffer`, `espnAsk`, `redemptionAsk` (order amounts) | derived from live NAV + settings | **Computed at runtime** |
| Per-holder REDEMPTION amounts (1:1) | snapshot JSON balances | **Computed at runtime** (from snapshot) |
| Per-holder STRY amounts | snapshot balances × live NAV ÷ `basisPriceUsd` | **Computed at runtime** |
| Order hash | `Seaport.getOrderHash` + `getCounter` | **Computed at runtime** |
| Token names/symbols (`ESPN Redemption`/`ESPNR`, `ETH Strategy Yield`/`STRY`) | constructor constants | **Hardcoded** (in contracts) |
| Token decimals (18) | OZ default | **Hardcoded** |
| `orderType = PARTIAL_OPEN`, `zone = 0`, `conduitKey = 0` | order construction | **Hardcoded** (in BuildOrderLib) |
| `REWARD_DURATION = 7 days` | existing `StakedStrat` constant | **Hardcoded** (pre-existing) |
| StakedStrat name `"Staked STRAT v2"` / `"sSTRAT-v2"` | existing constructor | **Hardcoded** (pre-existing, cosmetic quirk) |

Rule of thumb encoded above: **addresses and policy knobs are JSON; anything NAV-dependent is computed live at broadcast time; only true constants are hardcoded.** No token amount that depends on ESPN's NAV is ever written into a file.

## Testing Strategy

Three layers, per the shared convention: every deploy/operation script gets a companion mainnet-fork `Verify.s.sol` modeled directly on commit 6484357's Verify pattern (actor impersonation via `vm.prank`/`vm.deal`, `vm.warp` for time, before/after balance assertions, gas logging).

### 1. Mainnet-fork `Verify.s.sol` — Track A (`003-espn-redemption/Verify.s.sol`)

Runs against a mainnet fork (`FOUNDRY_PROFILE=integration` fork URL convention already in `package.json`):

1. Impersonate the deployer → run `Distribute` logic; assert REDEMPTION `totalSupply` == snapshot ESPN supply; **log gas for the full ~170-mint batch**.
2. Impersonate the treasury (`vm.deal` for gas) → run `BuildOrder` logic; assert order validated/uncancelled/unfilled via `getOrderStatus`.
3. Impersonate a sample snapshot holder → approve Seaport for ESPN + REDEMPTION → `fulfillAdvancedOrder()` with a partial fraction (e.g. numerator/denominator = 1/10 of the original order size).
4. Assert **exact balance deltas**: holder USDS +expected, holder ESPN −expected, holder REDEMPTION −expected (5× ESPN units), treasury USDS −expected, treasury ESPN/REDEMPTION +expected; assert `getOrderStatus` `totalFilled/totalSize` reflects the fraction.
5. A second partial fill by a second holder (proves `PARTIAL_OPEN` math against original size, mirroring `95ff244`'s test coverage).
6. **Log gas for a single fulfillment.**

### 2. Mainnet-fork `Verify.s.sol` — Track B (`004-stry-migration/Verify.s.sol`)

1. Distribute STRY (batch-mint) → assert `totalSupply(STRY) * basisPriceUsd ≈ ESPN.totalAssets()`; **log batch gas**.
2. Deploy the new `StakedStrat(STRY, USDS, controller, guardian)`.
3. Impersonate a sample holder → `STRY.approve` → `stake()`.
4. Run `WeeklyYield` logic: impersonate the yield payer, transfer USDS in, `syncRewards()`; assert `rewardRate`/`periodFinish` set for a 7-day stream.
5. `vm.warp(block.timestamp + 7 days)` → holder `claim()` → **assert claimed USDS equals the expected pro-rata reward amount** (sole staker ⇒ ~full week's deposit, minus stream rounding dust).
6. Run `StopEspnYield` logic (impersonate treasury/manager, approve + `increaseAssetsPerShare`); assert `totalAssets()` delta.

### 3. Unit tests (`test/unit/`, plain forge, no fork)

- `EspnRedemptionTokenTest.sol`: owner can `mint`; non-owner `mint` reverts `OwnableUnauthorizedAccount`; mint to zero address reverts `ERC20InvalidReceiver`; standard ERC20 behavior (transfer, approve/transferFrom, metadata name/symbol/decimals); ownership transfer moves mint rights.
- `StryTokenTest.sol`: same shape.
- No unit tests for `StakedStrat` beyond what already exists (`test/unit/StakedStratTest.sol` covers the unchanged contract).

### Gas-cost logging (explicit deliverable)

The team needs real numbers before running for real. Both Verify scripts log, via `console2`:

- total gas for the ~170-mint batch distribute (both tokens),
- gas for one `fulfillAdvancedOrder` fulfillment,
- gas for `stake` / `syncRewards` / `claim` (informational).

Measured as `gasBefore - gasleft()` around the call (or `vm.snapshotGas` equivalents), printed with labels so the output is copy-pasteable into the run checklist.

## Explicit Assumptions

**Must be confirmed before any real (non-fork) deployment.** The Verify scripts run fine on these assumptions; a mainnet broadcast does not.

1. **Treasury/redemption/offerer multisig = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`** — reused from the prior STRAT ragequit. **UNCONFIRMED.** If wrong, every script's offerer/recipient/owner is wrong.
2. **Reward token for the new StakedStrat instance = USDS** (same as ESPN's `asset()`). **UNCONFIRMED.** If the team wants a different reward asset, only `Deploy.s.sol` config changes — no code changes either way.
3. **"Stop yield" semantics:** `StopEspnYield.s.sol` only makes one final `increaseAssetsPerShare()` call and then the protocol stops calling it. ESPN's `withdrawalsDisabled` already defaults to `true` on the deployed contract, so no additional state change is obviously needed — but confirm "stop yield" doesn't mean something more (e.g. pausing deposits via `depositCap`, renouncing the manager, or a public announcement artifact).
4. **Tripwire controller + guardian for the new StakedStrat instance:** the constructor requires them (`constructor(address, address, ITripwireController, address)`). Assumed: reuse the protocol's existing deployed controller and guardian. Needs confirmation of the concrete addresses for `internalAddresses.json`.
5. **StakedStrat naming quirk:** the new instance will be named `"Staked STRAT v2"` / `"sSTRAT-v2"` (hardcoded in the unchanged contract) despite staking STRY. Accepted as cosmetic under the zero-code-change constraint; confirm the team is fine with it.
6. **`EspnRedemptionToken` name/symbol** (`"ESPN Redemption"` / `"ESPNR"`): placeholder pending confirmation; STRY's name/symbol were specified by the founder.
7. **Snapshot block choice** is an operational decision made at run time; both tracks must use the **same** block.

## Out of Scope

- **UI** — none. Holders interact via Seaport directly (etherscan/scripts); the team can point them at the order hash.
- **LP deployment** — no liquidity-pool creation or seeding script for STRY or REDEMPTION.
- **Weekly-yield automation** — no cron, keeper, Gelato, or CI schedule. `WeeklyYield.s.sol` is manually triggered; automation, if ever wanted, wraps the same script later.
- **Merkle distributor / claim flow** — deliberately replaced by direct batch mint (~170 holders).
- **Changes to any existing contract** (`StakedStrat`, `EthStrategyPerpetualNote`, tokens).
- **The `stoke` framework** — private and unavailable; its shape is replicated with plain forge-std, its code is not used.
- **ESPN contract wind-down beyond yield stop** (e.g. upgrading, pausing deposits, self-destruct) — out of scope unless assumption 3's confirmation says otherwise.
