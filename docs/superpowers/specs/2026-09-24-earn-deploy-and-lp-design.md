# EARN Deploy + Uniswap V4 EARN/USDS LP — Design Spec

- **Date:** 2026-09-24
- **Branch:** `EARN-deploy`
- **Status:** Design; user-confirmed decisions recorded as decisions; open items listed in the last section
- **Chain:** Ethereum mainnet (chain id 1)
- **Extends:** [`2026-08-21-espnv3-redemption-migration-design.md`](2026-08-21-espnv3-redemption-migration-design.md) (Track B) and [`2026-09-04-stry-merkl-yield-design.md`](2026-09-04-stry-merkl-yield-design.md). This spec reverses that spec's Assumption 10 for EARN and adds the LP deployment that spec listed as out of scope.

## 1. Goal & success criteria

Goal: deploy EARN (`src/StryToken.sol`) and sEARN (`src/StakedStrat.sol`) on mainnet, and produce one Safe batch that sets up a Uniswap V4 EARN/USDS pool with two positions owned by the redemption Safe.

Success criteria (all asserted by the fork Verify run, section 8):

- EARN deployed; `EARN.owner() == redemption Safe`.
- `EARN.totalSupply() == airdrop total + 2,500 EARN`.
- sEARN deployed against EARN/USDS with the live TripwireController.
- V4 pool `(EARN, USDS, fee 3000, tickSpacing 60, hooks 0)` initialized at 100 USDS per EARN.
- Position 1 (full range) holds ~250,000 USDS + ~2,500 EARN.
- Position 2 (bid wall, 50–100 USDS/EARN) holds ~250,000 USDS and 0 EARN.
- Both position NFTs owned by the redemption Safe.
- Residual USDS and EARN on the Safe after the batch are dust (section 8 tolerance).
- Batch file is consumable by `script/safe/propose-batch.mjs` unchanged.

## 2. Decisions

All items below are user-confirmed. They are decisions, not proposals.

- D1. Redemption Safe = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` (`internalAddresses.json` `.protocol.multisigs.redemption`). Assumption 1 of the prior spec is still UNCONFIRMED; this spec inherits it.
- D2. EARN initial price = 100 USDS per EARN. Source: `settings.json` `.espnv3.basisPriceUsd = 100` (unscaled integer). Not duplicated in the `lp` block.
- D3. Position 1: full range, 250,000 USDS + 2,500 EARN. 2,500 = `fullRangeUsds / basisPriceUsd`; derived, not configured.
- D4. Position 2: single-sided USDS, 250,000 USDS, band 50–100 USDS/EARN, upper tick at/below the pool price so the position holds USDS only. Needs no EARN.
- D5. Pool: fee 3000 (0.30%), tickSpacing 60, hooks = `address(0)`. Template: ESPN's main ESPN/USDS V4 pool, initialized at block 23544626 on PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`. ESPN's second pool (fee 0, tickSpacing 10, hook `0x3fb49f96338b22cadd9614a51633189d4ce21088`) is not the template.
- D6. Currency order decided at runtime by address comparison; EARN's address is unknown until deployed.
- D7. Both position NFTs owned by the redemption Safe (`owner` field of each MINT_POSITION = Safe).
- D8. EARN ownership: REVERSAL of prior-spec Assumption 10. `004-stry-migration/Distribute.s.sol:58` `stry.renounceOwnership()` becomes `stry.transferOwnership(safe)` with `safe` read from `internalAddresses.json` `.protocol.multisigs.redemption`. Purpose: more EARN can be minted later.
- D9. `StryToken` is single-step OZ `Ownable`. A wrong `transferOwnership` target is unrecoverable. `Distribute.s.sol` requires `safe != address(0)` and `safe.code.length > 0` before deploying. `Verify.s.sol` asserts `owner() == safe`.
- D10. Trust consequence (must be stated in docs): the redemption Safe can mint EARN without limit. EARN supply is not fixed. Any holder-facing claim of fixed supply is removed.
- D11. The LP batch's first call is `EARN.mintBatch([safe], [2500e18])`, executed by the Safe as owner. `Distribute.s.sol` mints nothing for the LP.
- D12. sEARN deploy = existing `004-stry-migration/Deploy.s.sol`, unchanged. `internalAddresses.json` `.protocol.tripwire.controller` = `0x328aED8F7a01f45A959c187F3cb97eC508064854` (uncommitted edit; has code; same controller as `script/DeployConvertibleNote.s.sol:19`).
- D13. `004-stry-migration/Verify.s.sol` lines 79–84 stop deploying a local `TripwireController` and use the live controller from `internalAddresses.json`. Reason: the fork now exercises the real `register()` path against the real controller. Alternative (rejected): keep the local deploy; it verifies nothing about the live controller.
- D14. Batch = 6 Safe transactions, in this order: `EARN.mintBatch`, `USDS.approve(Permit2)`, `EARN.approve(Permit2)`, `Permit2.approve(USDS → PositionManager)`, `Permit2.approve(EARN → PositionManager)`, `PositionManager.multicall([initializePool, modifyLiquidities])`.
- D15. New directory `script/deployments/1/005-earn-lp/`. `ProposeLp.s.sol` writes `script/deployments/1/multisig/005-earn-lp/NNN-0x0cbe9bDD-multisig.json` via `SafeBatchLib.write`.
- D16. Local minimal V4 interfaces under `005-earn-lp/interfaces/`, same pattern as `003-espn-redemption/interfaces/ISeaportMinimal.sol`. No v4-core / v4-periphery submodule.
- D17. V4 mainnet addresses (PositionManager, Permit2, StateView) are added to `externalAddresses.json` under a `uniswap-v4` key. They must be verified on-chain before commit (section 8, step V0). This spec does not assert their values.
- D18. New `lp` block in `settings.json`: `fullRangeUsds`, `singleSidedUsds`, `bandLowerUsd`, `bandUpperUsd`, `fee`, `tickSpacing`. Nothing about the LP is hardcoded in the script.
- D19. LP positions are not staked in sEARN. Contracts cannot call `claim()` (`docs/help/claim-earn-yield.md`).
- D20. Verification = mainnet-fork run that deploys EARN on the fork, builds the batch, and executes it under `vm.prank(safe)`.
- D21. Out of scope: ETH pairs, hooks, staking LP, frontend, any change to Track A.

## 3. Architecture & sequence

Mandated sequence:

| # | Step | Actor | Script | Output |
|---|---|---|---|---|
| 1 | Stop ESPN yield | Safe | `004-stry-migration/StopEspnYield.s.sol` | Safe batch `004-stry-migration/001-…` |
| 2 | Snapshot | operator | `script/snapshot/espn-holders.mjs` | `config/espn-holders-26043909.json` |
| 3 | Distribute EARN | deployer EOA | `004-stry-migration/Distribute.s.sol` | EARN address in `deploymentAddresses.json` `.stry`; owner = Safe |
| 4 | Deploy sEARN | deployer EOA | `004-stry-migration/Deploy.s.sol` | `.staked-earn` in `deploymentAddresses.json` |
| 5 | Build LP batch | operator | `005-earn-lp/ProposeLp.s.sol` | `multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json` |
| 6 | Propose | operator | `node script/safe/propose-batch.mjs <file>` | Safe tx in the queue |
| 7 | Sign + execute | Safe signers | Safe UI | pool live, positions minted |

Facts fixed for this run:

- Snapshot block = 26043909. File `script/deployments/1/config/espn-holders-26043909.json` is currently untracked; it must be committed.
- Snapshot taken at 11:00 Sydney, 2026-09-24.
- Seaport (`0x0000000000000068F116a894984e2DB1123eB395`) is excluded via `settings.json` `.espnv3.excludedAddresses` (uncommitted edit). Seaport holds 0 ESPN at the snapshot.
- Track A redemption order ended 2026-09-24T01:00Z. Treasury received 5,232.96 ESPN across 15 fills.
- Step 1 reads `settings.json` `.espnv3.finalYieldAmount`, currently `"0"` (Runbook section 8). At `0` the batch is a no-op. Not changed by this spec.
- Step 5 depends on step 3 (EARN address). Step 5 does not depend on step 4.
- Step 3 → step 7 window: EARN exists and is transferable; the pool does not exist. See Risk R6.

Data flow for step 5:

```
settings.json .lp + .espnv3.basisPriceUsd
externalAddresses.json .sky-money.USDS, .uniswap-v4.*
internalAddresses.json .protocol.multisigs.redemption
deploymentAddresses.json .stry
        │
        ▼
ProposeLp.s.sol
  currency order ← address(EARN) < address(USDS)
  sqrtPriceX96, ticks, liquidity ← section 6
  6 SafeBatchLib.Tx ← section 5
        │
        ▼
multisig/005-earn-lp/001-0x0cbe9bDD-multisig.json  →  propose-batch.mjs (tx-builder schema, raw calldata)
```

## 4. Components (files touched)

New:

- `script/deployments/1/005-earn-lp/ProposeLp.s.sol` — builds the batch; `run()` writes the file; internal `buildBatch(address earn, ...)` returns `SafeBatchLib.Tx[]` for Verify (same split as `PeriodicYield.periodicYield`).
- `script/deployments/1/005-earn-lp/Verify.s.sol` — fork verification (section 8).
- `script/deployments/1/005-earn-lp/interfaces/IV4Minimal.sol` — `PoolKey` struct, `IPositionManager` (`initializePool`, `modifyLiquidities`, `multicall`, `ownerOf`, `getPositionLiquidity`, `poolManager`), `IPermit2` (`approve(address,address,uint160,uint48)`, `allowance`), `IStateView` (`getSlot0`, `poolManager`), `Actions` constants. One file; split only if it exceeds ~150 lines.
- `script/deployments/1/multisig/005-earn-lp/` — written by `ProposeLp.s.sol` (`SafeBatchLib.write` creates the directory).
- `package.json` script `verify:lp` mirroring `verify:migration` (fork URL + `SNAPSHOT_BLOCK`).

Modified:

- `script/deployments/1/004-stry-migration/Distribute.s.sol` — line 58: `renounceOwnership()` → `transferOwnership(safe)`; add `safe` nonzero + code-at-address require; change the calibration log text if it mentions renounce. `distribute()` signature unchanged.
- `script/deployments/1/004-stry-migration/Verify.s.sol` — line 77: assert `owner() == safe` (not `address(0)`); lines 79–84: use `ConfigLib.addr("internalAddresses.json", ".protocol.tripwire.controller")` instead of `new TripwireController()`; drop the `TripwireController` import.
- `script/deployments/1/004-stry-migration/PeriodicYield.s.sol` — lines 12–13 comment says supply is "fixed forever after mintBatch + renounceOwnership()". Update the comment. Logic unchanged: the per-period amount reads live `totalSupply()`, so post-LP mints raise the yield amount automatically.
- `script/deployments/1/config/settings.json` — add `lp` block (section 7). Uncommitted `excludedAddresses` edit is committed with it.
- `script/deployments/1/config/externalAddresses.json` — add `uniswap-v4` block after on-chain verification (section 8, V0).
- `script/deployments/1/config/internalAddresses.json` — commit the `.protocol.tripwire.controller` edit.
- `script/deployments/1/config/espn-holders-26043909.json` — commit.
- `test/unit/StryTokenTest.sol` — contract is unchanged, so the existing `renounceOwnership` test remains valid for the contract. No test change required; the ownership end-state is a script decision, verified by `Verify.s.sol`. See open item O5.
- Docs: section 9.

Not modified: `src/StryToken.sol`, `src/StakedStrat.sol`, `script/deployments/1/004-stry-migration/Deploy.s.sol`, `StopEspnYield.s.sol`, `lib/*`, `script/safe/*`, anything under `003-espn-redemption/`.

## 5. Batch spec

Safe = redemption Safe. All six transactions have `value = 0`. Written by `SafeBatchLib.write(safe, "005-earn-lp", 1, "EARN/USDS V4 LP", <description>, txs)`.

| # | `to` | Call | Notes |
|---|---|---|---|
| 1 | EARN | `mintBatch([safe], [fullRangeEarn])` | `fullRangeEarn = fullRangeUsds / basisPriceUsd` = 2500e18. Safe is `owner()` (D8). |
| 2 | USDS | `approve(Permit2, fullRangeUsds + singleSidedUsds)` | 500,000e18. Exact amount, not max. |
| 3 | EARN | `approve(Permit2, fullRangeEarn)` | 2500e18. |
| 4 | Permit2 | `approve(USDS, PositionManager, uint160(fullRangeUsds + singleSidedUsds), expiration)` | |
| 5 | Permit2 | `approve(EARN, PositionManager, uint160(fullRangeEarn), expiration)` | |
| 6 | PositionManager | `multicall([initializePool(poolKey, sqrtPriceX96), modifyLiquidities(unlockData, deadline)])` | |

Permit2 `expiration` = `type(uint48).max`. Reason: the calldata is generated before signing; a timestamp would go stale in the Safe queue. Permit2 decrements the allowance amount on spend, so the residual allowance after execution is dust. Alternative: `expiration = 0` (Permit2 stores `block.timestamp`, valid only in the execution block); works only if the Safe executes the batch as one MultiSend tx, which `propose-batch.mjs` produces. Rejected as fragile.

`modifyLiquidities` `deadline` = `type(uint256).max`. Same reason. The Safe can decline to execute; a stale deadline would force regeneration.

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

- `amountMax` per position = the configured amount for that currency, 0 for the currency the position must not take. Position 2's EARN-side max = 0: if the tick math is wrong and the band is in range, the mint reverts instead of pulling EARN.
- `SETTLE_PAIR` settles both currencies for the sum of both mints; PositionManager pulls via Permit2 from `msg.sender` = Safe.
- `hookData` = empty bytes.
- Action constants: expected `MINT_POSITION = 0x02`, `SETTLE_PAIR = 0x0d` (v4-periphery `Actions.sol`). Copied, not derived; a wrong value reverts on the fork.
- `ownerOf(tokenId)` for both minted positions = Safe. PositionManager mints with `_mint` (no `onERC721Received` callback); the Safe's fallback handler is not required. Confirm on the fork.

Preflight requires in `ProposeLp.s.sol` (revert before writing the file):

- `EARN.owner() == safe`.
- `USDS.balanceOf(safe) >= fullRangeUsds + singleSidedUsds` (500,000e18).
- `EARN.decimals() == 18 && USDS.decimals() == 18`.
- `PositionManager.poolManager() == PoolManager` and `StateView.poolManager() == PoolManager` (address sanity, D17).
- `StateView.getSlot0(poolId).sqrtPriceX96 == 0` (pool not yet initialized). See R6.
- `bandUpperUsd == basisPriceUsd` or `bandUpperUsd < basisPriceUsd`; `bandLowerUsd < bandUpperUsd`; `fee`/`tickSpacing` nonzero.
- `fullRangeUsds % basisPriceUsd == 0`.

Signer verification: every tx is raw calldata (`contractMethod: null`), so the Safe UI shows `to` + selector only (Runbook section 6). The fork Verify is the proof of payload content. `ProposeLp.s.sol` logs, per tx, the `to`, selector, decoded amounts, ticks, liquidity, and `sqrtPriceX96` for the signers to compare against the Verify log.

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
- Full-range liquidity: `liqFull = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtAt(FULL_LOWER), sqrtAt(FULL_UPPER), amount0 = fullRangeEarn, amount1 = fullRangeUsds)` = `min(L0, L1)`. At P = 100 both sides evaluate to ~25000e18; the min binds by a few wei.
- Band liquidity: `liqBand = getLiquidityForAmount1(sqrtAt(BAND_LOWER), sqrtAt(BAND_UPPER), singleSidedUsds)`.
- amountMax: position 1 `(fullRangeEarn, fullRangeUsds)`; position 2 `(0, singleSidedUsds)`.

### Case B: USDS is currency0 (`address(USDS) < address(EARN)`)

- `P = EARN per USDS = 1 / B`.
- `sqrtPriceX96 = Math.sqrt((1 << 192) / B)`. For B = 100: `7922816251426433759354395033` (floor of `2^96 / 10`).
- `currentTick` = -46055 for B = 100 (`log_1.0001(0.01) = -46054.004`, floor → -46055).
- Bid wall holds currency0 (USDS) ⇒ needs `currentTick < BAND_LOWER` (strict).
- Price band in pool terms is `[1/Hi, 1/Lo]`.
- `BAND_LOWER = ceilToSpacingStrictlyAbove(currentTick)` when `Hi == B`: smallest multiple of `s` that is `> currentTick`. For B = 100: `-46020` (price 1/99.66). If `Hi < B`, `BAND_LOWER = ceilToSpacing(tick(1/Hi))`, then require `> currentTick`.
- `BAND_UPPER = ceilToSpacing(tick(1/Lo))`. For Lo = 50: `tick(0.02) = -39123` → `-39120` (price 1/49.99).
- Equality case: `BAND_LOWER == currentTick` is NOT USDS-only (it is in range). The rule above adds one spacing in that case. `ProposeLp.s.sol` requires `currentTick < BAND_LOWER` after rounding.
- `FULL_LOWER/UPPER` as Case A.
- `liqFull = getLiquidityForAmounts(sqrtP, sqrtAt(FULL_LOWER), sqrtAt(FULL_UPPER), amount0 = fullRangeUsds, amount1 = fullRangeEarn)`.
- `liqBand = getLiquidityForAmount0(sqrtAt(BAND_LOWER), sqrtAt(BAND_UPPER), singleSidedUsds)`.
- amountMax: position 1 `(fullRangeUsds, fullRangeEarn)`; position 2 `(singleSidedUsds, 0)`.

### Common

- Rounding rule in words: the band edge nearest the pool price rounds away from the price so the position is out of range on the USDS side; the far edge rounds outward (wider band). Case A far edge floors, Case B far edge ceils.
- `getLiquidityForAmountN` rounds liquidity down, so the settled amount is `<=` the configured amount. `amountMax = configured amount` is safe. If the fork shows a 1-wei round-up revert, raise `amountMax` by `1e6` wei and record it.
- `TickMath` and `LiquidityAmounts` are copied into `005-earn-lp/lib/` from v4-core / v4-periphery (pure math, no state); alternative is a git submodule, rejected (one-off use).
- Implementation must not compute `log` in Solidity; `TickMath.getTickAtSqrtPrice(sqrtPriceX96)` gives `currentTick`, and band edge ticks come from `getTickAtSqrtPrice(Math.sqrt(price << 192))` with the same formula per ordering.
- Integer sqrt: `openzeppelin-contracts/utils/math/Math.sol` `sqrt` (floor), already a dependency.

Reference values (B = 100, Lo = 50, Hi = 100, s = 60):

| Quantity | Case A (EARN = c0) | Case B (USDS = c0) |
|---|---|---|
| `sqrtPriceX96` | 792281625142643375935439503360 | 7922816251426433759354395033 |
| `currentTick` | 46054 | -46055 |
| `BAND_LOWER` | 39120 | -46020 |
| `BAND_UPPER` | 46020 | -39120 |
| USDS/EARN at band edges | 49.99 – 99.66 | 99.66 – 49.99 |
| `FULL_LOWER/UPPER` | -887220 / 887220 | -887220 / 887220 |

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

`deploymentAddresses.json`: `.stry` (EARN) written by Distribute; `.staked-earn` written by Deploy. Position token ids are logged by Verify, not stored (they are assigned at execution).

## 8. Verification / testing

### V0. Address verification (before editing `externalAddresses.json`)

For each of PositionManager, Permit2, StateView on mainnet:

1. `cast code <addr>` non-empty.
2. Real call: `PositionManager.poolManager()` returns `0x000000000004444c5dc75cB358380D2e3dE08A90`; `StateView.poolManager()` returns the same; `Permit2.DOMAIN_SEPARATOR()` returns nonzero and `PositionManager.permit2()` returns the Permit2 address.
3. Record block number and results in the commit message that adds the addresses.

Candidate values from Uniswap documentation, NOT verified by this spec: PositionManager `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, StateView `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227`. Treat as hints for V0, not facts.

Additional V0 check: read the ESPN/USDS pool's `PoolKey` from the block-23544626 `Initialize` event on PoolManager and confirm `fee == 3000`, `tickSpacing == 60`, `hooks == address(0)` match D5.

### V1. `yarn verify:migration` (existing, modified)

- Line 77 assertion becomes `assertEq(stry.owner(), safe)`.
- Uses the live controller; asserts `controller.code.length > 0` first.
- Everything else unchanged.

### V2. `yarn verify:lp` (new `005-earn-lp/Verify.s.sol`)

Fork at `SNAPSHOT_BLOCK`. Same harness as 004 (`vm.startPrank`, `deal`, `_executeBatch`).

1. Run `Distribute.distribute(deployer, holdersFile)` on the fork → `earn`. Record `airdropSupply = earn.totalSupply()`.
2. If `USDS.balanceOf(safe) < 500,000e18`, `deal` the shortfall and log a WARNING (mainnet preflight is a hard require; fork is not).
3. `txs = buildBatch(earn, ...)`; assert `txs.length == 6` and `txs[0].to == earn` with selector `mintBatch`.
4. Assert `StateView.getSlot0(poolId).sqrtPriceX96 == 0` before execution.
5. `_executeBatch(safe, txs)`; log gas.
6. Assert `earn.totalSupply() == airdropSupply + fullRangeEarn`.
7. Assert `getSlot0(poolId).sqrtPriceX96 == expected sqrtPriceX96` (exact) and `tick == expected currentTick`.
8. Assert `PositionManager.ownerOf(tokenId1) == safe` and `ownerOf(tokenId2) == safe` (token ids from `nextTokenId()` read before execution, or from `Transfer` logs).
9. Assert `getPositionLiquidity(tokenId1) == liqFull` and `getPositionLiquidity(tokenId2) == liqBand`.
10. Assert residual `USDS.balanceOf(safe) - balanceBefore + 500,000e18 <= 1e12` and `earn.balanceOf(safe) <= 1e12` (1e-6 token dust tolerance; rounding is bounded by wei per position).
11. Assert position 2 took zero EARN: EARN pulled from Safe == amount settled by position 1 only (equivalently `earn.balanceOf(safe)` dust after minting exactly `fullRangeEarn`).
12. Assert `Permit2.allowance(safe, USDS, PositionManager).amount <= 1e12` and same for EARN.
13. Negative test: re-run `buildBatch` after execution → must revert on the pool-already-initialized preflight (R6).
14. Negative test: on a state snapshot, swap position 2's amountMax so the EARN side is nonzero and shift `BAND_UPPER`/`BAND_LOWER` by one spacing into range → mint reverts (proves the out-of-range check is load-bearing). Optional; include if it costs under 30 lines.
15. Swap sanity (informational): `deal` 1,000 USDS to a test EOA, swap USDS→EARN through PoolManager via a minimal router or `PoolSwapTest` copied from v4-core, assert EARN received ≈ 1000/100 minus 0.3% fee. Skip if it needs more than the copied test router; log the reason.

Both orderings: the fork EARN address is deterministic per deployer nonce, so only one ordering runs live. To cover the other, Verify deploys a second `StryToken` under a different `makeAddr` deployer until `address(earn2) < address(USDS)` differs from the first case (loop with bounded attempts, max 32), and runs steps 3–12 again on a state snapshot. Log which case each run hit.

### V3. Unit tests

- `test/unit/ScriptLibsTest.sol` style test for the tick derivation: pure function `deriveTicks(currency0IsEarn, B, Lo, Hi, s)` returns the reference table in section 6 for both cases, plus the equality case (`currentTick` exactly on a spacing multiple → Case B lower moves up one spacing; Case A upper stays).
- No `StakedStrat` or `StryToken` contract tests change.

## 9. Docs to update

- `docs/ESPNv3_Runbook.md` Assumption 10: replace with "EARN: `transferOwnership(redemption Safe)`; Safe can mint without limit. REDEMPTION: renounced (unchanged)." Section 2 table: add steps for Deploy (sEARN) and ProposeLp. Section 6: add the `005-earn-lp/001-…` batch and its 6-tx order. Section 7: add `verify:lp`.
- `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md`: add a "Superseded" line at the top pointing here for Assumption 10 (EARN only) and for the LP out-of-scope item. No other edits.
- `docs/help/claim-earn-yield.md`: add one line: "EARN supply is not fixed. The redemption Safe can mint additional EARN; any mint dilutes existing holders." Add one line: "EARN held in the Uniswap V4 pool positions is not staked and earns no sEARN yield."
- `docs/RELEASE-NOTES.md`: user-visible entries per the release-notes rule: EARN launched; EARN/USDS Uniswap V4 pool at 100 USDS per EARN; EARN supply is mintable by the redemption Safe.
- `script/deployments/1/004-stry-migration/PeriodicYield.s.sol:12-13` comment (code comment, not a doc; listed here so it is not missed).
- Any holder communication that states EARN supply is fixed: none found in the repo (`grep` for "fixed supply", "no future mint", "cannot be minted" across `docs/`, `src/`, `README.md` returned only Runbook Assumption 10 and the PeriodicYield comment).

## 10. Risks

- R1. Pool goes live at 100 USDS/EARN while the airdrop is still landing in wallets. Holders can sell into the bid wall immediately; the Safe accumulates EARN in return. Accepted.
- R2. Minted-amount errors are correctable by further minting (D8). The pool initialization price is not correctable: a wrong `sqrtPriceX96` requires a new pool key (different fee/tickSpacing/hook) or arbitrage losses. The fork assertion on exact `sqrtPriceX96` (V2 step 7) is the guard.
- R3. Raw-calldata batches: signers verify `to` + selector only. Mitigation: `ProposeLp.s.sol` logs decoded parameters; Verify log is the reference. Same posture as every other batch in this repo.
- R4. Assumption 1 (redemption Safe address) is UNCONFIRMED. Every tx in the batch, the EARN owner, and the NFT owner are that address. A wrong value under D8 is unrecoverable (single-step Ownable).
- R5. USDS on the Safe must be `>= 500,000e18` at execution. `ProposeLp.s.sol` requires it at generation; the Safe executes later. Signers re-check before execution. Track A payouts have already reduced the Safe's USDS from the ~1.2M recorded on 2026-08-21; the current balance is not recorded in this spec.
- R6. Anyone can initialize a V4 pool with the same `PoolKey` once EARN's address is known (after step 3, before step 7), at any price. `PositionManager.initializePool` wraps `PoolManager.initialize` in try/catch and returns `type(int24).max` on failure instead of reverting (v4-periphery `PoolInitializer_v4`; confirm against the deployed source in V0). If so, a front-run initialization does not revert the batch, and position 1 would mint at the attacker's price. Mitigation in this spec: preflight `sqrtPriceX96 == 0` at generation, signer re-check at execution. See open item O1 for the stronger alternative.
- R7. ESPN has a second ESPN/USDS V4 pool (fee 0, tickSpacing 10, hook `0x3fb49f96338b22cadd9614a51633189d4ce21088`). Not used as template; listed so nobody copies its key by mistake.
- R8. `PeriodicYield.s.sol` computes the 28-day USDS amount from `EARN.totalSupply()`. After the LP mint, `totalSupply` includes 2,500 EARN that is not staked; the period amount rises by `2500 * 100 * 15% * 28/365 ≈ 2,877 USDS` and is paid to stakers. Any later Safe mint raises it further. Accepted; stated.
- R9. Safe dilution power (D10). No on-chain cap. Stated in docs (section 9).
- R10. Permit2 allowance and ERC20 allowance to Permit2 remain at dust after execution (exact amounts approved). No revoke tx in the batch.
- R11. The full-range position's EARN side is exactly the 2,500 minted in tx 1. If V4 rounds the settled amount up by 1 wei, `amountMax` reverts the batch. Fork run detects it (section 6 rounding note).

## 11. Explicit assumptions / open items

- O1. Recommendation: replace `PositionManager.initializePool` inside the multicall with a direct `PoolManager.initialize(poolKey, sqrtPriceX96)` as its own Safe tx (7 txs total). Reason: `PoolManager.initialize` reverts `PoolAlreadyInitialized`, making the whole Safe execution atomic-fail on a front-run (R6); `initializePool` swallows it. Alternative: keep D14's 6-tx shape and rely on the preflight + signer re-check. Decision is the user's; D14 stands until changed.
- O2. V4 addresses (PositionManager, Permit2, StateView) unverified until V0 runs. Candidates in section 8 are hints.
- O3. `Actions` constant values (`MINT_POSITION`, `SETTLE_PAIR`) and the `MINT_POSITION` param encoding order are taken from v4-periphery source at implementation time; confirmed by the fork run, not by this spec.
- O4. `PositionManager` ERC721 mint path: confirmed non-callback (`_mint`) at implementation time; the Safe has a fallback handler either way.
- O5. `test/unit/StryTokenTest.sol`: this spec keeps the renounce test (contract unchanged). If the user wants the test to reflect the operational end-state, add one test `transferOwnership(safe)` then `mintBatch` by the Safe succeeds; not added by default.
- O6. Assumption 1 (Safe address) — still unconfirmed (R4).
- O7. `finalYieldAmount = "0"` makes step 1 a no-op. Not changed here; inherited from Runbook section 8.
- O8. The Safe's current USDS balance after Track A fills is not recorded; R5 preflight covers it at generation time only.
- O9. Whether `Cancel.s.sol` (Track A allowance revoke) has been run is outside this spec; a live 700k Seaport allowance does not affect this batch's balance require, but does affect the Safe's spendable USDS if the order were re-validated. Out of scope (D21).
- O10. Case-B dual-ordering coverage in V2 uses repeated deployer addresses to hit the other ordering; if 32 attempts do not flip the ordering, log and skip; the untested ordering is then only unit-tested (V3).
