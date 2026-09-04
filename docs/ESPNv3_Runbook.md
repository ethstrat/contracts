# ESPNv3 Redemption + Migration Operator Run-Book

There is **no UI**. This document is the entire holder-facing and operator-facing
interface for both Track A (`003-espn-redemption`) and Track B (`004-stry-migration`).
Numbers below are real, captured from `yarn verify:redemption` and `yarn verify:migration`
against `SNAPSHOT_BLOCK=25800912` (see `script/deployments/1/config/espn-holders-25800912.json`).

## 1. Open assumptions — must be closed before any non-fork broadcast

These are Explicit Assumptions 1–13 from the design spec, of which **4 and 12 are retired
— Merkl replaces the staking contract**. The remaining 11 need sign-off before mainnet.
Four of them gate the schedule itself:

- [ ] 1. **Treasury/redemption/offerer multisig = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`.** Reused from the prior STRAT ragequit. **UNCONFIRMED for this project.** Wrong address ⇒ every script's offerer/recipient is wrong.
- [ ] 2. **Reward token for the weekly Merkl campaign = USDS.** Merkl-whitelisted, minimum 1 USDS per campaign-hour (≥ 168 USDS per 7-day campaign) — confirmed on-chain. Founder sign-off on USDS as the yield token: **still open.**

  The on-chain fact proves Merkl *accepts* USDS as an incentive token; it says nothing about whether USDS is the token the founder intends STRY holders to be paid in, which is what this assumption actually asks.
- [ ] 3. **"Stop yield" semantics.** `StopEspnYield.s.sol` makes one final `increaseAssetsPerShare()` call, after which no more calls are made from this project. Three things this does **not** give you, all needing confirmation:
  - `increaseAssetsPerShare` is external with **no access control** — anyone can keep raising NAV afterwards, including while the redemption order is live. This is a policy stop, not an on-chain state change.
  - The deployed `withdrawalsDisabled` is **`false`**, not `true`. Withdrawals are blocked today only by the vault's ~0.005 USDS balance, not by policy: **if `ESPN.manager()` ever returns USDS to the vault, holders can withdraw at NAV and bypass both tracks.** Confirm whether `setWithdrawalsDisabled(true)` should be called — this needs the **ESPN owner** (`0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`, the *main* multisig), **not** the redemption multisig used everywhere else in this document.
  - `finalYieldAmount` USDS leaves the treasury and lands at `ESPN.manager()` (`0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`), a third-party contract, not the treasury. Confirm this outflow is intended and budgeted — **`settings.json` currently ships `finalYieldAmount = "0"`, see section 8.**
- [x] 4. ~~Tripwire controller — BLOCKS TRACK B.~~ **Retired:** no staking contract is deployed; Merkl distributes directly to STRY holders.
- [ ] 5. Exclusion list (`excludedAddresses` in `settings.json`) is currently empty. LP pairs and the treasury's own holdings inflate the ratio cap if left in. Confirm which addresses to exclude from each airdrop.
- [ ] 6. Disposition of ESPN the treasury reclaims from fills: burn (raises NAV, shrinks `totalAssets()`) or hold. Confirm which, and when.
- [ ] 7. **Cross-track reconciliation.** Track A pays out ≤700,000 USDS; Track B mints STRY nominally claiming the *full* ESPN backing (~$3.88M at the snapshot used here) off the same snapshot — an ~18% overstatement if both ship as specified. This plan defaults to Option 2 (ship both off one snapshot, state $100 is a nominal basis price, not a redemption guarantee) per the spec. Needs sign-off.
- [ ] 8. **`depositCap` is wide open at `1e26`.** Anyone can mint new ESPN after the snapshot; it changes `ESPN.totalSupply()`, which both tracks' broadcast-time formulas read. Confirm whether to close deposits (`setDepositCap(0)`, ESPN owner only) before the snapshot, or accept the window as-is.
- [ ] 9. **`targetRedemptionUsd = 700,000` is the binding cap, not the 5:1 ratio ⇒ first-come-first-served.** Ratio capacity is ~704,396 USDS (ex-treasury) at this snapshot — only ~0.6% headroom. Confirm FCFS is intended, or raise `targetRedemptionUsd` to make the ratio the true cap.
- [ ] 10. `renounceOwnership()` after `mintBatch` for both tokens — no future mint possible. Confirm no further mint is wanted.
- [ ] 11. `EspnRedemptionToken` name/symbol (`"ESPN Redemption"` / `"ESPNR"`) — placeholder, unconfirmed.
- [x] 12. ~~The new staking contract's instance is cosmetically named "Staked STRAT v2".~~ **Retired:** no staking contract is deployed; Merkl distributes directly to STRY holders.
- [ ] 13. Snapshot block choice is operational, ≥64 blocks behind head, same block for both tracks (subject to Assumption 7 option 1, which deliberately breaks this).

**Assumptions 1, 7, 8 and 9 gate the schedule** — see Step 0 below.

## 2. Mandated global sequence

Running these out of order silently prices the two airdrops off two different NAVs.

| # | Step | Track |
|---|---|---|
| 0 | Close Assumptions 1, 7, 8, 9 | — |
| 0b | Before the **first** `WeeklyYield.s.sol` run: message Merkl support with the STRY address so the campaign is displayed and priced. `ERC20LOGPROCESSOR` scores any ERC20 from its `Transfer` logs and needs no on-chain registration; this is a UI/API-recognition step only. | B |
| 1 | `StopEspnYield.s.sol` — final `increaseAssetsPerShare` | B |
| 2 | Choose `snapshotBlock` ≥ 64 behind head; run `espn-holders.mjs` | shared |
| 3 | Track A `Distribute.s.sol` | A |
| 4 | Track B `Distribute.s.sol` | B |
| 5 | Track A `BuildOrder.s.sol` (Safe batch: approve + validate) | A |
| 6 | Holders fulfil, FCFS, until `endTime` or capacity exhausted | A |
| 7 | Track B `WeeklyYield.s.sol` (Safe batch: `approve` [+ `acceptConditions`] + `createCampaign`), weekly, from step 4 onward | B |
| 8 | `Cancel.s.sol` after `endTime` (cancel + revoke USDS approval) | A |

Step 1 must precede step 5: `usdsOffer` is pinned at `targetRedemptionUsd` regardless of
NAV, so the treasury's USDS outlay is bounded either way; what a higher NAV changes is
`espnAsk` — the treasury reclaims **less ESPN** for the same 700k. That is the honest
price, and it is why the yield stop must not land in the middle of the redemption window.

**Freeze `settings.json` between steps 5 and 8.** `Cancel.s.sol` re-derives the order from
`orderStartTime`, `orderEndTime` and `orderSalt` in `settings.json` and hard-reverts if the
recomputed hash does not match the order hash `BuildOrder.s.sol` printed at step 5 (see
section 8 for the one edit that must happen *before* step 5, not after). Editing
`settings.json` again after step 5 makes step 8 unable to produce a cancel batch, leaving a
live 700,000 USDS Seaport allowance with no way to revoke it through this run-book.

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
            = in practice, floor(yourRedemptionBalance * denominator / redemptionAsk)
              -> you can redeem at most 20% of your ESPN
            (the shorthand only equals your ESPN balance for addresses whose REDEMPTION
             balance still equals their ESPN balance, i.e. no REDEMPTION bought or sold
             since the airdrop — see section 4)

you pay     : espnAsk * numerator / denominator ESPN
              and redemptionAsk * numerator / denominator REDEMPTION
you receive : usdsOffer * numerator / denominator USDS
```

`BuildOrderLib.deriveNumerator` clamps `numerator` to `denominator` if the `min(...)` above
would exceed it (only reachable by an address holding a large majority of REDEMPTION
supply) — a fill can never ask for more than 100% of the grid.

- `denominator` **must be `1000000000`** — this is the `fillGrid` value in `settings.json`
  (`.espnv3.fillGrid`). Some design-spec prose calls the same value `FILL_GRID`, but that
  identifier does not exist anywhere in the source; use `fillGrid` when talking to holders.
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

From `SNAPSHOT_BLOCK=25800912 yarn verify:migration`:

| Operation | Execution gas |
|---|---|
| Track B `mintBatch` (113 holders) | 2,808,622 (2,865,782 total estimated) |
| `createCampaign` (Merkl, weekly) | 292,812 (319,508 total estimated) |

**Caveat:** `gasBefore - gasleft()` inside a script frame measures *execution* gas only.
It excludes each transaction's 21,000 intrinsic cost and its calldata cost. For Track A's
113-holder `mintBatch` this understates the real figure by 86,468 gas total (21,000
intrinsic + 65,468 calldata, i.e. the gap between the execution and total-estimated figures
above) — well under 100k, small against ~2.8M execution gas — and acceptable if stated,
which is why every number above that matters is printed both ways.

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
- `script/deployments/1/multisig/004-stry-migration/001-0x0cbe9bDD-multisig.json` — `StopEspnYield.s.sol` (payer is `.protocol.multisigs.redemption`, the same address and prefix as the two Track A batches above)
- `script/deployments/1/multisig/004-stry-migration/<NNN>-0x0cbe9bDD-multisig.json`, `NNN ≥ 002` — `WeeklyYield.s.sol`, one new file per weekly run. The index is **allocated by the script as the first free one** (`001` belongs to `StopEspnYield.s.sol`); it is never an env var and an existing weekly batch is never overwritten. To redo a week whose batch was generated but not yet signed, delete that file first. `WeeklyYield.s.sol`'s env is `WEEKLY_YIELD_AMOUNT` (plain decimal wei, changes every run) and `WEEKLY_YIELD_START` (hour-aligned unix seconds, more than 1 day ahead) — there is no index var.

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
4. **`WeeklyYield.s.sol` batch:** `USDS.approve(DistributionCreator, amount)` **then**
   `DistributionCreator.acceptConditions()` — *included only when the live check demands
   it; with the redemption Safe on Merkl's `userSignatureWhitelist` today, the batch has
   two transactions, not three* — **then** `DistributionCreator.createCampaign(params)`.

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
yarn verify:migration
```

Both Verify scripts derive the holders file from `SNAPSHOT_BLOCK` — it is the only env var
they need. `HOLDERS_FILE` applies to the broadcast scripts below, not to verification.

This section replaces the `script/snapshot/README.md` an earlier draft proposed — one
document, not two to keep in sync.

**Broadcast scripts (steps 1, 3, 4, 5, 8)**, each run as
`forge script <path> --rpc-url $RPC_URL --broadcast`:

| Step | Script | Required env |
|---|---|---|
| 1 | `004-stry-migration/StopEspnYield.s.sol` | none (reads `settings.json`/`internalAddresses.json`) |
| 3 | `003-espn-redemption/Distribute.s.sol` | `HOLDERS_FILE` |
| 4 | `004-stry-migration/Distribute.s.sol` | `HOLDERS_FILE` |
| 5 | `003-espn-redemption/BuildOrder.s.sol` | `HOLDERS_FILE` |
| 8 | `003-espn-redemption/Cancel.s.sol` | `USDS_OFFER`, `ESPN_ASK`, `REDEMPTION_ASK`, `EXPECTED_ORDER_HASH` — the four values step 5 printed |

Steps 1, 5, 7, 8 (`StopEspnYield`, `BuildOrder`, `WeeklyYield`, `Cancel`) never broadcast —
each writes a Safe batch instead (see section 6). Steps 3 and 4 broadcast directly from the
deployer's own key: the two `Distribute` scripts mint and airdrop. `WeeklyYield.s.sol`
writes a Safe batch that the redemption Safe executes — it never broadcasts and never moves
USDS itself.

## 8. Resetting placeholder config before broadcast

`settings.json` ships `orderStartTime` / `orderEndTime` as a future-dated placeholder:

```
orderStartTime = 1798761600  (2027-01-01T00:00:00Z)
orderEndTime   = 1799366400  (2027-01-08T00:00:00Z)
```

These **must be edited to the real window** before `BuildOrder.s.sol` is run for
broadcast (step 5). `BuildOrder.s.sol` hard-reverts if `orderStartTime <= block.timestamp`
— this is the forcing function that prevents broadcasting a stale window. Do not edit
`settings.json` again after step 5 runs — see the freeze note in section 2.

Fork verification is immune to this: `Verify.s.sol` warps unconditionally into the order
window regardless of wall-clock time, so the placeholder dates do not block testing.

`settings.json` also ships `finalYieldAmount = "0"`. Step 1 (`StopEspnYield.s.sol`) reads
this value directly into its Safe batch: `USDS.approve(ESPN, finalYieldAmount)` then
`ESPN.increaseAssetsPerShare(finalYieldAmount)`. Left at `0`, that batch is a no-op — the
"final top-up" the mandated sequence is built around never happens. Set the real amount
(Assumption 3) before step 1's batch is generated, or explicitly decide `0` is correct and
record that decision.

`WEEKLY_YIELD_START` is Track B's stale-value forcing function, the same role
`orderStartTime` plays for Track A. `WeeklyYield.s.sol` hard-reverts unless
`start > block.timestamp + 1 day` **and** `start % 3600 == 0`, so a start left over from
last week cannot produce a campaign that is already partly elapsed by the time the Safe
funds it. Merkl's `createCampaign` does not check `startTimestamp` against the clock, which
is why the script must.

## 9. Track B holder notes

- **Hold STRY. That is the whole action.** There is no staking step, no position token,
  and no approval to give. Merkl reads STRY `Transfer` logs, time-weights each holder's
  balance over the campaign week, and splits the week's USDS pro-rata.
- **Claim on Merkl.** Use app.merkl.xyz, or call
  `Distributor.claim(users, tokens, amounts, proofs)` on
  `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` directly. Leaves are cumulative, and Merkl's
  API serves the proofs.
- **Timing.** The engine scores roughly every 2 hours and posts a merkle root roughly
  every 8 hours (4–12 h), with a 1–2 h dispute window before newly posted rewards become
  claimable. Expect rewards to appear ~8–12 h after each campaign hour is scored, not
  instantly.
- **Contracts that hold STRY and cannot call `claim` — LP pairs above all — accrue
  rewards they can never collect**, unless they are blacklisted from the campaign or the
  rewards are forwarded. `settings.json` ships `.espnv3.merkl.blacklist = []`, i.e.
  nothing is blacklisted today.
- **A 3% Merkl fee is deducted from each weekly amount** before it reaches the
  Distributor. The script logs gross, fee and net every run so the signer sees it.
- **`$100 is a nominal basis price, not a redemption guarantee.`** STRY nominally claims
  the full ESPN backing at the snapshot; it is not backed to the extent Track A's 700,000
  USDS redemption pool is.
- **Merkl's off-chain half is not covered by `yarn verify:migration`** — scoring,
  merkle-root posting and holder claims cannot be exercised on a fork. The acceptance
  check is manual: within ~12 h of the Safe executing a weekly batch, confirm
  `GET https://api.merkl.xyz/v4/campaigns?chainId=1&creatorAddress=0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`
  lists the new campaign with `type: ERC20LOGPROCESSOR` and a non-zero `apr`/`dailyRewards`.
  If it does not, the campaign is funded but unscoreable — escalate before the next weekly
  run.
