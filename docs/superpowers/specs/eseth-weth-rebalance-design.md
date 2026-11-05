# esETH WETH rebalance — design (one script)

Branch: `eseth-weth-rebalance`. Status: design rev 5. Script 1 (`RedepositEth`: redeem -> unwrap -> `wrapAndMint`) was
dropped: esETH cannot hold native ETH (no receive/fallback, no ETH token type; `wrapAndMint` re-wraps to WETH),
so it was an economic no-op (net -1 wei esETH plus gas). Only `WethToStEth` remains.

## Goal

One Foundry script, run every fortnight, builds one Safe batch for Safe
`0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1` (esETH `treasuryManager` + minter). It does not broadcast.

- `WethToStEth`: redeem `AMOUNT` WETH from esETH, convert to stETH by the cheaper of
  Lido `submit` and Uniswap, mint the stETH back into esETH.

It emits a propose JSON (raw calldata, per-tx `value`; input to `hash-batch.mjs`,
`tenderly-simulate.mjs`, `propose-batch.mjs`) and a decoded tx-builder JSON (Safe UI import).

## On-chain facts (mainnet, blocks 26345192-26345203, 2026-11-05, via cast on publicnode)

esETH (`src/esETH.sol`, `0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb`):
- No `receive`/`fallback`. Plain ETH send to esETH reverts (`cast estimate --value 1` reverts).
- The only ETH entry point is `wrapAndMint(address receiver) payable` (line 158): requires
  `isMinter[msg.sender]`, calls `WETH.deposit{value}`, mints `msg.value` esETH against WETH.
  esETH never holds native ETH: `cast balance esETH` = 0.
- No token type for native ETH; `tokenConfigs(0xEeee...EEeE)` = UNSUPPORTED.
- `redeem(token, amount, receiver)` (line 203): burns `amount + 1` esETH (ERC20 type) from caller,
  `totalMinted -= amount`, sends `amount` token. Treasury manager bypasses `isRedeemable`.
- `mint(token, amount, receiver)` (line 137): requires `isMinter`; non-mintable tokens only for
  `treasuryManager` (line 186).
- `treasuryManager() == SAFE`, `isMinter(SAFE) == true`, `WETH() == 0xC02a...6Cc2`.
- `tokenConfigs(WETH)` = (ERC20, mintable, redeemable, totalMinted 74.064294416562676496e18).
- `tokenConfigs(stETH)` = (ERC20, isMintable **false**, redeemable, totalMinted 82.000000000000000002e18).
- `tokenConfigs(wstETH)` = UNSUPPORTED. wstETH cannot be deposited; must be unwrapped to stETH.
- `WETH.balanceOf(esETH)` = 74.064294416562676496 WETH (per-run cap; 74 whole ETH max).
- `stETH.balanceOf(esETH)` = 88.18 stETH.

Safe: v1.4.1 (singleton `0x41675C09...461a`), threshold 1, owner `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`,
nonce 105, no guard (guard slot = 0), no modules, 6640.86 esETH, 1591.86 stETH, 0 wstETH, 0 WETH, 1 gwei ETH.
The Safe's 1591.86 stETH stock means `esETH.mint(stETH, x)` succeeds even if this batch acquired less
than `x` stETH: the shortfall is drawn from the Safe's stock (fork-verified, see Fork verification).

## Fork verification (anvil fork of publicnode, block 26345229-26345235, 2026-11-05)

Executed as the Safe via `execTransaction(MultiSendCallOnly 0x9641...02e2, op 1, approved-hash sig v=1)`
from the impersonated owner:
- `WETH.withdraw(1e18)` sent directly from the impersonated Safe (no `execTransaction`): status 0.
  Cause: WETH9 `transfer` 2300 stipend vs cold singleton SLOAD + cold delegatecall in the proxy; inside
  `execTransaction` both are warm. Simulation must go through `execTransaction`, not `vm.prank(SAFE)`.
- Lido batch, amt 50 ETH: status 1, gas 233,851. Safe stETH shares +2 wei; `stETH.balanceOf(esETH)`
  +amt-3 wei (minted esETH = amt-2: 1 wei under-backed per run, left to `burnExcess`);
  `tokenConfigs(stETH).totalMinted` +amt-2; esETH `totalSupply` -3 wei; Safe ETH unchanged.
- Negative control (a packing bug truncated the `submit` value to 50e18 mod 2^64 = 13.1 ETH): batch
  still succeeded; `mint` drew 36.9 stETH from the Safe's stock; 36.9 ETH stranded in the Safe.

Pipeline: `safe-hash.mjs` (l.29) and `propose-batch.mjs` (l.135) carry per-tx `value` from the
tx-builder schema and assert the outer Safe tx `value` is 0. Recorded `multisendTo` in prior batches =
MultiSendCallOnly `0x9641...02e2`, same as the simulation target.

Lido stETH `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` (impl `0x028271E30a695c0527A0C50cA30603feD004cDb0`):
- `submit(address)` selector `0xa1903eab`, payable, returns shares (present in impl bytecode;
  `cast call submit --value 50ether` returns 40.0506e18 shares).
- `isStakingPaused() == false`, `getCurrentStakeLimit()` = 150000 ETH.
- 50 ETH -> `getPooledEthByShares(getSharesByPooledEth(50e18))` = 50e18 - 1 wei.

wstETH `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`: `unwrap(uint256) returns (uint256)` verified
(`cast call --from` a holder), `getStETHByWstETH(1e18)` = 1.248420541703429835e18.

Uniswap WETH/ETH -> stETH liquidity (see A5 for the quote table):

| venue | pool | state |
|---|---|---|
| v3 WETH/stETH 0.01%, 0.05%, 0.3% | `0x8f8e...6392`, `0xeacD...6b5C`, `0xF25B...2de3` | liquidity 0, empty |
| v3 WETH/stETH 1% | `0x63818BbDd21E69bE108A23aC1E84cBf66399Bd7D` | 46.7 stETH / 182.6 WETH |
| v2 WETH/stETH | `0x4028DAAC072e492d34a3Afdbef0ba7e35D8b55C4` | 42.5 / 42.5 |
| v4 ETH/stETH or WETH/stETH, hookless, fee/tickSpacing 1/1,10/1,50/1,100/1,100/10,200/4,500/10,3000/60,10000/200 | — | none initialised |
| v3 WETH/wstETH 0.01% | `0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa` (token0 wstETH) | liquidity 6.17e24; 604.6 wstETH / 1134.2 WETH |
| v4 ETH/wstETH 0.01% ts 1, hookless | id `0x1d5b2949...e2d76` | liquidity 5.03e22 (100x thinner than v3) |

SwapRouter02 `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`: `factory()` = v3 factory
`0x1F98431c8aD98523631AE4a59f267346ea31F984`, `WETH9()` = WETH, bytecode contains
`exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))` selector `0x04e45aaf`.
QuoterV2 `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`. Gas price at check: 0.037 gwei.

## WethToStEth

Route chosen on the fork (A6). `RebalanceParams.ROUTE` (`Params.sol`, env `ROUTE` overrides): `auto` (default) | `lido` | `uniswap`.

Lido route (5 txs):

| # | to | value | call |
|---|---|---|---|
| 1 | esETH | 0 | `redeem(WETH, amt, SAFE)` |
| 2 | WETH | 0 | `withdraw(amt)` |
| 3 | stETH | amt | `submit(address(0))` |
| 4 | stETH | 0 | `approve(esETH, amt - 2)` |
| 5 | esETH | 0 | `mint(stETH, amt - 2, SAFE)` |

Uniswap route (6 txs, A5/A7):

| # | to | value | call |
|---|---|---|---|
| 1 | esETH | 0 | `redeem(WETH, amt, SAFE)` |
| 2 | WETH | 0 | `approve(SwapRouter02, amt)` |
| 3 | SwapRouter02 | 0 | `exactInputSingle((WETH, wstETH, 100, SAFE, amt, minWst, 0))` |
| 4 | wstETH | 0 | `unwrap(minWst)` |
| 5 | stETH | 0 | `approve(esETH, stMint)` |
| 6 | esETH | 0 | `mint(stETH, stMint, SAFE)` |

`quoteWst` = QuoterV2 `quoteExactInputSingle(WETH, wstETH, amt, 100, 0)` on the fork.
`minWst = quoteWst * (10000 - SLIPPAGE_BPS) / 10000`. `stMint = wstETH.getStETHByWstETH(minWst) - 2`.
`wstETH` above `minWst` (at most the realised slippage headroom) stays in the Safe.

Simulation asserts (both routes): `WETH.balanceOf(esETH)` fell by exactly amt; `stETH.balanceOf(esETH)`
rose by `>= stMint - 2` (fork: `stMint - 1`); `tokenConfigs(stETH).totalMinted` rose by exactly `stMint`;
Safe esETH and esETH `totalSupply` changed by exactly `stMint - amt - 1`; `WETH.balanceOf(SAFE)` and
`SAFE.balance` unchanged; `stETH.balanceOf(SAFE)` after `>=` before (the mint did not draw on the Safe's
stETH stock). Lido route also: stETH received `>= amt - 2`, measured as
`getPooledEthByShares(delta(sharesOf(SAFE) + sharesOf(esETH)))` (no other stETH moves in the batch).
Uniswap route also: `WETH.allowance(SAFE, SwapRouter02) == 0` after, Safe wstETH delta `>= 0`.

### In-script batch guards

`_checkBatch` runs on the built batch before simulation and before any file is written (named reverts):
- Route resolved (`Lido` | `Uniswap`, not `Auto`); tx count (5 Lido, 6 Uniswap); value is 0 except Lido
  `submit` (`== amt`).
- Decodes every tx via `_at` (asserts position, target and selector) and asserts args: `redeem(WETH, amt, SAFE)`;
  `mint(stETH, stMint, SAFE)`, with `stMint` read back from the mint tx; stETH `approve(esETH, stMint)`.
  Lido: `withdraw(amt)`, `submit(0)`, `amt - 2 <= stMint <= amt`.
  Uniswap: WETH `approve(router, amt)`; swap `tokenIn/tokenOut/fee/recipient/amountIn/sqrtPriceLimitX96`,
  `amountOutMinimum == minWst`, calldata length exactly 7 words (no deadline); `unwrap <= minWst` and
  `getStETHByWstETH(unwrap) >= stMint + 2` (2 wei transfer rounding).
- No allowlist loop and no recomputation of `stMint` from `minWst`: `_at` already pins every tx, and `stMint`
  is bounded against independent values (`amt`, wstETH's own rate, the par floor).
- Par floor (Uniswap, any route-selection reason): `stMint >= amt * (10000 - SLIPPAGE_BPS) / 10000`, rate from
  `wstETH.getStETHByWstETH`, not the pool quote. Fails closed ("Uniswap stMint below par floor"), also when
  Lido is paused/capped and `auto` falls back to Uniswap. Effective bound: pool quote must be ~>= 1 stETH per ETH.
- Tests: one negative fork test per guard (a single tampered field each: counts, values, every redeem/mint/
  approve/withdraw/submit/swap arg, unwrap bounds, Lido range, par floor, route unresolved); tampering
  builders prove `buildAndSimulate` runs `_checkBatch` on both routes; mocks trigger each pre-check and
  post-simulation assert; mocked low quote / manipulated rate hit the par floor; the default `yarn test` (no fork) writes the real
  descriptors (redeem, withdraw, submit, approve, mint, unwrap) through `_write`/`verify`.

## Shared parameters and checks

Params (`script/deployments/1/009-eseth-weth-rebalance/Params.sol`, library `RebalanceParams`; the script
imports it; an env var of the same name overrides per run via `vm.envOr`):
- `AMOUNT` (default 0 = unset, reverts unless `AMOUNT` is given): whole ETH integer, `vm.envOr("AMOUNT", ...)`
  (non-integer such as `0.5`: cheatcode error, nothing written). `amt = AMOUNT * 1 ether` (checked; overflow panics).
  `require(AMOUNT > 0)`. Log `AMOUNT` and `amt` (wei). A wei value passed by mistake
  (e.g. `50000000000000000000`) exceeds the cap and reverts with the cap reason.
- `SLIPPAGE_BPS` (default 10, `require <= MAX_SLIPPAGE_BPS` = 100): Uniswap route only.
- `ROUTE` (default `"auto"`, `auto|lido|uniswap`): selects Lido vs Uniswap.
- `RPC_URL`: loaded by forge/node. The script author never reads `.env`.

Pre-conditions (named revert, before any file is written):
- `esETH.treasuryManager() == SAFE`, `esETH.isMinter(SAFE)`.
- `tokenConfigs(WETH).tokenType == ERC20`; also `tokenConfigs(stETH).tokenType == ERC20`.
- `amt <= WETH.balanceOf(esETH)`; `amt <= tokenConfigs(WETH).totalMinted` (line 228 underflow);
  `amt + 1 <= esETH.balanceOf(SAFE)`.
- Lido route: `!isStakingPaused()`, `amt <= getCurrentStakeLimit()`.
- Uniswap route: `minWst > 0`, `stMint > 0`.
- `Safe.nonce()` read (latest) and logged before simulation.
- Tripwire: not checked separately; a tripped wire reverts the simulation.

Simulation (unchanged from rev 2 A2): pack the txs as MultiSendCallOnly bytes, prank
`getOwners()[0]`, call `Safe.execTransaction(MULTISEND_CALL_ONLY, 0, multiSend(packed), 1, 0,0,0,0,0, sig)`
with the approved-hash signature; if `getThreshold() > 1`, `vm.store` threshold slot 4 to 1
(fork-only). Not `SafeBatchLib.execute`: `WETH.withdraw` reverts under `vm.prank(SAFE)` but succeeds
via `execTransaction` (re-verified on fork in rev 4, see Fork verification). MultiSend bytes: amounts
packed as uint256 via `abi.encodePacked`; never via a narrower type (the rev-4 negative control shows a
truncated `value` still executes).

## Code layout

- `script/deployments/1/009-eseth-weth-rebalance/Params.sol` — `RebalanceParams`: AMOUNT, ROUTE, SLIPPAGE_BPS,
  MAX_SLIPPAGE_BPS.
- `script/deployments/1/009-eseth-weth-rebalance/RebalanceBase.s.sol` — abstract: amount parse, caps,
  nonce log, MultiSend simulate, `_at`, index scan, both writes.
- `.../WethToStEth.s.sol`.
- Outputs: `script/deployments/1/multisig/009-eseth-weth-rebalance/steth/NNN-0xF89f49e2-multisig.json`
  (raw, `SafeBatchLib.write` values overload) and `...NNN-0xF89f49e2-multisig.tx-builder.json`
  (decoded, `SafeBatchDecodedLib.write`). First free `NNN` per subdir via `vm.exists` scan.
- `externalAddresses.json`: add `safe.multiSendCallOnly` (`0x9641d764fc13c8B624c04430C7356C1C7C8102e2`)
  and `uniswap-v3.swapRouter02`, `uniswap-v3.quoterV2` for the Uniswap route.
- Base holds only shared getters (Safe, esETH, WETH, MultiSendCallOnly); stETH/wstETH/Uniswap getters
  live in `WethToStEth`.

## Library changes (fold-in of review findings on 4d2bc563 / 6977cfaf)

- `SafeBatchDecodedLib.write` calls `verify(txs[i], i)` for every decoded tx before writing.
- JSON string guard: `write` reverts if any of `name`, `description`, `method`, input
  `name`/`typ`/`internalTyp`/`value` contains `"` or `\` (A12).
- Raw-data fallback: a `Tx` with empty `method` is written as `"data":"0x..."`,
  `"contractMethod":null,"contractInputsValues":null`; `verify` skipped for it (A12).
- Comments in both libs: replace `008-eseth-weth-rebalance/ProposeRebalance.s.sol` with the 009 paths.
- Tests (`test/unit/ScriptLibsTest.sol`): `verify` mismatch reverts; `uint256` input branch
  round-trips; `SafeBatchLib.write` values-length mismatch reverts; quote guard reverts; raw-data
  fallback writes `data` and null `contractMethod`.

## User flow

```
# defaults live in Params.sol (edit there, or override per run with env)
[AMOUNT=50] [ROUTE=auto] [SLIPPAGE_BPS=10] forge script script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol --fork-url $RPC_URL
node --env-file=.env script/safe/hash-batch.mjs <raw.json> --write [--nonce N if Safe queue non-empty]
node --env-file=.env script/safe/tenderly-simulate.mjs <raw.json>   # optional
node --env-file=.env script/safe/propose-batch.mjs <raw.json>
```

## Failure modes

| condition | behaviour |
|---|---|
| `AMOUNT` unset / 0 / above any cap | named revert, nothing written |
| `SLIPPAGE_BPS > 100`, unknown `ROUTE` | named revert |
| `ROUTE=lido` while paused or limit < amt | named revert |
| `ROUTE=uniswap` or auto-picked Uniswap; price moves below `minWst` before execution | swap reverts, whole Safe tx reverts; regenerate |
| stETH negative rebase between build and execution | unwrap / submit yields < `stMint`; `mint` does **not** revert, the shortfall is drawn from the Safe's stETH stock (Safe holds 1591.86 stETH); esETH still receives `stMint` |
| Batch acquires less stETH than `stMint` at build time (bug) | simulation assert `stETH.balanceOf(SAFE)` non-decreasing / `SAFE.balance` unchanged fails, nothing written |
| Public WETH redeems drain esETH below amt before execution | `redeem` reverts, whole Safe tx reverts |
| Tripwire tripped | simulation reverts, nothing written |
| Safe nonce moves after `hash-batch --write` | `propose-batch.mjs` rejects; re-run `--write` |
| Safe queue holds a tx at the on-chain nonce | pass `--nonce <next free>` to `hash-batch.mjs` |
| Run with `--broadcast` | no `vm.broadcast`; nothing sent |
| Decoded descriptor disagrees with calldata | `write` reverts via `verify`, nothing written |

## Test plan

- Fork tests in `test/integration/` (`FOUNDRY_PROFILE=integration forge test --fork-url $FORK_URL`),
  via a harness exposing `buildAndSimulate` (no files written):
  - `ROUTE=lido AMOUNT=50` passes; `ROUTE=uniswap AMOUNT=1` passes; `auto` picks Lido unless
    the Uniswap floor `stMint` exceeds Lido's `amt - 2` (at today's prices with `SLIPPAGE_BPS=10`:
    Lido); `auto` with `SLIPPAGE_BPS=0` picks Uniswap when the fork-block quote beats Lido (true at
    block 26345235: +1.56 bps); Lido paused (`vm.mockCall isStakingPaused`) + `ROUTE=lido` reverts and
    `auto` picks Uniswap; `ROUTE=uniswap` with a zero QuoterV2 quote (`vm.mockCall`) reverts `minWst == 0`;
    totalMinted < amt (`deal` WETH to esETH) reverts with the totalMinted reason (shared `RebalanceBase` check).
- Lib unit tests as listed above; existing `ScriptLibsTest` cases pass unchanged.

## Assumptions

Each: recommendation; reason; alternatives.

A1. Script 1 (`RedepositEth`) dropped (supersedes the rev 4 resolution to build it).
- Reason: esETH cannot hold native ETH (no receive/fallback, no ETH token type, plain send reverts).
  The only ETH entry, `wrapAndMint`, re-wraps to WETH, so the batch left esETH with the same WETH
  and cost -1 wei esETH plus gas. Nothing in esETH changed composition.
- Alternatives: (a) keep it as a no-op; (b) stop after `withdraw` (ETH left in the Safe) — removes
  backing from esETH; (c) owner adds a native-ETH path to esETH — contract change, out of scope.

A2. WETH -> ETH (Lido route) is `WETH.withdraw(amt)` called by the Safe; simulation via `execTransaction`.
- Reason: fork-verified in rev 2; no router or helper needed.
- Alternative: UniversalRouter `UNWRAP_WETH` — extra address, unwraps the router's whole balance.

A3. Funding source is the Safe's own esETH (6640.86 esETH; burns amt+1 per run).
- Reason: Safe is treasury manager and holds esETH; no desETH step needed.
- Alternative: desETH mint first (DesEthEsEthCycle) — two more txs, no benefit.

A4. `AMOUNT` whole ETH, required, no default; fractional WETH (0.064 today) is not pullable.
- Reason: user direction; a default could pull the full backing by accident.
- Alternative: `AMOUNT_WEI` override for the fractional remainder (not asked).

A5. Uniswap route = v3 WETH/wstETH 0.01% (`0x1098...7dAa`) via SwapRouter02 `exactInputSingle`,
then `wstETH.unwrap`.
- Reason: direct WETH/stETH pools are empty or thin; v4 hookless has no stETH pool. Quotes
  (stETH out; wstETH routes converted at `getStETHByWstETH`), block 26345203:

  | in (ETH) | Lido | v3 wstETH 0.01% | v4 ETH/wstETH 0.01% | v3 stETH 1% |
  |---|---|---|---|---|
  | 1 | 0.999999999999999999 | 1.000162980 | 1.000128923 | 0.998744052 |
  | 10 | ~10 | 10.001616759 | 9.980497292 | 9.969914637 |
  | 50 | 49.999999999999999999 | 50.007793858 | 12.445663416 (exhausted) | 24.904535302 (exhausted) |
  | 74 | ~74 | 74.011277450 | 12.445669632 | 24.904535449 |

  v3 wstETH quote beats Lido by ~1.6 bps at 50 ETH today (re-quoted block 26345235: 50.007793620
  stETH-equivalent), below the 10 bps slippage floor, so A6 picks Lido. Extra gas (~120k) at
  0.037 gwei ~ 5e-6 ETH. Recorded assumption: best Uniswap liquidity for WETH->stETH is this pool.
- Alternatives: v4 ETH/wstETH (thinner; v4 hooked pools not probed); UniversalRouter (bytes
  commands, harder to read in the Safe UI); Curve stETH/ETH (not Uniswap, not probed).

A6. `ROUTE=auto`: Uniswap iff `stMint > amt - 2` (strict; `stMint` = Uniswap post-slippage floor
minted into esETH, `amt - 2` = Lido mint) or Lido paused or `amt > getCurrentStakeLimit()`; else Lido.
Gas ignored. `ROUTE=lido|uniswap` forces. Raw quote, `stMint`, Lido mint and the choice are logged.
- Reason: user rule (Lido unless Uniswap yields strictly more after fees). The batch has fixed calldata,
  so esETH receives exactly `stMint` on the Uniswap route, never the quote; the quote-minus-floor
  remainder is stranded as wstETH in the Safe. Rev 3 compared the raw quote: at 50 ETH today
  (quote +1.56 bps over Lido, `SLIPPAGE_BPS=10`) it picked Uniswap and minted ~8.4 bps less stETH into
  esETH than Lido. Today this rule picks Lido.
- Alternative: compare the raw quote (rev 3) — picks Uniswap on a sub-slippage edge and moves less
  stETH into esETH.

A7. Uniswap amounts are static: unwrap `minWst`, mint `getStETHByWstETH(minWst) - 2`; surplus wstETH
stays in the Safe. `SLIPPAGE_BPS` default 10, max 100.
- Reason: Safe batches carry fixed calldata; exact-input with a floor is the simplest fail-closed form.
  Surplus is not lost (Safe is treasury).
  With A6, Uniswap is auto-picked only when `stMint` already beats Lido, so esETH never gets less
  than the Lido route would give; surplus wstETH accrues in the Safe (logged, not redeposited).
- Alternatives: `exactOutputSingle` (surplus left as WETH instead); a helper contract for dynamic
  amounts (deploy + audit surface).

A8. No swap deadline.
- Reason: `minWst` bounds price; a stale batch executes at >= floor or reverts.
- Alternative: wrap the swap in SwapRouter02 `multicall(uint256 deadline, bytes[])` with a
  `DEADLINE_HOURS` param.

A9. Lido: `submit(address(0))` (no referral); mint `amt - 2`; assert stETH received `>= amt - 2`
(shares-based, see the simulation asserts).
- Reason: share rounding loses at most 1-2 wei (measured: 1 wei at 50 ETH; fork: esETH balance
  +amt-3, Safe +2 shares). Without the assert a short `submit` is masked by the Safe's stETH stock.
- Alternative: referral = Safe (no effect on amounts).

A10. Sequence number 009 (`008-add-tripwire-operator` exists on main; no `009-*` on origin/main or any
remote branch, checked 2026-11-05); outputs in subdir
`steth/` of `multisig/009-eseth-weth-rebalance/`.
- Reason: one operation; the `steth/` subdir keeps the index scan per script.
- Alternative: no subdir.

A11. Nonce: script reads and logs `Safe.nonce()`; writes no `hashes` block; `hash-batch.mjs --write`
records it (unchanged from rev 2 A7).
- Reason: a partial `hashes` block fails `diffHashes`. On-chain nonce excludes the Safe queue; use
  `--nonce` if the queue is non-empty.
- Alternative: script writes a full `hashes` block itself (~25 lines, couples to protocol-kit).

A12. Decoded lib: reject `"`/`\` in strings instead of escaping; raw-data fallback for the
`exactInputSingle` tx (tuple arg) instead of adding tuple support.
- Reason: all strings are script-authored constants or `vm.toString` output; tuple support in
  `verify` and the writer is ~30 lines for one tx. The swap's params are logged on the console.
- Alternatives: JSON escaping helper; tuple support so the swap is decoded in the Safe UI.

A13. Shared abstract base contract `RebalanceBase` (kept after Script 1 was dropped).
- Reason: caps, nonce, simulation and writes are already factored and tested there.
- Alternative: inline into `WethToStEth`.

A14. QuoterV2 is called on the fork from the script (state-changing ABI, revert-based quote).
- Reason: on-chain quote at build time, as required; no broadcast, so no cost.
- Alternative: `slot0`/tick math in Solidity — more code, ignores tick crossings.

## Out of scope

- esETH contract changes (native ETH backing).
- Curve, aggregators, Chainlink feeds.
- "Pull all" mode, fractional AMOUNT.
- Reading the Safe Transaction Service queue from Solidity.
- `foundry.toml` changes.
