# ESPNv3 Redemption + Migration Operator Run-Book

There is **no UI**. This document is the entire holder-facing and operator-facing
interface for both Track A (`003-espn-redemption`) and Track B (`004-stry-migration`).
Numbers below are real, captured from `yarn verify:redemption` and `yarn verify:migration`
against `SNAPSHOT_BLOCK=25800912` (see `script/deployments/1/config/espn-holders-25800912.json`).

## 1. Open assumptions — must be closed before any non-fork broadcast

These are Explicit Assumptions 1-13 from the design spec. All 13 need sign-off before
mainnet. Four of them gate the schedule itself:

1. **Treasury/redemption/offerer multisig = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`.** Reused from the prior STRAT ragequit. **UNCONFIRMED for this project.** Wrong address ⇒ every script's offerer/recipient is wrong.
2. Reward token for the new `StakedStrat` instance = USDS. **UNCONFIRMED.**
3. "Stop yield" semantics: no access control on `increaseAssetsPerShare`, `withdrawalsDisabled == false`, `finalYieldAmount` USDS lands at `ESPN.manager()` (a third party, not the treasury). Confirm all three are acceptable.
4. **Tripwire controller — BLOCKS TRACK B.** `internalAddresses.json`'s `.tripwire.controller` is currently `0x0000000000000000000000000000000000000000`. `StakedStrat`'s constructor reverts `InvalidController()` against an address with no code. **Deploying a controller is unscoped work and must be escalated before Track B is planned further**, let alone broadcast.
5. Exclusion list (`excludedAddresses` in `settings.json`) is currently empty. LP pairs and the treasury's own holdings inflate the ratio cap if left in. Confirm which addresses to exclude from each airdrop.
6. Disposition of ESPN the treasury reclaims from fills: burn (raises NAV, shrinks `totalAssets()`) or hold. Confirm which, and when.
7. **Cross-track reconciliation.** Track A pays out ≤700,000 USDS; Track B mints STRY nominally claiming the *full* ESPN backing (~$3.88M at the snapshot used here) off the same snapshot — an ~18% overstatement if both ship as specified. This plan defaults to Option 2 (ship both off one snapshot, state $100 is a nominal basis price, not a redemption guarantee) per the spec. Needs sign-off.
8. **`depositCap` is wide open at `1e26`.** Anyone can mint new ESPN after the snapshot; it changes `ESPN.totalSupply()`, which both tracks' broadcast-time formulas read. Confirm whether to close deposits (`setDepositCap(0)`, ESPN owner only) before the snapshot, or accept the window as-is.
9. **`targetRedemptionUsd = 700,000` is the binding cap, not the 5:1 ratio ⇒ first-come-first-served.** Ratio capacity is ~704,396 USDS (ex-treasury) at this snapshot — only ~0.6% headroom. Confirm FCFS is intended, or raise `targetRedemptionUsd` to make the ratio the true cap.
10. `renounceOwnership()` after `mintBatch` for both tokens — no future mint possible. Confirm no further mint is wanted.
11. `EspnRedemptionToken` name/symbol (`"ESPN Redemption"` / `"ESPNR"`) — placeholder, unconfirmed.
12. `StakedStrat`'s new instance is cosmetically named `"Staked STRAT v2"` / `"sSTRAT-v2"` despite staking STRY (unchanged contract, hardcoded). Confirm acceptable.
13. Snapshot block choice is operational, ≥64 blocks behind head, same block for both tracks (subject to Assumption 7 option 1, which deliberately breaks this).

**Assumptions 1, 4, 7, 8 gate the schedule** — see Step 0 below.

## 2. Mandated global sequence

Running these out of order silently prices the two airdrops off two different NAVs.

| # | Step | Track |
|---|---|---|
| 0 | Close Assumptions 1, 4, 7, 8 | — |
| 1 | `StopEspnYield.s.sol` — final `increaseAssetsPerShare` | B |
| 2 | Choose `snapshotBlock` ≥ 64 behind head; run `espn-holders.mjs` | shared |
| 3 | Track A `Distribute.s.sol` | A |
| 4 | Track B `Distribute.s.sol` | B |
| 5 | Track A `BuildOrder.s.sol` (Safe batch: approve + validate) | A |
| 6 | Holders fulfil, FCFS, until `endTime` or capacity exhausted | A |
| 7 | Track B `Deploy.s.sol` (new `StakedStrat`) | B |
| 8 | Holders `stake(STRY)`, **then** the first `WeeklyYield.s.sol` run | B |
| 9 | `Cancel.s.sol` after `endTime` (cancel + revoke USDS approval) | A |

Step 1 must precede step 5: `usdsOffer` is pinned at `targetRedemptionUsd` regardless of
NAV, so the treasury's USDS outlay is bounded either way; what a higher NAV changes is
`espnAsk` — the treasury reclaims **less ESPN** for the same 700k. That is the honest
price, and it is why the yield stop must not land in the middle of the redemption window.

Step 8's order matters: yield deposited into `StakedStrat` with zero stakers is destroyed
permanently (see WeeklyYield notes, section 9).

## 3. Holder fill instructions

**You can redeem at most 20% of your ESPN.** REDEMPTION was airdropped 1:1 with ESPN and
the order consumes 5 REDEMPTION per ESPN redeemed, so your REDEMPTION balance, not your
ESPN balance, sets the maximum.

Figures below are from the real `BuildOrder.s.sol` / `Verify.s.sol` run against
`SNAPSHOT_BLOCK=25800912`:

```
order hash    = 0x326cbf176a77740c199c19d21d13234cdff67d5bdbc71cf92a1d142a37b594d8
espnAsk       = 6279726801165000000000   (6,279.726801165 ESPN)
redemptionAsk = 31398634005825000000000  (31,398.634005825 REDEMPTION)
usdsOffer     = 700000000000000000000000 (700,000 USDS)

denominator = 1000000000
numerator   = min( floor(yourEspnBalance * denominator / espnAsk),
                    floor(yourRedemptionBalance * denominator / redemptionAsk) )
            = in practice, floor(yourEspnBalance * denominator / redemptionAsk)
              -> you can redeem at most 20% of your ESPN

you pay     : espnAsk * numerator / denominator ESPN
              and redemptionAsk * numerator / denominator REDEMPTION
you receive : usdsOffer * numerator / denominator USDS
```

- `denominator` **must be `1000000000`** (this is the `fillGrid` JSON key / `FILL_GRID`
  Solidity constant — same value, two names for two audiences; use the one matching your
  context, do not mix them in one sentence to a holder).
- Any other denominator will most likely revert `InexactFraction`.
- Approve **Seaport directly** — `0x0000000000000068F116a894984e2DB1123eB395` — for both
  ESPN and REDEMPTION. There is no conduit.
- Sub-grid dust (your balance beyond the last exact grid unit) is retained, not
  redeemable.

## 4. What "pro-rata" does and does not mean

Capacity is capped at 700,000 USDS and is **first-come-first-served**, not a guaranteed
per-holder entitlement. In practice the pool is unlikely to be exhausted:

- Theoretical ex-treasury capacity at this snapshot: **704,395.92 USDS** (`usableRedemption`) — only ~0.6% headroom over the 700,000 offer.
- Reachable capacity, further excluding contract holders (LP pairs above all — REDEMPTION held by an address that cannot call `approve`/`fulfillAdvancedOrder` is permanently stranded): **635,251.45 USDS** (`reachableRedemption`).
- Each holder is capped at 20% of their ESPN by the 5:1 REDEMPTION ratio.

REDEMPTION is a plain, freely-transferable ERC20, and the order is `PARTIAL_OPEN` with no
zone. Anyone — including non-holders who buy REDEMPTION from apathetic holders and ESPN
from the LP — can consume capacity ahead of snapshot holders. This is accepted, not a bug;
a zone is explicitly out of scope.

## 5. Measured gas numbers

From `SNAPSHOT_BLOCK=25800912 yarn verify:redemption`:

| Operation | Execution gas | Total estimated (execution + 21,000 intrinsic + calldata) |
|---|---|---|
| Track A `mintBatch` (113 holders) | 2,814,900 | 2,901,368 |
| Track A `fulfillAdvancedOrder` (single fill) | 48,641 | 78,153 |

From `SNAPSHOT_BLOCK=25800912 HOLDERS_FILE=script/deployments/1/config/espn-holders-25800912.json yarn verify:migration`:

| Operation | Execution gas |
|---|---|
| Track B `mintBatch` (113 holders) | 2,808,623 (2,865,783 total estimated) |
| `stake` | 140,286 |
| `syncRewards` (WeeklyYield) | 123,824 |
| `claim` | 77,842 |
| `unstake` | 43,185 |

**Caveat:** `gasBefore - gasleft()` inside a script frame measures *execution* gas only.
It excludes each transaction's 21,000 intrinsic cost and its calldata cost. For a single
`mintBatch` this understates the real figure by ~21k plus ~113 holders × (20 bytes × 16
gas) ≈ well under 100k — small against ~2.8M, and acceptable if stated, which is why every
number above that matters is printed both ways.

**Chunking rule:** if a `mintBatch` transaction's total estimated gas exceeds 15,000,000,
chunk the batch into groups of 100 holders per transaction instead of one transaction for
the whole holder set. At 113 holders and ~2.9M total estimated gas this run does not need
chunking; the rule exists for a larger holder set or a future snapshot.

## 6. Safe batch files

`BuildOrder.s.sol`, `Cancel.s.sol` and `StopEspnYield.s.sol` cannot broadcast from a Safe —
they each write a Safe Transaction Builder JSON batch to
`script/deployments/1/multisig/<operation>/<NNN>-<safe-prefix>-multisig.json`:

- `script/deployments/1/multisig/003-espn-redemption/001-0x0cbe9bDD-multisig.json` — `BuildOrder.s.sol`
- `script/deployments/1/multisig/003-espn-redemption/002-0x0cbe9bDD-multisig.json` — `Cancel.s.sol`
- `script/deployments/1/multisig/004-stry-migration/001-<payer-prefix>-multisig.json` — `StopEspnYield.s.sol`

Every transaction in every batch is written as **raw calldata**: `"data": "0x…"`,
`"contractMethod": null`. The Transaction Builder therefore shows **no decoded
parameters** when the batch is imported — the signer verifies the `to` address and the
4-byte selector by eye, and the counterpart assertions run by the corresponding `Verify`
script are the proof that the payload does what it claims. `"checksum"` is `null` in every
written batch; the Transaction Builder re-derives it on import, this is expected and not
an error.

Execution order within each batch matters and is fixed by the order the script writes the
`transactions` array — do not reorder on import:

1. **`BuildOrder.s.sol` batch:** `USDS.approve(Seaport, usdsOffer)` **then**
   `Seaport.validate([order])`.
2. **`Cancel.s.sol` batch:** `Seaport.cancel([orderComponents])` **then**
   `USDS.approve(Seaport, 0)`. The USDS allowance survives order expiry; leaving a live
   700k allowance to Seaport after the window is an unnecessary standing risk.
3. **`StopEspnYield.s.sol` batch:** `USDS.approve(ESPN, finalYieldAmount)` **then**
   `ESPN.increaseAssetsPerShare(finalYieldAmount)`.

## 7. Operator env quick-reference

Snapshot script (`script/snapshot/espn-holders.mjs`):

| Env var | Required | Default |
|---|---|---|
| `RPC_URL` | yes | — |
| `SNAPSHOT_BLOCK` | no | `finalized` tag's block number |
| `ESPN_ADDRESS` | no | `0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE` |
| `SETTINGS_PATH` | no | `script/deployments/1/config/settings.json` |

- `yarn snapshot:espn` — runs the live snapshot against `RPC_URL`.
- `yarn snapshot:selftest` — runs the script's offline self-test (exit 0 = pass), no RPC needed.
- An invariant failure (`sum(balances) != totalSupply`) means the snapshot is unusable — do not proceed to Distribute with it.
- **The snapshot block lives only in the output filename (`espn-holders-<block>.json`) and the file body — never in `settings.json`.** `settings.json` has no snapshot-block field by design.

Before running either fork verification, export `SNAPSHOT_BLOCK` read off the holders
filename you're verifying against, so both fork runs pin to the snapshot block:

```
export SNAPSHOT_BLOCK=25800912
yarn verify:redemption
HOLDERS_FILE=script/deployments/1/config/espn-holders-25800912.json yarn verify:migration
```

This section replaces the `script/snapshot/README.md` an earlier draft proposed — one
document, not two to keep in sync.

## 8. Resetting the order window before broadcast

`settings.json` ships `orderStartTime` / `orderEndTime` as a future-dated placeholder:

```
orderStartTime = 1798761600  (2027-01-01T00:00:00Z)
orderEndTime   = 1799366400  (2027-01-08T00:00:00Z)
```

These **must be edited to the real window** before `BuildOrder.s.sol` is run for
broadcast. `BuildOrder.s.sol` hard-reverts if `orderStartTime <= block.timestamp` — this
is the forcing function that prevents broadcasting a stale window.

Fork verification is immune to this: `Verify.s.sol` warps unconditionally into the order
window regardless of wall-clock time, so the placeholder dates do not block testing.

## 9. Track B holder notes

- Approve **STRY**, not the position token, for the `StakedStrat` instance.
- The staked position token is **non-transferable**: `transfer`, `transferFrom` and
  `approve` all revert `TransferDisabled()`. Any integration that tries to `approve` the
  position token breaks.
- `unstake` takes an amount argument (partial unstake is supported).
- The instance is cosmetically named `"Staked STRAT v2"` / `"sSTRAT-v2"` even though it
  stakes STRY — a fact of the unchanged `StakedStrat` contract, accepted under the
  zero-code-change constraint.
- A tripwire trip locks staked STRY in until untripped.
- **`$100 is a nominal basis price, not a redemption guarantee.`** STRY nominally claims
  the full ESPN backing at the snapshot; it is not backed to the extent Track A's 700,000
  USDS redemption pool is.

## Definition of done (for this task)

- `forge build` and `FOUNDRY_PROFILE=integration forge build` both clean.
- `yarn test` green.
- `forge fmt --check` clean.
- `yarn snapshot:selftest` exits 0 offline.
- `SNAPSHOT_BLOCK=25800912 yarn verify:redemption` passes every assertion and prints both gas figures (captured above).
- `SNAPSHOT_BLOCK=25800912 HOLDERS_FILE=script/deployments/1/config/espn-holders-25800912.json yarn verify:migration` passes end to end, all steps (captured above).
- `git status` clean after both verify runs.
- `docs/ESPNv3_Runbook.md` (this file) exists with the real order hash and gas numbers filled in.
