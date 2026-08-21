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
| Submodules initialized | `git submodule status` shows `-` (uninitialized) for all three: `lib/forge-std`, `lib/halmos-cheatcodes`, `lib/openzeppelin-contracts`. `forge build` fails before anything else. | Step 1. |

**Folder numbering.** The plan uses `003-espn-redemption` and `004-stry-migration`, per the spec. `001`/`002` were consumed by the deleted stoke work; the numbering continues the historical sequence rather than reusing retired numbers.

---

## Task dependency order

```
Task 1 (prereqs + config + shared script libs)   ← blocking, land first
      ├── Task 2 (tokens + unit tests)           ┐
      ├── Task 3 (snapshot script)               ├─ independent of each other
      ├── Task 4 (Track A scripts)  ← needs 1,2  │
      └── Task 5 (Track B scripts)  ← needs 1,2  ┘
Task 6 (operator run-book)          ← needs 4,5 for the numbers it documents
```

Tasks 2 and 3 can run fully in parallel with each other. Tasks 4 and 5 can run in parallel with each other once 1 and 2 have landed (they share no files; both only *import* Task 1's libs).

---

## Task 1: Repo prerequisites, shared JSON config, shared script libraries

Nothing else in this plan compiles or runs until this task lands. It also owns every edit to `foundry.toml` and `package.json` for the whole project, so no later task touches those files.

**Files:**
- `foundry.toml` (edit)
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

- [ ] **Step 1: Initialize git submodules and confirm a clean baseline build**

  Run `git submodule update --init --recursive` (equivalently `forge install`). Then confirm `forge build` succeeds and `yarn test` passes **before** changing anything. If the baseline is already red, stop and report — do not fold a pre-existing failure into this task.

  Do not commit submodule pointer changes beyond what initialization requires; `.gitmodules` and the recorded SHAs are already correct.

- [ ] **Step 2: Grant filesystem permissions in `foundry.toml`**

  Current value grants write-only on `./tmp/` and therefore **no read access to anything**, so every `vm.readFile` in this project reverts. Replace:

  ```toml
  fs_permissions = [
      {access = "write", path = "./tmp/"},
      {access = "read-write", path = "./script/deployments/"},
  ]
  ```

  Leave `solc_version = "0.8.24"`, `via-ir = true`, `optimizer_runs`, `ffi = true`, `test = "test/unit"` and the `[profile.integration]` block untouched.

  Note for later tasks: `via-ir = true` makes the large `Verify.s.sol` scripts slow to compile. That is expected, not a bug.

- [ ] **Step 3: Delete the two orphaned integration tests**

  `test/integration/ESPNRedemptionQueueIntegrationTest.sol` imports `src/ESPNRedemptionQueue.sol` and `test/integration/MorphoBlueFlashLoanProviderIntegrationTest.sol` imports `src/MorphoBlueFlashLoanProvider.sol`. Both source contracts were deleted in `2d29ce6`; both are verified absent from `src/`. `FOUNDRY_PROFILE=integration forge test` currently fails to compile because of them.

  Delete both files. Keep `test/integration/esETHIntegrationTest.sol`.

  Verify: `FOUNDRY_PROFILE=integration forge build` compiles.

- [ ] **Step 4: Create `script/deployments/1/config/externalAddresses.json`**

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

- [ ] **Step 5: Create `script/deployments/1/config/internalAddresses.json`**

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

- [ ] **Step 6: Create `script/deployments/1/config/deploymentAddresses.json`**

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

- [ ] **Step 7: Create `script/deployments/1/config/settings.json`**

  **The unit convention is mandatory and is the single easiest thing to get wrong in this project.** The prior art's `"2900e18"` worked only because stoke shipped a custom parser; `vm.parseJsonUint` cannot parse `e18` notation. Therefore:

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
      "orderStartTime": "1787000000",
      "orderEndTime": "1787604800",
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
  - `orderStartTime` / `orderEndTime` are placeholders and **will be stale by the time anyone broadcasts**. `BuildOrder.s.sol` hard-reverts if `orderStartTime <= block.timestamp`, which is the intended forcing function.
  - `finalYieldAmount` is `"0"` pending a founder decision — it is a *policy* sum, not NAV-derived, which is why it is correctly in JSON. It leaves the treasury and lands at `ESPN.manager()` (`0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`, a third-party contract), so it must be budgeted (Assumption 3).
  - `excludedAddresses` is `[]` — **the airdrops exclude nothing by default**. Assumption 5 (LP pairs, the treasury, ESPN itself) is a founder decision.
  - `snapshotBlock` is deliberately **absent**. It lives only in the holders JSON filename and body (Task 3 Step 14).

- [ ] **Step 8: Write `script/deployments/1/lib/ConfigLib.sol`**

  A plain Solidity `library` with `internal` functions, `pragma ^0.8.24`, SPDX `MIT`. It gets the cheatcode address the standard way, since a library cannot inherit `Script`:

  ```solidity
  Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
  ```

  Public surface — keep it to exactly what the nine scripts need, nothing speculative:

  - `configRoot()` → `"script/deployments/1/config/"`.
  - `readJson(string memory fileName)` → `vm.readFile(string.concat(configRoot(), fileName))`.
  - `addr(string memory fileName, string memory key)` → `vm.parseJsonAddress(readJson(fileName), key)`.
  - `weiAmount(string memory fileName, string memory key)` → **`vm.parseUint(vm.parseJsonString(json, key))`**. This is the load-bearing one: the value is a quoted decimal string, so `vm.parseJsonUint` is the wrong call and will revert or misparse. Use `parseJsonString` then `parseUint`.
  - `number(string memory fileName, string memory key)` → `vm.parseJsonUint(json, key)`, for the unscaled JSON numbers (`redemptionRatio`, `fillGrid`, `basisPriceUsd`, `expectedSeaportCounter`).
  - `str(string memory fileName, string memory key)` → `vm.parseJsonString(json, key)`.
  - `addrArray(string memory fileName, string memory key)` → `vm.parseJsonAddressArray(json, key)`, for `excludedAddresses`. Must tolerate an empty array.
  - `writeDeployedAddress(string memory key, address value)` → `vm.writeJson(vm.toString(value), string.concat(configRoot(), "deploymentAddresses.json"), key)`.

  Convenience one-liners the scripts will each otherwise repeat — add these three and no more: `seaport()`, `usds()`, `espn()` reading from `externalAddresses.json`, and `treasury()` reading `.protocol.multisigs.redemption` from `internalAddresses.json`.

- [ ] **Step 9: Write `script/deployments/1/lib/HoldersLib.sol`**

  Reads the snapshot artifact produced by Task 3 and hands the distribute scripts arrays they can pass straight to `mintBatch`.

  ```solidity
  struct Holder { address addr; uint256 balance; bool isContract; bool excluded; }
  struct Snapshot { uint256 snapshotBlock; uint256 totalSupply; uint256 navPerEspn; Holder[] holders; }
  ```

  - `load(string memory path)` → reads the file, `vm.parseJson` into the struct, and **asserts the `snapshotBlock` in the body matches the number embedded in the filename** (spec: single source of truth). Extract the filename block by string-slicing between `"espn-holders-"` and `".json"`; `require` on mismatch with a message naming both values.
  - `included(Snapshot memory)` → `(address[] memory addrs, uint256[] memory balances, uint256 includedCount, uint256 excludedCount)`, filtering out `excluded == true`. `isContract` is **informational only** — it does not filter.
  - `sum(uint256[] memory)` → `uint256`.

  Field-ordering warning for the implementer: `vm.parseJson`'s ABI-decode path matches JSON object keys to struct fields **alphabetically**, not in declaration order. Either name the struct fields so alphabetical order matches, or decode field-by-field with `vm.parseJsonAddress`/`vm.parseJsonUint` on indexed paths (`.holders[0].address`, …). Whichever route is taken, the `ScriptLibsTest` in Step 11 must prove it round-trips a real fixture correctly — do not assume it works.

- [ ] **Step 10: Write `script/deployments/1/lib/SafeBatchLib.sol`**

  Neither `BuildOrder.s.sol`, `Cancel.s.sol` nor `StopEspnYield.s.sol` can broadcast — the sender is a Safe. Each emits a **Safe Transaction Builder JSON** batch instead. One shared writer, three call sites.

  Shape, matching the prior art (`git show 6484357:script/deployments/1/multisig/002-rage-quit-order/001-0x0cbe9bDD-multisig.json` for the exact reference):

  ```json
  { "version": "1.0", "chainId": "1", "createdAt": 0,
    "meta": { "name": "...", "description": "...", "txBuilderVersion": "2.0.1",
              "createdFromSafeAddress": "0x0cbe...", "checksum": null },
    "transactions": [ { "to": "0x...", "value": "0",
                        "contractMethod": { "inputs": [...], "name": "approve", "payable": false },
                        "contractInputsValues": { "spender": "0x...", "value": "..." } } ] }
  ```

  API:

  - `struct Tx { address to; string methodName; string inputsJson; string valuesJson; }` — `inputsJson` and `valuesJson` are pre-built JSON fragments supplied by the caller, so the library does no ABI introspection.
  - `write(address safe, string memory operation, uint256 index, string memory name, string memory description, Tx[] memory txs)` → builds the document with `string.concat` and writes it to `script/deployments/1/multisig/<operation>/<index padded to 3>-<first 10 chars of safe>-multisig.json`.

  **Emit `"checksum": null`.** The spec is explicit: the Transaction Builder accepts an absent/null checksum and the operator re-derives it on import. Do not attempt to reproduce Safe's checksum algorithm; do not block on it.

  `createdAt` may be `block.timestamp * 1000`. It is cosmetic.

- [ ] **Step 11: Write `test/unit/ScriptLibsTest.sol` and verify Task 1**

  One forge test file, run by the default profile. It is the runnable check for the three libraries — without it, a `vm.parseJson` struct-decoding mistake in `HoldersLib` surfaces for the first time inside a fork Verify script, where it is far more expensive to diagnose.

  Cover exactly:

  1. `ConfigLib.seaport()`, `.usds()`, `.espn()`, `.treasury()` return the four confirmed addresses from Step 4/5.
  2. `ConfigLib.weiAmount("settings.json", ".espnv3.targetRedemptionUsd") == 700_000e18`. This is the test that catches the `parseJsonUint`-vs-`parseUint` trap.
  3. `ConfigLib.number("settings.json", ".espnv3.basisPriceUsd") == 100` and `.fillGrid == 1_000_000_000`.
  4. `ConfigLib.addrArray("settings.json", ".espnv3.excludedAddresses").length == 0` (empty-array tolerance).
  5. `HoldersLib.load` against a small fixture written to `./tmp/espn-holders-123.json` by the test itself via `vm.writeFile` (`./tmp/` is already write-permitted; extend `fs_permissions` to `read-write` on `./tmp/` if the read side is needed). Assert the filename/body block-number cross-check fires on a deliberately mismatched fixture, and that `included()` drops `excluded: true` entries and preserves order.
  6. `SafeBatchLib.write` produces a file whose `.transactions[0].to` and `.meta.createdFromSafeAddress` parse back correctly.

  **Verify the whole task:** `forge build` clean; `yarn test` green; `FOUNDRY_PROFILE=integration forge build` clean; `forge fmt --check` clean.

- [ ] **Step 12: Add the `package.json` scripts**

  `foundry.toml` sets `test = "test/unit"` and `[profile.integration] test = "test/integration"`, so **`forge test` never picks up anything under `script/`**. Without named scripts, no Verify script in this project would ever be executed by `yarn test` or `yarn test:integration`. Add, reusing the fork URL default already present in `test:integration`:

  ```json
  "snapshot:espn": "node script/snapshot/espn-holders.mjs",
  "verify:redemption": "forge script script/deployments/1/003-espn-redemption/Verify.s.sol --fork-url ${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat} -vvv",
  "verify:migration": "forge script script/deployments/1/004-stry-migration/Verify.s.sol --fork-url ${FORK_URL:-https://mainnet.gateway.tenderly.co/2ykivsAa1llMFEFYtboaat} -vvv"
  ```

  Add **no** `dependencies` block. The snapshot script is zero-dependency by design (Task 3).

---

## Task 2: `EspnRedemptionToken` + `StryToken` contracts and unit tests

Two deliberately plain tokens. **Do not** use the `MintableBurnableToken` / `TripwireGuard` pattern that `StratToken`, `CdtToken` and `DesEthToken` use — the product ask is for something simple, and nothing here needs pausing, a minter allowlist, permit, or burn.

**Files:**
- `src/EspnRedemptionToken.sol`
- `src/StryToken.sol`
- `test/unit/EspnRedemptionTokenTest.sol`
- `test/unit/StryTokenTest.sol`

---

- [ ] **Step 13: Write `src/EspnRedemptionToken.sol` and `src/StryToken.sol`**

  Both files, complete:

  ```solidity
  // SPDX-License-Identifier: GPL-2.0-or-later
  pragma solidity ^0.8.20;

  import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
  import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

  contract EspnRedemptionToken is ERC20, Ownable {
      error LengthMismatch();

      constructor(address initialOwner) ERC20("ESPN Redemption", "ESPNR") Ownable(initialOwner) {}

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

  `StryToken` is byte-identical apart from the contract name and `ERC20("ETH Strategy Yield", "STRY")`. **Do not factor out a shared base contract.** The duplication is ~14 lines and keeping each token independently auditable is worth more than deduplicating it.

  Points that are load-bearing, not stylistic:

  - **`mintBatch`, not a loop of `mint()` calls.** `forge script --broadcast` sends one transaction per external call, so a `mint()` loop is ~170 separate transactions: not atomic, no resume story, ~3.6M gas of pure intrinsic overhead, and — because ownership is renounced immediately afterwards — a partial batch would leave holders permanently unmintable. `mintBatch` makes the airdrop one atomic transaction and makes the measured gas number meaningful. Expect ~4.5M gas for ~170 holders.
  - **18 decimals** (OZ default), matching ESPN, which the 1:1 airdrop depends on.
  - `pragma ^0.8.20` matches the rest of `src/`; `foundry.toml` pins `solc_version = "0.8.24"`.
  - Import paths use the `openzeppelin-contracts/` remapping already in `remappings.txt`.
  - Name/symbol for `EspnRedemptionToken` are **Assumption 11 — a placeholder pending founder confirmation**. `STRY` / `ETH Strategy Yield` were specified by the founder.

- [ ] **Step 14: Write `test/unit/EspnRedemptionTokenTest.sol` and `test/unit/StryTokenTest.sol`**

  Plain `forge-std/Test.sol`, no fork, following the shape of `test/unit/MintableBurnableTokenTest.sol` (SPDX `GPL-2.0-or-later`, `pragma ^0.8.20`, `contract … is Test`, `setUp()` deploying with an `owner` address constant).

  Both files cover the same list:

  1. `mint` by owner credits the recipient and moves `totalSupply`.
  2. `mint` by non-owner reverts `Ownable.OwnableUnauthorizedAccount(caller)` — assert with `vm.expectRevert(abi.encodeWithSelector(...))`, not a bare `vm.expectRevert()`.
  3. `mintBatch` by non-owner reverts the same way.
  4. `mintBatch` with mismatched array lengths reverts `LengthMismatch()`.
  5. **`mintBatch` with 170 entries** produces exactly the expected per-address balances and `totalSupply == sum(amounts)`. Generate the addresses deterministically (`address(uint160(i + 1))`); this both proves the loop and gives a first gas signal.
  6. `mint(address(0), …)` reverts `ERC20InvalidReceiver(address(0))`.
  7. Standard ERC20 behaviour: `transfer`, `approve` + `transferFrom`, `name()`, `symbol()`, and **`decimals() == 18`** (asserted, not assumed — four formulas downstream hardcode `1e18`).
  8. After `renounceOwnership()`, both `mint` and `mintBatch` revert `OwnableUnauthorizedAccount`.
  9. `mintBatch` with empty arrays is a no-op that does not revert.

  **Verify:** `yarn test` green, `forge fmt --check` clean.

---

## Task 3: ESPN holder snapshot script

Off-chain, Node ≥18, **zero dependencies** — Node 18's global `fetch` covers every JSON-RPC call. `viem` was proposed in the brainstorm and is **dropped**: it was justified as covering "log-fetching and hashing", there is no merkle tree so nothing needs hashing, and `package.json` currently has `devDependencies` only. Do not add a `dependencies` block.

**Files:**
- `script/snapshot/espn-holders.mjs`
- `script/snapshot/README.md`

---

- [ ] **Step 15: Write `script/snapshot/espn-holders.mjs`**

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
       "navPerEspn": "111469817424243522517",
       "holders": [ { "address": "0x...", "balance": "...", "isContract": false, "excluded": false } ] }
     ```

     `navPerEspn = totalAssets * 10n**18n / totalSupply`, both read at `snapshotBlock`. It is recorded for reference only — **every consuming Solidity script re-reads NAV live at broadcast time and must never use this field for an amount calculation.**

  8. Print a summary to stderr: block, holder count, contract count, excluded count, total supply, NAV.

  Keep it one file. No CLI-argument framework, no logger, no retry library.

- [ ] **Step 16: Write `script/snapshot/README.md` and run the script**

  Short operator doc: the env vars, `yarn snapshot:espn`, what the invariant failure means, and the rule that **the snapshot block lives only in the output filename and body — never in `settings.json`**, and that both tracks must use the same block (subject to Assumption 7 option 1).

  Then **actually run it** against a mainnet RPC at a finalized block and commit the resulting `script/deployments/1/config/espn-holders-<block>.json`. It is a generated artifact, so it is not listed in this task's file list, but Tasks 4 and 5's Verify scripts need a real holders file with addresses that genuinely hold ESPN on a fork — a hand-written fixture cannot fulfil a Seaport order.

  **Verify:** the script exits 0, the invariant passes, holder count is ~170, and the committed JSON parses. Then deliberately break it — pass `SNAPSHOT_BLOCK` equal to head — and confirm it exits non-zero on the reorg guard.

---

## Task 4: Track A — pro-rata capped redemption (`003-espn-redemption`)

Depends on Tasks 1 and 2. Reference reading before starting: `git show 6484357:script/deployments/1/002-rage-quit-order/BuildOrderLib.sol`, `…/Verify.s.sol`, and **`git show 95ff244:test/forge/seaport/README.md`** — particularly its "Numerator / denominator constraints", "Public fillability" and "MEV / fill competition" sections. Replicate the *shape*; use **none** of the `stoke` imports.

**Files:**
- `script/deployments/1/003-espn-redemption/interfaces/ISeaportMinimal.sol`
- `script/deployments/1/003-espn-redemption/BuildOrderLib.sol`
- `script/deployments/1/003-espn-redemption/Distribute.s.sol`
- `script/deployments/1/003-espn-redemption/BuildOrder.s.sol`
- `script/deployments/1/003-espn-redemption/Cancel.s.sol`
- `script/deployments/1/003-espn-redemption/Verify.s.sol`

---

- [ ] **Step 17: Revive `interfaces/ISeaportMinimal.sol`**

  Copy verbatim from `git show 6484357:script/deployments/1/002-rage-quit-order/interfaces/ISeaportMinimal.sol`. It is already exactly the surface this project needs: `ItemType`/`OrderType`/`Side` enums, `OfferItem`, `ConsiderationItem`, `OrderParameters`, `OrderComponents`, `AdvancedOrder`, `CriteriaResolver`, `Order`, plus `getCounter`, `getOrderHash`, `getOrderStatus`, `information`, `cancel`, `incrementCounter`, `fulfillAdvancedOrder`, `validate`, and the `OrderIsCancelled` error.

  Do not extend it. `pragma ^0.8.24`, SPDX `MIT`, as in the original.

  Note the two struct types that differ by one field: `OrderParameters` ends with `totalOriginalConsiderationItems` (used by `validate`/`fulfillAdvancedOrder`), `OrderComponents` ends with `counter` (used by `getOrderHash`/`cancel`). Mixing them up produces a wrong order hash that will not be caught until a fill fails.

- [ ] **Step 18: Write `BuildOrderLib.sol` — order construction and the fill grid**

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

  The fix: snap every amount down to a multiple of `FILL_GRID = 1e9`, and mandate `denominator = FILL_GRID` for all fills. If every item amount is a multiple of `fillGrid`, then `amount * n` is a multiple of `fillGrid` for **any** integer `n ≤ fillGrid`, so `_getFraction` is exact at every numerator. Two consequences come free: the **final tranche is fillable** (Seaport clamps `numerator = denominator - filledNumerator`, still an integer `< fillGrid`, so no permanently-unfillable dust tail strands the end of the 700k), and **no uint120 cross-scaling** ever occurs, so no fill can revert because of an earlier fulfiller's denominator choice.

  Accepted costs, all to be stated in the run-book: snapping loses < 1e9 wei per item (negligible against 700,000e18); one grid unit ≈ 0.0000063 ESPN ≈ $0.0007, so a holder with less than that cannot fill; each holder rounds **down** to `n = floor(myEspn * fillGrid / espnAsk)` and retains sub-grid dust; a fulfiller who ignores the convention either reverts `InexactFraction` or triggers cross-scaling — there is no zone, so the convention cannot be enforced on-chain, and the mitigation is that the naive attempt reverts rather than succeeding badly.

- [ ] **Step 19: Write `Distribute.s.sol`**

  Plain `forge-std/Script`, `pragma ^0.8.24`. One broadcast (`vm.startBroadcast()` / `vm.stopBroadcast()`), holders-file path from env `HOLDERS_FILE`:

  1. `HoldersLib.load(holdersFile)`, then `HoldersLib.included(...)`.
  2. `new EspnRedemptionToken(deployer)`.
  3. **One** `mintBatch(addrs, balances)` call — 1:1 with snapshot ESPN balances. Wrap it in `gasBefore = gasleft()` / `gasAfter = gasleft()`.
  4. `renounceOwnership()` in the same broadcast (Assumption 10).
  5. `ConfigLib.writeDeployedAddress(".espn-redemption-token", address(token))`.
  6. Log holder count, excluded count, total minted, and gas (see Step 23 for the gas-logging format).

  In-script post-conditions, asserted with `require`: `totalSupply() == HoldersLib.sum(balances)`; `owner() == address(0)`; and a loop asserting `balanceOf(addrs[i]) == balances[i]` for **every** included holder (170 view calls cost nothing in a script and this is the cheapest possible proof the airdrop is right).

- [ ] **Step 20: Write `BuildOrder.s.sol`**

  **Never broadcasts.** The offerer is a Safe. It computes, asserts, logs, and emits a Safe batch.

  1. Read addresses and settings via `ConfigLib`; read `REDEMPTION` from `deploymentAddresses.json`.
  2. Read live `ESPN.totalAssets()` / `ESPN.totalSupply()`; call `BuildOrderLib.deriveAmounts`.
  3. **Pre-conditions.** These replace the vacuous `redemptionAsk <= REDEMPTION.totalSupply()` from an earlier draft, which passes by 5× at any plausible NAV and detects nothing:
     - **Hard revert:** `USDS.balanceOf(treasury) >= usdsOffer`. The treasury holds ~1,199,676 USDS today, comfortably above 700,000 — assert it anyway, never assume. `ESPN.totalAssets()` is bookkeeping, not a balance; the vault itself holds ~0.005 USDS because `_deposit` and `increaseAssetsPerShare` forward every asset straight to `manager`.
     - **Hard revert:** `USDS.decimals() == 18 && ESPN.decimals() == 18 && REDEMPTION.decimals() == 18`.
     - **Hard revert:** `Seaport.getCounter(treasury) == expectedSeaportCounter` from settings (currently `0`). If the multisig ever increments its counter, every previously validated order silently dies; the counter feeds the order hash anyway.
     - **Hard revert:** `usdsOffer % fillGrid == 0 && espnAsk % fillGrid == 0 && redemptionAsk % fillGrid == 0`.
     - **Hard revert:** `block.timestamp < startTime` and `startTime < endTime`. Absolute timestamps in a committed JSON go stale between authoring and broadcast; this is the intended forcing function.
     - **Logged, not reverted:** `usableRedemption = REDEMPTION.totalSupply() - REDEMPTION.balanceOf(treasury) - sum(REDEMPTION.balanceOf(x) for x in excludedAddresses)`; log `usableRedemption / redemptionRatio * navPerEspn / 1e18` next to `usdsOffer` so the signer can see **which side binds** before signing. At current numbers the offer binds (700,000 vs ~704,396).
  4. Build the order via `BuildOrderLib.constructOrderParams` with `offerer = treasury`, offer `[USDS, usdsOffer]`, consideration `[[REDEMPTION, redemptionAsk, treasury], [ESPN, espnAsk, treasury]]`.
  5. Compute and log the order hash: build `OrderComponents` (same fields but `counter = Seaport.getCounter(treasury)` in place of `totalOriginalConsiderationItems`) and call `Seaport.getOrderHash`.
  6. Log the **holder run-book block** verbatim — there is no UI, so this text is the entire holder-facing interface:

     ```
     denominator = 1000000000
     numerator   = floor(yourEspnBalance * 1000000000 / <espnAsk>)
     you pay     : espnAsk * n / 1e9 ESPN  and  redemptionAsk * n / 1e9 REDEMPTION
     you receive : usdsOffer * n / 1e9 USDS
     approve Seaport (0x0000000000000068F116a894984e2DB1123eB395) for both amounts first
     ```

  7. Emit the **2-transaction Safe batch** via `SafeBatchLib.write` to `script/deployments/1/multisig/003-espn-redemption/001-0x0cbe9bDD-multisig.json`: `USDS.approve(Seaport, usdsOffer)` **then** `Seaport.validate([order])`. The approval is a separate transaction from `validate` and must be in the same Safe execution.

  Expose the derivation and order-construction as `internal` functions so `Verify.s.sol` can call them under a prank rather than duplicating the logic.

- [ ] **Step 21: Write `Cancel.s.sol`**

  Also never broadcasts. Rebuilds **identical** order components from the same config so the cancelled hash provably matches the validated one, asserts the recomputed hash equals the hash logged by `BuildOrder.s.sol` (passed in via env `EXPECTED_ORDER_HASH`), then emits a 2-transaction Safe batch to `script/deployments/1/multisig/003-espn-redemption/002-0x0cbe9bDD-multisig.json`:

  1. `Seaport.cancel([orderComponents])`
  2. `USDS.approve(Seaport, 0)`

  The second transaction is not optional. The USDS allowance survives order expiry, and leaving a live 700,000 USDS allowance to Seaport after the window is a standing risk with no upside.

  Because NAV moves, rebuilding from live NAV would produce a *different* hash than the validated order. `Cancel.s.sol` must therefore reconstruct the amounts from `EXPECTED_ORDER_HASH`'s originals — take `usdsOffer`, `espnAsk` and `redemptionAsk` as explicit env inputs (the values `BuildOrder.s.sol` logged), derive nothing from live NAV, and let the hash assertion be the proof they are right.

- [ ] **Step 22: Write `Verify.s.sol` (Track A, mainnet fork)**

  `contract Verify is Script, StdCheats, StdAssertions` — a `Script` inherits only `StdCheatsSafe`, so `deal` and `assertEq` need the explicit imports. Use `vm.startPrank`/`vm.stopPrank`, **not** `vm.startBroadcast`, for impersonation: broadcast signs with a key and cannot act as a Safe; prank can.

  Sequence, in order:

  1. `vm.warp` into the order window if `block.timestamp < startTime`. A fork pinned before `startTime` otherwise fails at fulfilment for a reason unrelated to the code.
  2. Prank the deployer → run the `Distribute` logic. Assert `totalSupply == sum(included snapshot balances)` and `owner() == address(0)`. **Log gas for the single `mintBatch`.**
  3. Prank the treasury (`vm.deal(treasury, 1 ether)` for gas). `deal(USDS, treasury, usdsOffer)` **only if** the fork's real balance is short — it is ~1.2M USDS on a current fork, so normally assert the real balance instead of faking it. Run the `BuildOrder` logic → `USDS.approve` + `Seaport.validate`. Assert `getOrderStatus(orderHash)` → `isValidated == true`, `isCancelled == false`, `totalFilled == 0`.
  4. Prank a sample snapshot holder → approve Seaport for ESPN and REDEMPTION → `fulfillAdvancedOrder` with `denominator = fillGrid` and a **realistic derived** `numerator = floor(holderBalance * fillGrid / espnAsk)`. **Not** a convenient round fraction like `1/10` — a round fraction happens to divide and would mask the entire `InexactFraction` class of bug the grid exists to prevent.
  5. Assert **exact** balance deltas: holder USDS `+usdsOffer*n/D`, holder ESPN `−espnAsk*n/D`, holder REDEMPTION `−redemptionAsk*n/D`, and the treasury's mirror image. Assert `getOrderStatus`'s `totalFilled`/`totalSize` reflect the fraction.
  6. A **second partial fill by a second holder at a different numerator** over the same `fillGrid` denominator. This proves `PARTIAL_OPEN` fractions are taken against the **original** order size (not the remainder) and that no cross-scaling occurs.
  7. A **deliberate over-large fill** whose numerator exceeds the remainder, proving Seaport's clamp still divides exactly on the grid. This is the regression test for the dust-tail failure.
  8. A **negative test**: a fill with a non-grid denominator (e.g. `7`) expected to revert `InexactFraction`, documenting the constraint the run-book warns about. Use `vm.expectRevert`.
  9. Run the `Cancel` logic → assert `isCancelled == true` and `USDS.allowance(treasury, Seaport) == 0`.
  10. **Log gas for a single fulfilment.**

  Pick the sample holders from the committed snapshot JSON at runtime — the two largest non-contract, non-excluded balances — rather than hardcoding addresses that may have moved.

- [ ] **Step 23: Gas logging format, and verify Task 4**

  Both Verify scripts log through `console2`. The measurement caveat must be honoured, not glossed: `gasBefore - gasleft()` inside a single script frame measures **execution gas only** — it excludes the transaction's 21,000 intrinsic cost and its calldata cost. For one `mintBatch` that understates the real figure by roughly 21k + 170 × (20 bytes × 16 gas) ≈ **~76k**: small against ~4.5M, and acceptable **if stated**.

  So log two lines per measurement:

  ```
  mintBatch execution gas: <n>
  mintBatch total estimated (execution + 21000 intrinsic + calldata): <n>
  ```

  This caveat is precisely why `mintBatch` replaced the 170-transaction loop — for the loop the excluded overhead (~3.6M) would have been the *dominant* term and the whole deliverable would have been worthless.

  **Decision rule to record in the run-book:** if measured `mintBatch` gas exceeds **~15M**, split into chunks of 100 and record the loss of atomicity. At ~170 holders it will not.

  **Verify Task 4:** `forge build` clean, `forge fmt --check` clean, and `yarn verify:redemption` completes with every assertion passing and both gas figures printed.

---

## Task 5: Track B — migration to a yield-paying token (`004-stry-migration`)

Depends on Tasks 1 and 2. Shares no files with Task 4; imports Task 1's libs only.

**`src/StakedStrat.sol` gets ZERO code changes.** Its constructor is already generic: `constructor(address _stratToken, address _rewardToken, ITripwireController controller_, address guardian_)`. Track B deploys a **new instance**.

**Files:**
- `script/deployments/1/004-stry-migration/StopEspnYield.s.sol`
- `script/deployments/1/004-stry-migration/Distribute.s.sol`
- `script/deployments/1/004-stry-migration/Deploy.s.sol`
- `script/deployments/1/004-stry-migration/WeeklyYield.s.sol`
- `script/deployments/1/004-stry-migration/Verify.s.sol`

---

- [ ] **Step 24: Write `StopEspnYield.s.sol`**

  One-time, and **first in the global operational sequence** — it changes NAV, and every later formula must read the final NAV. Never broadcasts; emits a Safe batch.

  What `increaseAssetsPerShare` actually does, verified against `src/EthStrategyPerpetualNote.sol:57-63`:

  ```solidity
  SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);  // caller pays
  SafeERC20.safeTransfer(IERC20(asset()), manager, assets);                        // forwarded out
  _totalAssets += assets;                                                          // bookkeeping only
  emit AssetsPerShareIncreased(msg.sender, _totalAssets, assets);
  ```

  Therefore:

  - Pre-assert `USDS.balanceOf(payer) >= finalYieldAmount` — the caller must hold **and** approve it.
  - Pre-assert `ESPN.manager() != address(0)` (the call reverts on a zero manager) and **log the manager address prominently**. It is `0x823EfFFA08f946233D2a502a1B073C5E16Fea16b`, a **contract, and not the redemption multisig**. `finalYieldAmount` USDS leaves the treasury and lands at a third party. This is a real outflow, not a round trip, and the signer must see it (Assumption 3).
  - Emit the 2-transaction Safe batch: `USDS.approve(ESPN, finalYieldAmount)` then `ESPN.increaseAssetsPerShare(finalYieldAmount)`, to `script/deployments/1/multisig/004-stry-migration/001-0x0cbe9bDD-multisig.json`.
  - Post-conditions (asserted in `Verify.s.sol`, since this script does not execute): `totalAssets()` increased by **exactly** `finalYieldAmount`, and `AssetsPerShareIncreased` fired. **Beware the event's field names** — the signature is `AssetsPerShareIncreased(address indexed caller, uint256 newAssetsPerShare, uint256 delta)` but the contract passes post-increment `_totalAssets` into the `newAssetsPerShare` slot (line 62). Any assertion on that field must expect **total assets**, not a per-share figure.

  Record in the log output that this "stop" is a **policy, not an on-chain state change**: `increaseAssetsPerShare` is `external` with **no access control**, so anyone can keep raising NAV afterwards, including while the redemption order is live (Assumption 3). The order's amounts are fixed at validate time and do not follow NAV.

- [ ] **Step 25: Write `Distribute.s.sol` (STRY)**

  Same single-`mintBatch` pattern as Track A. One broadcast:

  1. `HoldersLib.load` + `included`, same `HOLDERS_FILE` env input.
  2. `new StryToken(deployer)`.
  3. Read **live** `ESPN.totalAssets()` / `ESPN.totalSupply()` and `basisPriceUsd` (unscaled `100`) from settings. Per included holder:

     ```
     stryAmount_i = espnBalance_i * totalAssets / (totalSupply * basisPriceUsd)
     ```

     At the block-25,800,591 NAV this yields ~38,786.53 STRY total (~3,878,653 USDS ÷ $100). **`navPerEspn` from the snapshot JSON must not be used here** — read it live.

  4. One `mintBatch`, then `renounceOwnership()`, then `ConfigLib.writeDeployedAddress(".stry", …)`.
  5. **Calibration assertion with the correct tolerance.** Each per-holder division truncates up to 1 wei of STRY; multiplied back by `basisPriceUsd = 100`, that is up to **100 wei of USDS per holder**, so over ~170 holders the tolerance is `holderCount * basisPriceUsd` wei ≈ **17,000 wei** — not "1 wei per holder":

     ```
     espnBackingRepresented = sum(includedBalances) * totalAssets / totalSupply
     require(totalSupply(STRY) * basisPriceUsd <= espnBackingRepresented);                                   // truncation only undershoots
     require(espnBackingRepresented - totalSupply(STRY) * basisPriceUsd <= holderCount * basisPriceUsd);
     ```

     Excluded holders' backing is deliberately not claimed, which is why the left side sums **included** balances only.

  6. Log `mintBatch` gas in the Step 23 two-line format.

  **Record in the script's log output and in the run-book:** per Assumption 7 / option 2, **$100 is a nominal basis price, not a redemption guarantee.** Both tracks lay claim to the same ~$3.878M of ESPN backing — Track A pays out up to 700,000 USDS of it, Track B mints STRY nominally claiming the full amount, an overstatement of ~18% if both ship off one snapshot. The spec defaults to option 2 and requires the nominal-basis caveat to appear wherever the $100 figure does. Do not print "$100 backed".

- [ ] **Step 26: Write `Deploy.s.sol` (new `StakedStrat` instance)**

  `new StakedStrat(STRY, USDS, tripwireController, guardian)`, controller and guardian from `internalAddresses.json`, then `ConfigLib.writeDeployedAddress(".staked-stry", …)`.

  **Pre-assert `tripwireController.code.length > 0` with an explicit message naming Assumption 4** before deploying. `TripwireGuard`'s constructor reverts a bare `InvalidController()` on a zero-or-codeless controller, which is opaque, and `internalAddresses.json` currently carries the zero-address placeholder because **no deployed controller address is recorded anywhere in this repo**. Fail with something the operator can act on, e.g.:

  ```
  Assumption 4 unresolved: no TripwireController deployed at <addr>.
  Track B is blocked until one exists. Deploying a controller is unscoped work.
  ```

  Facts of the unmodified contract to record in the log and the run-book (all accepted under the zero-code-change constraint):

  - The ERC20 name/symbol are hardcoded `"Staked STRAT v2"` / `"sSTRAT-v2"`; the new instance carries that name despite staking STRY. Cosmetic (Assumption 12).
  - `REWARD_DURATION = 7 days` is a constant; `syncRewards()` is **permissionless**.
  - The staked **position** token is non-transferable: `transfer`, `transferFrom` **and `approve`** all revert `TransferDisabled()` (`src/StakedStrat.sol:114-124`). Holders approve the **STRY** token for the staking contract, never the position token. Any integration that calls `approve` on the position token breaks.
  - The constructor reverts on a zero `_stratToken`/`_rewardToken` or on the two being equal.
  - Tripwire registration is **self-service and permissionless** — `TripwireGuard`'s constructor calls `controller_.register(address(this), guardian_)` itself, so no controller-owner transaction is needed. Trip state is per-guarded-contract, so the new instance inherits nothing.
  - `unstake()` is `whenNotTripped`: a trip **locks stakers' STRY in** until untripped. Worth telling holders.
  - `_CONTROLLER` is `immutable` and the guardian is fixed at construction. A wrong value means **redeploying**.

- [ ] **Step 27: Write `WeeklyYield.s.sol` (repeatable, manually triggered)**

  Not a one-time script and **not** automation — no cron, keeper, or CI schedule. Amount per run comes from env `WEEKLY_YIELD_AMOUNT` (plain decimal wei), not `settings.json`, because it changes every run.

  0. **`require(stakedStrat.totalStaked() > 0)` — hard revert, first thing.** This guard is the whole reason the script exists rather than two `cast` calls. `_currentRewardsPerShare()` returns early when `totalStaked == 0` (`src/StakedStrat.sol:137`), but `syncRewards()` has already folded the deposit into `totalNotifiedRewards` and started the clock (lines 163-172). Every second elapsed with zero stakers accrues to **nobody**, and those tokens can **never** be re-notified — a later `syncRewards()` sees `totalDeposited <= totalNotifiedRewards` and early-returns (line 169). **Depositing before anyone stakes permanently destroys the deposit**, and Track B's chronology (deploy → holders stake whenever they choose) makes a day-one loss the *default* failure mode.
  1. `USDS.transfer(stakedStrat, amount)` from the yield payer.
  2. `stakedStrat.syncRewards()`.
  3. Assert `periodFinish` moved and `totalNotifiedRewards` increased by exactly `amount`; log the new `rewardRate` and `periodFinish`.

- [ ] **Step 28: Write `Verify.s.sol` (Track B, mainnet fork)**

  Same harness as Track A: `contract Verify is Script, StdCheats, StdAssertions`, `vm.startPrank` not `vm.startBroadcast`.

  1. Run the `StopEspnYield` logic first (prank the payer, `deal` USDS, approve + `increaseAssetsPerShare`). Assert `totalAssets()` delta equals `finalYieldAmount` **exactly**, and assert the USDS landed at `ESPN.manager()` — the point is to make the third-party outflow visible in test output, not merely to pass.
  2. Distribute STRY (single `mintBatch`) → assert the calibration invariant with the `holderCount * basisPriceUsd` wei tolerance; assert `owner() == address(0)`; **log `mintBatch` gas** in the Step 23 format.
  3. Deploy the new `StakedStrat(STRY, USDS, controller, guardian)`. If no controller is configured, the script must **fail with the explicit Assumption 4 message** from Step 26, not revert opaquely inside `TripwireGuard`.
  4. **Zero-staker loss case — must come before the happy path.** With `totalStaked == 0`, transfer USDS in and call `syncRewards()` **directly**, bypassing the script's guard. Warp 1 day, then have a holder stake and warp to `periodFinish`. Assert the holder's claim is **strictly less than** the deposit, and that a second `syncRewards()` is a no-op. This demonstrates the permanent loss the Step 27 guard prevents. Then restore: take a state snapshot before this case and revert to it (`vm.snapshotState()` / `vm.revertToState()` in current forge-std; `vm.snapshot()` / `vm.revertTo()` in older — check `lib/forge-std` and use whichever is present).
  5. Happy path: prank a sample holder → `STRY.approve(stakedStrat, amount)` → `stake()`. **Approve STRY, never the position token** (position-token `approve` reverts `TransferDisabled()`).
  6. Run the `WeeklyYield` logic **including its `totalStaked > 0` guard** → assert `rewardRate`/`periodFinish` describe a 7-day stream and `totalNotifiedRewards` increased by the deposit.
  7. `vm.warp(block.timestamp + 7 days)` → holder `claim()` → assert claimed USDS equals the expected reward (sole staker ⇒ ~the full week's deposit, minus stream rounding dust — use a tolerance, not exact equality).
  8. `unstake()` the full position → assert STRY returned **and** the auto-claim paid out. `unstake()` is its own `external nonReentrant whenNotTripped` function (line 220) that auto-claims first — it is not reached "via the claim path".
  9. Log gas for `stake` / `syncRewards` / `claim` / `unstake` (informational).

  If `finalYieldAmount` is still `"0"` in settings, step 1 must still run and assert a zero delta rather than being skipped — a skipped step is an untested step.

  **Verify Task 5:** `forge build` clean, `forge fmt --check` clean, `yarn verify:migration` passes end to end with gas printed. If Assumption 4 is unresolved, the run is expected to stop at step 3 with the explicit message — that is a **pass for the script** and a **blocked status for the track**. Report it as such; do not fake a controller address to make the run go green.

---

## Task 6: Operator run-book

There is **no UI**. This document is the entire holder-facing and operator-facing interface for the whole project. Depends on Tasks 4 and 5 for the numbers it quotes.

**Files:**
- `docs/ESPNv3_Runbook.md`

---

- [ ] **Step 29: Write `docs/ESPNv3_Runbook.md`**

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

  3. **The holder fill instructions**, verbatim from Step 20's logged block, with the actual `espnAsk` / `redemptionAsk` / `usdsOffer` / order hash filled in after `BuildOrder.s.sol` runs. State plainly that `denominator` must be `1000000000`, that any other denominator will most likely revert `InexactFraction`, that holders must approve **Seaport directly** (no conduit) for both ESPN and REDEMPTION, and that sub-grid dust is retained rather than redeemable.
  4. **What "pro-rata" does and does not mean.** Capacity is capped at 700,000 USDS and is **first-come-first-served**, not a guaranteed per-holder entitlement. REDEMPTION is a plain freely-transferable ERC20 and the order is `PARTIAL_OPEN` with no zone, so anyone — including non-holders who buy REDEMPTION from apathetic holders and ESPN from the LP — can consume capacity ahead of snapshot holders. This is accepted, not a bug; a zone is explicitly out of scope.
  5. **Measured gas numbers** from both Verify runs, with the execution-gas caveat stated, and the ">15M ⇒ chunk into 100s" decision rule.
  6. **Safe batch files**: where each is written, that `checksum` is null and the operator re-derives it on import, and the order the two transactions in each batch must execute in.
  7. **Track B holder notes**: approve **STRY** not the position token; the position token is non-transferable; the instance is cosmetically named `"Staked STRAT v2"`; a tripwire trip locks staked STRY in until untripped; `$100 is a nominal basis price, not a redemption guarantee`.

---

## Definition of done

- `forge build` and `FOUNDRY_PROFILE=integration forge build` both clean.
- `yarn test` green (includes the two new token test files and `ScriptLibsTest`).
- `forge fmt --check` clean (a pre-existing CI blocker in this repo — see `c98c2a2`).
- `yarn verify:redemption` passes every assertion, including the `InexactFraction` negative test and the over-large-fill clamp test, and prints both gas figures.
- `yarn verify:migration` passes end to end, **or** stops at the `Deploy` step with the explicit Assumption 4 message if no `TripwireController` is deployed.
- A real snapshot JSON is committed and its `sum(balances) == totalSupply` invariant passed.
- `docs/ESPNv3_Runbook.md` exists with the real order hash and gas numbers filled in.
- No dependency on `stoke`. No `dependencies` block in `package.json`. No changes to `src/StakedStrat.sol`, `src/EthStrategyPerpetualNote.sol`, or any other existing contract.
