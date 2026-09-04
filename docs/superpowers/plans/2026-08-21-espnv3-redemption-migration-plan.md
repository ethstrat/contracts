# ESPNv3 — Implementation Plan

- **Date:** 2026-08-21
- **Branch:** `espn-redemption`
- **Design spec:** [`docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md`](../specs/2026-08-21-espnv3-redemption-migration-design.md)
- **Chain:** Ethereum mainnet (chain id 1)
- **Toolchain:** Foundry + forge-std only. OpenZeppelin vendored at `lib/openzeppelin-contracts`. **No `stoke`** (private repo, unavailable) and **no new JS runtime dependency**.

---

## Corrections to the spec, verified against this checkout

The spec was written against an assumption about `main` that does not hold. Verified with `git ls-tree -r HEAD --name-only | grep script` → **empty**. Implementers must not go looking for files that are not there.

| Spec says | Reality in this checkout | What the plan does |
|---|---|---|
| "`externalAddresses.json` already has `.opensea.seaport`… **extend** the existing file" | `script/` does not exist on HEAD at all. The config layer was added in `1f05843` and removed with the stoke work. | **Create** the four config files. Seed them from the recoverable prior content (reproduced verbatim in Task 1) so nothing is lost, then add the ESPNv3 keys. |
| "`deploymentAddresses.json` already has STRAT / convertible-note / cdt / esETH" | Same — recoverable only via `git show 1f05843:…`. | Same: recreate with the historical content plus the three new placeholder keys. |
| `test/forge/seaport/**` prior art | Not on HEAD (removed). Recoverable via `git show 95ff244:…`. | Read it for reference; revive only `ISeaportMinimal.sol`. |
| Submodules initialized | `.gitmodules` lists **five** entries; only **three** gitlinks exist in the tree (`lib/Locked_VestingTokenPlans` and `lib/openzeppelin-v4` are orphan `.gitmodules` entries with no index entry). Of the three real ones, `lib/halmos-cheatcodes` and `lib/openzeppelin-contracts` are uninitialised (`-`); `lib/forge-std` is at `999be66`. `forge build` fails before anything else. | Step 1. |
| Spec's directory layout has no `lib/` and its unit-test section lists only the two token tests | The plan adds `script/deployments/1/lib/{ConfigLib,HoldersLib,SafeBatchLib}.sol`, `test/unit/ScriptLibsTest.sol` and `test/unit/BuildOrderLibTest.sol`. | **Deliberate deviation.** Without stoke's config/context layer every script re-implements JSON reading; without the two test files the first execution of that code is inside a slow fork script. Recorded here so it is not mistaken for spec compliance. |
| Spec's parameter table names the grid `FILL_GRID` | The JSON key is `fillGrid` (camelCase, matching every other settings key). | Same value, two spellings. The run-book (Step 29) quotes **`fillGrid`** for the JSON key and `denominator` for the holder-facing number; `FILL_GRID` appears only as the Solidity constant name. |

**Folder numbering.** The plan uses `003-espn-redemption` and `004-stry-migration`, per the spec. `001`/`002` were consumed by the deleted stoke work; the numbering continues the historical sequence rather than reusing retired numbers.

---

## Task dependency order

```
Task 1 (prereqs + config + shared script libs)   ← blocking, land first
      ├── Task 2 (tokens + unit tests)           ← needs 1a only
      ├── Task 3 (snapshot script + real snapshot JSON)  ← needs 1a only
      ├── Task 4 (Track A scripts)  ← needs 1, 2, 3
      └── Task 5 (Track B scripts)  ← needs 1, 2, 3
Task 6 (operator run-book)          ← needs 4, 5 for the numbers it documents
```

**Tasks 4 and 5 depend on Task 3, not just on 1 and 2.** Both Verify scripts need the *real committed* holders JSON — addresses that genuinely hold ESPN on a fork; a hand-written fixture cannot fulfil a Seaport order (Step 22 picks its sample holders from that file at runtime, and both Verify runs pin the fork to its `snapshotBlock`).

**Task 1 is internally split**, without being two tasks: **1a = Steps 1-7 + 12** (submodules, `foundry.toml`, `remappings.txt`, the two test deletions, the four config files, `package.json`) is purely mechanical and unblocks Tasks 2 and 3 the moment it lands; **1b = Steps 8-11** (the three Solidity libraries and their test) is only needed by Tasks 4 and 5. An implementer should commit 1a first so 2 and 3 can start against it. Not split into separate tasks because 1b's `ScriptLibsTest` verifies config files 1a creates — one task, one reviewer, one file scope.

Tasks 2 and 3 run fully in parallel with each other. Tasks 4 and 5 run in parallel with each other once 1, 2 and 3 have landed: their static file lists are disjoint, and both only *import* Task 1's libs.

**One runtime write is shared and must not be made concurrent:** Task 4's `Distribute.s.sol` writes `.espn-redemption-token` and Task 5's writes `.stry` into the same `script/deployments/1/config/deploymentAddresses.json` via `ConfigLib.writeDeployedAddress`. Two rules keep that safe: (1) `writeDeployedAddress` lives **outside** the `internal` function `Verify.s.sol` calls, so `yarn verify:*` never dirties the committed file; (2) the two `Distribute` scripts are only ever *broadcast* serially, per the run-book's global sequence.

---

## Task 1: Repo prerequisites, shared JSON config, shared script libraries

Nothing else in this plan compiles or runs until this task lands. It also owns every edit to `foundry.toml`, `remappings.txt` and `package.json` for the whole project, so no later task touches those files.

**Files:**
- `foundry.toml` (edit)
- `remappings.txt` (edit)
- `package.json` (edit)
- `test/integration/ESPNRedemptionQueueIntegrationTest.sol` (delete)
- `test/integration/MorphoBlueFlashLoanProviderIntegrationTest.sol` (delete)
- `script/deployments/1/config/externalAddresses.json` (create)
- `script/deployments/1/config/internalAddresses.json` (create)
- `script/deployments/1/config/deploymentAddresses.json` (create)
- `script/deployments/1/config/settings.json` (create)
- `script/deployments/1/lib/ConfigLib.sol` (create)
- `script/deployments/1/lib/HoldersLib.sol` (create)
- `script/deployments/1/lib/SafeBatchLib.sol` (create)
- `test/unit/ScriptLibsTest.sol` (create)

---

- [x] **Step 1: Initialize git submodules and confirm a clean baseline build**

  Run `git submodule update --init --recursive` (equivalently `forge install`). Then confirm `forge build` succeeds and `yarn test` passes **before** changing anything. If the baseline is already red, stop and report — do not fold a pre-existing failure into this task.

  State of the checkout, verified — do **not** repeat the earlier draft's claim that ".gitmodules and the recorded SHAs are already correct":

  - `.gitmodules` lists **five** submodules; the index carries **three** gitlinks. `lib/Locked_VestingTokenPlans` and `lib/openzeppelin-v4` are orphan `.gitmodules` entries with no corresponding tree entry. `git submodule update --init --recursive` iterates the *index*, so it initialises exactly the three real ones and the orphans are harmless.
  - Of the three, `lib/forge-std` is present at `999be66` (v1.9.5-3); `lib/halmos-cheatcodes` and `lib/openzeppelin-contracts` show `-`.

  Leave the orphan entries alone (removing them is unrelated churn); do not commit submodule pointer changes beyond what initialization requires.

  Confirmed at this forge-std pin, so no later step needs to re-check them: `abstract contract Script is ScriptBase, StdChains, StdCheatsSafe, StdUtils` — it does **not** inherit `StdCheats`, so `contract Verify is Script, StdCheats, StdAssertions` linearizes cleanly (Steps 22 and 28). `vm.parseUint`, `vm.parseJsonUint`, `vm.parseJsonAddressArray` (empty array → length 0), `vm.snapshotState` and `vm.revertToState` all exist.

- [x] **Step 2: Grant filesystem permissions in `foundry.toml` and add the `src/` remapping**

  Current `fs_permissions` grants write-only on `./tmp/` and therefore **no read access to anything**, so every `vm.readFile` in this project reverts. `./tmp/` must be `read-write`, not `write` — Step 11's `HoldersLib` test writes a fixture there and reads it back, and a `write`-only grant makes that test revert. Replace:

  ```toml
  fs_permissions = [
      {access = "read-write", path = "./tmp/"},
      {access = "read-write", path = "./script/deployments/"},
  ]
  ```

  Leave `solc_version = "0.8.24"`, `via-ir = true`, `optimizer_runs`, `ffi = true`, `test = "test/unit"` and the `[profile.integration]` block untouched.

  **Also append to `remappings.txt`:**

  ```
  src/=src/
  ```

  Verified: `forge remappings` currently emits only `forge-std/=` and `openzeppelin-contracts/=`. Without this line the nine scripts under `script/deployments/1/00X-…/` can only reach `EspnRedemptionToken`, `StryToken`, `StakedStrat` and `EthStrategyPerpetualNote` through four-level relative paths. One line here, `import {StryToken} from "src/StryToken.sol";` everywhere else.

  Note for later tasks: `via-ir = true` makes the large `Verify.s.sol` scripts slow to compile. That is expected, not a bug.

- [x] **Step 3: Delete the two orphaned integration tests**

  `test/integration/ESPNRedemptionQueueIntegrationTest.sol` imports `src/ESPNRedemptionQueue.sol` and `test/integration/MorphoBlueFlashLoanProviderIntegrationTest.sol` imports `src/MorphoBlueFlashLoanProvider.sol`. Both source contracts were deleted in `2d29ce6`; both are verified absent from `src/`. `FOUNDRY_PROFILE=integration forge test` currently fails to compile because of them.

  Delete both files. Keep `test/integration/esETHIntegrationTest.sol`.

  Verify: `FOUNDRY_PROFILE=integration forge build` compiles.

- [x] **Step 4: Create `script/deployments/1/config/externalAddresses.json`**

  Recreate the historical file (recoverable verbatim via `git show 6484357:script/deployments/1/config/externalAddresses.json`) and add the ESPN entry. Final content:

  ```json
  {
    "opensea": {
      "seaport": "0x0000000000000068F116a894984e2DB1123eB395"
    },
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "lido": {
      "stETH": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
      "wstETH": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
    },
    "sky-money": {
      "USDS": "0xdC035D45d973E3EC169d2276DDab16f1e407384F"
    },
    "eth-strategy": {
      "espn": "0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE"
    }
  }
  ```

  All three ESPNv3-relevant addresses are **confirmed on-chain**: Seaport 1.6, USDS (= `ESPN.asset()`), and ESPN (`EthStrategyPerpetualNote`, ERC4626).

- [x] **Step 5: Create `script/deployments/1/config/internalAddresses.json`**

  Recreate the historical file and add a placeholder for the tripwire controller:

  ```json
  {
    "protocol": {
      "multisigs": {
        "main": "0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8",
        "encumbered": "0x1b005A566983721bc736b57D7D3B1EE028782362",
        "unencumbered": "0xF89f49e21A2Bd1fb24332462cB21dc1378aA25e1",
        "tripwire-guardian": "0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8",
        "redemption": "0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D"
      },
      "tripwire": {
        "controller": "0x0000000000000000000000000000000000000000"
      }
    }
  }
  ```

  Two flags that must be carried into the commit message and the run-book, **not** silently accepted:

  - `.protocol.multisigs.redemption` is the treasury / offerer / consideration-recipient for all of Track A. It is reused from the prior STRAT ragequit and is **Assumption 1 — unconfirmed for this project**. It currently holds ~1,199,676 USDS and ~3,199.73 ESPN (9.20% of supply), which is consistent with the role, but that is corroboration, not confirmation.
  - `.protocol.tripwire.controller` is the zero address because **no deployed `TripwireController` is recorded anywhere in this repo and none was confirmed on mainnet**. This is **Assumption 4 and it blocks Track B's `Deploy.s.sol` at runtime** — `TripwireGuard`'s constructor reverts `InvalidController()` on a controller with no code. Task 5 Step 26 makes that failure loud rather than opaque. Leave the placeholder; do not invent an address.

  `.protocol.multisigs.main` (`0xC53CCed…`) is confirmed as ESPN's `owner()`. Note it is **not** the redemption multisig — any `setWithdrawalsDisabled` / `setDepositCap` call (Assumptions 3 and 8) needs the main multisig.

- [x] **Step 6: Create `script/deployments/1/config/deploymentAddresses.json`**

  Historical content plus three zero-address placeholders. The placeholders must exist as keys, because `vm.writeJson(value, path, key)` overwrites an existing key rather than creating a nested path:

  ```json
  {
    "STRAT": "0x14cF922aa1512Adfc34409b63e18D391e4a86A2f",
    "convertible-note": "0xb96D4D74Dcb2F7899C74878d0727FFab009ACcc4",
    "cdt": "0xD4598307B5507A2b04d0502FCC9b68bbcA9275F3",
    "esETH": "0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb",
    "espn-redemption-token": "0x0000000000000000000000000000000000000000",
    "stry": "0x0000000000000000000000000000000000000000",
    "staked-stry": "0x0000000000000000000000000000000000000000"
  }
  ```

- [x] **Step 7: Create `script/deployments/1/config/settings.json`**

  **The unit convention is mandatory.** Its justification is *not* the one an earlier draft gave: on the forge version pinned here `vm.parseJsonUint` was verified to parse both `"34795546682818036103184"` and `"2900e18"` correctly, so there is no "`parseJsonUint`-vs-`parseUint` trap" to catch and no reason to route wei amounts through `parseJsonString` + `parseUint`. The real reasons to quote amounts and timestamps as decimal strings are: a 22-digit **unquoted** JSON number is silently mangled by every JSON consumer that uses IEEE-754 doubles — including `JSON.parse` in Task 3's `.mjs` writer and `jq` — and `e18` notation is unreadable to those same consumers. Therefore:

  - Every **token amount** and every **timestamp** is a **plain decimal string** — no `e18`, no underscores.
  - Every **ratio / count / price / grid** is an **unscaled JSON number**.
  - `salt` is a **UTF-8 string**, hashed later as `uint256(keccak256(bytes(salt)))`.

  ```json
  {
    "espnv3": {
      "targetRedemptionUsd": "700000000000000000000000",
      "redemptionRatio": 5,
      "fillGrid": 1000000000,
      "basisPriceUsd": 100,
      "expectedSeaportCounter": 0,
      "orderStartTime": "1798761600",
      "orderEndTime": "1799366400",
      "orderSalt": "espnv3-redemption-1",
      "finalYieldAmount": "0",
      "excludedAddresses": []
    }
  }
  ```

  Per-key notes to put in the commit message:

  - `targetRedemptionUsd` = 700,000 USDS. **This, not the 5:1 ratio, is the binding cap** (ratio capacity ≈ 775,731 USDS; ≈ 704,396 excluding the treasury's own 9.2%), so redemption is first-come-first-served. Assumption 9: raise to `"775731000000000000000000"` if the founder wants the ratio to be the true cap. No code changes either way.
  - `basisPriceUsd` is `100` **dollars, unscaled — not a wad**. Writing `100e18` (or `"100000000000000000000"`) mints 1e18× too little STRY.
  - `fillGrid` = `1000000000` (1e9). See Task 4 Step 18 for why this exists.
  - `orderStartTime` = `1798761600` = **2027-01-01T00:00:00Z**, `orderEndTime` = `1799366400` = **2027-01-08T00:00:00Z** (a 7-day window). An earlier draft shipped `1787000000` / `1787604800`, which is **2026-08-17 → 2026-08-24** — i.e. a window that had already opened four days before this plan was written and would make `BuildOrder.s.sol`'s `block.timestamp < startTime` pre-condition revert on the very first run, taking `yarn verify:redemption` (a Definition-of-Done item) with it. The committed values must always be **in the future at commit time**; the operator resets them to the real window before broadcast. `BuildOrder.s.sol` hard-reverts if `orderStartTime <= block.timestamp`, which is the intended forcing function — and Step 22 item 1 warps the fork **unconditionally** to just before `startTime`, in either direction, so a stale committed value never breaks `yarn verify:redemption`.
  - `finalYieldAmount` is `"0"` pending a founder decision — it is a *policy* sum, not NAV-derived, which is why it is correctly in JSON. It leaves the treasury and lands at `ESPN.manager()` (`0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`, a third-party contract), so it must be budgeted (Assumption 3).
  - `excludedAddresses` is `[]` — **the airdrops exclude nothing by default**. Assumption 5 (LP pairs, the treasury, ESPN itself) is a founder decision.
  - `snapshotBlock` is deliberately **absent**. It lives only in the holders JSON filename and body (Task 3 Step 14).

- [x] **Step 8: Write `script/deployments/1/lib/ConfigLib.sol`**

  A plain Solidity `library` with `internal` functions, `pragma ^0.8.24`, SPDX `MIT`. It gets the cheatcode address the standard way, since a library cannot inherit `Script`:

  ```solidity
  Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
  ```

  Public surface — keep it to exactly what the nine scripts need, nothing speculative:

  - `configRoot()` → `"script/deployments/1/config/"`.
  - `readJson(string memory fileName)` → `vm.readFile(string.concat(configRoot(), fileName))`.
  - `addr(string memory fileName, string memory key)` → `vm.parseJsonAddress(readJson(fileName), key)`.
  - `num(string memory fileName, string memory key)` → `vm.parseJsonUint(readJson(fileName), key)`. **One function, not two.** An earlier draft split this into `weiAmount` (via `parseJsonString` + `parseUint`) and `number` (via `parseJsonUint`) on the belief that `parseJsonUint` cannot read a quoted decimal string. That is false at this forge pin — verified: `vm.parseJsonUint` parses `"34795546682818036103184"` and even `"2900e18"` correctly. One accessor covers both the quoted wei amounts and the unscaled numbers.
  - `str(string memory fileName, string memory key)` → `vm.parseJsonString(json, key)`.
  - `addrArray(string memory fileName, string memory key)` → `vm.parseJsonAddressArray(json, key)`, for `excludedAddresses`. Must tolerate an empty array (verified: empty JSON array → `length == 0`, no revert).
  - `writeDeployedAddress(string memory key, address value)` → `vm.writeJson(vm.toString(value), string.concat(configRoot(), "deploymentAddresses.json"), key)`. **Callers must keep this out of any `internal` function a `Verify.s.sol` invokes** — see Steps 19, 22, 25 and 28. A fork run that writes a throwaway address into the committed config is a silent corruption.

  That is the whole surface. **No `seaport()` / `usds()` / `espn()` / `treasury()` wrappers** — an earlier draft added four zero-logic aliases over `addr(file, key)` in a library the same step declares should carry "nothing speculative". Scripts call `ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn")` and friends directly; the key strings are self-documenting and appear in the file they name.

- [x] **Step 9: Write `script/deployments/1/lib/HoldersLib.sol`**

  Reads the snapshot artifact produced by Task 3 and hands the distribute scripts arrays they can pass straight to `mintBatch`.

  **Use exactly this shape — it was verified against the pinned forge, and the obvious alternatives were verified to fail:**

  ```solidity
  struct Holder { address addr; string balance; bool excluded; bool isContract; }

  struct Snapshot { uint256 snapshotBlock; uint256 totalSupply; Holder[] holders; }
  ```

  - `load(string memory path)` → read the file, then:
    - `snapshotBlock` and `totalSupply` via `ConfigLib`-style `vm.parseJsonUint(json, ".snapshotBlock")` / `".totalSupply"` — **not** as part of a whole-document struct decode.
    - holders via **`abi.decode(vm.parseJson(json, ".holders"), (Holder[]))`**, then `vm.parseUint(h.balance)` per entry to get the `uint256`.
    - **assert the `snapshotBlock` in the body matches the number embedded in the filename** (spec: single source of truth). Extract the filename block by string-slicing between `"espn-holders-"` and `".json"`; `require` on mismatch with a message naming both values.
  - `included(Snapshot memory)` → `(address[] memory addrs, uint256[] memory balances, uint256 includedCount, uint256 excludedCount)`, filtering out `excluded == true`. `isContract` is **informational only** — it does not filter.
  - `sum(uint256[] memory)` → `uint256`.

  Three decoding facts, all verified, that the struct above exists to satisfy — an implementer who "simplifies" any of them gets a revert or, worse, silently wrong data:

  1. **`balance` must be declared `string`, not `uint256`.** The snapshot writes amounts as quoted decimal strings (Step 7's convention, Step 15's output), and `vm.parseJson` ABI-encodes a JSON string as `string`. `abi.decode(..., (Holder[]))` with a `uint256 balance` field **reverts**. Convert with `vm.parseUint` after decoding.
  2. **Field order must match JSON-key alphabetical order, not declaration intent.** `vm.parseJson` emits fields in alphabetical key order: `address`, `balance`, `excluded`, `isContract`. The struct above matches. Declaring `bool isContract; bool excluded;` instead returns the two flags **swapped, with no error** — a holder set silently mis-flagged. This is why the struct is `excluded` before `isContract` even though that reads backwards.
  3. **Decode the `.holders` array, do not decode the whole document, and do not use wildcards.** `abi.decode(vm.parseJson(json), (Snapshot))` on the full document fails for the same string/uint reason plus key ordering. Array-path cheatcodes are not an escape hatch either: wildcard paths such as `.holders[*].balance` were verified to fail with "must return exactly one JSON value". The `Holder[]` decode is also the **only** way to learn the holder count — the JSON has no length key.

  Step 11's `ScriptLibsTest` must prove this round-trips a real fixture. Do not assume it works.

- [x] **Step 10: Write `script/deployments/1/lib/SafeBatchLib.sol`**

  Neither `BuildOrder.s.sol`, `Cancel.s.sol` nor `StopEspnYield.s.sol` can broadcast — the sender is a Safe. Each emits a **Safe Transaction Builder JSON** batch instead. One shared writer, three call sites.

  **Use the raw-calldata transaction form. Do not reproduce the ABI-descriptor form.** This is the single largest scope reduction in the plan and it is not optional.

  The prior art (`git show 6484357:script/deployments/1/multisig/002-rage-quit-order/001-0x0cbe9bDD-multisig.json`, worth opening once) encodes `Seaport.validate` as a ~1,990-character nested `contractMethod.inputs` ABI descriptor plus an ~800-character escaped-JSON `contractInputsValues` blob — a `tuple[]` of `OrderParameters` containing two nested dynamic arrays. Those were generated by **stoke's ABI introspection**, which is gone. An earlier draft pushed reproducing them onto every caller as hand-written `inputsJson` / `valuesJson` strings and compressed it into one sub-bullet of Step 20.

  The Transaction Builder also accepts transactions specified as raw calldata: `"data": "0x…"` with `"contractMethod": null` and `"contractInputsValues": null`. That deletes the entire nested-ABI problem, needs nothing beyond the `ISeaportMinimal` interface Step 17 already copies, and produces the identical on-chain call.

  API:

  - `struct Tx { address to; bytes data; }` — callers build `data` with `abi.encodeCall`, e.g. `abi.encodeCall(ISeaportMinimal.validate, (orders))`, `abi.encodeCall(IERC20.approve, (seaport, usdsOffer))`, `abi.encodeCall(ISeaportMinimal.cancel, (components))`, `abi.encodeCall(IEspn.increaseAssetsPerShare, (finalYieldAmount))`. No ABI introspection anywhere, in the library or in the callers.
  - `write(address safe, string memory operation, uint256 index, string memory name, string memory description, Tx[] memory txs)` → builds the document with `string.concat` (`vm.toString(tx.data)` for the hex) and writes it to `script/deployments/1/multisig/<operation>/<index padded to 3>-<first 10 chars of safe>-multisig.json`.

  Emitted shape — **match the reference file key-for-key**, including the two keys an earlier draft dropped (`"data"` inside each transaction, `"createdFromOwnerAddress"` in `meta`). The importer is picky and matching it is free:

  ```json
  { "version": "1.0", "chainId": "1", "createdAt": 0,
    "meta": { "name": "...", "description": "...", "txBuilderVersion": "2.0.1",
              "createdFromSafeAddress": "0x0cbe...", "createdFromOwnerAddress": "", "checksum": null },
    "transactions": [ { "to": "0x...", "value": "0", "data": "0x095ea7b3...",
                        "contractMethod": null, "contractInputsValues": null } ] }
  ```

  **Emit `"checksum": null`.** The spec is explicit: the Transaction Builder accepts an absent/null checksum and the operator re-derives it on import. Do not attempt to reproduce Safe's checksum algorithm; do not block on it.

  `createdAt` may be `block.timestamp * 1000`. It is cosmetic.

  Note for Steps 20, 21 and 24: the prior-art batch contains **one** transaction, not two. This plan's batches are 2-transaction batches for reasons of its own (approve-then-act, cancel-then-revoke) — there is no precedent to copy for that shape, so do not describe it as "matching the prior art".

- [x] **Step 11: Write `test/unit/ScriptLibsTest.sol` and verify Task 1**

  One forge test file, run by the default profile. It is the runnable check for the three libraries — without it, a `vm.parseJson` struct-decoding mistake in `HoldersLib` surfaces for the first time inside a fork Verify script, where it is far more expensive to diagnose.

  Cover exactly:

  1. `ConfigLib.addr` returns the four confirmed addresses from Steps 4/5: Seaport, USDS, ESPN (from `externalAddresses.json`) and `.protocol.multisigs.redemption` (from `internalAddresses.json`).
  2. `ConfigLib.num("settings.json", ".espnv3.targetRedemptionUsd") == 700_000e18` — a quoted 24-digit decimal string read through `parseJsonUint`.
  3. `ConfigLib.num("settings.json", ".espnv3.basisPriceUsd") == 100` and `.fillGrid == 1_000_000_000`.
  4. `ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses").length == 0` (empty-array tolerance).
  5. `HoldersLib.load` against a small fixture written to `./tmp/espn-holders-123.json` by the test itself via `vm.writeFile` — Step 2 grants `read-write` on `./tmp/`, which the read-back in this test requires. Assert: balances decode to the right `uint256`s; **`isContract` and `excluded` land on the right holders** (make the fixture asymmetric — one holder `excluded: true, isContract: false`, another the reverse — so a swapped decode fails loudly); the filename/body block-number cross-check fires on a deliberately mismatched fixture; and `included()` drops `excluded: true` entries and preserves order.
  6. `SafeBatchLib.write` produces a file whose `.transactions[0].to`, `.transactions[0].data` and `.meta.createdFromSafeAddress` parse back correctly, and whose `.transactions[0].data` equals `vm.toString(abi.encodeCall(IERC20.approve, (spender, amount)))` for a known pair.

  **Verify the whole task:** `forge build` clean; `yarn test` green; `FOUNDRY_PROFILE=integration forge build` clean; `forge fmt --check` clean.

- [x] **Step 12: Add the `package.json` scripts**

  `foundry.toml` sets `test = "test/unit"` and `[profile.integration] test = "test/integration"`, so **`forge test` never picks up anything under `script/`**. Without named scripts, no Verify script in this project would ever be executed by `yarn test` or `yarn test:integration`. Add, reusing the fork URL default already present in `test:integration`:

  ```json
  "snapshot:espn": "node script/snapshot/espn-holders.mjs",
  "snapshot:selftest": "node script/snapshot/espn-holders.mjs --selftest",
  "verify:redemption": "forge script script/deployments/1/003-espn-redemption/Verify.s.sol --fork-url ${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat} ${SNAPSHOT_BLOCK:+--fork-block-number $SNAPSHOT_BLOCK} -vvv",
  "verify:migration": "forge script script/deployments/1/004-stry-migration/Verify.s.sol --fork-url ${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat} ${SNAPSHOT_BLOCK:+--fork-block-number $SNAPSHOT_BLOCK} -vvv"
  ```

  **The fork block must be pinned, and `${SNAPSHOT_BLOCK:+…}` is how.** Both Verify scripts mint from *snapshot* balances and then fill against *live* balances; on an unpinned `latest` fork, any holder who moved ESPN after the snapshot breaks the fill for reasons that have nothing to do with the code under test. The `:+` form expands to nothing when `SNAPSHOT_BLOCK` is unset, so the scripts still run before Task 3 has produced a snapshot. Both Verify scripts additionally `require(block.number >= snapshotBlock)` and **log a prominent warning when `block.number != snapshotBlock`**, naming `SNAPSHOT_BLOCK` as the fix. The run-book records exporting `SNAPSHOT_BLOCK` (it is in the holders filename) as part of the standard verify invocation.

  Add **no** `dependencies` block. The snapshot script is zero-dependency by design (Task 3), and `snapshot:selftest` uses only `node:assert` and `node:test`-free plain asserts.

---

## Task 2: `EspnRedemptionToken` + `StryToken` contracts and unit tests

Two deliberately plain tokens. **Do not** use the `MintableBurnableToken` / `TripwireGuard` pattern that `StratToken`, `CdtToken` and `DesEthToken` use — the product ask is for something simple, and nothing here needs pausing, a minter allowlist, permit, or burn.

**Files:**
- `src/EspnRedemptionToken.sol`
- `src/StryToken.sol`
- `test/unit/EspnRedemptionTokenTest.sol`
- `test/unit/StryTokenTest.sol`

---

- [x] **Step 13: Write `src/EspnRedemptionToken.sol` and `src/StryToken.sol`**

  Both files, complete:

  ```solidity
  // SPDX-License-Identifier: GPL-2.0-or-later
  pragma solidity ^0.8.20;

  import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
  import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

  contract EspnRedemptionToken is ERC20, Ownable {
      error LengthMismatch();

      constructor(address initialOwner) ERC20("ESPN Redemption", "ESPNR") Ownable(initialOwner) {}

      function mintBatch(address[] calldata to, uint256[] calldata amounts) external onlyOwner {
          if (to.length != amounts.length) revert LengthMismatch();
          for (uint256 i; i < to.length; ++i) {
              _mint(to[i], amounts[i]);
          }
      }
  }
  ```

  `StryToken` is byte-identical apart from the contract name and `ERC20("ETH Strategy Yield", "STRY")`. **Do not factor out a shared base contract.** The duplication is ~14 lines and keeping each token independently auditable is worth more than deduplicating it.

  Points that are load-bearing, not stylistic:

  - **There is no single-recipient `mint(address,uint256)`.** An earlier draft had one. No script in this plan calls it, ownership is renounced in the same transaction as the airdrop, and its only consumer was its own unit tests. `mintBatch` with a one-element array covers every case it could have served.
  - **`mintBatch`, not a loop of `mint()` calls.** `forge script --broadcast` sends one transaction per external call, so a `mint()` loop is ~170 separate transactions: not atomic, no resume story, ~3.6M gas of pure intrinsic overhead, and — because ownership is renounced immediately afterwards — a partial batch would leave holders permanently unmintable. `mintBatch` makes the airdrop one atomic transaction and makes the measured gas number meaningful. Expect ~4.5M gas for ~170 holders.
  - **18 decimals** (OZ default), matching ESPN, which the 1:1 airdrop depends on.
  - `pragma ^0.8.20` matches the rest of `src/`; `foundry.toml` pins `solc_version = "0.8.24"`.
  - Import paths use the `openzeppelin-contracts/` remapping already in `remappings.txt`.
  - Name/symbol for `EspnRedemptionToken` are **Assumption 11 — a placeholder pending founder confirmation**. `STRY` / `ETH Strategy Yield` were specified by the founder.

- [x] **Step 14: Write `test/unit/EspnRedemptionTokenTest.sol` and `test/unit/StryTokenTest.sol`**

  Plain `forge-std/Test.sol`, no fork, following the shape of `test/unit/MintableBurnableTokenTest.sol` (SPDX `GPL-2.0-or-later`, `pragma ^0.8.20`, `contract … is Test`, `setUp()` deploying with an `owner` address constant).

  Both files cover the same list:

  1. `mintBatch` with a single entry, by the owner, credits the recipient and moves `totalSupply`.
  2. `mintBatch` by a non-owner reverts `Ownable.OwnableUnauthorizedAccount(caller)` — assert with `vm.expectRevert(abi.encodeWithSelector(...))`, not a bare `vm.expectRevert()`.
  3. `mintBatch` with mismatched array lengths reverts `LengthMismatch()`.
  4. **`mintBatch` with 170 entries** produces exactly the expected per-address balances and `totalSupply == sum(amounts)`. Generate the addresses deterministically (`address(uint160(i + 1))`); this both proves the loop and gives a first gas signal.
  5. `mintBatch` including `address(0)` reverts `ERC20InvalidReceiver(address(0))`.
  6. Standard ERC20 behaviour: `transfer`, `approve` + `transferFrom`, `name()`, `symbol()`, and **`decimals() == 18`** (asserted, not assumed — four formulas downstream hardcode `1e18`).
  7. After `renounceOwnership()`, `mintBatch` reverts `OwnableUnauthorizedAccount`.
  8. `mintBatch` with empty arrays is a no-op that does not revert.

  **Verify:** `yarn test` green, `forge fmt --check` clean.

---

## Task 3: ESPN holder snapshot script

Off-chain, Node ≥18, **zero dependencies** — Node 18's global `fetch` covers every JSON-RPC call. `viem` was proposed in the brainstorm and is **dropped**: it was justified as covering "log-fetching and hashing", there is no merkle tree so nothing needs hashing, and `package.json` currently has `devDependencies` only. Do not add a `dependencies` block.

**Files:**
- `script/snapshot/espn-holders.mjs`

No `script/snapshot/README.md`. An earlier draft had one; every line of its stated contents (env vars, `yarn snapshot:espn`, what the invariant failure means, the snapshot-block rule) is a strict subset of Task 6 Step 29's run-book. Two documents to keep in sync, for a single-file script. The env vars and the snapshot-block rule go in a header comment in the `.mjs`; the operator instructions go in the run-book, which is the one document this project tells operators to read.

---

- [x] **Step 15: Write `script/snapshot/espn-holders.mjs`**

  Inputs via env: `RPC_URL` (required), `SNAPSHOT_BLOCK` (optional — defaults to the `finalized` tag's block number), `ESPN_ADDRESS` (defaults to `0xb250C9E0F7bE4cfF13F94374C993aC445A1385fE`), `SETTINGS_PATH` (defaults to `script/deployments/1/config/settings.json`).

  Algorithm, in order. Each numbered item is a hard requirement, not a suggestion:

  1. **Reorg guard, first.** Read `eth_blockNumber`. If `head - snapshotBlock < 64`, **exit non-zero**. Two epochs. Prefer resolving the `finalized` tag when `SNAPSHOT_BLOCK` is unset. Without this, a reorged `eth_getLogs` result yields a wrong holder set that the supply invariant in item 4 still passes, because both sides are read from the same reorged view.
  2. **Address discovery.** Page `eth_getLogs` for ESPN's `Transfer` topic (`0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`) from ESPN's deployment block to `snapshotBlock`, in **chunks of 10,000 blocks** (public and gateway RPCs commonly cap at ~10k blocks / ~10k logs per call). Bounded retry: 3 attempts with exponential backoff, and **automatic chunk-halving** on a range- or size-related error. Collect the unique set of `from`/`to` addresses from topics 1 and 2 (last 20 bytes of each 32-byte topic). Drop `address(0)`. Find ESPN's deployment block once and hardcode it as a constant with a comment; scanning from block 0 wastes hours.
  3. **Balances from `balanceOf`, not from log arithmetic.** One `eth_call` of `balanceOf(address)` per candidate **at `blockNumber = snapshotBlock`**. ~170–400 calls; send them as JSON-RPC **array batch** requests of ~50. Reconstructing `balance += / -=` across every Transfer is the error-prone part and is unnecessary — `balanceOf` at a block is exact by construction.
  4. **Invariant: `sum(balances) === ESPN.totalSupply()` at `snapshotBlock`** (read at that same block). **Hard fail on mismatch, exit non-zero.** This is a complete check, not a spot-check: a holder whose only `Transfer` fell inside a dropped chunk is absent from the address set, and their balance is missing from the sum. Use `BigInt` throughout — these are 22-digit numbers and `Number` silently loses precision.
  5. Drop zero balances **after** the invariant check.
  6. **Flags, no default exclusions.** Set `"isContract": true` for any holder whose `eth_getCode` at `snapshotBlock` is not `"0x"`. Set `"excluded": true` for any address in `settings.json`'s `.espnv3.excludedAddresses` (case-insensitive compare). **Exclude nothing by default** — exclusion is Assumption 5, a founder decision. The invariant in item 4 is checked **before** exclusions are applied.
  7. **Output** to `script/deployments/1/config/espn-holders-<snapshotBlock>.json`, holders sorted by address for determinism, all amounts as plain decimal strings:

     ```json
     { "snapshotBlock": 25800591,
       "totalSupply": "34795546682818036103184",
       "holders": [ { "address": "0x...", "balance": "...", "isContract": false, "excluded": false } ] }
     ```

     **There is no `navPerEspn` field.** An earlier draft wrote one and then forbade its use from three separate places (here, Step 25, and the spec). Every consuming Solidity script re-reads `totalAssets()` / `totalSupply()` live at broadcast time, so the field had exactly no consumer and three warnings. Deleting the field deletes the warnings. NAV still gets **printed** by item 8 for the operator's eyes.

     `HoldersLib` (Step 9) decodes `.holders` as a struct array in **alphabetical key order** — `address`, `balance`, `excluded`, `isContract`. Emit exactly those four keys per holder and nothing else; an extra key or a renamed one breaks the decode.

  8. Print a summary to stderr: block, holder count, contract count, excluded count, total supply, and NAV (`totalAssets * 10n**18n / totalSupply`, both read at `snapshotBlock`) — reference figures for the operator, not written to the file.

  Keep it one file. No CLI-argument framework, no logger, no retry library.

  **`--selftest`, the one runnable check.** This script is ~200 lines of BigInt arithmetic, topic slicing, chunk halving and batched JSON-RPC parsing feeding *both* airdrops, and its only other verification is a live network run. Write the pure helpers as plain functions — `topicToAddress(topic32)`, `halveChunk(range)`, `parseBatchResponse(jsonArray)`, `sumBalances(map)` — and put a `--selftest` branch at the top of `main()` that `assert`s them against hardcoded literals and `process.exit(0)`s without touching the network. `node:assert` only; no test framework, no second file, no fixtures directory. `yarn snapshot:selftest` (Step 12) runs it offline.

- [x] **Step 16: Run the script and commit a real snapshot**

  Put the operator-facing notes in the `.mjs` header comment, not a separate doc (see this task's file list): the env vars, and the rule that **the snapshot block lives only in the output filename and body — never in `settings.json`**, and that both tracks must use the same block (subject to Assumption 7 option 1). Step 29's run-book carries the rest.

  Then **actually run it** against a mainnet RPC at a finalized block and commit the resulting `script/deployments/1/config/espn-holders-<block>.json`. It is a generated artifact, so it is not listed in this task's file list, **but it is a hard dependency of Tasks 4 and 5** — their Verify scripts need a real holders file with addresses that genuinely hold ESPN on a fork (a hand-written fixture cannot fulfil a Seaport order), Step 22 picks sample holders from it at runtime, and both Verify runs pin the fork to its `snapshotBlock`. Neither Task 4 nor Task 5 can be verified until this step lands.

  **Verify:** `yarn snapshot:selftest` exits 0 offline; the live run exits 0, the invariant passes, holder count is ~170, and the committed JSON parses. Then deliberately break it — pass `SNAPSHOT_BLOCK` equal to head — and confirm it exits non-zero on the reorg guard.

---

## Task 4: Track A — pro-rata capped redemption (`003-espn-redemption`)

Depends on Tasks 1, 2 **and 3** — `Verify.s.sol` cannot run without Task 3's committed holders JSON. Reference reading before starting: `git show 6484357:script/deployments/1/002-rage-quit-order/BuildOrderLib.sol`, `…/Verify.s.sol`, and **`git show 95ff244:test/forge/seaport/README.md`** — particularly its "Numerator / denominator constraints", "Public fillability" and "MEV / fill competition" sections. Replicate the *shape*; use **none** of the `stoke` imports.

**Files:**
- `script/deployments/1/003-espn-redemption/interfaces/ISeaportMinimal.sol`
- `script/deployments/1/003-espn-redemption/BuildOrderLib.sol`
- `script/deployments/1/003-espn-redemption/Distribute.s.sol`
- `script/deployments/1/003-espn-redemption/BuildOrder.s.sol`
- `script/deployments/1/003-espn-redemption/Cancel.s.sol`
- `script/deployments/1/003-espn-redemption/Verify.s.sol`
- `test/unit/BuildOrderLibTest.sol`

---

- [x] **Step 17: Revive `interfaces/ISeaportMinimal.sol`**

  Copy verbatim from `git show 6484357:script/deployments/1/002-rage-quit-order/interfaces/ISeaportMinimal.sol`. It is already exactly the surface this project needs: `ItemType`/`OrderType`/`Side` enums, `OfferItem`, `ConsiderationItem`, `OrderParameters`, `OrderComponents`, `AdvancedOrder`, `CriteriaResolver`, `Order`, plus `getCounter`, `getOrderHash`, `getOrderStatus`, `information`, `cancel`, `incrementCounter`, `fulfillAdvancedOrder`, `validate`, and the `OrderIsCancelled` error.

  Do not extend it. `pragma ^0.8.24`, SPDX `MIT`, as in the original.

  Note the two struct types that differ by one field: `OrderParameters` ends with `totalOriginalConsiderationItems` (used by `validate`/`fulfillAdvancedOrder`), `OrderComponents` ends with `counter` (used by `getOrderHash`/`cancel`). Mixing them up produces a wrong order hash that will not be caught until a fill fails.

- [x] **Step 18: Write `BuildOrderLib.sol` — order construction and the fill grid**

  Port `6484357`'s `BuildOrderLib` with the stoke `Context`/`Config` plumbing removed. Keep `constructOrderParams` essentially as-is: it is correct and it already produces `PARTIAL_OPEN`, `zone = address(0)`, `zoneHash = 0`, `conduitKey = bytes32(0)`, `salt = uint256(keccak256(order.salt))`, `totalOriginalConsiderationItems = consideration.length`. Replace `minimalOrderParams(Context, address)` with a plain function that takes explicit arguments.

  Add the two things the port needs:

  **(a) Amount derivation.** `deriveAmounts(uint256 targetRedemptionUsd, uint256 redemptionRatio, uint256 fillGrid, uint256 totalAssets, uint256 totalSupply)` → `(uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk, uint256 navPerEspn)`:

  ```
  navPerEspn        = totalAssets * 1e18 / totalSupply
  usdsOffer_raw     = targetRedemptionUsd            // the offer IS the target; no round-trip
  espnAsk_raw       = targetRedemptionUsd * 1e18 / navPerEspn
  redemptionAsk_raw = espnAsk_raw * redemptionRatio

  usdsOffer     = (usdsOffer_raw     / fillGrid) * fillGrid
  espnAsk       = (espnAsk_raw       / fillGrid) * fillGrid
  redemptionAsk = (redemptionAsk_raw / fillGrid) * fillGrid
  ```

  `usdsOffer = targetRedemptionUsd` **directly**. An earlier draft used `usdsOffer = espnAsk * navPerEspn / 1e18`, which recomputes the target minus a rounding error — and that error is exactly the kind that breaks fraction exactness.

  **(b) The fill grid, and why it exists.** This is the mechanism's sharpest edge. Seaport's `_getFraction(numerator, denominator, value)` reverts `InexactFraction` unless `value * numerator % denominator == 0` for **every offer item and every consideration item independently**. Raw NAV-derived amounts are ~22-digit arbitrary integers, so a holder trying to spend their exact balance would need a `n/d ≤ uint120` satisfying exact divisibility for all three items simultaneously. They cannot, and almost every attempted fill reverts. The prior art dodged this by hardcoding round `e18` amounts and filling at `33/100`; this project derives amounts from live NAV and cannot.

  The fix: snap every amount down to a multiple of `FILL_GRID = 1e9`, and mandate `denominator = FILL_GRID` for all fills. If every item amount is a multiple of `fillGrid`, then `amount * n` is a multiple of `fillGrid` for **any** integer `n ≤ fillGrid`, so `_getFraction` is exact at every numerator. One consequence comes free: the **final tranche is fillable** (Seaport clamps `numerator = denominator - filledNumerator`, still an integer `< fillGrid`, so no permanently-unfillable dust tail strands the end of the 700k).

  **(c) The holder's numerator — REDEMPTION binds, not ESPN.** This is the formula every holder-facing surface prints, and getting it wrong makes every printed instruction revert:

  ```
  n = min( floor(espnBalance       * fillGrid / espnAsk),
           floor(redemptionBalance * fillGrid / redemptionAsk) )
  ```

  Expose it as `deriveNumerator(uint256 espnBalance, uint256 redemptionBalance, uint256 espnAsk, uint256 redemptionAsk, uint256 fillGrid)`.

  An earlier draft printed `n = floor(espnBalance * fillGrid / espnAsk)` in three places (Step 20's logged holder block, Step 22's fork fill, Step 29 §3). That is wrong by exactly `redemptionRatio` = **5×**. REDEMPTION is airdropped **1:1** with ESPN (Step 19 item 3) but the order consumes **5 REDEMPTION per 1 ESPN**, so the REDEMPTION leg is the binding constraint: a holder sized off their ESPN balance is asked for 5× the REDEMPTION they own and the fill reverts on insufficient balance. Since `redemptionAsk = 5 * espnAsk` and the two balances start equal, the second term always wins and the practical statement is: **each holder can redeem at most 20% of their ESPN.** Say that in plain words in the run-book — it is the single most surprising property of the mechanism.

  Note this is *not* a capacity bug: aggregate capacity was already computed off the ratio (20% of ~$3.878M NAV ≈ 775,731 USDS, ~704,392 excluding the treasury's 9.2%), which is why 700,000 still binds. Only the printed per-holder formula was wrong.

  Accepted costs, all to be stated in the run-book: snapping loses < 1e9 wei per item (negligible against 700,000e18); one grid unit ≈ 0.0000063 ESPN ≈ $0.0007, so a holder with less than that cannot fill; each holder rounds **down** and retains sub-grid dust; a fulfiller who ignores the `denominator = fillGrid` convention most likely reverts `InexactFraction` — there is no zone, so the convention cannot be enforced on-chain, and the mitigation is that the naive attempt reverts rather than succeeding badly.

  **(d) `test/unit/BuildOrderLibTest.sol` — write it in this step, not later.** `deriveAmounts`, the grid snapping and `deriveNumerator` are pure arithmetic with no fork requirement, and this step calls the grid "the mechanism's sharpest edge". Leaving their only coverage inside the slow mainnet-fork Verify script is exactly the argument Step 11 makes for `ScriptLibsTest` — a mistake surfaces first inside a fork script, where it is far more expensive to diagnose — applied to the one calculation that can revert every fill. Plain `forge-std/Test.sol`, no fork, importing `BuildOrderLib` by relative path. Cover:

  1. `deriveAmounts` at the block-25,800,591 figures (`totalAssets = 3878653235910468821362228`, `totalSupply = 34795546682818036103184`) yields `navPerEspn == 111469817424243522517` and `usdsOffer == targetRedemptionUsd` exactly.
  2. All three returned amounts are `% fillGrid == 0`, at those figures **and** at two deliberately awkward NAVs (a prime-ish `totalAssets`, and one where each raw amount ends in nines) — the snapping is the whole point and it must hold for arbitrary inputs, not one lucky sample.
  3. `redemptionAsk == espnAsk * redemptionRatio` after snapping (both are grid multiples, so the identity survives).
  4. `deriveNumerator` with equal ESPN and REDEMPTION balances returns the REDEMPTION-bound value, and the resulting `espnAsk * n / fillGrid <= espnBalance` **and** `redemptionAsk * n / fillGrid <= redemptionBalance` — i.e. the holder can always afford the fill the formula tells them to make. Fuzz it over balances.
  5. `value * n % fillGrid == 0` for all three amounts across a fuzzed `n` in `[1, fillGrid]` — the grid invariant `_getFraction` depends on, asserted directly rather than inferred.

  **On cross-scaling, stated accurately.** An earlier draft claimed "no uint120 cross-scaling ever occurs". That is only true while every fulfiller uses `denominator = 1e9`, which the same paragraph admits cannot be enforced. The correct claim is weaker and still sufficient: **exactness survives cross-scaling.** Seaport's scaling multiplies numerator and denominator by the same factor, so `value * n % d == 0` is preserved, and the scaled denominator stays `≤ 1e18`, far below `uint120` max. Write it that way; do not overclaim.

- [x] **Step 19: Write `Distribute.s.sol`**

  Plain `forge-std/Script`, `pragma ^0.8.24`. One broadcast (`vm.startBroadcast()` / `vm.stopBroadcast()`), holders-file path from env `HOLDERS_FILE`:

  1. `HoldersLib.load(holdersFile)`, then `HoldersLib.included(...)`.
  2. `new EspnRedemptionToken(deployer)`.
  3. **One** `mintBatch(addrs, balances)` call — 1:1 with snapshot ESPN balances. Wrap it in `gasBefore = gasleft()` / `gasAfter = gasleft()`.
  4. `renounceOwnership()` in the same broadcast (Assumption 10).
  5. `ConfigLib.writeDeployedAddress(".espn-redemption-token", address(token))`.
  6. Log holder count, excluded count, total minted, and gas (see Step 23 for the gas-logging format).

  **Structure so that `Verify.s.sol` never writes config.** Put items 1-4 and the post-conditions in an `internal` function that returns the deployed token; call `writeDeployedAddress` (item 5) only from `run()`, outside it. `Verify.s.sol` calls the `internal` function. Otherwise every `yarn verify:redemption` run overwrites the committed `deploymentAddresses.json` with a throwaway fork address — and Task 5's `Distribute` has the identical hazard on `.stry` / `.staked-stry` in the same file.

  In-script post-conditions, asserted with `require`: `totalSupply() == HoldersLib.sum(balances)`; `owner() == address(0)`; and a loop asserting `balanceOf(addrs[i]) == balances[i]` for **every** included holder (170 view calls cost nothing in a script and this is the cheapest possible proof the airdrop is right).

- [x] **Step 20: Write `BuildOrder.s.sol`**

  **Never broadcasts.** The offerer is a Safe. It computes, asserts, logs, and emits a Safe batch.

  1. Read addresses and settings via `ConfigLib`; read `REDEMPTION` from `deploymentAddresses.json`.
  2. Read live `ESPN.totalAssets()` / `ESPN.totalSupply()`; call `BuildOrderLib.deriveAmounts`.
  3. **Pre-conditions.** These replace the vacuous `redemptionAsk <= REDEMPTION.totalSupply()` from an earlier draft, which passes by 5× at any plausible NAV and detects nothing:
     - **Hard revert:** `USDS.balanceOf(treasury) >= usdsOffer`. The treasury holds ~1,199,676 USDS today, comfortably above 700,000 — assert it anyway, never assume. `ESPN.totalAssets()` is bookkeeping, not a balance; the vault itself holds ~0.005 USDS because `_deposit` and `increaseAssetsPerShare` forward every asset straight to `manager`.
     - **Hard revert:** `USDS.decimals() == 18 && ESPN.decimals() == 18 && REDEMPTION.decimals() == 18`.
     - **Hard revert:** `ESPN.asset() == USDS`. Both addresses are hand-copied into `externalAddresses.json` (Step 4) and nothing else in the project checks that they relate — Step 11's config test only proves the JSON round-trips a string. A wrong USDS address flows straight into the Seaport offer item, into `USDS.approve(Seaport, 700k)` and into `StopEspnYield`. One `require` is the entire fix and it is the only cheap on-chain confirmation of the `0xb250C9E0…` / `0xdC035D45…` pair. Assert the same thing in both Verify scripts and in `StopEspnYield.s.sol`.
     - **Hard revert:** `treasury.code.length > 0`. `0x0cbe9bDD…` is **Assumption 1, explicitly unconfirmed**. A wrong EOA passes every `vm.startPrank` in `Verify.s.sol` without complaint and yields a Safe batch nobody can execute.
     - **Hard revert:** `Seaport.getCounter(treasury) == expectedSeaportCounter` from settings (currently `0`). If the multisig ever increments its counter, every previously validated order silently dies; the counter feeds the order hash anyway.
     - **Hard revert:** `usdsOffer % fillGrid == 0 && espnAsk % fillGrid == 0 && redemptionAsk % fillGrid == 0`.
     - **Hard revert:** `block.timestamp < startTime` and `startTime < endTime`. Absolute timestamps in a committed JSON go stale between authoring and broadcast; this is the intended forcing function.
     - **Logged, not reverted — two capacity figures, not one.** The signer must see the realistic cap, not just the theoretical one.

       ```
       usableRedemption   = REDEMPTION.totalSupply()
                          - REDEMPTION.balanceOf(treasury)
                          - sum(REDEMPTION.balanceOf(x) for x in excludedAddresses)
       reachableRedemption = usableRedemption
                          - sum(REDEMPTION.balanceOf(h) for h in holders where isContract)
       ```

       Log `usableRedemption / redemptionRatio * navPerEspn / 1e18` **and** the same expression over `reachableRedemption`, both next to `usdsOffer`, so the signer can see which side binds. Theoretical ex-treasury capacity is ~704,392 USDS against a 700,000 target — **0.6% headroom** — and any REDEMPTION airdropped to a contract that cannot call `approve` / `fulfillAdvancedOrder` (LP pairs above all, and ESPN's stated exit path *is* the LP) is permanently stranded and comes straight off that number. Combined with the 20%-of-ESPN per-holder cap from Step 18(c), exhausting the 700,000 pool is unlikely; the run-book must not imply otherwise. `isContract` still **does not filter** the airdrop (Step 9) — this is a logged figure only.
  4. Build the order via `BuildOrderLib.constructOrderParams` with `offerer = treasury`, offer `[USDS, usdsOffer]`, consideration `[[REDEMPTION, redemptionAsk, treasury], [ESPN, espnAsk, treasury]]`.
  5. Compute and log the order hash: build `OrderComponents` (same fields but `counter = Seaport.getCounter(treasury)` in place of `totalOriginalConsiderationItems`) and call `Seaport.getOrderHash`.
  6. Log the **holder run-book block** verbatim — there is no UI, so this text is the entire holder-facing interface:

     ```
     denominator = 1000000000
     numerator   = min( floor(yourEspnBalance       * 1000000000 / <espnAsk>),
                        floor(yourRedemptionBalance * 1000000000 / <redemptionAsk>) )
                 = in practice, floor(yourEspnBalance * 1000000000 / <redemptionAsk>)
                   -> you can redeem at most 20% of your ESPN
     you pay     : espnAsk * n / 1e9 ESPN  and  redemptionAsk * n / 1e9 REDEMPTION
     you receive : usdsOffer * n / 1e9 USDS
     approve Seaport (0x0000000000000068F116a894984e2DB1123eB395) for both amounts first
     ```

     Compute `n` with `BuildOrderLib.deriveNumerator` (Step 18(c)) — do **not** inline a formula here that can drift from the library the fork test exercises. The "at most 20%" line is load-bearing, not commentary: REDEMPTION is airdropped 1:1 with ESPN and the order consumes 5 REDEMPTION per ESPN.

  7. Emit the **2-transaction Safe batch** via `SafeBatchLib.write` to `script/deployments/1/multisig/003-espn-redemption/001-0x0cbe9bDD-multisig.json`: `USDS.approve(Seaport, usdsOffer)` **then** `Seaport.validate([order])`. The approval is a separate transaction from `validate` and must be in the same Safe execution. Both are raw-calldata transactions built with `abi.encodeCall` (Step 10) — there is **no** ABI descriptor to hand-write, and no precedent in the prior art for a 2-transaction batch.

  Expose the derivation and order-construction as `internal` functions so `Verify.s.sol` can call them under a prank rather than duplicating the logic. Keep the `SafeBatchLib.write` call in `run()`, outside them, so a fork run does not scatter throwaway batch files.

- [x] **Step 21: Write `Cancel.s.sol`**

  Also never broadcasts. Rebuilds **identical** order components from the same config so the cancelled hash provably matches the validated one, asserts the recomputed hash equals the hash logged by `BuildOrder.s.sol` (passed in via env `EXPECTED_ORDER_HASH`), then emits a 2-transaction Safe batch to `script/deployments/1/multisig/003-espn-redemption/002-0x0cbe9bDD-multisig.json`:

  1. `Seaport.cancel([orderComponents])`
  2. `USDS.approve(Seaport, 0)`

  The second transaction is not optional. The USDS allowance survives order expiry, and leaving a live 700,000 USDS allowance to Seaport after the window is a standing risk with no upside.

  Because NAV moves, rebuilding from live NAV would produce a *different* hash than the validated order. `Cancel.s.sol` must therefore reconstruct the amounts from `EXPECTED_ORDER_HASH`'s originals — take `usdsOffer`, `espnAsk` and `redemptionAsk` as explicit env inputs (the values `BuildOrder.s.sol` logged), derive nothing from live NAV, and let the hash assertion be the proof they are right.

  **Same structural rule as Step 20, and it is not optional: expose the component rebuild + hash assertion as an `internal` function taking the three amounts as arguments**, with `run()` reading them from env and calling `SafeBatchLib.write`. Step 22 item 9 requires `Verify.s.sol` to run the `Cancel` logic under a prank; without the `internal` entry point it would have to shell out env vars mid-script or duplicate the logic, and a duplicated hash rebuild is exactly the drift the hash assertion exists to catch.

- [x] **Step 22: Write `Verify.s.sol` (Track A, mainnet fork)**

  `contract Verify is Script, StdCheats, StdAssertions` — verified to linearize at this forge-std pin: `Script` inherits `StdCheatsSafe`, not `StdCheats`, so `deal` and `assertEq` need the explicit imports. `assertEq` delegates to `vm.assertEq`, which reverts, so assertions genuinely fail a `forge script` run. Use `vm.startPrank`/`vm.stopPrank`, **not** `vm.startBroadcast`, for impersonation: broadcast signs with a key and cannot act as a Safe; prank can.

  Call the `internal` entry points of `Distribute`, `BuildOrder` and `Cancel` — **never their `run()`s**, which write config and Safe batch files (Steps 19, 20, 21). A `yarn verify:*` run must leave the working tree clean.

  Sequence, in order:

  0. **Fork block check.** `require(block.number >= snapshotBlock)` from the holders file, and log a loud warning if `block.number != snapshotBlock` naming `SNAPSHOT_BLOCK` (Step 12) as the fix. Distribute mints from snapshot balances while item 4 fills against live balances; on an unpinned fork any holder who moved ESPN since the snapshot breaks the fill for reasons unrelated to the code.
  1. **`vm.warp(startTime - 1 hours)` unconditionally**, in either direction, then let the `BuildOrder` pre-condition (`block.timestamp < startTime`) do its job before item 3 warps into the window. Do **not** make this conditional on `block.timestamp < startTime`: the committed `settings.json` window goes stale by construction (Step 7), and a one-sided warp means a stale committed value reverts `BuildOrder`'s pre-condition and takes `yarn verify:redemption` — a Definition-of-Done item — down with it. `vm.warp` moves fork time backwards as happily as forwards; this makes the Verify script indifferent to how stale the committed window is, while leaving the hard revert intact on the broadcast path.
  2. Prank the deployer → run the `Distribute` logic. Assert `totalSupply == sum(included snapshot balances)` and `owner() == address(0)`. **Log gas for the single `mintBatch`.**
  3. Prank the treasury (`vm.deal(treasury, 1 ether)` for gas). `deal(USDS, treasury, usdsOffer)` **only if** the fork's real balance is short — it is ~1.2M USDS on a current fork, so normally assert the real balance instead of faking it. Run the `BuildOrder` logic → `USDS.approve` + `Seaport.validate`. Assert `getOrderStatus(orderHash)` → `isValidated == true`, `isCancelled == false`, `totalFilled == 0`.
  4. Prank a sample snapshot holder → approve Seaport for ESPN and REDEMPTION → `fulfillAdvancedOrder` with `denominator = fillGrid` and a **realistic derived** numerator from `BuildOrderLib.deriveNumerator(espnBal, redemptionBal, espnAsk, redemptionAsk, fillGrid)` — the REDEMPTION-bound `min`, per Step 18(c). **Not** `floor(holderBalance * fillGrid / espnAsk)`: that asks for 5× the REDEMPTION the holder owns and reverts on insufficient balance. And **not** a convenient round fraction like `1/10` — a round fraction happens to divide and would mask the entire `InexactFraction` class of bug the grid exists to prevent. Assert before filling that the holder can actually afford both legs, so a numerator regression fails with a legible message rather than a Seaport transfer revert.
  5. Assert **exact** balance deltas: holder USDS `+usdsOffer*n/D`, holder ESPN `−espnAsk*n/D`, holder REDEMPTION `−redemptionAsk*n/D`, and the treasury's mirror image. Assert `getOrderStatus`'s `totalFilled`/`totalSize` reflect the fraction.
  6. A **second partial fill by a second holder at a different numerator** over the same `fillGrid` denominator. This proves `PARTIAL_OPEN` fractions are taken against the **original** order size (not the remainder) and that no cross-scaling occurs.
  7. A **deliberate over-large fill** whose numerator exceeds the remainder, proving Seaport's clamp still divides exactly on the grid. This is the regression test for the dust-tail failure.
  8. A **negative test**: a fill with a non-grid denominator expected to revert `InexactFraction`, documenting the constraint the run-book warns about. Use `vm.expectRevert`. **Derive the denominator, do not hardcode `7`.** At the current NAV `7` happens to work — `usdsOffer % 7 == 0` and the snapped `espnAsk % 7 == 1`, so only the ESPN item forces the revert — and that depends entirely on live NAV at run time. At a different NAV the test can silently stop testing anything. Instead loop the small primes (3, 7, 11, 13, 17, …) and pick the first `d` that divides **none** of `usdsOffer`, `espnAsk`, `redemptionAsk`; `require` that such a `d` was found, and log it.
  9. Run the `Cancel` logic → assert `isCancelled == true` and `USDS.allowance(treasury, Seaport) == 0`.
  10. **Log gas for a single fulfilment.**

  Pick the sample holders from the committed snapshot JSON at runtime — the two largest non-contract, non-excluded balances — rather than hardcoding addresses that may have moved. This is why Task 4 depends on Task 3, not merely on Tasks 1 and 2.

- [x] **Step 23: Gas logging format, and verify Task 4**

  Both Verify scripts log through `console2`. The measurement caveat must be honoured, not glossed: `gasBefore - gasleft()` inside a single script frame measures **execution gas only** — it excludes the transaction's 21,000 intrinsic cost and its calldata cost. For one `mintBatch` that understates the real figure by roughly 21k + 170 × (20 bytes × 16 gas) ≈ **~76k**: small against ~4.5M, and acceptable **if stated**.

  So log two lines per measurement:

  ```
  mintBatch execution gas: <n>
  mintBatch total estimated (execution + 21000 intrinsic + calldata): <n>
  ```

  This caveat is precisely why `mintBatch` replaced the 170-transaction loop — for the loop the excluded overhead (~3.6M) would have been the *dominant* term and the whole deliverable would have been worthless.

  **Decision rule to record in the run-book:** if measured `mintBatch` gas exceeds **~15M**, split into chunks of 100 and record the loss of atomicity. At ~170 holders it will not.

  **Verify Task 4:** `forge build` clean, `forge fmt --check` clean, `yarn test` green (now including `test/unit/BuildOrderLibTest.sol`), and `SNAPSHOT_BLOCK=<block from the holders filename> yarn verify:redemption` completes with every assertion passing and both gas figures printed. Then `git status` must be **clean** — a Verify run that dirtied `deploymentAddresses.json` or wrote a Safe batch file is a failure of Steps 19-21's structural rule, not a pass.

---

## Task 5: Track B — migration to a yield-paying token (`004-stry-migration`)

Depends on Tasks 1, 2 **and 3** — `Verify.s.sol` needs Task 3's committed holders JSON and pins the fork to its `snapshotBlock`. Shares no *static* files with Task 4; imports Task 1's libs only. The one shared **runtime** write is `deploymentAddresses.json` (`.stry` here; `.espn-redemption-token` in Task 4) — see the dependency-order section: `writeDeployedAddress` stays out of every `internal` function `Verify.s.sol` calls, and the two `Distribute` scripts are only ever broadcast serially.

**Files:**
- `script/deployments/1/004-stry-migration/StopEspnYield.s.sol`
- `script/deployments/1/004-stry-migration/Distribute.s.sol`
- `script/deployments/1/004-stry-migration/interfaces/IMerklDistributionCreator.sol`
- `script/deployments/1/004-stry-migration/MerklCampaignLib.sol`
- `script/deployments/1/004-stry-migration/WeeklyYield.s.sol`
- `script/deployments/1/004-stry-migration/Verify.s.sol`

---

- [x] **Step 24: Write `StopEspnYield.s.sol`**

  One-time, and **first in the global operational sequence** — it changes NAV, and every later formula must read the final NAV. Never broadcasts; emits a Safe batch.

  What `increaseAssetsPerShare` actually does, verified against `src/EthStrategyPerpetualNote.sol:57-63`:

  ```solidity
  SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);  // caller pays
  SafeERC20.safeTransfer(IERC20(asset()), manager, assets);                        // forwarded out
  _totalAssets += assets;                                                          // bookkeeping only
  emit AssetsPerShareIncreased(msg.sender, _totalAssets, assets);
  ```

  Therefore:

  - Pre-assert `ESPN.asset() == USDS` (same rationale as Step 20 — the two addresses are hand-copied and nothing else checks they relate).
  - Pre-assert `USDS.balanceOf(payer) >= finalYieldAmount` — the caller must hold **and** approve it.
  - **Pre-assert `ESPN.manager() == 0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`** — a hard equality against the recorded address, not merely `!= address(0)` plus a log. The entire "real outflow to a third party, must be budgeted" warning (Assumption 3) rests on that identity, and `manager` is **owner-settable**, so a silent change turns a budgeted payment into a payment to somewhere else. Revert message: `manager changed from the recorded address — re-confirm Assumption 3 (who receives finalYieldAmount) before updating this constant.` Log the address prominently either way. It is a **contract, and not the redemption multisig**: `finalYieldAmount` USDS leaves the treasury and lands at a third party. This is a real outflow, not a round trip, and the signer must see it.
  - Emit the 2-transaction Safe batch: `USDS.approve(ESPN, finalYieldAmount)` then `ESPN.increaseAssetsPerShare(finalYieldAmount)`, to `script/deployments/1/multisig/004-stry-migration/001-0x0cbe9bDD-multisig.json`. Both as raw-calldata `abi.encodeCall` transactions (Step 10).
  - Post-conditions (asserted in `Verify.s.sol`, since this script does not execute): `totalAssets()` increased by **exactly** `finalYieldAmount`, and `AssetsPerShareIncreased` fired. **Beware the event's field names** — the signature is `AssetsPerShareIncreased(address indexed caller, uint256 newAssetsPerShare, uint256 delta)` but the contract passes post-increment `_totalAssets` into the `newAssetsPerShare` slot (line 62). Any assertion on that field must expect **total assets**, not a per-share figure.

  Record in the log output that this "stop" is a **policy, not an on-chain state change**: `increaseAssetsPerShare` is `external` with **no access control**, so anyone can keep raising NAV afterwards, including while the redemption order is live (Assumption 3). The order's amounts are fixed at validate time and do not follow NAV.

- [x] **Step 25: Write `Distribute.s.sol` (STRY)**

  Same single-`mintBatch` pattern as Track A. One broadcast:

  1. `HoldersLib.load` + `included`, same `HOLDERS_FILE` env input.
  2. `new StryToken(deployer)`.
  3. Read **live** `ESPN.totalAssets()` / `ESPN.totalSupply()` and `basisPriceUsd` (unscaled `100`) from settings. Per included holder:

     ```
     stryAmount_i = espnBalance_i * totalAssets / (totalSupply * basisPriceUsd)
     ```

     At the block-25,800,591 NAV this yields ~38,786.53 STRY total (~3,878,653 USDS ÷ $100). Read NAV **live**; the snapshot JSON no longer carries a `navPerEspn` field to be tempted by (Step 15 item 7).

  4. One `mintBatch`, then `renounceOwnership()`, then `ConfigLib.writeDeployedAddress(".stry", …)`. **Same structural rule as Step 19:** items 1-3 and the assertions go in an `internal` function; `writeDeployedAddress` is called only from `run()`, so `yarn verify:migration` never dirties the committed `deploymentAddresses.json`.
  5. **Calibration assertion with the correct tolerance.** Each per-holder division truncates up to 1 wei of STRY; multiplied back by `basisPriceUsd = 100`, that is up to **100 wei of USDS per holder**, so over ~170 holders the tolerance is `holderCount * basisPriceUsd` wei ≈ **17,000 wei** — not "1 wei per holder":

     ```
     espnBackingRepresented = sum(includedBalances) * totalAssets / totalSupply
     require(totalSupply(STRY) * basisPriceUsd <= espnBackingRepresented);                                   // truncation only undershoots
     require(espnBackingRepresented - totalSupply(STRY) * basisPriceUsd <= holderCount * basisPriceUsd);
     ```

     Excluded holders' backing is deliberately not claimed, which is why the left side sums **included** balances only.

  6. Log `mintBatch` gas in the Step 23 two-line format.

  **Record in the script's log output and in the run-book:** per Assumption 7 / option 2, **$100 is a nominal basis price, not a redemption guarantee.** Both tracks lay claim to the same ~$3.878M of ESPN backing — Track A pays out up to 700,000 USDS of it, Track B mints STRY nominally claiming the full amount, an overstatement of ~18% if both ship off one snapshot. The spec defaults to option 2 and requires the nominal-basis caveat to appear wherever the $100 figure does. Do not print "$100 backed".

- [ ] **Step 27: Write `WeeklyYield.s.sol` (repeatable, manually triggered)**

  Superseded. `WeeklyYield.s.sol` no longer transfers USDS to a staking contract; it emits
  a Safe batch creating a weekly Merkl campaign. See the Architecture section of
  [`../specs/2026-09-04-stry-merkl-yield-design.md`](../specs/2026-09-04-stry-merkl-yield-design.md)
  and Task 3 of [`2026-09-04-stry-merkl-yield-plan.md`](2026-09-04-stry-merkl-yield-plan.md).

- [ ] **Step 28: Write `Verify.s.sol` (Track B, mainnet fork)**

  Same harness as Track A: `contract Verify is Script, StdCheats, StdAssertions`, `vm.startPrank` not `vm.startBroadcast`, calling the scripts' `internal` entry points and never their `run()`s, so no config or Safe batch file is written. Same fork-block check as Step 22 item 0 (`require(block.number >= snapshotBlock)`, warn if not equal).

  1. Run the `StopEspnYield` logic first (prank the payer, `deal` USDS, approve + `increaseAssetsPerShare`). Assert `totalAssets()` delta equals `finalYieldAmount` **exactly**, and assert the USDS landed at `ESPN.manager()` — the point is to make the third-party outflow visible in test output, not merely to pass.
  2. Distribute STRY (single `mintBatch`) → assert the calibration invariant with the `holderCount * basisPriceUsd` wei tolerance; assert `owner() == address(0)`; **log `mintBatch` gas** in the Step 23 format.
  3. Superseded by the Testing approach of [`../specs/2026-09-04-stry-merkl-yield-design.md`](../specs/2026-09-04-stry-merkl-yield-design.md) items 3–10, implemented in Tasks 3 and 4 of [`2026-09-04-stry-merkl-yield-plan.md`](2026-09-04-stry-merkl-yield-plan.md).

  If `finalYieldAmount` is still `"0"` in settings, step 1 must still run and assert a zero delta rather than being skipped — a skipped step is an untested step.

  **Verify Task 5:** `forge build` clean, `forge fmt --check` clean, and `SNAPSHOT_BLOCK=<block> yarn verify:migration` **passes end to end, with gas printed** — there is no accepted early-exit. `git status` clean afterwards.

---

## Task 6: Operator run-book

There is **no UI**. This document is the entire holder-facing and operator-facing interface for the whole project. Depends on Tasks 4 and 5 for the numbers it quotes.

**Files:**
- `docs/ESPNv3_Runbook.md`

---

- [x] **Step 29: Write `docs/ESPNv3_Runbook.md`**

  Follow the naming style already used in `docs/` (`ESPN_User_Stories.md`, `StakedStrat_User_Stories.md`). Sections:

  1. **Open assumptions — must be closed before any non-fork broadcast.** Reproduce the spec's list 1-13 as a checklist, with 1 (treasury multisig), 4 (tripwire controller — **blocks Track B**), 7 (cross-track reconciliation), 8 (`depositCap` wide open at 1e26, so anyone can mint new ESPN after the snapshot and change `totalSupply()`, which both tracks' formulas read) and 9 (700k is the binding cap ⇒ FCFS) called out as the ones that gate the schedule.
  2. **Mandated global sequence.** Running these out of order silently prices the two airdrops off two different NAVs:

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

     Note why step 1 precedes step 5: `usdsOffer` is pinned at `targetRedemptionUsd` regardless of NAV, so the treasury's USDS outlay is bounded either way; what a higher NAV changes is `espnAsk` — the treasury reclaims **less ESPN** for the same 700k. That is the honest price, and it is why the yield stop must not land in the middle of the redemption window. Note why step 8's order matters: yield deposited with zero stakers is destroyed permanently.

  3. **The holder fill instructions**, verbatim from Step 20's logged block, with the actual `espnAsk` / `redemptionAsk` / `usdsOffer` / order hash filled in after `BuildOrder.s.sol` runs. Lead with the sentence holders most need: **you can redeem at most 20% of your ESPN** — REDEMPTION was airdropped 1:1 with ESPN and the order consumes 5 REDEMPTION per ESPN, so your REDEMPTION balance, not your ESPN balance, sets the maximum (Step 18(c)). Print the `min(...)` numerator formula, not the ESPN-only one. State plainly that `denominator` must be `1000000000` (the JSON key is `fillGrid`; `FILL_GRID` is only the Solidity constant name — use one spelling per audience and do not mix them), that any other denominator will most likely revert `InexactFraction`, that holders must approve **Seaport directly** (no conduit) for both ESPN and REDEMPTION, and that sub-grid dust is retained rather than redeemable.
  4. **What "pro-rata" does and does not mean.** Capacity is capped at 700,000 USDS and is **first-come-first-served**, not a guaranteed per-holder entitlement — and in practice the pool is unlikely to be exhausted: theoretical ex-treasury capacity is only ~704,392 USDS (0.6% headroom), REDEMPTION held by contracts that cannot call `approve` / `fulfillAdvancedOrder` (LP pairs above all) is permanently stranded and comes off that figure, and each holder is capped at 20% of their ESPN. Quote both the `usableRedemption` and `reachableRedemption` figures `BuildOrder.s.sol` logs (Step 20). REDEMPTION is a plain freely-transferable ERC20 and the order is `PARTIAL_OPEN` with no zone, so anyone — including non-holders who buy REDEMPTION from apathetic holders and ESPN from the LP — can consume capacity ahead of snapshot holders. This is accepted, not a bug; a zone is explicitly out of scope.
  5. **Measured gas numbers** from both Verify runs, with the execution-gas caveat stated, and the ">15M ⇒ chunk into 100s" decision rule.
  6. **Safe batch files**: where each is written, that `checksum` is null and the operator re-derives it on import, that each transaction is **raw calldata** (`"data": "0x…"`, `"contractMethod": null`) so the Transaction Builder shows no decoded parameters — the signer verifies the `to` address and the selector, and the batch's counterpart assertions in the Verify runs are the proof of the payload — and the order the two transactions in each batch must execute in.
  7. **Operator env quick-reference**: the snapshot script's env vars (`RPC_URL`, `SNAPSHOT_BLOCK`, `ESPN_ADDRESS`, `SETTINGS_PATH`), `yarn snapshot:espn` / `yarn snapshot:selftest`, what an invariant failure means, and the rule that **the snapshot block lives only in the output filename and body — never in `settings.json`**. Also: export `SNAPSHOT_BLOCK` (read off the holders filename) before `yarn verify:redemption` / `yarn verify:migration` so both fork runs pin to the snapshot block. This section replaces the `script/snapshot/README.md` an earlier draft proposed — one document, not two to keep in sync.
  8. **Resetting the order window before broadcast.** `settings.json` ships `orderStartTime` / `orderEndTime` as a future-dated placeholder (2027-01-01 → 2027-01-08). They must be edited to the real window before `BuildOrder.s.sol` is run for broadcast; the script hard-reverts if `orderStartTime <= block.timestamp`, which is the forcing function. Fork verification is immune — Step 22 warps unconditionally.
  9. **Track B holder notes**: approve **STRY** not the position token; the position token is non-transferable; `unstake` takes an amount argument; the instance is cosmetically named `"Staked STRAT v2"`; a tripwire trip locks staked STRY in until untripped; `$100 is a nominal basis price, not a redemption guarantee`.

---

## Definition of done

- `forge build` and `FOUNDRY_PROFILE=integration forge build` both clean.
- `yarn test` green (includes the two token test files, `ScriptLibsTest` and `BuildOrderLibTest`).
- `forge fmt --check` clean (a pre-existing CI blocker in this repo — see `c98c2a2`).
- `yarn snapshot:selftest` exits 0 offline.
- `SNAPSHOT_BLOCK=<block> yarn verify:redemption` passes every assertion, including the `InexactFraction` negative test (with a **derived** denominator) and the over-large-fill clamp test, and prints both gas figures.
- `SNAPSHOT_BLOCK=<block> yarn verify:migration` **passes end to end** — see the Definition of done in [`2026-09-04-stry-merkl-yield-plan.md`](2026-09-04-stry-merkl-yield-plan.md).
- `git status` is clean after both verify runs — neither writes `deploymentAddresses.json` or a Safe batch file.
- A real snapshot JSON is committed and its `sum(balances) == totalSupply` invariant passed.
- `settings.json`'s `orderStartTime` is in the **future** relative to the commit date.
- `docs/ESPNv3_Runbook.md` exists with the real order hash and gas numbers filled in.
- No dependency on `stoke`. No `dependencies` block in `package.json`. No changes to `src/EthStrategyPerpetualNote.sol`, or any other existing contract.

---

## Review findings deliberately not applied

Two independent reviews were folded into this plan. Everything else they raised was applied. These three were not, with reasons:

1. **"Split Task 1 into a mechanical half and a code half (two tasks)."** Not split. The task count stays at six and the file scopes stay strictly disjoint; the parallelism benefit is captured instead by the **1a / 1b internal ordering** documented in the dependency section, which unblocks Tasks 2 and 3 after Step 7 + 12 land. Splitting would put `ScriptLibsTest` (1b) in a different task from the config files it asserts against (1a), i.e. two reviewers for one contract.

2. **"Remove the two orphan `.gitmodules` entries."** Recorded as a verified fact in the corrections table and in Step 1, but not fixed. `git submodule update --init --recursive` iterates the index, so the orphans are inert; deleting them is unrelated churn on a branch that already touches `foundry.toml`, `remappings.txt` and `package.json`.

3. **"Assert `usableRedemption` excludes contract holders as a hard revert."** Applied as a **logged** figure (`reachableRedemption`, Step 20), not a revert. Which contracts can and cannot fulfil is a judgement the script cannot make — a Safe holding REDEMPTION can fill perfectly well — and turning it into a pre-condition would block a signable order on a heuristic. The signer sees both numbers and decides.
