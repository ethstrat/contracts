# esETH WETH Rebalance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One fortnightly Foundry script that builds one Safe batch for the unencumbered Safe: `WethToStEth` (redeem WETH, convert to stETH by Lido `submit` or Uniswap, whichever mints more into esETH, mint the stETH back).

**Architecture:** Abstract `RebalanceBase.s.sol` holds env parsing (`AMOUNT` whole ETH), shared pre-checks, Safe nonce log, Safe simulation through the real `execTransaction` + MultiSendCallOnly, first-free-index scan, and writes of a raw propose JSON (`SafeBatchLib.write` values overload) and a decoded tx-builder JSON (`SafeBatchDecodedLib.write`). `WethToStEth.s.sol` implements `buildAndSimulate` (txs + script-specific asserts) and a `run()` that writes. Hashing/proposing stay in `script/safe/*.mjs`. Nothing broadcasts.

**Tech Stack:** Solidity 0.8.24, Foundry (forge script / forge test, via-ir), forge-std, Safe v1.4.1, WETH9, Lido stETH/wstETH, Uniswap v3 SwapRouter02 + QuoterV2.

**Spec:** `docs/superpowers/specs/eseth-weth-rebalance-design.md` (rev 5). The earlier Script 1 (`RedepositEth`, redeem -> unwrap -> `wrapAndMint`) was dropped: esETH cannot hold native ETH (no receive/fallback; `wrapAndMint` re-wraps to WETH), so it was an economic no-op.

## Global Constraints

- Safe: `ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.unencumbered")` (= `0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1`). esETH: `ConfigLib.addr("deploymentAddresses.json", ".esETH")`. WETH: `externalAddresses.json` `.WETH`. stETH / wstETH: `.lido.stETH` / `.lido.wstETH`. New in `externalAddresses.json`: `.safe.multiSendCallOnly` = `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`, `.uniswap-v3.swapRouter02` = `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`, `.uniswap-v3.quoterV2` = `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`. No hardcoded addresses in scripts.
- Sequence number `009` (`008-add-tripwire-operator` exists on main; no `009-*` on origin/main or any remote branch, re-checked 2026-11-05). Scripts: `script/deployments/1/009-eseth-weth-rebalance/{RebalanceBase,WethToStEth}.s.sol`. Operation string: `"009-eseth-weth-rebalance/steth"`. Outputs: `script/deployments/1/multisig/009-eseth-weth-rebalance/steth/NNN-0xF89f49e2-multisig.json` (raw) and `NNN-0xF89f49e2-multisig.tx-builder.json` (decoded).
- `AMOUNT` = `vm.envUint("AMOUNT")`, whole ETH integer, required, no default. `amt = AMOUNT * 1 ether`. `AMOUNT == 0` reverts. Log both `AMOUNT` (ETH) and `amt` (wei).
- Script env: `ROUTE` = `vm.envOr("ROUTE", string("auto"))`, one of `auto|lido|uniswap`; `SLIPPAGE_BPS` = `vm.envOr("SLIPPAGE_BPS", uint256(10))`, max 100.
- Uniswap route: v3 WETH/wstETH fee 100 (pool `0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa`), SwapRouter02 `exactInputSingle`, then `wstETH.unwrap`. Recorded assumption (spec A5): best Uniswap liquidity for WETH->stETH is this pool. Re-checked block 26345256: QuoterV2 50 WETH -> 40.0568 wstETH; Lido not paused, stake limit 150000 ETH.
- Route rule (spec A6): `auto` picks Uniswap iff `stMintUni > amt - 2` (strict) or Lido unavailable (`isStakingPaused()` or `amt > getCurrentStakeLimit()`); else Lido. Gas ignored.
- No `vm.broadcast` anywhere. Scripts write no `hashes` block (`hash-batch.mjs --write` does).
- Do not modify: `script/lib/SafeBatchLib.sol`, `script/DesEthEsEthCycle.s.sol`, `SafeBatchLib.Tx`, `SafeBatchLib.execute`, `foundry.toml`, `src/`.
- 6-arg `SafeBatchLib.write` output stays byte-identical (pinned by `test_SafeBatchLib_write_sixArgBytesUnchanged`).
- Revert prefixes: `Rebalance: ` (shared pre-checks), `Rebalance sim: ` (shared sim asserts), `WethToStEth: `, `WethToStEth sim: `.
- Commits: conventional-commit subject; the only trailer is `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. No `Claude-Session:` trailer, session ID or claude.ai URL. After each commit run `git log -1 --format=%B`; if violated, `git commit --amend` before the next step.
- Never `git push`. Never read `.env` or other secret files (commands that load `.env` internally, e.g. `yarn safe:hash`, are fine).
- Unit tests: `forge test --match-contract ScriptLibsTest -vv`. Fork tests: `yarn test:integration --match-contract <Name> -vv` (wraps `FOUNDRY_PROFILE=integration forge test --fork-url ${FORK_URL:-...}`). CI gate before every script-task commit: `yarn lint && yarn test`.
- Fork test block: `FORK_BLOCK = 26345235` (`vm.rollFork` in `setUp`, `require(block.chainid == 1)`).

## Review Focus

1. `AMOUNT` passed in wei by mistake (`50000000000000000000`): expect the named cap revert `Rebalance: AMOUNT > WETH.balanceOf(esETH)`, no panic, nothing written. Pinned by `testFork_weiPassedByMistake_reverts` (ported from Script 1's suite).
2. `AMOUNT=50` (value > 2^64 wei): a value packed through a narrower type still executes (spec negative control). Expect tx value == `50 ether` and Safe ETH/WETH unchanged. Pinned by `testFork_lido_fifty_passes` (Task 6).
3. Safe threshold raised above 1: expect the simulation still runs (slot 4 overwritten on the fork). Pinned by `testFork_thresholdAboveOne_passes` (ported from Script 1's suite).
4. A previous fortnight's batch file already at `001`: expect the next run to write `002`, never overwrite. Pinned by `test_firstFreeIndex_skipsExisting` (ported from Script 1's suite).
5. Lido paused or stake limit < `amt`: `ROUTE=lido` expects the named revert; `ROUTE=auto` expects Uniswap, not a revert. Pinned by `testFork_lidoPaused_forcedLido_reverts`, `testFork_lidoPaused_auto_picksUniswap`, `testFork_stakeLimit_auto_picksUniswap` (Task 7).

---

### Task 1: `SafeBatchLib.write` overload with per-tx values (DONE, 4d2bc563)

**Files:** `script/deployments/1/lib/SafeBatchLib.sol`, `test/unit/ScriptLibsTest.sol`

**Interfaces:**
- Produces: `SafeBatchLib.write(address safe, string memory operation, uint256 index, string memory name, string memory description, Tx[] memory txs, uint256[] memory values) internal` — `"value":"<values[i]>"` per tx; reverts `"SafeBatchLib: values length != txs length"`. 6-arg `write` delegates with zero values. `SafeBatchLib.path(safe, operation, index)`.

- [x] **Step 1: Write the failing tests** `test_SafeBatchLib_writeWithValues_emitsValue`, `test_SafeBatchLib_write_sixArgBytesUnchanged`
- [x] **Step 2: Run test to verify it fails**
- [x] **Step 3: Implement the overload**
- [x] **Step 4: Run all ScriptLibsTest tests to verify they pass**
- [x] **Step 5: Build everything**
- [x] **Step 6: Commit**

---

### Task 2: Decoded tx-builder writer with per-tx value (DONE, 6977cfaf)

**Files:** `script/deployments/1/lib/SafeBatchDecodedLib.sol`, `test/unit/ScriptLibsTest.sol`

**Interfaces:**
- Produces: `struct Input { string name; string typ; string internalTyp; string value; }`, `struct Tx { address to; uint256 value; bytes data; string method; Input[] inputs; }`, `verify(Tx memory t, uint256 index) internal pure`, `write(string memory filePath, address safe, string memory name, string memory description, Tx[] memory txs) internal` (`payable` = `value > 0`).

- [x] **Step 1: Write the failing test** `test_SafeBatchDecodedLib_write_valueAndPayable`
- [x] **Step 2: Run test to verify it fails**
- [x] **Step 3: Create `SafeBatchDecodedLib.sol`**
- [x] **Step 4: Run test to verify it passes**
- [x] **Step 5: Commit**

---

### Task 3: Library fix-ups from review (verify in write, string guard, raw-data fallback, tests)

**Files:**
- Modify: `script/deployments/1/lib/SafeBatchDecodedLib.sol`
- Modify: `script/deployments/1/lib/SafeBatchLib.sol` (NatSpec only, line 9)
- Test: `test/unit/ScriptLibsTest.sol`

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces (signatures unchanged):
  - `SafeBatchDecodedLib.write` now, before building any string, in this order: (1) reverts `"SafeBatchDecodedLib: quote or backslash in string"` if any of `name`, `description`, each `method`, each input `name`/`typ`/`internalTyp`/`value` contains `"` or `\` (guard first: `verify` would otherwise fail inside `vm.parseUint` with a cheatcode error); (2) for each tx with `bytes(method).length > 0`, `verify(txs[i], i)`. Nothing written on revert.
  - Raw-data fallback: a `Tx` with empty `method` is written as `{"to":..,"value":"<v>","data":"0x<data>","contractMethod":null,"contractInputsValues":null}` (`verify` skipped; `inputs` ignored). Used for the `exactInputSingle` tuple tx (spec A12).
  - NatSpec in both libs: replace `008-eseth-weth-rebalance/ProposeRebalance.s.sol` with `009-eseth-weth-rebalance (WethToStEth)`.

- [x] **Step 1: Write the failing tests** in `test/unit/ScriptLibsTest.sol`

Library `internal` functions revert inside the test frame, so add two external wrappers to the test contract and call them via `this.`:

```solidity
function writeDecodedExt(string memory p, string memory name, SafeBatchDecodedLib.Tx[] memory txs) external {
    SafeBatchDecodedLib.write(p, address(0x1111111111111111111111111111111111111111), name, "d", txs);
}
function writeRawExt(SafeBatchLib.Tx[] memory txs, uint256[] memory values) external {
    SafeBatchLib.write(address(0x1111111111111111111111111111111111111111), "999-test-fixture-len", 1, "n", "d", txs, values);
}
```

Tests (decoded output path `./tmp/<test-name>.tx-builder.json`, removed at end when written):

| test | input | assertion |
|---|---|---|
| `test_SafeBatchDecodedLib_verify_mismatchReverts` | `Tx(address(0xA), 0, abi.encodeWithSignature("withdraw(uint256)", 2), "withdraw", [Input("wad","uint256","uint256","1")])` | `vm.expectRevert(bytes("SafeBatchDecodedLib.verify: decoded descriptor mismatch for tx 0 (withdraw)"))` on `this.writeDecodedExt(p, "n", txs)`; then `assertFalse(vm.exists(p))` |
| `test_SafeBatchDecodedLib_uint256Input_roundTrips` | same tx with `"wad"="2"`, data encodes `2` | write succeeds; `parseJsonString(json, ".transactions[0].contractInputsValues.wad") == "2"`; `.contractMethod.inputs[0].type == "uint256"` |
| `test_SafeBatchLib_write_valuesLengthReverts` | 2 txs, `new uint256[](1)` | `vm.expectRevert(bytes("SafeBatchLib: values length != txs length"))` on `this.writeRawExt` |
| `test_SafeBatchDecodedLib_quoteGuardReverts` | valid `withdraw` tx, name `"a\"b"`; second case: valid tx, name `"n"`, input value `"1\\"` | both `vm.expectRevert(bytes("SafeBatchDecodedLib: quote or backslash in string"))`; `assertFalse(vm.exists(p))` |
| `test_SafeBatchDecodedLib_rawFallback_writesData` | `Tx(address(0xC), 0, hex"04e45aaf01", "", new Input[](0))` | `parseJsonBytes(json, ".transactions[0].data") == hex"04e45aaf01"`; `vm.contains(json, "\"contractMethod\":null,\"contractInputsValues\":null")` |

- [x] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract ScriptLibsTest -vv`
Expected: `verify_mismatchReverts`, `quoteGuardReverts`, `rawFallback_writesData` FAIL; `uint256Input_roundTrips`, `valuesLengthReverts` may already PASS (they pin existing behavior).

- [x] **Step 3: Implement** the write-time `verify` loop, the guard (one private `_assertSafe(string memory s)` scanning bytes for `0x22`/`0x5c`), and the raw-data fallback branch in `SafeBatchDecodedLib.write`; update both NatSpec comments.

- [x] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract ScriptLibsTest -vv`
Expected: all PASS, including `test_SafeBatchDecodedLib_write_valueAndPayable` and `test_SafeBatchLib_write_sixArgBytesUnchanged` unchanged.

- [x] **Step 5: Lint and unit suite**

Run: `yarn lint && yarn test`
Expected: `forge fmt --check` clean; all unit tests PASS.

- [x] **Step 6: Commit**

```bash
git add script/deployments/1/lib/SafeBatchDecodedLib.sol script/deployments/1/lib/SafeBatchLib.sol test/unit/ScriptLibsTest.sol
git commit -m "fix(script): verify decoded txs on write, guard JSON strings, raw-data fallback" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git log -1 --format=%B
```

---

### Task 4: `RebalanceBase` (DONE)

> Script 1 (`RedepositEth`, a redeem -> withdraw -> wrapAndMint no-op) was built, then dropped: esETH cannot hold native ETH, so the ETH is re-wrapped to WETH and nothing changes. Its former Task 4/5 content is removed; only the shared base remains.

**Files:**
- Modify: `script/deployments/1/config/externalAddresses.json` — add `"safe": {"multiSendCallOnly": ...}` only (value in Global Constraints; `uniswap-v3` entries land in Task 7, where they are first used)
- Create: `script/deployments/1/009-eseth-weth-rebalance/RebalanceBase.s.sol`

**Interfaces:**
- Consumes: `SafeBatchDecodedLib.Tx/Input/verify` (Tasks 2-3), `ConfigLib.addr`, `esETH` from `src/esETH.sol` (`tokenConfigs(t)` returns `(TokenType tokenType, bool isMintable, bool isRedeemable, uint256 totalMinted)`).
- Produces in `RebalanceBase.s.sol`:
  - `abstract contract RebalanceBase is Script`
  - address getters `safe()`, `eseth()`, `weth()`, `multiSendCallOnly()` — `internal view returns (address)`, each one `ConfigLib.addr` call. Script-only getters live in `WethToStEth.s.sol` (Tasks 6-7).
  - `function _amountWei(uint256 amountEth) internal returns (uint256 amt)` — require `amountEth > 0` (`Rebalance: AMOUNT must be > 0`), `amt = amountEth * 1 ether`, logs `AMOUNT (ETH)` and `amt (wei)`.
  - `function _checkCommon(uint256 amt) internal view` — pre-checks below, in this order.
  - `function _logNonce() internal view` — logs `ISafe(safe()).nonce()` (latest when run with `--fork-url` and no block).
  - `function _simulate(SafeBatchDecodedLib.Tx[] memory txs) internal` — records `WETH.balanceOf(safe)` and `safe.balance`, packs, overrides threshold, executes, asserts both unchanged. Packing and call:

```solidity
bytes memory packed;
for (uint256 i = 0; i < txs.length; i++) {
    // uint256 value, never a narrower type: a truncated value still executes (spec rev 4 negative control)
    packed = abi.encodePacked(packed, uint8(0), txs[i].to, txs[i].value, txs[i].data.length, txs[i].data);
}
ISafe s = ISafe(safe());
address ms = multiSendCallOnly(); // resolve before vm.prank: only the execTransaction call may carry the prank
if (s.getThreshold() > 1) vm.store(address(s), bytes32(uint256(4)), bytes32(uint256(1))); // fork-only
address owner = s.getOwners()[0];
bytes memory sig = abi.encodePacked(uint256(uint160(owner)), bytes32(0), uint8(1));
bytes memory msData = abi.encodeWithSignature("multiSend(bytes)", packed);
vm.prank(owner);
bool ok = s.execTransaction(ms, 0, msData, 1, 0, 0, 0, address(0), payable(address(0)), sig);
require(ok, "Rebalance sim: execTransaction returned false");
```
  Post: `Rebalance sim: WETH stranded in Safe`, `Rebalance sim: ETH stranded in Safe`. Not `SafeBatchLib.execute`: `WETH.withdraw` reverts under `vm.prank(SAFE)` (spec, Fork verification).
  - File-local interfaces in `RebalanceBase.s.sol`: `ISafe { nonce(); getOwners(); getThreshold(); execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes) payable returns (bool) }`, `IWETH9 { withdraw(uint256); approve(address,uint256) returns (bool) }`.
  - Helper `function _in(string memory name, string memory typ, string memory value) internal pure returns (SafeBatchDecodedLib.Input memory)` (`internalTyp = typ`).
**Shared pre-checks** (`_checkCommon`, this order):

| # | condition | reason |
|---|---|---|
| 1 | `esETH.treasuryManager() == safe` | `Rebalance: esETH.treasuryManager() != Safe` |
| 2 | `esETH.isMinter(safe)` | `Rebalance: Safe is not an esETH minter` |
| 3 | `tokenConfigs(WETH).tokenType == ERC20` | `Rebalance: WETH tokenType != ERC20` |
| 4 | `amt <= WETH.balanceOf(esETH)` | `Rebalance: AMOUNT > WETH.balanceOf(esETH)` |
| 5 | `amt <= tokenConfigs(WETH).totalMinted` | `Rebalance: AMOUNT > esETH WETH totalMinted` |
| 6 | `amt + 1 <= esETH.balanceOf(safe)` | `Rebalance: AMOUNT + 1 > esETH.balanceOf(Safe)` |

---

### Task 6: the script — `WethToStEth` Lido route (fork-tested)

**Files:**
- Create: `script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol`
- Test: `test/integration/WethToStEthForkTest.sol`

**Interfaces:**
- Consumes: `RebalanceBase` (Tasks 4-5).
- Produces:
  - `contract WethToStEth is RebalanceBase`, `string internal constant OPERATION = "009-eseth-weth-rebalance/steth";`, `enum Route { Auto, Lido, Uniswap }`
  - getter `steth()` (`ConfigLib.addr("externalAddresses.json", ".lido.stETH")`), `internal view`, in this contract (not the base).
  - `function _parseRoute(string memory s) internal pure returns (Route)` — `"auto"|"lido"|"uniswap"|"compare"`, else revert `WethToStEth: ROUTE must be auto|lido|uniswap|compare`.
  - `function buildAndSimulate(uint256 amountEth, Route route, uint256 slippageBps) internal returns (SafeBatchDecodedLib.Tx[] memory txs, Route chosen)` — `_amountWei`, `require(slippageBps <= 100, "WethToStEth: SLIPPAGE_BPS > 100")`, `_checkCommon`, `require(tokenConfigs(stETH).tokenType == ERC20, "WethToStEth: stETH tokenType != ERC20")`, `_logNonce`. In this task: `Auto` and `Lido` both resolve to Lido (Task 7 adds Uniswap); `Uniswap` reverts `WethToStEth: uniswap route not implemented` (removed in Task 7). Lido requires: `!isStakingPaused()` (`WethToStEth: Lido staking paused`), `amt <= getCurrentStakeLimit()` (`WethToStEth: AMOUNT > Lido stake limit`). Logs Lido mint `amt - 2` and the chosen route.
  - `function _lidoTxs(uint256 amt) internal view returns (SafeBatchDecodedLib.Tx[] memory)`; `stMint = amt - 2`.
  - `function _assertConverted(uint256 amt, uint256 stMint, Before memory b) internal view` — shared sim asserts below; `struct Before` holds the pre-values.
  - File-local `ILido { submit(address) payable returns (uint256); isStakingPaused() view returns (bool); getCurrentStakeLimit() view returns (uint256); sharesOf(address) view returns (uint256); getPooledEthByShares(uint256) view returns (uint256); approve(address,uint256) returns (bool) }`.
  - `run()` stub: `buildAndSimulate(vm.envUint("AMOUNT"), _parseRoute(vm.envOr("ROUTE", string("auto"))), vm.envOr("SLIPPAGE_BPS", uint256(10)));` (Task 8 adds the write).

**Lido batch:**

| # | to | value | method | inputs |
|---|---|---|---|---|
| 0 | esETH | 0 | `redeem` | `token:address`=WETH, `tokenAmount:uint256`=amt, `receiver:address`=safe |
| 1 | WETH | 0 | `withdraw` | `wad:uint256`=amt |
| 2 | stETH | amt | `submit` | `_referral:address`=address(0) |
| 3 | stETH | 0 | `approve` | `_spender:address`=esETH, `_amount:uint256`=stMint |
| 4 | esETH | 0 | `mint` | `token:address`=stETH, `tokenAmount:uint256`=stMint, `receiver:address`=safe |

**Shared the script sim asserts** (`_assertConverted`):

| assert | reason |
|---|---|
| `wethEsEthAfter + amt == wethEsEthBefore` | `WethToStEth sim: esETH WETH delta != amt` |
| `stEthEsEthAfter + 2 >= stEthEsEthBefore + stMint` | `WethToStEth sim: esETH stETH delta < stMint - 2` |
| `stEthMintedAfter == stEthMintedBefore + stMint` | `WethToStEth sim: stETH totalMinted delta != stMint` |
| `supplyAfter + amt + 1 == supplyBefore + stMint` | `WethToStEth sim: esETH supply delta` |
| `safeEsEthAfter + amt + 1 == safeEsEthBefore + stMint` | `WethToStEth sim: Safe esETH delta` |
| `stETH.balanceOf(safe)` after `>=` before | `WethToStEth sim: mint drew on Safe stETH stock` |

Lido-only: `getPooledEthByShares((sharesOf(safe) + sharesOf(esETH))_after - _before) >= amt - 2` → `WethToStEth sim: Lido stETH received < amt - 2`.

- [x] **Step 1: Write the failing fork test** `test/integration/WethToStEthForkTest.sol` with harness `exposed_buildAndSimulate(uint256, WethToStEth.Route, uint256) returns (SafeBatchDecodedLib.Tx[] memory, WethToStEth.Route)` and `exposed_parseRoute(string)`.

```solidity
function testFork_lido_fifty_passes() public {
    (SafeBatchDecodedLib.Tx[] memory txs, WethToStEth.Route chosen) =
        harness.exposed_buildAndSimulate(50, WethToStEth.Route.Lido, 10);
    assertEq(uint8(chosen), uint8(WethToStEth.Route.Lido));
    assertEq(txs.length, 5);
    assertEq(txs[2].value, 50 ether);
}
function testFork_auto_defaultSlippage_picksLido() public {
    (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(50, WethToStEth.Route.Auto, 10);
    assertEq(uint8(chosen), uint8(WethToStEth.Route.Lido));
}
```

| test | setup | call | reason |
|---|---|---|---|
| `testFork_zero_reverts` | none | `(0, Lido, 10)` | `Rebalance: AMOUNT must be > 0` |
| `testFork_slippageAbove100_reverts` | none | `(1, Lido, 101)` | `WethToStEth: SLIPPAGE_BPS > 100` |
| `testFork_lidoPaused_forcedLido_reverts` | `vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true))` | `(1, Lido, 10)` | `WethToStEth: Lido staking paused` |
| `testFork_stakeLimit_forcedLido_reverts` | `vm.mockCall(STETH, abi.encodeWithSignature("getCurrentStakeLimit()"), abi.encode(uint256(0.5 ether)))` | `(1, Lido, 10)` | `WethToStEth: AMOUNT > Lido stake limit` |
| `test_parseRoute_unknownReverts` | none | `exposed_parseRoute("curve")` | `WethToStEth: ROUTE must be auto|lido|uniswap|compare` |

- [x] **Step 2: Run to verify it fails**

Run: `yarn test:integration --match-contract WethToStEthForkTest -vv`
Expected: compile error, `WethToStEth.s.sol` not found.

- [x] **Step 3: Create `WethToStEth.s.sol`** per Interfaces and tables. NatSpec header as Task 4, plus the route rule (spec A6) and "esETH receives exactly `stMint`; Lido rounding leaves 1 wei under-backed per run, left to `burnExcess`".

- [x] **Step 4: Run to verify it passes**

Run: `yarn test:integration --match-contract WethToStEthForkTest -vv`
Expected: 7 tests PASS.

- [x] **Step 5: Format, lint, unit suite**

Run: `forge fmt script/deployments/1/009-eseth-weth-rebalance test/integration/WethToStEthForkTest.sol && yarn lint && yarn test`
Expected: clean; all PASS.

- [x] **Step 6: Commit**

```bash
git add script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol test/integration/WethToStEthForkTest.sol
git commit -m "feat(script): add esETH WETH->stETH batch builder, Lido route" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git log -1 --format=%B
```

---

### Task 7: the script — Uniswap route and `auto` selection (fork-tested)

**Files:**
- Modify: `script/deployments/1/config/externalAddresses.json` — add `"uniswap-v3": {"swapRouter02": ..., "quoterV2": ...}` (values in Global Constraints)
- Modify: `script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol`
- Test: `test/integration/WethToStEthForkTest.sol`

**Interfaces:**
- Consumes: Task 6.
- Produces:
  - getters `wsteth()` (`.lido.wstETH`), `swapRouter02()` (`.uniswap-v3.swapRouter02`), `quoterV2()` (`.uniswap-v3.quoterV2`), `internal view`, in `WethToStEth`.
  - File-local `IQuoterV2.quoteExactInputSingle(QuoteExactInputSingleParams{address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;}) returns (uint256 amountOut, uint160, uint32, uint256)`; `ISwapRouter02.exactInputSingle(ExactInputSingleParams{address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;}) payable returns (uint256)` (selector `0x04e45aaf`); `IWstETH { unwrap(uint256) returns (uint256); getStETHByWstETH(uint256) view returns (uint256) }`.
  - `function _quoteUni(uint256 amt, uint256 slippageBps) internal returns (uint256 quoteWst, uint256 minWst, uint256 stMintUni)` — `quoteWst` from QuoterV2 (WETH -> wstETH, fee 100) on the fork; `minWst = quoteWst * (10000 - slippageBps) / 10000`; `stMintUni = getStETHByWstETH(minWst) - 2` (0 if `getStETHByWstETH(minWst) < 2`). Logs all three.
  - `function _uniTxs(uint256 amt, uint256 minWst, uint256 stMint) internal view returns (SafeBatchDecodedLib.Tx[] memory)`.
  - Route resolution in `buildAndSimulate`: `_quoteUni` runs for `Auto` and `Uniswap` (not forced `Lido`). `lidoOk = !isStakingPaused() && amt <= getCurrentStakeLimit()`. `Auto` -> `Uniswap` iff `stMintUni > amt - 2 || !lidoOk`, else `Lido`. Forced `Lido` keeps the Task 6 reverts. Uniswap (forced or chosen) requires, in this order, `minWst > 0` (`WethToStEth: Uniswap minWst == 0`) then `stMintUni > 0` (`WethToStEth: Uniswap stMint == 0`). Remove the Task 6 "not implemented" revert. Log Lido mint, `stMintUni`, choice.

**Uniswap batch** (tx 2 uses the raw-data fallback: `method = ""`, tuple arg):

| # | to | value | method | inputs |
|---|---|---|---|---|
| 0 | esETH | 0 | `redeem` | `token:address`=WETH, `tokenAmount:uint256`=amt, `receiver:address`=safe |
| 1 | WETH | 0 | `approve` | `guy:address`=SwapRouter02, `wad:uint256`=amt |
| 2 | SwapRouter02 | 0 | `""` (raw) | `exactInputSingle((WETH, wstETH, 100, safe, amt, minWst, 0))` |
| 3 | wstETH | 0 | `unwrap` | `_wstETHAmount:uint256`=minWst |
| 4 | stETH | 0 | `approve` | `_spender:address`=esETH, `_amount:uint256`=stMint |
| 5 | esETH | 0 | `mint` | `token:address`=stETH, `tokenAmount:uint256`=stMint, `receiver:address`=safe |

Uniswap-only sim asserts: `WETH.allowance(safe, swapRouter02) == 0` (`WethToStEth sim: router allowance left`); Safe wstETH after `>=` before (`WethToStEth sim: Safe wstETH fell`). Shared `_assertConverted` with `stMint = stMintUni`.

- [x] **Step 1: Write the failing tests** in `test/integration/WethToStEthForkTest.sol`

```solidity
function testFork_uniswap_one_passes() public {
    (SafeBatchDecodedLib.Tx[] memory txs, WethToStEth.Route chosen) =
        harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
    assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
    assertEq(txs.length, 6);
    assertEq(bytes4(txs[2].data), bytes4(0x04e45aaf));
    for (uint256 i; i < 6; i++) assertEq(txs[i].value, 0);
}
function testFork_auto_zeroSlippage_picksUniswap() public { // fork block quote beats Lido by ~1.56 bps
    (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(50, WethToStEth.Route.Auto, 0);
    assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
}
function testFork_lidoPaused_auto_picksUniswap() public {
    vm.mockCall(STETH, abi.encodeWithSignature("isStakingPaused()"), abi.encode(true));
    (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(1, WethToStEth.Route.Auto, 10);
    assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
}
function testFork_stakeLimit_auto_picksUniswap() public {
    vm.mockCall(STETH, abi.encodeWithSignature("getCurrentStakeLimit()"), abi.encode(uint256(0.5 ether)));
    (, WethToStEth.Route chosen) = harness.exposed_buildAndSimulate(1, WethToStEth.Route.Auto, 10);
    assertEq(uint8(chosen), uint8(WethToStEth.Route.Uniswap));
}
function testFork_uniswap_zeroQuote_reverts() public { // QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
    vm.mockCall(
        QUOTER,
        abi.encodePacked(bytes4(keccak256("quoteExactInputSingle((address,address,uint256,uint24,uint160))"))),
        abi.encode(uint256(0), uint160(0), uint32(0), uint256(0))
    );
    vm.expectRevert(bytes("WethToStEth: Uniswap minWst == 0"));
    harness.exposed_buildAndSimulate(1, WethToStEth.Route.Uniswap, 10);
}
```

`testFork_auto_defaultSlippage_picksLido` (Task 6) must still pass.

- [x] **Step 2: Run to verify they fail**

Run: `yarn test:integration --match-contract WethToStEthForkTest -vv`
Expected: the 5 new tests FAIL (`WethToStEth: uniswap route not implemented`, `Lido staking paused`, `AMOUNT > Lido stake limit`, or wrong route); Task 6 tests PASS.

- [x] **Step 3: Add the `uniswap-v3` entries to `externalAddresses.json`; implement the getters, `_quoteUni`, `_uniTxs`, route resolution, Uniswap asserts** per Interfaces.

- [x] **Step 4: Run to verify they pass**

Run: `yarn test:integration --match-contract WethToStEthForkTest -vv`
Expected: 12 tests PASS.

- [x] **Step 5: Format, lint, unit suite**

Run: `forge fmt script/deployments/1/009-eseth-weth-rebalance test/integration/WethToStEthForkTest.sol && yarn lint && yarn test`
Expected: clean; all PASS.

- [x] **Step 6: Commit**

```bash
git add script/deployments/1/config/externalAddresses.json script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol test/integration/WethToStEthForkTest.sol
git commit -m "feat(script): add Uniswap v3 wstETH route and auto route selection" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git log -1 --format=%B
```

---

### Task 8: the script — write both files, dry-run both routes

**Files:**
- Modify: `script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol`

**Interfaces:**
- Consumes: `_write` (`RebalanceBase`), `buildAndSimulate` (Tasks 6-7).
- Produces: `run()` — parse env, `(txs, chosen) = buildAndSimulate(...)`, `_write(OPERATION, "esETH WETH -> stETH rebalance", string.concat("Redeems ", vm.toString(amountEth), " ETH of WETH from esETH, converts to stETH via ", chosen == Route.Lido ? "Lido submit" : "Uniswap v3 WETH/wstETH 0.01% + unwrap", ", mints the stETH into esETH."), txs)`.

- [x] **Step 1: Implement `run()`** per Interfaces.

- [x] **Step 2: Dry-run, auto route**

Run: `AMOUNT=1 forge script script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol --fork-url https://ethereum-rpc.publicnode.com`
Expected: `Script ran successfully`; logs `AMOUNT` 1, `amt` wei, nonce, Uniswap quote / `minWst` / `stMintUni`, Lido mint `999999999999999998`, chosen route consistent with the logged values (Uniswap iff `stMintUni > 999999999999999998`; latest block, so not pinned), index `1`, paths under `multisig/009-eseth-weth-rebalance/steth/`.

- [x] **Step 3: Dry-run, forced Uniswap**

Run: `AMOUNT=1 ROUTE=uniswap forge script script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol --fork-url https://ethereum-rpc.publicnode.com`
Expected: success; index `2`; decoded file tx 2 has `"data":"0x04e45aaf..."` and `contractMethod: null`.

- [x] **Step 4: Check the hash tooling on all four files (prints only)**

Run: `for f in script/deployments/1/multisig/009-eseth-weth-rebalance/steth/00{1,2}-0xF89f49e2-multisig{,.tx-builder}.json; do yarn safe:hash "$f" || exit 1; done`
Expected: all exit 0; MultiSend to `0x9641d764fc13c8B624c04430C7356C1C7C8102e2`; `safeTxHash` of `001` raw == `001` decoded, `002` raw == `002` decoded.

- [x] **Step 5: Delete the dry-run output**

Run: `rm -r script/deployments/1/multisig/009-eseth-weth-rebalance && git status --short`
Expected: nothing under `script/deployments/1/multisig/`.

- [x] **Step 6: Full regression**

Run: `forge fmt script/deployments/1/009-eseth-weth-rebalance && yarn test:integration --match-contract WethToStEthForkTest -vv && yarn lint && yarn test`
Expected: all `WethToStEthForkTest` tests PASS; `forge fmt --check` clean; all unit tests PASS.

- [x] **Step 7: Commit**

```bash
git add script/deployments/1/009-eseth-weth-rebalance/WethToStEth.s.sol
git commit -m "feat(script): write raw and decoded stETH rebalance batches at first free index" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git log -1 --format=%B
```
