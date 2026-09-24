# EARN Deploy + Uniswap V4 EARN/USDS LP — Design Spec

- **Date:** 2026-09-24
- **Branch:** `EARN-deploy`
- **Status:** Design, with the adversarial review folded in (1 blocking, 7 should-fix, 10 nits). User-confirmed decisions are recorded as decisions. Items that need the user's sign-off are listed first. Open items are in the last section.
- **Chain:** Ethereum mainnet (chain id 1)
- **Extends:** [`2026-08-21-espnv3-redemption-migration-design.md`](2026-08-21-espnv3-redemption-migration-design.md) (Track B) and [`2026-09-04-stry-merkl-yield-design.md`](2026-09-04-stry-merkl-yield-design.md). This spec reverses that spec's Assumption 10 for EARN and adds the LP deployment that spec listed as out of scope.

## 0. Decisions needing user sign-off

Format: recommendation | reason | alternatives. Until the user signs off, the spec uses the default shown in the recommendation.

- SO1. Safe USDS runway (O8). Recommendation: before step 7, the user confirms a USDS inflow plan for the redemption Safe. | Reason: 615,087.33 USDS − 500,000 LP = 115,087.33 USDS. That covers ~3.4 PeriodicYield periods (~33,791 USDS each, airdrop-only base), about 95 days, with no inflow. | Alternatives: (a) reduce `lp.singleSidedUsds`, which is a config change only; (b) accept ~3 periods and top up later from the main multisig.
- SO2. Pool init shape (O1). Recommendation: keep D14's 6-tx shape. | Reason: the `amountMax` values already make a front-run initialization at any wrong price revert the whole batch (R6). A direct `PoolManager.initialize` tx adds only a clearer revert reason (`PoolAlreadyInitialized`). | Alternative: the 7-tx shape, with `PoolManager.initialize` as its own tx followed by the multicall without `initializePool`.
- SO3. Recovery if the pool key is taken by someone else (R6). Recommendation: pre-agree that the fallback is a config-only re-key: same fee 3000 and hooks 0, `lp.tickSpacing` changed from 60 to 30, then re-run ProposeLp. | Reason: a front-run costs the attacker gas only and makes the 3000/60/0 key unusable at 100. A re-key needs no new code. | Alternatives: (a) a price-reset swap if the pool has zero liquidity (needs a router, which is new code); (b) a hook-bearing key (reverses D5).
- SO4. Mint authority (D10, R9). Recommendation: accept that EARN mint authority is the redemption Safe. That Safe is 1-of-1, so the authority belongs in practice to the signers of main multisig `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`. | Reason: this is the current on-chain configuration (Safe 1.4.1, threshold 1, one owner). | Alternatives: (a) raise the redemption Safe's threshold or owner set before step 3; (b) transfer EARN ownership to a dedicated minter Safe. (b) changes D1/D8.
- SO5. Uniswap protocol fee (R12). Recommendation: accept. | Reason: the PoolManager's protocol fee controller returns 500 pips per direction (0.05%) for 3000/60 keys. Once anyone calls `triggerFeeUpdate(key)`, swappers pay ~0.35% in total. The protocol fee is taken from swap input, not from LP principal. | Alternative: a different fee tier. That reverses D5 and must be re-checked against the controller's `getFee`.
- SO6. Assumption 1 (O6). Recommendation: confirm `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` as the redemption Safe. | Reason: on-chain it is a Safe 1.4.1, 1-of-1 under the main multisig, holding 615,087.33 USDS at block 26043909. Under D8, a wrong target is unrecoverable. | Alternative: none. Nothing broadcasts until it is confirmed.

## 1. Goal & success criteria

Goal: deploy EARN (`src/StryToken.sol`) and sEARN (`src/StakedStrat.sol`) on mainnet, and produce one Safe batch that sets up a Uniswap V4 EARN/USDS pool with two positions owned by the redemption Safe.

Success criteria. All are asserted by the fork runs in section 8: the V2 Verify run, and ProposeLp's own pre-write simulation on a fork of the latest block.

- EARN deployed; `EARN.owner() == redemption Safe`.
- No address in `settings.json` `.espnv3.excludedAddresses` receives EARN from the airdrop (D23).
- Airdrop total recorded once in `deploymentAddresses.json` `.earn-airdrop-supply` (D22). Checked on mainnet after step 3; not asserted by the fork.
- `EARN.totalSupply() == airdrop total + 2,500 EARN`.
- The PeriodicYield per-period amount is computed from the airdrop total only. The 2,500 LP EARN does not change it (D22).
- sEARN deployed against EARN/USDS with the live TripwireController.
- V4 pool `(EARN, USDS, fee 3000, tickSpacing 60, hooks 0)` initialized at 100 USDS per EARN.
- Position 1 (full range) holds ~250,000 USDS + ~2,500 EARN.
- Position 2 (bid wall, 50–100 USDS/EARN) holds ~250,000 USDS and 0 EARN.
- Both position NFTs owned by the redemption Safe.
- The Safe spends 500,000e18 USDS ± dust. Its EARN balance after the batch is ≤ dust. About 115,087 USDS stays on the Safe (not dust; see SO1).
- The exact batch written to the file has been executed on a fork of the latest block, with the mainnet EARN address, before the file is written (B1).
- Batch file is consumable by `script/safe/propose-batch.mjs` unchanged.

## 2. Decisions

D1–D21 are user-confirmed. They are decisions, not proposals. D22–D23 are user decisions added after the review.

- D1. Redemption Safe = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` (`internalAddresses.json` `.protocol.multisigs.redemption`). Assumption 1 of the prior spec is still UNCONFIRMED; this spec inherits it (SO6). On-chain facts: Safe 1.4.1, threshold 1, one owner = main multisig `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8` (a nested Safe). USDS balance 615,087.33 at block 26043909.
- D2. EARN initial price = 100 USDS per EARN. Source: `settings.json` `.espnv3.basisPriceUsd = 100` (unscaled integer). Not duplicated in the `lp` block.
- D3. Position 1: full range, 250,000 USDS + 2,500 EARN. 2,500 = `fullRangeUsds / basisPriceUsd`; derived, not configured.
- D4. Position 2: single-sided USDS, 250,000 USDS, band 50–100 USDS/EARN, upper tick at/below the pool price so the position holds USDS only. Needs no EARN.
- D5. Pool: fee 3000 (0.30%), tickSpacing 60, hooks = `address(0)`. Template: ESPN's main ESPN/USDS V4 pool, initialized at block 23544626 on PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`. ESPN's second pool (fee 0, tickSpacing 10, hook `0x3fb49f96338b22cadd9614a51633189d4ce21088`) is not the template. Fact: the Uniswap protocol fee applies to this key (R12, SO5).
- D6. Currency order decided at runtime by address comparison; EARN's address is unknown until deployed.
- D7. Both position NFTs owned by the redemption Safe (`owner` field of each MINT_POSITION = Safe).
- D8. EARN ownership: REVERSAL of prior-spec Assumption 10. `004-stry-migration/Distribute.s.sol:58` `stry.renounceOwnership()` becomes `stry.transferOwnership(safe)` with `safe` read from `internalAddresses.json` `.protocol.multisigs.redemption`. Purpose: more EARN can be minted later.
- D9. `StryToken` is single-step OZ `Ownable`. A wrong `transferOwnership` target is unrecoverable. `Distribute.s.sol` requires `safe != address(0)` and `safe.code.length > 0` before deploying. `Verify.s.sol` asserts `owner() == safe`.
- D10. Trust consequence (must be stated in docs): the redemption Safe can mint EARN without limit. EARN supply is not fixed. Any holder-facing claim of fixed supply is removed. Who holds the authority: the redemption Safe is 1-of-1, owned by the main multisig, so the signers of main multisig `0xC53CCed6…20b8` control minting (SO4).
- D11. The LP batch's first call is `EARN.mintBatch([safe], [2500e18])`, executed by the Safe as owner. `Distribute.s.sol` mints nothing for the LP.
- D12. sEARN deploy = existing `004-stry-migration/Deploy.s.sol`, logic unchanged (comment-only edit, section 4). `internalAddresses.json` `.protocol.tripwire.controller` = `0x328aED8F7a01f45A959c187F3cb97eC508064854` (uncommitted edit; has code at block 26043909; same controller as `script/DeployConvertibleNote.s.sol:19`).
- D13. `004-stry-migration/Verify.s.sol` lines 79–84 stop deploying a local `TripwireController` and use the live controller from `internalAddresses.json`. Reason: the fork now exercises the real `register()` path against the real controller. Alternative (rejected): keep the local deploy; it verifies nothing about the live controller.
- D14. Batch = 6 Safe transactions, in this order: `EARN.mintBatch`, `USDS.approve(Permit2)`, `EARN.approve(Permit2)`, `Permit2.approve(USDS → PositionManager)`, `Permit2.approve(EARN → PositionManager)`, `PositionManager.multicall([initializePool, modifyLiquidities])`. The 7-tx alternative is under SO2.
- D15. New directory `script/deployments/1/005-earn-lp/`. `ProposeLp.s.sol` writes `script/deployments/1/multisig/005-earn-lp/NNN-0x0cbe9bDD-multisig.json` via `SafeBatchLib.write`.
- D16. Local minimal V4 interfaces under `005-earn-lp/interfaces/`, same pattern as `003-espn-redemption/interfaces/ISeaportMinimal.sol`. No v4-core / v4-periphery submodule.
- D17. V4 mainnet addresses (PositionManager, Permit2, StateView) are added to `externalAddresses.json` under a `uniswap-v4` key. They must be verified on-chain before commit (section 8, step V0). The review ran the V0 checks at block 26044553; the results are in V0.
- D18. New `lp` block in `settings.json`: `fullRangeUsds`, `singleSidedUsds`, `bandLowerUsd`, `bandUpperUsd`, `fee`, `tickSpacing`. Nothing about the LP is hardcoded in the script.
- D19. LP positions are not staked in sEARN. Contracts cannot call `claim()` (`docs/help/claim-earn-yield.md`).
- D20. Verification = mainnet-fork run that deploys EARN on the fork, builds the batch, and executes it under `vm.prank(safe)`. Added by B1: ProposeLp also executes the real batch on a fork of the latest block before it writes the file (section 8, V4).
- D21. Out of scope: ETH pairs, hooks, staking LP, frontend, any change to Track A, LP fee collection (O11).
- D22. Yield base = original airdrop mint only. The 15% (`settings.json` `.espnv3.annualDividendRatioX100 = 1500`) is computed on the EARN total minted by `Distribute` in `mintBatch`. It excludes the 2,500 LP EARN and any later Safe mint. Mechanism:
  - Storage: `deploymentAddresses.json` key `.earn-airdrop-supply`, a quoted decimal wei string. The placeholder `"0"` is committed now, in the same way as the `.stry` zero-address placeholder.
  - Writer: `Distribute.run()` only. Before broadcasting, it requires `ConfigLib.num("deploymentAddresses.json", ".earn-airdrop-supply") == 0`, with the message "Distribute: airdrop supply already recorded; refusing to overwrite". After `distribute()` returns, it records `stry.totalSupply()`. At that point the only mint that has run is `mintBatch`: `transferOwnership` runs after it, and the Safe cannot act inside the script. The value is written with `vm.writeJson(string.concat('"', vm.toString(airdropSupply), '"'), <deploymentAddresses path>, ".earn-airdrop-supply")`, right after `writeDeployedAddress(".stry", …)`. `distribute()` keeps its signature. `Verify.s.sol` never writes the key.
  - Immutability: once the value is nonzero, `Distribute.run()` refuses to run. No other script writes the key. Changing it is a manual edit to a committed file and shows in review.
  - Reader: `PeriodicYield.run()` reads it with `ConfigLib.num("deploymentAddresses.json", ".earn-airdrop-supply")` and passes it down. `periodicYieldAmount(uint256 airdropSupply)` and `periodicYield(safe, usds, stakedEarn, airdropSupply)` take it as an argument and require `airdropSupply > 0`. They no longer read `stakedEarn.stratToken().totalSupply()`. `_periodicYieldAmountPure` is unchanged; its first argument is renamed `supplyBase`. `Verify.s.sol` passes the value it captured in memory after its own `distribute()` call, so a fork run never depends on the committed placeholder.
  - Consequence: EARN that the Safe buys back through the bid wall stays in the base. Stakers are paid on the full airdrop total whether or not every holder stakes. This is the existing behaviour and is stated here, not changed.
- D23. Excluded holders get no airdrop EARN (confirmed invariant). `Distribute` mints only to `HoldersLib.included()`, which skips every snapshot holder flagged `excluded`. `settings.json` `.espnv3.excludedAddresses` = V4 PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`, redemption Safe `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`, and Seaport `0x0000000000000068F116a894984e2DB1123eB395`. At snapshot 26043909, PoolManager held 0.000363 ESPN and the Safe held 8,432.70 ESPN (both flagged `excluded`). Seaport held 0 and is not in the file. New assertion: right after `distribute()` in `004-stry-migration/Verify.s.sol`, and in `005-earn-lp/Verify.s.sol` before the batch runs, loop over `ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses")` and `assertEq(stry.balanceOf(a), 0)`. The assertion must run before the LP batch: after it, PoolManager holds EARN and the Safe holds dust.

## 3. Architecture & sequence

Mandated sequence:

| # | Step | Actor | Script | Output |
|---|---|---|---|---|
| 1 | Stop ESPN yield | Safe | `004-stry-migration/StopEspnYield.s.sol` | Safe batch `004-stry-migration/001-…` |
| 2 | Snapshot | operator | `script/snapshot/espn-holders.mjs` | `config/espn-holders-26043909.json` |
| 3 | Distribute EARN | deployer EOA | `004-stry-migration/Distribute.s.sol` | `deploymentAddresses.json` `.stry` (EARN) and `.earn-airdrop-supply`; owner = Safe |
| 4 | Deploy sEARN | deployer EOA | `004-stry-migration/Deploy.s.sol` | `.staked-earn` in `deploymentAddresses.json` |
| 5 | Build + simulate LP batch | operator | `005-earn-lp/ProposeLp.s.sol` (`--rpc-url` mainnet, no broadcast) | `multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json`, written only after the fork simulation passes |
| 6 | Propose | operator | `node script/safe/propose-batch.mjs <file>` | Safe tx in the queue |
| 7 | Sign + execute | main multisig signers, via nested Safe | Safe UI | pool live, positions minted |

Step 7, nested signing: the redemption Safe is 1-of-1 and its owner is the main multisig. Main multisig signers approve the inner transaction hash of the redemption Safe through the Safe UI nested-Safe flow. The outer signers see only an approval of that hash. Before signing, they:

1. Run the Safe UI's Tenderly simulation of the inner batch.
2. Compare the decoded values against the ProposeLp log.
3. Re-check `getSlot0(poolId).sqrtPriceX96 == 0`.

Facts fixed for this run:

- Snapshot block = 26043909. File `script/deployments/1/config/espn-holders-26043909.json` is currently untracked; it must be committed.
- Snapshot taken at 11:00 Sydney, 2026-09-24.
- Seaport (`0x0000000000000068F116a894984e2DB1123eB395`) is excluded via `settings.json` `.espnv3.excludedAddresses` (uncommitted edit). Seaport holds 0 ESPN at the snapshot.
- Track A redemption order ended 2026-09-24T01:00Z. Treasury received 5,232.96 ESPN across 15 fills.
- Step 1 reads `settings.json` `.espnv3.finalYieldAmount`, currently `"0"` (Runbook section 8). At `0` the batch is a no-op. Not changed by this spec.
- Step 5 depends on step 3 (EARN address). Step 5 does not depend on step 4.
- Step 3 → step 7 window: EARN exists and is transferable; the pool does not exist. See Risk R6.
- Estimated airdrop total: ~29,366.17 EARN to 112 included holders. This figure uses the snapshot file's `totalAssets`/`totalSupply`; `Distribute` reads live `totalAssets()` at broadcast, so the real figure can differ.

Data flow for step 5:

```
settings.json .lp + .espnv3.basisPriceUsd
externalAddresses.json .sky-money.USDS, .uniswap-v4.*
internalAddresses.json .protocol.multisigs.redemption
deploymentAddresses.json .stry
        │
        ▼
ProposeLp.s.sol  (mainnet RPC, never broadcasts)
  buildBatch: preflight requires (section 5), currency order, sqrtPriceX96, ticks, liquidity, 6 txs
  simulate:   SafeBatchLib.execute(safe, txs) under prank on the latest-block fork → V2 steps 6–12 asserts
        │  (only if every assert passes)
        ▼
multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json  →  propose-batch.mjs (tx-builder schema, raw calldata)
```

## 4. Components (files touched)

New:

- `script/deployments/1/005-earn-lp/ProposeLp.s.sol`. `run()` does four things in order:
  1. Refuses if the batch file already exists: `require(!vm.exists(SafeBatchLib.path(safe, "005-earn-lp", 1)))`. This is the same guard idea as PeriodicYield (N2).
  2. Calls `buildBatch(address earn, ...)`, which holds every preflight `require` (N1) and returns `SafeBatchLib.Tx[]`.
  3. Calls `_simulateAndCheck(earn, txs, expected)`: executes the txs as the Safe on the RPC fork and asserts V2 steps 6–12 (B1).
  4. Only then calls `SafeBatchLib.write`.
  `buildBatch` and `_simulateAndCheck` are `internal` so that `Verify.s.sol` inherits them. This is the same split as `PeriodicYield.periodicYield`.
- `script/deployments/1/005-earn-lp/Verify.s.sol` — fork verification (section 8). Inherits `ProposeLp`, `Distribute` and `PeriodicYield`.
- `script/deployments/1/005-earn-lp/interfaces/IV4Minimal.sol`. Contents:
  - `PoolKey` struct.
  - `IPositionManager`: `initializePool`, `modifyLiquidities`, `multicall`, `ownerOf`, `getPositionLiquidity`, `poolManager`, `nextTokenId`, `permit2`.
  - `IPermit2`: `approve(address,address,uint160,uint48)`, `allowance`.
  - `IStateView`: `getSlot0`, `poolManager`.
  - `Actions` constants.
  One file; split only if it exceeds ~150 lines.
- `script/deployments/1/005-earn-lp/lib/`: `TickMath`, `LiquidityAmounts` and their transitive imports, copied unmodified: `FullMath`, `FixedPoint96`, `BitMath`, `CustomRevert`, `SafeCast`. About 7 files (N5). Keep each file's original SPDX header. Before committing, check that each licence is compatible with the repo licence. Any BUSL-1.1 file blocks the copy; stop and ask.
- `script/deployments/1/multisig/005-earn-lp/` — written by `ProposeLp.s.sol` (`SafeBatchLib.write` creates the directory).
- `package.json` script `verify:lp` mirroring `verify:migration` (fork URL + `SNAPSHOT_BLOCK`).

Modified:

- `script/deployments/1/004-stry-migration/Distribute.s.sol`:
  - Line 58: `renounceOwnership()` → `transferOwnership(safe)`.
  - Add the `safe` nonzero and code-at-address requires.
  - `run()`: add the `.earn-airdrop-supply == 0` refusal before broadcast and the write after `.stry` (D22).
  - Change the calibration log text if it mentions renounce.
  - `distribute()` signature unchanged.
- `script/deployments/1/004-stry-migration/Verify.s.sol`:
  - Line 77: assert `owner() == safe` (not `address(0)`).
  - Lines 79–84: use `ConfigLib.addr("internalAddresses.json", ".protocol.tripwire.controller")` instead of `new TripwireController()`, and drop the `TripwireController` import.
  - Capture `airdropSupply = stry.totalSupply()` right after `distribute()`.
  - Add the excluded-holder zero-balance loop (D23).
  - Pass `airdropSupply` to `periodicYieldAmount` / `periodicYield`.
  - Add one assertion: after `vm.prank(safe); stry.mintBatch([safe], [1e18])`, `periodicYieldAmount(airdropSupply)` is unchanged. This proves the base is not live `totalSupply` (D22).
  - Move `_executeBatch` to `SafeBatchLib.execute(safe, txs)` so ProposeLp can use it.
- `script/deployments/1/lib/SafeBatchLib.sol` — gains `execute(address safe, Tx[] memory txs)`, moved from 004 `Verify._executeBatch`. The body is unchanged: `vm.prank(safe)` + call + require success.
- `script/deployments/1/004-stry-migration/PeriodicYield.s.sol` (D22):
  - `run()` reads `.earn-airdrop-supply`.
  - `periodicYieldAmount(uint256 airdropSupply)` and `periodicYield(..., uint256 airdropSupply)` take the base as an argument, require it to be > 0, and stop reading live `totalSupply()`.
  - The lines 9–13 comment is rewritten. It must not say "fixed forever after mintBatch + renounceOwnership()". It must say that the base is the recorded airdrop total and that later mints do not change it.
- `script/deployments/1/004-stry-migration/Deploy.s.sol` — comment-only (N6):
  - Lines 19–23 and 58–61: drop "deploys its own TripwireController" / "fork-local TripwireController".
  - Line 29 require message: drop "(yarn verify:migration is unaffected -- it deploys its own controller on the fork.)".
  - No logic change.
- `test/unit/PeriodicYieldTest.sol`:
  - Harness wrappers take `airdropSupply` in place of reading `earn.totalSupply()`.
  - `test_periodicYieldAmount_matchesRealConfig` passes an explicit base and still pins the `basisPriceUsd` / `annualDividendRatioX100` config reads.
  - Add `test_periodicYieldAmount_ignoresPostAirdropMint`: mint extra EARN; the amount for the same `airdropSupply` is unchanged.
  - Add `test_periodicYield_revertsOnZeroAirdropSupply`.
- `script/deployments/1/config/deploymentAddresses.json` — add placeholder `"earn-airdrop-supply": "0"`.
- `script/deployments/1/config/settings.json` — add `lp` block (section 7). Uncommitted `excludedAddresses` edit is committed with it.
- `script/deployments/1/config/externalAddresses.json` — add `uniswap-v4` block after on-chain verification (section 8, V0).
- `script/deployments/1/config/internalAddresses.json` — commit the `.protocol.tripwire.controller` edit.
- `script/deployments/1/config/espn-holders-26043909.json` — commit.
- `test/unit/StryTokenTest.sol` — the contract is unchanged, so the existing `renounceOwnership` test is still valid for the contract. No test change required: the ownership end-state is a script decision, and `Verify.s.sol` verifies it. See open item O5.
- Docs: section 9.

Not modified: `src/StryToken.sol`, `src/StakedStrat.sol`, `StopEspnYield.s.sol`, `lib/*`, `script/safe/*`, anything under `003-espn-redemption/`.

## 5. Batch spec

Safe = redemption Safe. All six transactions have `value = 0`. Written by `SafeBatchLib.write(safe, "005-earn-lp", 1, "EARN/USDS V4 LP", <description>, txs)`.

| # | `to` | Call | Notes |
|---|---|---|---|
| 1 | EARN | `mintBatch([safe], [fullRangeEarn])` | `fullRangeEarn = fullRangeUsds / basisPriceUsd` = 2500e18. Safe is `owner()` (D8). Does not change the yield base (D22). |
| 2 | USDS | `approve(Permit2, fullRangeUsds + singleSidedUsds)` | 500,000e18. Exact amount, not max. |
| 3 | EARN | `approve(Permit2, fullRangeEarn)` | 2500e18. |
| 4 | Permit2 | `approve(USDS, PositionManager, uint160(fullRangeUsds + singleSidedUsds), expiration)` | |
| 5 | Permit2 | `approve(EARN, PositionManager, uint160(fullRangeEarn), expiration)` | |
| 6 | PositionManager | `multicall([initializePool(poolKey, sqrtPriceX96), modifyLiquidities(unlockData, deadline)])` | |

Permit2 `expiration` = `type(uint48).max`. Reason: the calldata is generated before signing, so a timestamp would go stale in the Safe queue. Permit2 decrements the allowance amount on spend, so the residual allowance after execution is dust.
- Alternative (rejected as fragile): `expiration = 0`. Permit2 then stores `block.timestamp`, so the allowance is valid only in the execution block. That works only if the Safe executes the batch as one MultiSend tx, which `propose-batch.mjs` produces.

`modifyLiquidities` `deadline` = `type(uint256).max`, for the same reason. The Safe can decline to execute; a stale deadline would force regeneration.

`poolKey`:

```
currency0 = min(EARN, USDS) by address
currency1 = max(EARN, USDS) by address
fee       = settings .lp.fee          (3000)
tickSpacing = settings .lp.tickSpacing (60)
hooks     = address(0)
```

`unlockData = abi.encode(actions, params)`:

```
actions = abi.encodePacked(uint8(MINT_POSITION), uint8(MINT_POSITION), uint8(SETTLE_PAIR))
params[0] = abi.encode(poolKey, FULL_LOWER, FULL_UPPER, liqFull, amount0MaxFull, amount1MaxFull, safe, "")
params[1] = abi.encode(poolKey, BAND_LOWER, BAND_UPPER, liqBand, amount0MaxBand, amount1MaxBand, safe, "")
params[2] = abi.encode(currency0, currency1)
```

- `amountMax` per position = the configured amount for that currency, and 0 for the currency the position must not take.
  - Position 2's EARN-side max = 0. If the tick math is wrong and the band is in range, the mint reverts instead of pulling EARN.
  - `amountMax` is also the price guard. At any pool price other than the intended one, position 1's fixed liquidity needs more than the configured amount of one currency, so the mint reverts `MaximumAmountExceeded` and the whole MultiSend reverts (R6).
- `SETTLE_PAIR` settles both currencies for the sum of both mints; PositionManager pulls via Permit2 from `msg.sender` = Safe.
- `hookData` = empty bytes.
- Action constants: `MINT_POSITION = 0x02`, `SETTLE_PAIR = 0x0d` (v4-periphery `Actions.sol`). Copied, not derived; a wrong value reverts in the ProposeLp simulation.
- `ownerOf(tokenId)` for both minted positions = Safe. PositionManager mints with `_mint` (no `onERC721Received` callback), so the Safe's fallback handler is not required.

Preflight requires. All of them are in `buildBatch` (N1), so they revert before any simulation or file write, and V2 step 13 can rely on them:

- `EARN.owner() == safe`.
- `USDS.balanceOf(safe) >= fullRangeUsds + singleSidedUsds` (500,000e18).
- `EARN.decimals() == 18 && USDS.decimals() == 18`.
- `PositionManager.poolManager() == PoolManager` and `StateView.poolManager() == PoolManager` (address sanity, D17).
- `StateView.getSlot0(poolId).sqrtPriceX96 == 0` (pool not yet initialized). See R6.
- `bandUpperUsd <= basisPriceUsd`; `bandLowerUsd < bandUpperUsd`; `fee`/`tickSpacing` nonzero.
- `fullRangeUsds % basisPriceUsd == 0`.

Signer verification: every tx is raw calldata (`contractMethod: null`), so the Safe UI shows `to` + selector only (Runbook section 6). With the nested Safe, the outer signers see only a hash approval (section 3, step 7).
- Proof of payload content: ProposeLp's pre-write simulation of the exact txs, against the mainnet EARN on the latest block (B1). The Safe UI Tenderly simulation before signing checks it a second time.
- `ProposeLp.s.sol` logs, per tx, the `to`, selector, decoded amounts, ticks, liquidity and `sqrtPriceX96`, followed by the simulation results.

## 6. Tick / price math

Definitions:

- V4 price `P = currency1 / currency0` in raw token units. Both tokens are 18 decimals, so no decimal adjustment.
- `sqrtPriceX96 = sqrt(P) * 2^96`.
- `tick(P) = floor(log_1.0001(P))`.
- Position ticks must be multiples of `tickSpacing` (60).
- Position composition (v4-core `Pool.modifyLiquidity`): `currentTick < tickLower` → currency0 only; `tickLower <= currentTick < tickUpper` → both; `currentTick >= tickUpper` → currency1 only.

Two orderings. `B = basisPriceUsd` (100), `Lo = bandLowerUsd` (50), `Hi = bandUpperUsd` (100), `s = tickSpacing` (60).

### Case A: EARN is currency0 (`address(EARN) < address(USDS)`)

- `P = USDS per EARN = B`.
- `sqrtPriceX96 = Math.sqrt(B << 192)`. For `B = 100`: `10 * 2^96 = 792281625142643375935439503360`, exact.
- `currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96)` = 46054 for B = 100 (`log_1.0001(100) = 46054.004`).
- Bid wall holds currency1 (USDS) ⇒ needs `currentTick >= BAND_UPPER`.
- `BAND_UPPER = floorToSpacing(tick(Hi))` = largest multiple of `s` that is `<= tick(Hi)`. For Hi = 100: `tick = 46054` → `46020` (price 99.66).
- `BAND_LOWER = floorToSpacing(tick(Lo))`. For Lo = 50: `tick = 39122` → `39120` (price 49.99).
- Equality case: `BAND_UPPER == currentTick` is allowed (`>=`), position is still USDS-only.
- `FULL_LOWER = -887220`, `FULL_UPPER = 887220` (MIN/MAX_TICK ±887272 rounded inward to a multiple of 60).
- Full-range liquidity: `liqFull = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtAt(FULL_LOWER), sqrtAt(FULL_UPPER), amount0 = fullRangeEarn, amount1 = fullRangeUsds)` = `min(L0, L1)`. At P = 100, both L0 and L1 floor to exactly 25000e18 (N7). Both sides settle at exactly 2,500e18 EARN and 250,000e18 USDS.
- Band liquidity: `liqBand = getLiquidityForAmount1(sqrtAt(BAND_LOWER), sqrtAt(BAND_UPPER), singleSidedUsds)`.
- amountMax: position 1 `(fullRangeEarn, fullRangeUsds)`; position 2 `(0, singleSidedUsds)`.

### Case B: USDS is currency0 (`address(USDS) < address(EARN)`)

- `P = EARN per USDS = 1 / B`.
- `sqrtPriceX96 = Math.sqrt((1 << 192) / B)`. For B = 100: `7922816251426433759354395033` (floor of `2^96 / 10`).
- `currentTick` = -46055 for B = 100 (`log_1.0001(0.01) = -46054.004`, floor → -46055).
- Bid wall holds currency0 (USDS) ⇒ needs `currentTick < BAND_LOWER` (strict).
- Price band in pool terms is `[1/Hi, 1/Lo]`.
- `BAND_LOWER = ceilToSpacing(tick(1/Hi)); if (BAND_LOWER <= currentTick) BAND_LOWER += s;` This single rule covers both `Hi == B` and `Hi < B` (N4). For B = Hi = 100: `ceilToSpacing(-46055) = -46020` (price 1/99.66).
- `BAND_UPPER = ceilToSpacing(tick(1/Lo))`. For Lo = 50: `tick(0.02) = -39123` → `-39120` (price 1/49.99).
- Equality case: `BAND_LOWER == currentTick` is NOT USDS-only (it is in range). The `+= s` above handles it. `buildBatch` still requires `currentTick < BAND_LOWER` after rounding.
- `FULL_LOWER/UPPER` as Case A.
- `liqFull = getLiquidityForAmounts(sqrtP, sqrtAt(FULL_LOWER), sqrtAt(FULL_UPPER), amount0 = fullRangeUsds, amount1 = fullRangeEarn)` = 25000e18 − 1 (N7). The settled amounts are ≤ the configured amounts.
- `liqBand = getLiquidityForAmount0(sqrtAt(BAND_LOWER), sqrtAt(BAND_UPPER), singleSidedUsds)`.
- amountMax: position 1 `(fullRangeUsds, fullRangeEarn)`; position 2 `(singleSidedUsds, 0)`.

### Common

- Rounding rule in words: the band edge nearest the pool price rounds away from the price, so the position is out of range on the USDS side. The far edge rounds outward (wider band). Case A far edge floors, Case B far edge ceils.
- Sign handling (N3): Solidity `/` truncates toward zero, so `t / s * s` is a ceiling for negative `t` and a floor for positive `t`. The helpers must correct for sign:
  - `floorToSpacing(t)`: `q = t / s; if (t % s != 0 && t < 0) q--; return q * s;`
  - `ceilToSpacing(t)`: `q = t / s; if (t % s != 0 && t > 0) q++; return q * s;`
  Case A uses positive ticks and Case B negative ticks, so the V3 unit test calls both helpers with both signs.
- Liquidity rounding (S2, R11):
  - `getLiquidityForAmountN` rounds liquidity down. The reviewer's hand calculation shows exact consumption in Case A and ≤ consumption in Case B, so `amountMax = configured amount` is safe. R11 is low risk.
  - Raising `amountMax` alone is NOT a fix. Tx 1 mints exactly 2,500e18 EARN and txs 2–5 approve exact amounts, so a 1-wei round-up would move the revert to Permit2 `InsufficientAllowance` or to the ERC20 balance check.
  - If the simulation shows a 1-wei round-up revert, the fix is `liqFull -= 1` (or `liqBand -= 1`), and the change is recorded.
- `TickMath` and `LiquidityAmounts` and their imports are copied into `005-earn-lp/lib/` (section 4, N5). Alternative (rejected, one-off use): a git submodule.
- Implementation must not compute `log` in Solidity. `TickMath.getTickAtSqrtPrice(sqrtPriceX96)` gives `currentTick`. Band edge ticks come from `getTickAtSqrtPrice(Math.sqrt(price << 192))`, using the same formula per ordering.
- Integer sqrt: `openzeppelin-contracts/utils/math/Math.sol` `sqrt` (floor), already a dependency.

Reference values (B = 100, Lo = 50, Hi = 100, s = 60). The review recomputed them and they match:

| Quantity | Case A (EARN = c0) | Case B (USDS = c0) |
|---|---|---|
| `sqrtPriceX96` | 792281625142643375935439503360 | 7922816251426433759354395033 |
| `currentTick` | 46054 | -46055 |
| `BAND_LOWER` | 39120 | -46020 |
| `BAND_UPPER` | 46020 | -39120 |
| USDS/EARN at band edges | 49.99 – 99.66 | 99.66 – 49.99 |
| `FULL_LOWER/UPPER` | -887220 / 887220 | -887220 / 887220 |
| `liqFull` | 25000e18 | 25000e18 − 1 |

## 7. Config

`settings.json` addition:

```json
"lp": {
  "fullRangeUsds": "250000000000000000000000",
  "singleSidedUsds": "250000000000000000000000",
  "bandLowerUsd": 50,
  "bandUpperUsd": 100,
  "fee": 3000,
  "tickSpacing": 60
}
```

- Token amounts: plain decimal wei strings (prior-spec unit convention).
- `bandLowerUsd`, `bandUpperUsd`: unscaled USDS per EARN.
- `fee`: V4 fee in hundredths of a bip (3000 = 0.30%). `tickSpacing`: int24.
- `basisPriceUsd` is read from `.espnv3.basisPriceUsd`; not duplicated.
- `fullRangeEarn` is derived (`fullRangeUsds / basisPriceUsd`); not configured.

`externalAddresses.json` addition (values filled only after V0):

```json
"uniswap-v4": {
  "poolManager": "0x000000000004444c5dc75cB358380D2e3dE08A90",
  "positionManager": "<verified>",
  "permit2": "<verified>",
  "stateView": "<verified>"
}
```

`poolManager` is known from the ESPN pool (D5). `propose-batch.mjs` rejects `<...>` placeholders, so unfilled values cannot reach a proposal.

`internalAddresses.json`: `.protocol.tripwire.controller = 0x328aED8F7a01f45A959c187F3cb97eC508064854` (commit the pending edit).

`deploymentAddresses.json`:
- `.stry` (EARN) and `.earn-airdrop-supply` (D22) are written by `Distribute.run()` only.
- `.staked-earn` is written by Deploy.
- Position token ids are logged by ProposeLp's simulation and by Verify, not stored; they are assigned at execution.

## 8. Verification / testing

### V0. Address verification (before editing `externalAddresses.json`)

For each of PositionManager, Permit2, StateView on mainnet:

1. `cast code <addr>` non-empty.
2. Real call: `PositionManager.poolManager()` returns `0x000000000004444c5dc75cB358380D2e3dE08A90`; `StateView.poolManager()` returns the same; `Permit2.DOMAIN_SEPARATOR()` returns nonzero and `PositionManager.permit2()` returns the Permit2 address.
3. Record block number and results in the commit message that adds the addresses.

Review result (N9), read-only `cast` against mainnet at blocks 26044553 and 26043909:
- Checks 1 and 2 pass for PositionManager `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3` and StateView `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227`.
- The 3000/60/0 ESPN/USDS key is initialized: tick 46702, lpFee 3000, protocolFee 2048500.
- `initializePool` on that already-initialized key returns `type(int24).max` (8388607) without reverting. `PoolManager.initialize` on the same key reverts `PoolAlreadyInitialized`.
- The redemption Safe's Permit2 allowance to PositionManager is 0.
- Remaining for the address commit: re-run checks 1–2 and record them (step 3). Optionally, match the block-23544626 `Initialize` event; the slot0 read already confirms the key exists.

### V1. `yarn verify:migration` (existing, modified)

- Line 77 assertion becomes `assertEq(stry.owner(), safe)`.
- Uses the live controller; asserts `controller.code.length > 0` first.
- Excluded-holder zero-balance loop right after `distribute()` (D23).
- PeriodicYield is called with the in-memory `airdropSupply`. A post-airdrop Safe mint leaves the amount unchanged (D22).
- Everything else unchanged.

### V2. `yarn verify:lp` (new `005-earn-lp/Verify.s.sol`)

Fork at `SNAPSHOT_BLOCK`. Same harness as 004 (`vm.startPrank`, `deal`, `SafeBatchLib.execute`).

1. Run `Distribute.distribute(deployer, holdersFile)` on the fork → `earn`. Record `airdropSupply = earn.totalSupply()`. Run the excluded-holder zero-balance loop (D23).
2. If `USDS.balanceOf(safe) < 500,000e18`, `deal` the shortfall and log a WARNING. The mainnet preflight is a hard require; the fork is not. Record `usdsBefore = USDS.balanceOf(safe)`.
3. `txs = buildBatch(earn, ...)`; assert `txs.length == 6` and `txs[0].to == earn` with selector `mintBatch`.
4. Assert `StateView.getSlot0(poolId).sqrtPriceX96 == 0` before execution.
5. `SafeBatchLib.execute(safe, txs)`; log gas.
6. Assert `earn.totalSupply() == airdropSupply + fullRangeEarn`. Assert `periodicYieldAmount(airdropSupply)` equals its pre-batch value (D22).
7. Assert `getSlot0(poolId).sqrtPriceX96 == expected sqrtPriceX96` (exact) and `tick == expected currentTick`.
8. Assert `PositionManager.ownerOf(tokenId1) == safe` and `ownerOf(tokenId2) == safe`. Token ids = `nextTokenId()` read before execution, then +1.
9. Assert `getPositionLiquidity(tokenId1) == liqFull` and `getPositionLiquidity(tokenId2) == liqBand`.
10. Assert `usdsBefore - USDS.balanceOf(safe)` is within `1e12` of `500,000e18` (S3; no underflow). Assert `earn.balanceOf(safe) <= 1e12`. The 1e12 tolerance is 1e-6 of a token of dust; rounding is bounded by wei per position.
11. Assert position 2 took zero EARN: `earn.balanceOf(safe)` is dust after minting exactly `fullRangeEarn`, and position 1 alone accounts for the EARN pulled.
12. Assert `Permit2.allowance(safe, USDS, PositionManager).amount <= 1e12` and same for EARN.
13. Negative test: re-run `buildBatch` after execution → must revert on the pool-already-initialized preflight.
14. Negative test (S1), on a state snapshot: a third party calls `PositionManager.initializePool(poolKey, wrongSqrtPrice)` at 2× and at 0.5× the intended price, then the Safe executes the batch. The batch must revert (`MaximumAmountExceeded`), and `ownerOf` for the expected token ids must not exist. This proves that `amountMax` is the price guard.
15. Swap sanity (informational):
    - `deal` 1,000 USDS to a test EOA.
    - Swap USDS→EARN through PoolManager via `PoolSwapTest` copied from v4-core.
    - Read `slot0.protocolFee` and `lpFee` on the fork.
    - Assert the EARN received ≈ `1000/100 × (1 − lpFee − protocolFee)` within 1% (S6).
    - Skip if it needs more than the copied test router; log the reason.

Both orderings (S7): no deployer-address loop. On a state snapshot, `deployCodeTo("StryToken.sol:StryToken", abi.encode(safe), <addr>)` places a second EARN at a fixed low address, then at a fixed high address. Steps 3–12 run against each.
- Only `mintBatch([safe], …)` (tx 1) is needed on these instances. No airdrop.
- Low address: `address(0x10000)`, not `0x01`–`0x0a` or `0x100`, which are precompiles or reserved.
- High address: `address(type(uint160).max - 0xffff)`.
- Both are on the correct side of USDS `0xdC03…`. Both Cases run on every Verify, and the log states which Case the real mainnet EARN hit.

### V3. Unit tests

- A `test/unit/ScriptLibsTest.sol`-style test for the tick derivation. Pure function `deriveTicks(currency0IsEarn, B, Lo, Hi, s)` must return:
  - the section 6 reference table for both cases;
  - the equality case (`currentTick` exactly on a spacing multiple → Case B lower moves up one spacing; Case A upper stays);
  - negative and positive inputs to `floorToSpacing` / `ceilToSpacing`, including exact multiples (N3).
- `test/unit/PeriodicYieldTest.sol` changes as listed in section 4 (D22).
- No `StakedStrat` or `StryToken` contract tests change.

### V4. ProposeLp pre-write simulation (B1, mainnet run)

`ProposeLp.run()` runs with `--rpc-url` mainnet and without `--broadcast`, so forge executes against a local fork of the latest block. After `buildBatch`, it executes the exact txs it will write as the Safe (`SafeBatchLib.execute`) against the mainnet EARN address. It then asserts V2 steps 6–12, using the live `earn.totalSupply()` read before the simulation in place of `airdropSupply`.
- Any failed assert reverts `run()` before `SafeBatchLib.write`, so no file is produced.
- No `snapshotState`/`revertToState` is needed: the script never broadcasts, and the file is written from the same in-memory `txs`.
- Runbook step: before signing, the signers run the Safe UI Tenderly simulation of the queued inner tx.

## 9. Docs to update

- `docs/ESPNv3_Runbook.md`:
  - Assumption 10: replace with "EARN: `transferOwnership(redemption Safe)`; the Safe (1-of-1, owned by main multisig `0xC53C…20b8`) can mint without limit. REDEMPTION: renounced (unchanged)."
  - Section 2 table: add steps for Deploy (sEARN) and ProposeLp.
  - Section 6: add the `005-earn-lp/001-…` batch, its 6-tx order, the nested-Safe signing flow, and the Tenderly check before signing.
  - Section 7: add `verify:lp`.
  - Section 8: PeriodicYield base = `.earn-airdrop-supply`.
- `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md`: add a "Superseded" line at the top pointing here for Assumption 10 (EARN only) and for the LP out-of-scope item. No other edits.
- `docs/help/claim-earn-yield.md`: add these lines.
  - "EARN supply is not fixed. The redemption Safe, controlled by the main multisig, can mint additional EARN; any mint dilutes existing holders."
  - "The 28-day yield is sized on the original airdrop supply. EARN minted later, including the pool's EARN, does not change the yield amount."
  - "EARN held in the Uniswap V4 pool positions is not staked and earns no sEARN yield."
  - "Swaps in the EARN/USDS pool pay a 0.30% pool fee plus a Uniswap protocol fee of up to 0.05%."
- `docs/RELEASE-NOTES.md`: user-visible entries per the release-notes rule:
  - EARN launched.
  - EARN/USDS Uniswap V4 pool at 100 USDS per EARN.
  - EARN supply is mintable by the redemption Safe.
  - EARN yield is sized on the original airdrop supply.
- `script/deployments/1/004-stry-migration/PeriodicYield.s.sol:9-13` and `Deploy.s.sol` comments (code comments, not docs; listed here so they are not missed).
- Holder communication that states EARN supply is fixed: none found in the repo. A `grep` for "fixed supply", "no future mint" and "cannot be minted" across `docs/`, `src/` and `README.md` returned only Runbook Assumption 10 and the PeriodicYield comment.

## 10. Risks

- R1. Pool goes live at 100 USDS/EARN while the airdrop is still landing in wallets. Holders can sell into the bid wall immediately; the Safe accumulates EARN in return. Accepted.
- R2. Minted-amount errors can be corrected by further minting (D8). The pool initialization price cannot be corrected: a wrong `sqrtPriceX96` needs a new pool key or causes arbitrage losses. Guards: the exact `sqrtPriceX96` assertion in the ProposeLp simulation on the real payload (V4) and in V2 step 7.
- R3. Raw-calldata batches and a nested Safe: outer signers approve a hash. Mitigations:
  - ProposeLp executes the exact payload on a latest-block fork before writing (V4).
  - Decoded-parameter log.
  - Safe UI Tenderly simulation before signing.
- R4. Assumption 1 (redemption Safe address) is UNCONFIRMED (SO6). Every tx in the batch, the EARN owner and the NFT owner are that address. Under D8, a wrong value is unrecoverable (single-step Ownable).
- R5. USDS on the Safe must be `>= 500,000e18` at execution.
  - Balance at block 26043909: 615,087.33 USDS. After the LP: ~115,087 USDS.
  - `buildBatch` requires the 500,000e18 at generation; signers re-check before execution.
  - Runway against PeriodicYield is SO1 / O8.
- R6. Pool-key squatting: denial of service, not a wrong-price mint (S1).
  - Once EARN's address is known (after step 3, before step 7), anyone can initialize the `(EARN, USDS, 3000, 60, 0)` key at any price.
  - `PositionManager.initializePool` swallows the resulting error (confirmed in V0).
  - At any price other than the intended one, position 1's fixed liquidity needs more than `amountMax` of one currency. The batch therefore reverts atomically; nothing is minted and no funds move.
  - Impact: this key can no longer be used at 100. ProposeLp's `sqrtPriceX96 == 0` preflight also refuses to regenerate for it.
  - Recovery: SO3.
  - Initialization at exactly the intended price does not harm the batch.
  - V2 step 14 proves the guard.
- R7. ESPN has a second ESPN/USDS V4 pool (fee 0, tickSpacing 10, hook `0x3fb49f96338b22cadd9614a51633189d4ce21088`). Not used as template; listed so nobody copies its key by mistake.
- R8. PeriodicYield base (D22). The per-period amount = `airdropSupply × 100 × 15% × 28/365`.
  - For the estimated airdrop of ~29,366.17 EARN, that is ~440,492 USDS a year, or ~33,791 USDS per 28-day period.
  - The 2,500 LP EARN and any later Safe mint do not change it. The previous +2,877 USDS/period effect of the LP mint is removed.
  - Stakers share the whole amount regardless of how much of the airdrop is staked. Accepted.
- R9. Safe dilution power (D10): no on-chain cap. Held in practice by the main multisig's signers through the 1-of-1 redemption Safe (SO4). Stated in docs (section 9).
- R10. After execution, the Permit2 allowance and the ERC20 allowance to Permit2 are dust (exact amounts approved). No revoke tx in the batch. The leftover is harmless: PositionManager's `_pay` pulls only from `msgSender()`, which is the locker = the Safe, so no third party can make PositionManager spend it (N8).
- R11. The full-range position's EARN side is exactly the 2,500 minted in tx 1. The hand calculation shows exact consumption, so the risk is low. If the simulation shows a 1-wei round-up, reduce liquidity by 1; raising `amountMax` does not fix it (section 6, S2).
- R12. Uniswap protocol fee (S6). `PoolManager.protocolFeeController()` (`0x89A5…51dB`) `getFee(key)` returns 2048500 (500 pips each direction) for 3000/60 keys. The ESPN pool already has it set. Once `triggerFeeUpdate(key)` is called, swappers pay ~0.35% in total. The protocol fee does not reduce LP principal. Decision: SO5.

## 11. Explicit assumptions / open items

- O1. Pool init shape: see SO2. D14 stands until the user changes it. Corrected reasoning: `initializePool` does swallow a front-run, but `amountMax` makes the batch revert anyway (R6). The 7-tx shape gives a clearer revert reason, not more safety.
- O2. V4 addresses: the review checked them (V0). Committing them still requires the V0 record step.
- O3. `Actions` constant values (`MINT_POSITION`, `SETTLE_PAIR`) and the `MINT_POSITION` param encoding order are taken from v4-periphery source at implementation time. The review found no mismatch. The ProposeLp simulation confirms them.
- O4. `PositionManager` ERC721 mint path: non-callback `_mint` (review confirmed). The Safe has a fallback handler either way.
- O5. `test/unit/StryTokenTest.sol`: this spec keeps the renounce test (contract unchanged). If the user wants the test to reflect the operational end-state, add one test: `transferOwnership(safe)`, then `mintBatch` by the Safe succeeds. Not added by default.
- O6. Assumption 1 (Safe address): see SO6.
- O7. `finalYieldAmount = "0"` makes step 1 a no-op. Not changed here; inherited from Runbook section 8.
- O8. USDS runway (for the user to decide, SO1):
  - Safe balance 615,087.33 USDS at block 26043909; after the LP, ~115,087 USDS.
  - PeriodicYield with the airdrop-only base: ~33,791 USDS per period (estimate; the actual figure = the recorded `.earn-airdrop-supply` × 100 × 0.15 × 28/365).
  - Runway: ~3.4 periods, ~95 days, with no inflow.
  - PeriodicYield's `balanceOf(safe) >= amount` require is the hard stop.
- O9. Whether `Cancel.s.sol` (Track A allowance revoke) has been run is outside this spec. A live 700k Seaport allowance does not affect this batch's balance require. It would affect the Safe's spendable USDS if the order were re-validated. Out of scope (D21).
- O10. Removed. Case-B coverage now uses `deployCodeTo` at fixed addresses (V2, S7) and always runs.
- O11. LP fee collection is out of scope (D21). When needed: a Safe batch calling `PositionManager.modifyLiquidities` with `DECREASE_LIQUIDITY` (liquidity 0) + `TAKE_PAIR` to the Safe, per position.
