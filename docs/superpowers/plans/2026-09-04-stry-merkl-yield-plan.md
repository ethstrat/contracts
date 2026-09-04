# STRY Yield via Merkl — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Track B's `StakedStrat`-based weekly yield with a repeatable Foundry script that emits a Safe Transaction Builder batch creating a new 7-day Merkl campaign paying USDS to plain STRY holders, and delete the staking contract entirely.

**Architecture:** `WeeklyYield.s.sol` is rewritten in place: an `internal weeklyYield(...)` builds Merkl `CampaignParameters` (asserting live pre-conditions and computing `campaignData = sha256(canonicalJson(config))` via a new pure `MerklCampaignLib`), and `run()` alone POSTs that JSON to Merkl's config store over `vm.ffi` + `curl` and writes a 2-or-3-transaction Safe batch (`USDS.approve`, conditional `acceptConditions`, `createCampaign`) at the first free never-overwritten index. `Verify.s.sol` executes that batch's calls under `vm.startPrank(safe)` on a mainnet fork against Merkl's real `DistributionCreator` and asserts registration, balances and three negative paths. `src/StakedStrat.sol`, its test, its user stories and `004-stry-migration/Deploy.s.sol` are deleted.

**Tech Stack:** Foundry + forge-std only (`forge script`, `vm.ffi`, `sha256` precompile, `vm.parseJson*`), OpenZeppelin `IERC20` (vendored), Merkl `DistributionCreator` on Ethereum mainnet, Safe Transaction Builder JSON.

**Spec:** docs/superpowers/specs/2026-09-04-stry-merkl-yield-design.md

## Global Constraints

- Chain id **1** only. Every path under `script/deployments/1/` is mainnet-only; `computeChainId` is the literal `1` in the canonical config JSON.
- **No new npm dependency.** `package.json` keeps `devDependencies` only — no `dependencies` block. No `viem`, no JS runtime library.
- **`ffi = true` is already set** in `foundry.toml`; `fs_permissions` already grants `read-write` on `./tmp/` and `./script/deployments/`. No `foundry.toml` change in this plan.
- **No `package.json` change.** `verify:migration` already points at `004-stry-migration/Verify.s.sol` and already requires `SNAPSHOT_BLOCK` (`--fork-block-number ${SNAPSHOT_BLOCK:?…}`).
- Merkl `DistributionCreator` (mainnet) = `0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd`; `Distributor` = `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`; `feeRecipient` = `0xeaC6A75e19beB1283352d24c0311De865a867DAB`.
- Campaign type = **`18`** (`ERC20LOGPROCESSOR`); distribution method = **`DUTCH_AUCTION`**; `computeMethod` = **`genericTimeWeighted`**; duration = **`604800`** (7 days).
- `campaignType` and `duration` live in `settings.json` (`.espnv3.merkl`), **not** as Solidity constants. `duration` is a quoted decimal string per the Step 7 unit convention of the 2026-08-21 plan; `campaignType` is an unscaled JSON number.
- Creator / payer Safe = `.protocol.multisigs.redemption` = `0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D`. It is on `userSignatureWhitelist` (value `1`), so `acceptConditions()` is **not** required today.
- `defaultFees()` = `30000000` of `BASE_9 = 1e9` = **3%**; `campaignSpecificFees(18)` = `0`; `feeRebate(redemption Safe)` = `0`.
- `rewardTokenMinAmounts(USDS)` = `1e18` ⇒ the floor is **≥ 168 USDS per 7-day campaign** (`amount * 3600 >= minAmount * duration`).
- Canonical JSON = keys in **sorted order**, **no whitespace**, addresses **EIP-55 checksummed**, `amount` a decimal **string**, timestamps JSON **numbers**. `campaignData = sha256(bytes(json))`, carried on-chain as exactly 32 bytes.
- `WEEKLY_YIELD_AMOUNT` (plain decimal wei) and `WEEKLY_YIELD_START` (hour-aligned unix seconds, `> now + 1 day`) are env vars, not settings — they change every run. **There is no index env var**: the batch index is derived as the first free file.
- Scripts that a `Verify.s.sol` calls must never write files: `SafeBatchLib.write`, `ConfigLib.writeDeployedAddress` and `vm.ffi` live only in `run()`. `git status` must be clean after `yarn verify:migration`.
- Unit test command: `forge test` (no fork; `foundry.toml` sets `test = "test/unit"`), or `yarn test` (`forge test --fuzz-runs 20`).
- Fork command: `SNAPSHOT_BLOCK=25800912 yarn verify:migration` (the committed snapshot is `script/deployments/1/config/espn-holders-25800912.json`).
- `forge fmt --check` must stay clean — it is an enforced CI gate in this repo.
- Commit subjects go through husky + `@commitlint/config-conventional` (`.husky/commit-msg` runs `yarn commitlint --edit`) — the subject must not be sentence-case/pascal-case; start it with a lowercase verb.

---

## Facts re-confirmed against mainnet while writing this plan

Do not re-derive these; they are `cast`-confirmed and they are what the code below is written against.

| Fact | Confirmed value |
|---|---|
| `DistributionCreator.distributor()` | `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` |
| `feeRecipient()` / `defaultFees()` / `campaignSpecificFees(18)` | `0xeaC6A75e19beB1283352d24c0311De865a867DAB` / `30000000` / `0` |
| `messageHash()` | `0x229e20607dee64ebb81fc71bd4e50e29c264a0b894dbdcc3e8bd614f372cecb6` |
| `rewardTokenMinAmounts(USDS)` | `1000000000000000000` |
| `userSignatureWhitelist(0x0cbe9bDD…)` / `userSignatures(0x0cbe9bDD…)` / `feeRebate(0x0cbe9bDD…)` | `1` / `0x0` / `0` |
| **`CampaignParameters` struct layout** | `(bytes32,address,address,uint256,uint32,uint32,uint32,bytes)` — confirmed by calling `campaignId(...)` on mainnet with the Feb-2026 fixture's fields and getting back the real campaign id `0x2653bceda930d0c6f409bc8744ab04c19a71b8ea55f73d498b6667032ccc3cb0` |
| `campaign(0x2653bced…)` | `(0x2653bced…, 0xC53CCed6…, wETH, 22504000000000000000, 18, 1771160400, 3628800, 0x687bd056…)` — the stored `amount` is **net of the 3% fee** (23.2 → 22.504 wETH) |
| `campaignLookup(0x2653bced…)` | `3883` — the campaign's **index-1** for a registered id |
| **`campaignLookup` on an UNKNOWN id** | **reverts `CampaignDoesNotExist()` (selector `0x9b35ed3b`) — it does NOT return 0.** Confirmed live: `cast call 0x8BB4C975… "campaignLookup(bytes32)(uint256)" 0x00…01` → `execution reverted: CampaignDoesNotExist`. "Registered" is therefore tested by the call *not reverting*, never by comparing the returned value against `0`. |
| Both pinned hashes | `sha256` of the canonical string reproduces `0x687bd05668bd74bd5b5bc83cd6c516f3a4cf32c991735da35670990e16f4d706` (with `url`) and `0x4e08c911037453c7e092198804fbbcfd7cfd01f0cb3b0ffa53eab0b19141c6b1` (without) |
| `vm.toString(address)` at this forge-std pin | **emits EIP-55 checksum casing** (verified: `0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8`). No checksum routine is needed in `MerklCampaignLib`. |
| `vm.exists(string)`, `vm.ffi(string[])`, `assertEq(bytes,bytes,string)`, `assertEq(string,string,string)` | all present at this pin |

---

## Task dependency order

```
Task 1 (Merkl config + interface + SafeBatchLib.path)   ← blocking, land first
Task 2 (MerklCampaignLib + its pinned unit test)        ← independent of 1, runs in parallel
Task 3 (WeeklyYield rewrite + StakedStrat deletion + Verify items 1-3)  ← needs 1 AND 2
Task 4 (Verify items 4-10)                              ← needs 3
Task 5 (run-book + prior plan/spec doc edits)           ← needs 4 for the gas number it quotes
```

Tasks 1 and 2 are fully parallel: disjoint file lists, and neither imports the other.

**Deliberate ordering deviation, stated so it is not mistaken for an oversight.** The obvious reading of the spec puts "delete `StakedStrat`" first. It cannot go first: `WeeklyYield.s.sol` and `Verify.s.sol` both `import {StakedStrat} from "src/StakedStrat.sol"`, and `Verify.s.sol` also imports and inherits `Deploy.s.sol`. Deleting the contract before rewriting its two consumers leaves the repo unable to `forge build`, i.e. a task that does not produce working software. The deletion is therefore folded into **Task 3**, which rewrites both consumers in the same commit — the smallest change set that starts green and ends green.

**Task 3 is deliberately larger than Task 4's slice of the same file.** It is the atomic red→green unit: `forge build` is broken from the moment `src/StakedStrat.sol` is deleted until the new `WeeklyYield.s.sol` compiles. Splitting it would hand a reviewer a non-building tree. Task 3 leaves `Verify.s.sol` covering Testing items 1–3 (build only); Task 4 extends the same file to items 4–10 (execution, assertions, negatives, gas) and is independently reviewable.

**One structural rule carries over from the 2026-08-21 plan and is not negotiable here:** `weeklyYield(...)` is `internal view`, writes no file and makes no `vm.ffi` call. `SafeBatchLib.write` and the config-store `curl` live only in `run()`. `Verify.s.sol` calls `weeklyYield(...)`, never `run()`.

---

## Task 1: Merkl config, `IMerklDistributionCreator`, and the Safe-batch path helper

Purely additive. Nothing is deleted and no existing behaviour changes, so the tree builds and `yarn test` stays green throughout.

**Files:**
- Create: `script/deployments/1/004-stry-migration/interfaces/IMerklDistributionCreator.sol`
- Modify: `script/deployments/1/config/externalAddresses.json` (add the `merkl` block)
- Modify: `script/deployments/1/config/settings.json` (add `.espnv3.merkl`)
- Modify: `script/deployments/1/lib/SafeBatchLib.sol:17-57` (extract `path(...)`, use it from `write`)
- Test: `test/unit/ScriptLibsTest.sol` (four new/changed assertions)

**Interfaces:**
- Consumes: `ConfigLib.addr(string,string) → address`, `ConfigLib.num(string,string) → uint256`, `ConfigLib.addrArray(string,string) → address[] memory` (all already exist).
- Produces:
  - `IMerklDistributionCreator.CampaignParameters` = `struct { bytes32 campaignId; address creator; address rewardToken; uint256 amount; uint32 campaignType; uint32 startTimestamp; uint32 duration; bytes campaignData; }`
  - `IMerklDistributionCreator`: `createCampaign(CampaignParameters memory) returns (bytes32)`, `acceptConditions()`, `campaignId(CampaignParameters memory) view returns (bytes32)`, `campaign(bytes32) view returns (CampaignParameters memory)`, `campaignLookup(bytes32) view returns (uint256)`, `distributor() view returns (address)`, `feeRecipient() view returns (address)`, `defaultFees() view returns (uint256)`, `campaignSpecificFees(uint32) view returns (uint256)`, `feeRebate(address) view returns (uint256)`, `rewardTokenMinAmounts(address) view returns (uint256)`, `userSignatureWhitelist(address) view returns (uint256)`, `userSignatures(address) view returns (bytes32)`, `messageHash() view returns (bytes32)`; errors `NotSigned()`, `CampaignRewardTooLow()`, `CampaignRewardTokenNotWhitelisted()`, `CampaignAlreadyExists()`.
  - `SafeBatchLib.path(address safe, string memory operation, uint256 index) internal pure returns (string memory)`
  - Config keys `.merkl.distributionCreator`, `.merkl.distributor` (externalAddresses.json) and `.espnv3.merkl.campaignType`, `.espnv3.merkl.duration`, `.espnv3.merkl.blacklist` (settings.json).

---

- [ ] **Step 1: Write the failing tests in `test/unit/ScriptLibsTest.sol`**

  Append these three test functions to the existing contract (after `test_ConfigLib_addrArray_emptyExcludedAddresses`), and change the path construction inside the existing `test_SafeBatchLib_write_roundTrips` to go through the new helper:

  ```solidity
  function test_ConfigLib_addr_merklAddresses() public view {
      assertEq(
          ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator"),
          0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd
      );
      assertEq(
          ConfigLib.addr("externalAddresses.json", ".merkl.distributor"),
          0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae
      );
  }

  function test_ConfigLib_num_merklSettings() public view {
      assertEq(ConfigLib.num("settings.json", ".espnv3.merkl.campaignType"), 18);
      assertEq(ConfigLib.num("settings.json", ".espnv3.merkl.duration"), 604_800);
  }

  function test_ConfigLib_addrArray_emptyMerklBlacklist() public view {
      assertEq(ConfigLib.addrArray("settings.json", ".espnv3.merkl.blacklist").length, 0);
  }
  ```

  In `test_SafeBatchLib_write_roundTrips`, replace the two hand-built path lines

  ```solidity
      string memory dir = string.concat("script/deployments/1/multisig/", operation);
      string memory path = string.concat(dir, "/001-0x11111111-multisig.json");
  ```

  with a helper-derived path plus an equality assertion against the literal, so `path()` and `write()` provably agree:

  ```solidity
      string memory dir = string.concat("script/deployments/1/multisig/", operation);
      string memory path = SafeBatchLib.path(safe, operation, 1);
      assertEq(path, string.concat(dir, "/001-0x11111111-multisig.json"));
  ```

- [ ] **Step 2: Run the tests to verify they fail**

  ```
  forge test --match-path test/unit/ScriptLibsTest.sol
  ```

  Expected: compilation fails with `Member "path" not found or not visible after argument-dependent lookup in type(library SafeBatchLib)`. After the `path` helper is added but before the config keys are, expect three failures reading `key ".merkl.distributionCreator" not found`, `key ".espnv3.merkl.campaignType" not found` and `key ".espnv3.merkl.blacklist" not found`.

- [ ] **Step 3a: Add the `merkl` block to `script/deployments/1/config/externalAddresses.json`**

  Final content:

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
    },
    "merkl": {
      "distributionCreator": "0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd",
      "distributor": "0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae"
    }
  }
  ```

- [ ] **Step 3b: Add `.espnv3.merkl` to `script/deployments/1/config/settings.json`**

  Append the `merkl` object as the last key inside `espnv3`. Final content:

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
      "excludedAddresses": [],
      "merkl": {
        "campaignType": 18,
        "duration": "604800",
        "blacklist": []
      }
    }
  }
  ```

  `campaignType` is an unscaled number (it is an enum ordinal); `duration` is a quoted decimal string (it is a time quantity, per the plan's unit convention); `blacklist` ships empty — every STRY holder, including the redemption Safe's own ~9.2%, earns. That is Open Risk 6, a founder decision, and it is overridable per campaign later via Merkl's blacklist override without a new campaign.

- [ ] **Step 3c: Write `script/deployments/1/004-stry-migration/interfaces/IMerklDistributionCreator.sol`**

  Minimal, mirroring `003-espn-redemption/interfaces/ISeaportMinimal.sol`. Nothing beyond what `WeeklyYield.s.sol` and `Verify.s.sol` call. Complete file:

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  /// @notice Minimal Merkl DistributionCreator interface -- only the surface 004-stry-migration
  /// needs. Mainnet: 0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd (same address on most EVM chains).
  /// The struct layout below was confirmed against mainnet: calling campaignId(...) with the
  /// treasury's own Feb-2026 campaign fields returns that campaign's real id
  /// 0x2653bceda930d0c6f409bc8744ab04c19a71b8ea55f73d498b6667032ccc3cb0.
  interface IMerklDistributionCreator {
      // -------------------------------------------------------------------------
      // Errors asserted by Verify.s.sol
      // -------------------------------------------------------------------------

      error CampaignAlreadyExists();
      error CampaignRewardTokenNotWhitelisted();
      error CampaignRewardTooLow();
      error NotSigned();

      // -------------------------------------------------------------------------
      // Structs
      // -------------------------------------------------------------------------

      /// @dev `campaignId` is not one of the fields campaignId() hashes -- _createCampaign
      /// overwrites it with the derived id -- so filling it in before the call is cosmetic and
      /// does not change the resulting id.
      struct CampaignParameters {
          bytes32 campaignId;
          address creator;
          address rewardToken;
          uint256 amount;
          uint32 campaignType;
          uint32 startTimestamp;
          uint32 duration;
          bytes campaignData;
      }

      // -------------------------------------------------------------------------
      // State-changing
      // -------------------------------------------------------------------------

      function acceptConditions() external;

      function createCampaign(CampaignParameters memory newCampaign) external returns (bytes32);

      // -------------------------------------------------------------------------
      // Views
      // -------------------------------------------------------------------------

      function campaignId(CampaignParameters memory campaign_) external view returns (bytes32);

      function campaign(bytes32 _campaignId) external view returns (CampaignParameters memory);

      /// @dev Reverts CampaignDoesNotExist() when the id is unknown; returns the campaign's
      /// index-1 otherwise. Confirmed live on mainnet. Existence is tested by the call not
      /// reverting -- never by comparing the return value against 0.
      function campaignLookup(bytes32 _campaignId) external view returns (uint256);

      function distributor() external view returns (address);

      function feeRecipient() external view returns (address);

      /// @dev Of BASE_9 = 1e9. Mainnet today: 30000000 == 3%.
      function defaultFees() external view returns (uint256);

      /// @dev 0 means "the default applies"; 1 means "zero fees".
      function campaignSpecificFees(uint32 campaignType) external view returns (uint256);

      function feeRebate(address user) external view returns (uint256);

      /// @dev 0 means the token is not whitelisted as an incentive token at all.
      function rewardTokenMinAmounts(address token) external view returns (uint256);

      function userSignatureWhitelist(address user) external view returns (uint256);

      function userSignatures(address user) external view returns (bytes32);

      function messageHash() external view returns (bytes32);
  }
  ```

- [ ] **Step 3d: Extract `path(...)` in `script/deployments/1/lib/SafeBatchLib.sol`**

  `write` ends in `vm.writeFile`, which overwrites silently. `WeeklyYield.s.sol` is this repo's first **repeatable** batch producer and must scan for the first free index using *exactly* the writer's derivation — a drift between the two rewrites a previous week's batch in place with no error. So there is one derivation, used by both.

  Replace the first three lines of `write`'s body:

  ```solidity
          string memory dir = string.concat("script/deployments/1/multisig/", operation, "/");
          vm.createDir(dir, true);

          string memory path = string.concat(dir, _pad3(index), "-", _slice10(vm.toString(safe)), "-multisig.json");
  ```

  with:

  ```solidity
          vm.createDir(string.concat("script/deployments/1/multisig/", operation, "/"), true);

          string memory filePath = path(safe, operation, index);
  ```

  change the final line of `write` from `vm.writeFile(path, json);` to `vm.writeFile(filePath, json);`, and add this function immediately after `write`:

  ```solidity
      /// @dev The exact path `write` writes to. Exposed so a repeatable batch producer
      /// (004-stry-migration/WeeklyYield.s.sol) can scan for the first free index using the same
      /// derivation as the writer -- `write` ends in vm.writeFile, which overwrites silently.
      function path(address safe, string memory operation, uint256 index) internal pure returns (string memory) {
          return string.concat(
              "script/deployments/1/multisig/",
              operation,
              "/",
              _pad3(index),
              "-",
              _slice10(vm.toString(safe)),
              "-multisig.json"
          );
      }
  ```

- [ ] **Step 4: Run the tests to verify they pass**

  ```
  forge build
  forge test --match-path test/unit/ScriptLibsTest.sol
  forge fmt --check
  ```

  Expected: `forge build` succeeds (`IMerklDistributionCreator` compiles under `solc 0.8.24`); the ScriptLibs suite passes with the three new tests plus the amended `test_SafeBatchLib_write_roundTrips`; `forge fmt --check` prints nothing.

- [ ] **Step 5: Commit**

  ```
  git add script/deployments/1/004-stry-migration/interfaces/IMerklDistributionCreator.sol \
          script/deployments/1/config/externalAddresses.json \
          script/deployments/1/config/settings.json \
          script/deployments/1/lib/SafeBatchLib.sol \
          test/unit/ScriptLibsTest.sol
  git commit -m "feat(004-stry-migration): add Merkl addresses, settings and a minimal DistributionCreator interface

  Adds .merkl.distributionCreator/.distributor to externalAddresses.json and
  .espnv3.merkl.{campaignType,duration,blacklist} to settings.json, both covered by
  ScriptLibsTest round-trips. Adds IMerklDistributionCreator (struct layout confirmed
  on mainnet against campaign 0x2653bced...) and extracts SafeBatchLib.path so a
  repeatable batch producer can find the first free index with the writer's own
  derivation.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TZWFMQom5wUTiyQXvGtZSX"
  ```

---

## Task 2: `MerklCampaignLib` — canonical JSON, its sha256, and the ISO window rendering

The highest-risk task in this plan and the reason it gets its own reviewer gate. On the current Merkl engine `campaignData` is **not** an ABI-encoded config — it is `sha256` of a canonically-serialised JSON that must also be stored with Merkl. If the canonicalisation is wrong, the campaign is created on-chain, the USDS leaves the Safe, and the engine can never score it. This test is the one runnable check for that, and it is anchored to a real mainnet campaign.

Purely additive: nothing imports this library until Task 3.

**Files:**
- Create: `script/deployments/1/004-stry-migration/MerklCampaignLib.sol`
- Test: `test/unit/MerklCampaignLibTest.sol`

**Interfaces:**
- Consumes: `Vm` from `forge-std/Vm.sol` (the standard `Vm(address(uint160(uint256(keccak256("hevm cheat code")))))` constant, as in `ConfigLib`/`SafeBatchLib` — a library cannot inherit `Script`). Nothing from Task 1.
- Produces, and every later caller must match these exactly:
  - `MerklCampaignLib.canonicalJson(uint256 amount, address creator, address rewardToken, address targetToken, uint32 campaignType, uint32 startTimestamp, uint32 duration, address[] memory blacklist, string memory url) internal pure returns (string memory)`
  - `MerklCampaignLib.campaignData(string memory json) internal pure returns (bytes32)`
  - `MerklCampaignLib.isoUtc(uint256 unixSeconds) internal pure returns (string memory)`

  **Note on `campaignData`'s signature.** The spec writes it as `campaignData(...) returns (bytes32)`. It takes the JSON string, not a repeat of `canonicalJson`'s nine arguments: it is `sha256(bytes(json))` and nothing else, and re-passing nine arguments would create a second place where a transposed address could hide. Every call site does `campaignData(canonicalJson({…}))`, so there is exactly one argument list per site. All call sites use Solidity's **named-argument call syntax** (`canonicalJson({amount: …, creator: …})`) — with four `address` and three `uint32` parameters, positional calls are a transposition waiting to happen.

---

- [ ] **Step 6: Write the failing test `test/unit/MerklCampaignLibTest.sol`**

  Complete file:

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import {Test} from "forge-std/Test.sol";
  import {MerklCampaignLib} from "../../script/deployments/1/004-stry-migration/MerklCampaignLib.sol";

  /// @notice Pins the canonicalisation against a real mainnet campaign, no fork needed: the
  /// treasury's own Feb-2026 wETH -> sSTRAT campaign
  /// 0x2653bceda930d0c6f409bc8744ab04c19a71b8ea55f73d498b6667032ccc3cb0, created from the main
  /// Safe. Its on-chain campaignData is 0x687bd056...;
  /// GET https://api.merkl.xyz/v4/config/hash/0x687bd056... returns the stored JSON, and sha256 of
  /// that JSON re-serialised with sorted keys and no whitespace equals it.
  contract MerklCampaignLibTest is Test {
      uint256 internal constant FIXTURE_AMOUNT = 23_200_000_000_000_000_000; // 23.2 wETH
      address internal constant MAIN_SAFE = 0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8;
      address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
      address internal constant SSTRAT = 0xD6664390E0485Cd609d4D04b430e84e945a51994;
      address internal constant REDEMPTION_SAFE = 0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D;
      uint32 internal constant FIXTURE_START = 1_771_160_400; // 2026-02-15T13:00:00Z
      uint32 internal constant FIXTURE_DURATION = 3_628_800; // 42 days -> end 1774789200
      string internal constant FIXTURE_URL = "https://app.ethstrat.xyz/strat";

      bytes32 internal constant FIXTURE_HASH_WITH_URL =
          0x687bd05668bd74bd5b5bc83cd6c516f3a4cf32c991735da35670990e16f4d706;
      bytes32 internal constant FIXTURE_HASH_NO_URL =
          0x4e08c911037453c7e092198804fbbcfd7cfd01f0cb3b0ffa53eab0b19141c6b1;
      bytes32 internal constant FIXTURE_HASH_TWO_BLACKLISTED =
          0x8c15ee7c2623732b0ce1030ac5e3f57a7ef4c9f573e811a8fad92477c79a5409;

      function _fixtureJson(uint256 amount, address[] memory blacklist, string memory url)
          internal
          pure
          returns (string memory)
      {
          return MerklCampaignLib.canonicalJson({
              amount: amount,
              creator: MAIN_SAFE,
              rewardToken: WETH,
              targetToken: SSTRAT,
              campaignType: 18,
              startTimestamp: FIXTURE_START,
              duration: FIXTURE_DURATION,
              blacklist: blacklist,
              url: url
          });
      }

      /// @dev The mainnet-anchored assertion. It covers key ordering, the number-vs-string choice
      /// per key, and -- the likeliest thing to go wrong -- whether vm.toString(address) emits the
      /// EIP-55 checksum casing the stored JSON uses. If this fails on casing, the library needs a
      /// checksum routine.
      function test_campaignData_matchesMainnetFixture_withUrl() public pure {
          assertEq(
              MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, new address[](0), FIXTURE_URL)),
              FIXTURE_HASH_WITH_URL,
              "canonical JSON with url does not hash to campaign 0x2653bced...'s on-chain campaignData"
          );
      }

      /// @dev The omission branch: the shape production actually hashes and Merkl must store.
      function test_campaignData_matchesMainnetFixture_withoutUrl() public pure {
          assertEq(
              MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, new address[](0), "")),
              FIXTURE_HASH_NO_URL,
              "canonical JSON without url does not hash to the pinned value"
          );
      }

      /// @dev Pins the string itself, so a canonicalisation failure names the offending character
      /// instead of only a mismatched 32-byte hash.
      function test_canonicalJson_exactStoredString() public pure {
          assertEq(
              _fixtureJson(FIXTURE_AMOUNT, new address[](0), FIXTURE_URL),
              "{\"amount\":\"23200000000000000000\",\"blacklist\":[],\"campaignType\":18,\"computeChainId\":1,\"computeScoreParameters\":{\"computeMethod\":\"genericTimeWeighted\"},\"creator\":\"0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8\",\"distributionMethodParameters\":{\"distributionMethod\":\"DUTCH_AUCTION\",\"distributionSettings\":{}},\"endTimestamp\":1774789200,\"forwarders\":[],\"hooks\":[],\"rewardToken\":\"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"startTimestamp\":1771160400,\"targetToken\":\"0xD6664390E0485Cd609d4D04b430e84e945a51994\",\"url\":\"https://app.ethstrat.xyz/strat\",\"whitelist\":[]}",
              "canonical JSON string drifted from the config Merkl stores for campaign 0x2653bced..."
          );
      }

      function test_canonicalJson_blacklistSerialisation() public pure {
          address[] memory two = new address[](2);
          two[0] = REDEMPTION_SAFE;
          two[1] = SSTRAT;

          assertEq(
              _fixtureJson(FIXTURE_AMOUNT, two, ""),
              "{\"amount\":\"23200000000000000000\",\"blacklist\":[\"0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D\",\"0xD6664390E0485Cd609d4D04b430e84e945a51994\"],\"campaignType\":18,\"computeChainId\":1,\"computeScoreParameters\":{\"computeMethod\":\"genericTimeWeighted\"},\"creator\":\"0xC53CCed6332D06972A7eaEDc64FDF6d4aF5220b8\",\"distributionMethodParameters\":{\"distributionMethod\":\"DUTCH_AUCTION\",\"distributionSettings\":{}},\"endTimestamp\":1774789200,\"forwarders\":[],\"hooks\":[],\"rewardToken\":\"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\",\"startTimestamp\":1771160400,\"targetToken\":\"0xD6664390E0485Cd609d4D04b430e84e945a51994\",\"whitelist\":[]}",
              "non-empty blacklist is not serialised as a JSON array of checksummed addresses"
          );
          assertEq(
              MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, two, "")),
              FIXTURE_HASH_TWO_BLACKLISTED,
              "two-address blacklist hash drifted"
          );
      }

      function test_campaignData_amountSensitivity() public pure {
          assertTrue(
              MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT, new address[](0), ""))
                  != MerklCampaignLib.campaignData(_fixtureJson(FIXTURE_AMOUNT + 1, new address[](0), "")),
              "two configs differing only in amount hash identically"
          );
      }

      /// @dev isoUtc is what WeeklyYield.s.sol prints for the Safe signers. Pinned against the same
      /// fixture window so the date arithmetic has a runnable check.
      function test_isoUtc_pinsFixtureWindow() public pure {
          assertEq(MerklCampaignLib.isoUtc(FIXTURE_START), "2026-02-15T13:00:00Z");
          assertEq(MerklCampaignLib.isoUtc(uint256(FIXTURE_START) + FIXTURE_DURATION), "2026-03-29T13:00:00Z");
      }
  }
  ```

- [ ] **Step 7: Run the test to verify it fails**

  ```
  forge test --match-path test/unit/MerklCampaignLibTest.sol
  ```

  Expected: compilation fails with `Source "script/deployments/1/004-stry-migration/MerklCampaignLib.sol" not found`.

- [ ] **Step 8: Write `script/deployments/1/004-stry-migration/MerklCampaignLib.sol`**

  Complete file:

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import {Vm} from "forge-std/Vm.sol";

  /// @notice Pure canonical-JSON + sha256 encoder for Merkl's `campaignData`, plus the ISO-8601
  /// window rendering WeeklyYield.s.sol logs for the Safe signers.
  ///
  /// On the current Merkl engine `campaignData` is NOT an ABI-encoded config: it is
  /// sha256(canonicalJson(config)), and the JSON itself must be stored with Merkl
  /// (POST https://api.merkl.xyz/v4/config/store) so the engine can resolve the hash. Canonical
  /// form = keys in sorted order, no whitespace, addresses EIP-55 checksummed (exactly what
  /// vm.toString(address) emits), the amount as a decimal string, timestamps as JSON numbers.
  ///
  /// Verified: this string's sha256 reproduces the on-chain campaignData of the treasury's own
  /// Feb-2026 campaign 0x2653bced... -- see test/unit/MerklCampaignLibTest.sol. Reads no config
  /// and touches no chain state.
  library MerklCampaignLib {
      Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

      /// @param url Merkl campaign page URL, emitted in sorted position between `targetToken` and
      /// `whitelist`. "" omits the key entirely, which is what production passes -- the key is
      /// optional in Merkl's schema and there is no STRY page. The argument exists because the
      /// Feb-2026 fixture the unit test pins does carry a url inside the hashed string, so a
      /// library that could never emit `url` could not reproduce that hash at all.
      /// @dev computeChainId is the literal 1: every script under script/deployments/1/ is
      /// mainnet-only.
      function canonicalJson(
          uint256 amount,
          address creator,
          address rewardToken,
          address targetToken,
          uint32 campaignType,
          uint32 startTimestamp,
          uint32 duration,
          address[] memory blacklist,
          string memory url
      ) internal pure returns (string memory) {
          // Split in two so the concat argument list stays readable; the halves are joined below.
          string memory head = string.concat(
              "{\"amount\":\"",
              vm.toString(amount),
              "\",\"blacklist\":",
              _addressArray(blacklist),
              ",\"campaignType\":",
              vm.toString(uint256(campaignType)),
              ",\"computeChainId\":1,\"computeScoreParameters\":{\"computeMethod\":\"genericTimeWeighted\"},\"creator\":\"",
              vm.toString(creator),
              "\",\"distributionMethodParameters\":{\"distributionMethod\":\"DUTCH_AUCTION\",\"distributionSettings\":{}},\"endTimestamp\":",
              vm.toString(uint256(startTimestamp) + duration)
          );
          return string.concat(
              head,
              ",\"forwarders\":[],\"hooks\":[],\"rewardToken\":\"",
              vm.toString(rewardToken),
              "\",\"startTimestamp\":",
              vm.toString(uint256(startTimestamp)),
              ",\"targetToken\":\"",
              vm.toString(targetToken),
              "\",",
              _urlKey(url),
              "\"whitelist\":[]}"
          );
      }

      /// @dev The on-chain campaignData, as 32 bytes. Takes the JSON rather than repeating
      /// canonicalJson's nine arguments: it is sha256 and nothing else, and one argument list per
      /// call site is one place a transposed address can hide instead of two.
      function campaignData(string memory json) internal pure returns (bytes32) {
          return sha256(bytes(json));
      }

      /// @dev Unix seconds -> "YYYY-MM-DDTHH:MM:SSZ" (Howard Hinnant's civil-from-days algorithm).
      /// Logged for the Safe signers so the campaign window is readable without a converter.
      function isoUtc(uint256 unixSeconds) internal pure returns (string memory) {
          uint256 z = unixSeconds / 86400 + 719468;
          uint256 era = z / 146097;
          uint256 doe = z - era * 146097;
          uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
          uint256 y = yoe + era * 400;
          uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
          uint256 mp = (5 * doy + 2) / 153;
          uint256 d = doy - (153 * mp + 2) / 5 + 1;
          uint256 m = mp < 10 ? mp + 3 : mp - 9;
          if (m <= 2) ++y;
          uint256 s = unixSeconds % 86400;
          return string.concat(
              vm.toString(y),
              "-",
              _two(m),
              "-",
              _two(d),
              "T",
              _two(s / 3600),
              ":",
              _two((s % 3600) / 60),
              ":",
              _two(s % 60),
              "Z"
          );
      }

      function _addressArray(address[] memory addrs) private pure returns (string memory out) {
          out = "[";
          for (uint256 i; i < addrs.length; ++i) {
              out = string.concat(out, i == 0 ? "\"" : ",\"", vm.toString(addrs[i]), "\"");
          }
          out = string.concat(out, "]");
      }

      function _urlKey(string memory url) private pure returns (string memory) {
          if (bytes(url).length == 0) return "";
          return string.concat("\"url\":\"", url, "\",");
      }

      function _two(uint256 v) private pure returns (string memory) {
          return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
      }
  }
  ```

- [ ] **Step 9: Run the test to verify it passes**

  ```
  forge test --match-path test/unit/MerklCampaignLibTest.sol -vv
  forge fmt --check
  ```

  Expected: `Suite result: ok. 6 passed; 0 failed; 0 skipped`, and `forge fmt --check` prints nothing.

  If `test_campaignData_matchesMainnetFixture_withUrl` fails while `test_canonicalJson_exactStoredString` passes, the sha256 call is wrong. If both fail on a casing difference in the address literals, `vm.toString(address)` is not emitting EIP-55 at this pin and the library needs a checksum routine — that is exactly what this assertion exists to find. (Verified at the current pin: it does emit EIP-55, so no routine is expected to be needed.)

- [ ] **Step 10: Commit**

  ```
  git add script/deployments/1/004-stry-migration/MerklCampaignLib.sol test/unit/MerklCampaignLibTest.sol
  git commit -m "feat(004-stry-migration): add MerklCampaignLib canonical config JSON and its sha256

  campaignData on the current Merkl engine is sha256 of a canonically-serialised JSON
  config (sorted keys, no whitespace, EIP-55 addresses), not an ABI encoding. Pinned
  against the treasury's own Feb-2026 mainnet campaign 0x2653bced...: with url ->
  0x687bd056..., without -> 0x4e08c911.... Also pins blacklist serialisation, amount
  sensitivity and the ISO window rendering the weekly script logs for signers.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TZWFMQom5wUTiyQXvGtZSX"
  ```

---

## Task 3: Rewrite `WeeklyYield.s.sol`, delete `StakedStrat`, retarget `Verify.s.sol` to Testing items 1–3

Depends on Tasks 1 and 2. This is the one task in the plan that goes through a non-building intermediate state, by necessity: `WeeklyYield.s.sol` and `Verify.s.sol` both import `src/StakedStrat.sol`, and `Verify.s.sol` inherits `004-stry-migration/Deploy.s.sol`. The deletion and the rewrite are the same change.

**Files:**
- Delete: `src/StakedStrat.sol`
- Delete: `test/unit/StakedStratTest.sol`
- Delete: `docs/StakedStrat_User_Stories.md`
- Delete: `script/deployments/1/004-stry-migration/Deploy.s.sol`
- Modify: `script/deployments/1/config/deploymentAddresses.json:8` (remove the `staked-stry` key)
- Rewrite: `script/deployments/1/004-stry-migration/WeeklyYield.s.sol` (whole file)
- Rewrite: `script/deployments/1/004-stry-migration/Verify.s.sol` (whole file; items 1–3 only, items 4–10 land in Task 4)
- Test: the fork run `SNAPSHOT_BLOCK=25800912 yarn verify:migration`, plus `forge build` and `forge test`

**Interfaces:**
- Consumes: `IMerklDistributionCreator.CampaignParameters` and every view listed in Task 1; `SafeBatchLib.path(address,string,uint256)`, `SafeBatchLib.write(address,string,uint256,string,string,Tx[])`, `SafeBatchLib.Tx{address to; bytes data;}`; `MerklCampaignLib.canonicalJson(uint256,address,address,address,uint32,uint32,uint32,address[],string)`, `MerklCampaignLib.campaignData(string)`, `MerklCampaignLib.isoUtc(uint256)`; `ConfigLib.addr/num/addrArray`; existing `StopEspnYield._preconditions()` and `Distribute.distribute(address,string)`.
- Produces, for Task 4 and for the run-book:
  - `WeeklyYield.weeklyYield(address safe, address usds, address stry, uint256 amount, uint32 startTimestamp, address[] memory blacklist) internal view returns (IMerklDistributionCreator.CampaignParameters memory params, bytes32 campaignId, string memory json)`
  - `WeeklyYield._needsAcceptConditions(IMerklDistributionCreator dc, address safe) internal view returns (bool)`
  - `WeeklyYield._merklFeeSplit(IMerklDistributionCreator dc, address creator, uint32 campaignType, uint256 amount) internal view returns (uint256 net, uint256 fee)`
  - `WeeklyYield.BASE_9 = 1e9` (`uint256 internal constant`)
  - The revert string `"WeeklyYield: WEEKLY_YIELD_AMOUNT is below Merkl's floor of rewardTokenMinAmounts(USDS) per campaign-hour (>= 168 USDS for a 7-day campaign)"`, asserted verbatim by Task 4's negative test.
- Removes: `StakedStrat`, `Deploy`, `Deploy.deploy(address,address,address)`, `Verify._pickLargestHolder`, `Verify.ZERO_STAKER_DEPOSIT`, `Verify.WEEKLY_DEPOSIT`, `Verify.CLAIM_TOLERANCE`, and the `.staked-stry` config key.

---

- [ ] **Step 11: Delete the staking contract, its test, its user stories and its deploy step**

  ```
  git rm src/StakedStrat.sol test/unit/StakedStratTest.sol docs/StakedStrat_User_Stories.md \
         script/deployments/1/004-stry-migration/Deploy.s.sol
  ```

  Then remove the `staked-stry` key from `script/deployments/1/config/deploymentAddresses.json`, leaving:

  ```json
  {
    "STRAT": "0x14cF922aa1512Adfc34409b63e18D391e4a86A2f",
    "convertible-note": "0xb96D4D74Dcb2F7899C74878d0727FFab009ACcc4",
    "cdt": "0xD4598307B5507A2b04d0502FCC9b68bbcA9275F3",
    "esETH": "0xE7A2F9b5fE8a3bb067c15ad08644d96b9dfDf9cb",
    "espn-redemption-token": "0x0000000000000000000000000000000000000000",
    "stry": "0x0000000000000000000000000000000000000000"
  }
  ```

  Two consequences to record in the commit message, not hide:

  - The **live sSTRAT contract** (`0xD6664390E0485Cd609d4D04b430e84e945a51994`, "Staked STRAT") *is* this source. It stays deployed and unaffected; the source stays in git history and on Etherscan's verified-source record. Deletion changes nothing on-chain.
  - `src/lib/TripwireGuard.sol`, `src/lib/TripwireController.sol` and `src/interfaces/ITripwireController.sol` **stay** — `StratToken`, `CdtToken`, `DesEthToken` and their tests use them. `docs/StratETHTreasuryLend_User_Stories.md:16` mentions `StakedStrat` as an example and is **left alone**. `internalAddresses.json`'s `.protocol.tripwire.controller` is **left in place**: a config key with no reader is inert, and removing it is unrelated churn on a file Track A does not touch.

- [ ] **Step 12: Rewrite `script/deployments/1/004-stry-migration/Verify.s.sol` down to Testing items 1–3**

  Complete file (items 4–10 are added in Task 4):

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {StdCheats} from "forge-std/StdCheats.sol";
  import {StdAssertions} from "forge-std/StdAssertions.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
  import {StryToken} from "src/StryToken.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {HoldersLib} from "../lib/HoldersLib.sol";
  import {IMerklDistributionCreator} from "./interfaces/IMerklDistributionCreator.sol";
  import {MerklCampaignLib} from "./MerklCampaignLib.sol";
  import {StopEspnYield} from "./StopEspnYield.s.sol";
  import {Distribute} from "./Distribute.s.sol";
  import {WeeklyYield} from "./WeeklyYield.s.sol";

  /// @notice Track B mainnet-fork Verify script. Same harness as Track A: vm.startPrank, not
  /// vm.startBroadcast, so no config or Safe batch file is written. Calls the other scripts'
  /// internal entry points, never their run()s.
  contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, WeeklyYield {
      /// @dev The fork Safe holds ~1.2M USDS, comfortably above this and above Merkl's 168 USDS
      /// floor for a 7-day campaign.
      uint256 internal constant FORK_YIELD_AMOUNT = 10_000e18;

      function run() external override(StopEspnYield, Distribute, WeeklyYield) {
          // Same derivation as 003-espn-redemption/Verify.s.sol: the holders file is named after the
          // snapshot block, so SNAPSHOT_BLOCK alone pins both the fork and the snapshot.
          uint256 snapshotBlockTarget = vm.envUint("SNAPSHOT_BLOCK");
          string memory holdersFile =
              string.concat("script/deployments/1/config/espn-holders-", vm.toString(snapshotBlockTarget), ".json");
          HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);

          // Item 0: fork block check.
          require(block.number >= snapshot.snapshotBlock, "Verify: fork block is behind snapshotBlock");
          if (block.number != snapshot.snapshotBlock) {
              console2.log("WARNING: fork block != snapshotBlock; export SNAPSHOT_BLOCK to fix:");
              console2.log(snapshot.snapshotBlock);
          }

          // Item 1: StopEspnYield -- the third-party outflow must be visible in test output, not
          // merely pass.
          (address usds, address espnAddr, address payer, uint256 finalYieldAmount) = _preconditions();
          EthStrategyPerpetualNote espn = EthStrategyPerpetualNote(espnAddr);
          uint256 totalAssetsBefore = espn.totalAssets();
          uint256 managerBalanceBefore = IERC20(usds).balanceOf(espn.manager());
          if (IERC20(usds).balanceOf(payer) < finalYieldAmount) {
              deal(usds, payer, finalYieldAmount);
          }
          vm.startPrank(payer);
          IERC20(usds).approve(espnAddr, finalYieldAmount);
          vm.expectEmit(true, false, false, true, espnAddr);
          emit EthStrategyPerpetualNote.AssetsPerShareIncreased(
              payer, totalAssetsBefore + finalYieldAmount, finalYieldAmount
          );
          espn.increaseAssetsPerShare(finalYieldAmount);
          vm.stopPrank();
          assertEq(
              espn.totalAssets(), totalAssetsBefore + finalYieldAmount, "Verify: totalAssets delta != finalYieldAmount"
          );
          assertEq(
              IERC20(usds).balanceOf(espn.manager()),
              managerBalanceBefore + finalYieldAmount,
              "Verify: USDS did not land at ESPN.manager()"
          );

          // Item 2: Distribute STRY (single mintBatch). This is the fork-fresh STRY address item 3
          // passes to weeklyYield as an argument -- never via deploymentAddresses.json.
          address stryDeployer = makeAddr("stryDeployer");
          vm.startPrank(stryDeployer);
          StryToken stry = distribute(stryDeployer, holdersFile);
          vm.stopPrank();
          assertEq(stry.owner(), address(0), "Verify: STRY ownership not renounced");

          // Item 3: build the campaign. No vm.warp is needed: the start is derived from the fork
          // clock, 48 hour-slots ahead, which is >= block.timestamp + 47h and hour-aligned, so it
          // satisfies weeklyYield's two WEEKLY_YIELD_START pre-conditions by construction.
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          address[] memory blacklist = ConfigLib.addrArray("settings.json", ".espnv3.merkl.blacklist");
          uint32 start = uint32((block.timestamp / 3600 + 48) * 3600);

          (IMerklDistributionCreator.CampaignParameters memory params, bytes32 campaignId, string memory json) =
              weeklyYield(safe, usds, address(stry), FORK_YIELD_AMOUNT, start, blacklist);

          IMerklDistributionCreator dc =
              IMerklDistributionCreator(ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator"));
          assertEq(campaignId, dc.campaignId(params), "Verify: returned campaignId != DistributionCreator.campaignId");
          assertEq(
              params.campaignData,
              abi.encodePacked(MerklCampaignLib.campaignData(json)),
              "Verify: params.campaignData != sha256 of the JSON the script would POST to Merkl"
          );
          // Independent re-derivation from the same inputs, so a transposed argument inside
          // weeklyYield fails here rather than on Merkl's engine a week later.
          assertEq(
              json,
              MerklCampaignLib.canonicalJson({
                  amount: FORK_YIELD_AMOUNT,
                  creator: safe,
                  rewardToken: usds,
                  targetToken: address(stry),
                  campaignType: params.campaignType,
                  startTimestamp: start,
                  duration: params.duration,
                  blacklist: blacklist,
                  url: ""
              }),
              "Verify: weeklyYield's canonical JSON does not match an independent re-derivation"
          );
          assertEq(uint256(params.campaignType), 18, "Verify: campaignType != 18 (ERC20LOGPROCESSOR)");
          assertEq(uint256(params.duration), 604_800, "Verify: duration != 604800 (7 days)");
          assertEq(params.creator, safe, "Verify: creator != the redemption Safe");
          assertEq(params.rewardToken, usds, "Verify: rewardToken != USDS");
          assertEq(params.amount, FORK_YIELD_AMOUNT, "Verify: amount != the requested gross");
          assertEq(params.campaignData.length, 32, "Verify: campaignData is not exactly 32 bytes");
      }
  }
  ```

- [ ] **Step 13: Run `forge build` to verify it fails for exactly the expected reason**

  ```
  forge build
  ```

  Expected: failure, with errors confined to `script/deployments/1/004-stry-migration/WeeklyYield.s.sol` — `Source "src/StakedStrat.sol" not found` on its import line, and `Identifier not found or not unique` for `StakedStrat` inside `weeklyYield`. If any error names a file other than `WeeklyYield.s.sol`, stop: something else still depends on the deleted contract and the deletion inventory in Step 11 is incomplete.

- [ ] **Step 14: Rewrite `script/deployments/1/004-stry-migration/WeeklyYield.s.sol`**

  Complete file:

  ```solidity
  // SPDX-License-Identifier: MIT
  pragma solidity ^0.8.24;

  import "forge-std/Script.sol";
  import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
  import {EthStrategyPerpetualNote} from "src/EthStrategyPerpetualNote.sol";
  import {ConfigLib} from "../lib/ConfigLib.sol";
  import {SafeBatchLib} from "../lib/SafeBatchLib.sol";
  import {IMerklDistributionCreator} from "./interfaces/IMerklDistributionCreator.sol";
  import {MerklCampaignLib} from "./MerklCampaignLib.sol";

  /// @notice Repeatable, manually triggered -- NOT one-time automation. No cron, keeper, or CI
  /// schedule. Amount per run comes from env WEEKLY_YIELD_AMOUNT (plain decimal wei) and the start
  /// from env WEEKLY_YIELD_START (hour-aligned unix seconds), not settings.json, because both
  /// change every run.
  ///
  /// Never broadcasts: the payer is the redemption Safe. Each run emits a Safe Transaction Builder
  /// batch -- USDS.approve(DistributionCreator, amount), acceptConditions() only when the live
  /// check demands it, DistributionCreator.createCampaign(params) -- creating a NEW 7-day Merkl
  /// campaign that pays USDS to plain STRY holders. There is no staking contract: holders do
  /// nothing but hold STRY, Merkl time-weights their balances off-chain, and they self-claim on
  /// Merkl's Distributor.
  ///
  /// createCampaign is idempotent per (creator, rewardToken, type, start, duration, campaignData)
  /// and reverts CampaignAlreadyExists on an exact duplicate, so an accidentally re-imported batch
  /// fails rather than double-paying.
  contract WeeklyYield is Script {
      uint256 internal constant BASE_9 = 1e9;

      function run() external virtual {
          address safe = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
          address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
          address stry = ConfigLib.addr("deploymentAddresses.json", ".stry");
          address dc = ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator");
          address[] memory blacklist = ConfigLib.addrArray("settings.json", ".espnv3.merkl.blacklist");
          uint256 amount = vm.envUint("WEEKLY_YIELD_AMOUNT");
          uint32 startTimestamp = uint32(vm.envUint("WEEKLY_YIELD_START"));

          (IMerklDistributionCreator.CampaignParameters memory params,, string memory json) =
              weeklyYield(safe, usds, stry, amount, startTimestamp, blacklist);

          // Store the canonical config with Merkl BEFORE writing the batch. The engine resolves
          // campaignData by looking the hash up in its config store, so an unstored hash is a
          // campaign it can never score. Storing is idempotent and has no on-chain effect, so
          // re-running this script is harmless; a network failure yields no batch at all rather
          // than an un-scoreable one.
          _storeConfig(json, params.campaignData);

          SafeBatchLib.Tx[] memory txs = _batch(dc, usds, safe, amount, params);
          SafeBatchLib.write(
              safe,
              "004-stry-migration",
              _firstFreeBatchIndex(safe),
              "Weekly STRY yield via Merkl",
              "Creates a new 7-day Merkl ERC20LOGPROCESSOR campaign paying USDS to STRY holders. Execute the transactions in the order listed.",
              txs
          );
      }

      /// @dev Pure computation plus live pre-condition reads. Writes no file and never calls
      /// vm.ffi -- run() alone does both -- so `yarn verify:migration`, which calls this directly,
      /// leaves `git status` clean.
      function weeklyYield(
          address safe,
          address usds,
          address stry,
          uint256 amount,
          uint32 startTimestamp,
          address[] memory blacklist
      )
          internal
          view
          returns (IMerklDistributionCreator.CampaignParameters memory params, bytes32 campaignId, string memory json)
      {
          IMerklDistributionCreator dc =
              IMerklDistributionCreator(ConfigLib.addr("externalAddresses.json", ".merkl.distributionCreator"));
          uint32 campaignType = uint32(ConfigLib.num("settings.json", ".espnv3.merkl.campaignType"));
          uint32 duration = uint32(ConfigLib.num("settings.json", ".espnv3.merkl.duration"));

          _merklPreconditions(dc, safe, usds, stry, amount, startTimestamp, duration);

          json = MerklCampaignLib.canonicalJson({
              amount: amount,
              creator: safe,
              rewardToken: usds,
              targetToken: stry,
              campaignType: campaignType,
              startTimestamp: startTimestamp,
              duration: duration,
              blacklist: blacklist,
              url: ""
          });

          params = IMerklDistributionCreator.CampaignParameters({
              campaignId: bytes32(0),
              creator: safe, // explicit, not address(0): campaignId hashes the creator field
              rewardToken: usds,
              amount: amount,
              campaignType: campaignType,
              startTimestamp: startTimestamp,
              duration: duration,
              campaignData: abi.encodePacked(MerklCampaignLib.campaignData(json))
          });
          campaignId = dc.campaignId(params);
          // campaignId is not one of the fields campaignId() hashes, so filling it in afterwards
          // does not change the id -- it just makes the batch's calldata self-describing and lets
          // Verify compare campaign(id) against params field for field.
          params.campaignId = campaignId;

          // campaignLookup REVERTS CampaignDoesNotExist() for an unknown id -- it does not return 0
          // (confirmed live on mainnet). So the duplicate guard is "did the lookup succeed", not a
          // value comparison. try/catch is legal from an internal view function.
          try dc.campaignLookup(campaignId) returns (uint256) {
              revert(
                  "WeeklyYield: a campaign with these exact parameters already exists -- change WEEKLY_YIELD_START or WEEKLY_YIELD_AMOUNT"
              );
          } catch {}

          _log(dc, params, json);
      }

      /// @dev acceptConditions() is per creator address and permanent for the current messageHash.
      /// The redemption Safe is on userSignatureWhitelist today, so the emitted batch has two
      /// transactions; the branch exists so a change of creator Safe, or a Merkl messageHash
      /// rotation, still produces a batch that executes.
      function _needsAcceptConditions(IMerklDistributionCreator dc, address safe) internal view returns (bool) {
          return dc.userSignatureWhitelist(safe) == 0 && dc.userSignatures(safe) != dc.messageHash();
      }

      /// @dev Mirrors DistributionCreator._computeFees exactly. campaignSpecificFees == 1 means
      /// zero fees; == 0 means the default applies. Mainnet today: campaignSpecificFees(18) == 0,
      /// defaultFees == 3e7 of BASE_9 == 3%, feeRebate(redemption Safe) == 0.
      function _merklFeeSplit(IMerklDistributionCreator dc, address creator, uint32 campaignType, uint256 amount)
          internal
          view
          returns (uint256 net, uint256 fee)
      {
          uint256 base = dc.campaignSpecificFees(campaignType);
          if (base == 1) base = 0;
          else if (base == 0) base = dc.defaultFees();
          uint256 fees = base * (BASE_9 - dc.feeRebate(creator)) / BASE_9;
          net = amount * (BASE_9 - fees) / BASE_9;
          fee = amount - net;
      }

      function _merklPreconditions(
          IMerklDistributionCreator dc,
          address safe,
          address usds,
          address stry,
          uint256 amount,
          uint32 startTimestamp,
          uint32 duration
      ) internal view {
          // Carried over from StopEspnYield/BuildOrder: the only cheap on-chain proof the
          // hand-copied USDS address is right.
          address espnAddr = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
          require(EthStrategyPerpetualNote(espnAddr).asset() == usds, "WeeklyYield: ESPN.asset() != USDS");

          // Same idea for the two Merkl addresses: prove they relate to each other on-chain.
          require(address(dc).code.length > 0, "WeeklyYield: .merkl.distributionCreator has no code");
          require(
              dc.distributor() == ConfigLib.addr("externalAddresses.json", ".merkl.distributor"),
              "WeeklyYield: .merkl.distributor != DistributionCreator.distributor()"
          );

          // A campaign targeting an undeployed or undistributed token is accepted by the contract
          // and pays nobody.
          require(stry.code.length > 0, "WeeklyYield: STRY has no code -- run Distribute.s.sol first");
          require(
              IERC20(stry).totalSupply() > 0,
              "WeeklyYield: STRY totalSupply() == 0 -- a campaign targeting an undistributed token pays nobody"
          );

          // Mirrors _createCampaign so the failure names the floor instead of a bare
          // CampaignRewardTooLow.
          uint256 minAmount = dc.rewardTokenMinAmounts(usds);
          require(minAmount != 0, "WeeklyYield: USDS is not whitelisted as a Merkl reward token");
          require(
              amount * 3600 >= minAmount * duration,
              "WeeklyYield: WEEKLY_YIELD_AMOUNT is below Merkl's floor of rewardTokenMinAmounts(USDS) per campaign-hour (>= 168 USDS for a 7-day campaign)"
          );

          require(IERC20(usds).balanceOf(safe) >= amount, "WeeklyYield: Safe USDS balance < WEEKLY_YIELD_AMOUNT");

          // The Safe executes hours or days after this script runs and the contract does not check
          // start against the clock, so a stale start silently produces a campaign that is already
          // partly elapsed when funded. Same forcing-function pattern as orderStartTime.
          require(
              startTimestamp > block.timestamp + 1 days,
              "WeeklyYield: WEEKLY_YIELD_START must be more than 1 day ahead -- the Safe executes hours or days after this script runs"
          );
          require(
              startTimestamp % 3600 == 0, "WeeklyYield: WEEKLY_YIELD_START must be hour-aligned (start % 3600 == 0)"
          );
      }

      /// @dev Everything the Safe signer needs to check before signing, including the URL that
      /// proves Merkl already holds the config this campaignData resolves to.
      function _log(
          IMerklDistributionCreator dc,
          IMerklDistributionCreator.CampaignParameters memory params,
          string memory json
      ) internal view {
          (uint256 net, uint256 fee) = _merklFeeSplit(dc, params.creator, params.campaignType, params.amount);
          console2.log("gross USDS pulled from the Safe:", params.amount);
          console2.log("Merkl fee:", fee);
          console2.log("net to Merkl Distributor:", net);
          console2.log("campaignId:");
          console2.logBytes32(params.campaignId);
          console2.log("campaignData (sha256 of the canonical config JSON):");
          console2.log(vm.toString(params.campaignData));
          console2.log("canonical config JSON (this is what run() POSTs to Merkl's config store):");
          console2.log(json);
          console2.log(string.concat("campaign start: ", MerklCampaignLib.isoUtc(params.startTimestamp)));
          console2.log(
              string.concat(
                  "campaign end:   ", MerklCampaignLib.isoUtc(uint256(params.startTimestamp) + params.duration)
              )
          );
          console2.log("SIGNER CHECK -- Merkl must already hold this config before you sign:");
          console2.log(string.concat("https://api.merkl.xyz/v4/config/hash/", vm.toString(params.campaignData)));
      }

      /// @dev Transactions in fixed execution order. The approval is for the exact amount, not
      /// type(uint256).max: the allowance is consumed in the same execution (_pullTokens does one
      /// safeTransferFrom for the net leg and one for the fee leg, both from the Safe) and nothing
      /// should be left standing -- same reasoning as Cancel.s.sol's revoke.
      function _batch(
          address dc,
          address usds,
          address safe,
          uint256 amount,
          IMerklDistributionCreator.CampaignParameters memory params
      ) internal view returns (SafeBatchLib.Tx[] memory txs) {
          bool needsAccept = _needsAcceptConditions(IMerklDistributionCreator(dc), safe);
          txs = new SafeBatchLib.Tx[](needsAccept ? 3 : 2);
          txs[0] = SafeBatchLib.Tx({to: usds, data: abi.encodeCall(IERC20.approve, (dc, amount))});
          uint256 i = 1;
          if (needsAccept) {
              txs[i++] = SafeBatchLib.Tx({to: dc, data: abi.encodeCall(IMerklDistributionCreator.acceptConditions, ())});
          }
          txs[i] = SafeBatchLib.Tx({to: dc, data: abi.encodeCall(IMerklDistributionCreator.createCampaign, (params))});
          console2.log("Safe batch transaction count (3 means acceptConditions() is included):", txs.length);
      }

      /// @dev The one off-chain call, and it lives in run() only -- never in weeklyYield(), which
      /// Verify.s.sol calls. ffi = true is already global in foundry.toml. The response is asserted
      /// against the locally computed hash, so a compromised response cannot alter the batch.
      function _storeConfig(string memory json, bytes memory expectedHash) internal {
          string[] memory curl = new string[](9);
          curl[0] = "curl";
          curl[1] = "-sS";
          curl[2] = "-X";
          curl[3] = "POST";
          curl[4] = "https://api.merkl.xyz/v4/config/store";
          curl[5] = "-H";
          curl[6] = "content-type: application/json";
          curl[7] = "--data";
          curl[8] = json;

          bytes memory response = vm.ffi(curl);
          console2.log("POST https://api.merkl.xyz/v4/config/store returned:");
          console2.log(vm.toString(response));
          // forge decodes an ffi stdout that looks like 0x-prefixed hex into raw bytes and returns
          // anything else verbatim, so accept either encoding of the same hash.
          require(
              keccak256(response) == keccak256(expectedHash)
                  || keccak256(response) == keccak256(bytes(vm.toString(expectedHash))),
              "WeeklyYield: Merkl config/store did not return the locally computed campaignData hash"
          );
      }

      /// @dev This is the repo's first repeatable batch producer, and SafeBatchLib.write ends in
      /// vm.writeFile, which overwrites silently. A stale index would rewrite a previous week's
      /// batch in place with a different campaignData and amount, with no error -- and a batch
      /// mid-signature-collection in the Safe UI would stop matching what the next signer diffs
      /// against. So there is no index env var and no manual counter: 001 is taken by
      /// StopEspnYield.s.sol, so start at 2 and take the first free index. Redoing a week whose
      /// batch was generated but not signed means deleting that file first -- a deliberate act on
      /// a named path.
      function _firstFreeBatchIndex(address safe) internal view returns (uint256 index) {
          for (index = 2;; ++index) {
              if (!vm.exists(SafeBatchLib.path(safe, "004-stry-migration", index))) return index;
          }
      }
  }
  ```

- [ ] **Step 15: Run the unit suite and the build to verify they pass**

  ```
  forge build
  forge test
  forge fmt --check
  ```

  Expected: `forge build` succeeds with `src/StakedStrat.sol` absent; `forge test` green (the `StakedStratTest` suite is gone, `MerklCampaignLibTest` and `ScriptLibsTest` pass); `forge fmt --check` prints nothing.

- [ ] **Step 16: Run the fork verification for items 1–3 and confirm the tree stays clean**

  ```
  SNAPSHOT_BLOCK=25800912 yarn verify:migration
  git status --porcelain -- script/deployments/1/config script/deployments/1/multisig
  ```

  Expected: the script completes with no revert, printing the `mintBatch` gas lines from `Distribute`, then the `_log` block — gross/fee/net, `campaignId`, `campaignData`, the canonical JSON, and ISO start/end 48 hours apart — followed by no assertion failure. The scoped `git status --porcelain` prints **nothing**: no `deploymentAddresses.json` change, no file under `script/deployments/1/multisig/`. Output there is a failure of the structural rule, not a pass. Untracked paths elsewhere in the tree (e.g. `script/safe-propose/`, `script/multisig/`) are pre-existing and unrelated — do not stage them, and do not read them as a failure.

- [ ] **Step 17: Commit**

  ```
  git add src/StakedStrat.sol test/unit/StakedStratTest.sol docs/StakedStrat_User_Stories.md \
          script/deployments/1/004-stry-migration/Deploy.s.sol \
          script/deployments/1/004-stry-migration/WeeklyYield.s.sol \
          script/deployments/1/004-stry-migration/Verify.s.sol \
          script/deployments/1/config/deploymentAddresses.json
  git status --short   # confirm nothing else is staged before committing
  git commit -m "feat(004-stry-migration)!: pay STRY yield via Merkl, delete StakedStrat

  WeeklyYield.s.sol now builds Merkl CampaignParameters (campaignData =
  sha256(canonicalJson)), asserts live pre-conditions, POSTs the config to Merkl's
  config store from run() only, and emits a Safe batch at the first free never-
  overwritten index -- approve, conditional acceptConditions, createCampaign. It no
  longer broadcasts and no longer moves USDS itself.

  Deletes src/StakedStrat.sol, its unit test, its user stories, 004's Deploy.s.sol and
  the .staked-stry config key. The live sSTRAT contract 0xD6664390... is this source; it
  stays deployed and unaffected, and the source stays in git history and on Etherscan.
  TripwireGuard/TripwireController stay -- StratToken, CdtToken and DesEthToken use them.

  Verify.s.sol keeps items 1-2 unchanged and covers Testing item 3; items 4-10 follow.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TZWFMQom5wUTiyQXvGtZSX"
  ```

  The paths are enumerated deliberately — **do not** use `git add -A src script test`. `-A` on `script/` recursively stages every untracked tree under it, and this working tree has unrelated in-progress work there (`script/multisig/`, `script/safe-propose/`) that must not land in this commit. The four deleted paths are already staged by Step 11's `git rm`; re-listing them is harmless and makes the set explicit. `git status --short` should show only the paths above.

---

## Task 4: `Verify.s.sol` — Testing items 4–10 against Merkl's real mainnet contracts

Depends on Task 3. This is the half of verification that actually spends the USDS: it executes the emitted batch's calls under `vm.startPrank(safe, safe)` against the real `DistributionCreator` on a fork, asserts the campaign is registered with the expected fields and the three balances moved by the expected amounts, and drives the three negative paths.

**Files:**
- Modify: `script/deployments/1/004-stry-migration/Verify.s.sol` (extend `run()`, add four internal helpers)
- Test: the fork run `SNAPSHOT_BLOCK=25800912 yarn verify:migration`

**Interfaces:**
- Consumes, all from Task 3: `weeklyYield(address,address,address,uint256,uint32,address[]) → (CampaignParameters,bytes32,string)`, `_needsAcceptConditions(IMerklDistributionCreator,address) → bool`, `_merklFeeSplit(IMerklDistributionCreator,address,uint32,uint256) → (uint256,uint256)`, `BASE_9`, the floor revert string; from Task 1 the full `IMerklDistributionCreator` surface and its four errors; `SafeBatchLib` is **not** used here (Verify never writes a batch).
- Produces: the measured `createCampaign` gas figures Task 5 puts in the run-book's §5 table.

---

- [ ] **Step 18: Write the failing assertions — extend `run()` with items 4–10**

  Append to `run()`, immediately after the item-3 assertions written in Step 12:

  ```solidity
          // Item 4: execute the batch's calls in the emitted order, as the Safe. startPrank's
          // two-argument form also sets tx.origin, because Merkl's hasSigned modifier reads both.
          {
              (uint256 net, uint256 fee) = _merklFeeSplit(dc, safe, params.campaignType, params.amount);
              // The Safe holds ~1.2M USDS on this fork, so assert the real balance rather than
              // faking it; deal only if a future fork block is short.
              if (IERC20(usds).balanceOf(safe) < params.amount) {
                  console2.log("WARNING: fork Safe USDS balance short -- dealing instead of using the real balance");
                  deal(usds, safe, params.amount);
              }
              address distributorAddr = dc.distributor();
              address feeRecipientAddr = dc.feeRecipient();
              uint256 safeBefore = IERC20(usds).balanceOf(safe);
              uint256 distributorBefore = IERC20(usds).balanceOf(distributorAddr);
              uint256 feeRecipientBefore = IERC20(usds).balanceOf(feeRecipientAddr);

              // The script omits acceptConditions() from the batch when the Safe is whitelisted.
              // Assert the branch agrees with the live state rather than trusting either alone.
              assertEq(dc.userSignatureWhitelist(safe), 1, "Verify: redemption Safe is no longer Merkl-whitelisted");
              assertFalse(
                  _needsAcceptConditions(dc, safe),
                  "Verify: script would include acceptConditions() for a whitelisted Safe"
              );

              vm.startPrank(safe, safe);
              IERC20(usds).approve(address(dc), params.amount);
              uint256 gasBefore = gasleft();
              bytes32 createdId = dc.createCampaign(params);
              uint256 executionGas = gasBefore - gasleft();
              vm.stopPrank();

              assertEq(createdId, campaignId, "Verify: createCampaign returned a different id than campaignId()");

              // Item 5: registration. campaignLookup reverts CampaignDoesNotExist() for an unknown
              // id and returns index-1 otherwise, so "registered" means "this call does not revert".
              try dc.campaignLookup(createdId) returns (uint256) {}
              catch {
                  revert("Verify: campaign is not registered");
              }
              IMerklDistributionCreator.CampaignParameters memory stored = dc.campaign(createdId);
              assertEq(stored.campaignId, campaignId, "Verify: stored campaignId mismatch");
              assertEq(stored.creator, safe, "Verify: stored creator != the redemption Safe");
              assertEq(stored.rewardToken, usds, "Verify: stored rewardToken != USDS");
              assertEq(uint256(stored.campaignType), 18, "Verify: stored campaignType != 18");
              assertEq(uint256(stored.startTimestamp), uint256(start), "Verify: stored startTimestamp mismatch");
              assertEq(uint256(stored.duration), 604_800, "Verify: stored duration != 604800");
              assertEq(stored.campaignData, params.campaignData, "Verify: stored campaignData mismatch");
              // DistributionCreator stores the amount NET of fees -- confirmed on mainnet against
              // the treasury's own campaign (23.2 -> 22.504 wETH at the default 3%).
              assertEq(stored.amount, net, "Verify: stored amount != gross * (1e9 - fees) / 1e9");

              // Item 6: balances.
              assertEq(IERC20(usds).balanceOf(safe), safeBefore - params.amount, "Verify: Safe USDS delta != -gross");
              assertEq(
                  IERC20(usds).balanceOf(distributorAddr),
                  distributorBefore + net,
                  "Verify: Distributor USDS delta != +net"
              );
              assertEq(
                  IERC20(usds).balanceOf(feeRecipientAddr),
                  feeRecipientBefore + fee,
                  "Verify: feeRecipient USDS delta != +fee"
              );
              assertEq(
                  IERC20(usds).allowance(safe, address(dc)),
                  0,
                  "Verify: USDS allowance to DistributionCreator not fully consumed"
              );

              // Item 10: gas, in the Step 23 two-line format. The calldata term is an upper bound
              // (16 gas per byte, ignoring the 4-gas discount on zero bytes).
              uint256 calldataGasEstimate =
                  21_000 + abi.encodeCall(IMerklDistributionCreator.createCampaign, (params)).length * 16;
              console2.log("createCampaign execution gas:", executionGas);
              console2.log(
                  "createCampaign total estimated (execution + 21000 intrinsic + calldata):",
                  executionGas + calldataGasEstimate
              );
          }

          // Items 7-9: the negative paths.
          _assertRejectsBelowMinimum(dc, safe, usds, address(stry), start, blacklist);
          _assertRejectsDuplicate(dc, safe, usds, params);
          _assertUnsignedCreatorMustAcceptConditions(dc, usds, params);
  ```

  And add these four members to the contract, after `run()`:

  ```solidity
      /// @dev Item 7. Both halves of the same floor: Merkl's own revert, and the script's named
      /// pre-condition, which exists so the operator sees the 168 USDS figure instead of a bare
      /// CampaignRewardTooLow.
      function _assertRejectsBelowMinimum(
          IMerklDistributionCreator dc,
          address safe,
          address usds,
          address stry,
          uint32 start,
          address[] memory blacklist
      ) internal {
          uint256 tooLow = dc.rewardTokenMinAmounts(usds) * 168 - 1;

          // A different start keeps the campaignId distinct from the one already created, so this
          // reverts on the amount and not on CampaignAlreadyExists.
          IMerklDistributionCreator.CampaignParameters memory low = IMerklDistributionCreator.CampaignParameters({
              campaignId: bytes32(0),
              creator: safe,
              rewardToken: usds,
              amount: tooLow,
              campaignType: 18,
              startTimestamp: start + 3600,
              duration: 604_800,
              campaignData: abi.encodePacked(
                  MerklCampaignLib.campaignData(
                      MerklCampaignLib.canonicalJson({
                          amount: tooLow,
                          creator: safe,
                          rewardToken: usds,
                          targetToken: stry,
                          campaignType: 18,
                          startTimestamp: start + 3600,
                          duration: 604_800,
                          blacklist: blacklist,
                          url: ""
                      })
                  )
              )
          });

          vm.startPrank(safe, safe);
          IERC20(usds).approve(address(dc), tooLow);
          vm.expectRevert(IMerklDistributionCreator.CampaignRewardTooLow.selector);
          dc.createCampaign(low);
          IERC20(usds).approve(address(dc), 0);
          vm.stopPrank();

          // The script's own pre-condition, asserted through an external call boundary --
          // weeklyYield is an internal function, so vm.expectRevert cannot observe its revert
          // otherwise (same reason as ScriptLibsTest._loadExternal).
          vm.expectRevert(
              bytes(
                  "WeeklyYield: WEEKLY_YIELD_AMOUNT is below Merkl's floor of rewardTokenMinAmounts(USDS) per campaign-hour (>= 168 USDS for a 7-day campaign)"
              )
          );
          this.weeklyYieldExternal(safe, usds, stry, tooLow, start + 3600, blacklist);
      }

      /// @dev External wrapper so vm.expectRevert has a CALL boundary to observe.
      function weeklyYieldExternal(
          address safe,
          address usds,
          address stry,
          uint256 amount,
          uint32 startTimestamp,
          address[] memory blacklist
      ) external view returns (IMerklDistributionCreator.CampaignParameters memory, bytes32, string memory) {
          return weeklyYield(safe, usds, stry, amount, startTimestamp, blacklist);
      }

      /// @dev Item 8. _createCampaign pulls the tokens before it checks the id, so the allowance
      /// has to be re-granted for the attempt even though it reverts and rolls back.
      function _assertRejectsDuplicate(
          IMerklDistributionCreator dc,
          address safe,
          address usds,
          IMerklDistributionCreator.CampaignParameters memory params
      ) internal {
          if (IERC20(usds).balanceOf(safe) < params.amount) deal(usds, safe, params.amount);
          vm.startPrank(safe, safe);
          IERC20(usds).approve(address(dc), params.amount);
          vm.expectRevert(IMerklDistributionCreator.CampaignAlreadyExists.selector);
          dc.createCampaign(params);
          IERC20(usds).approve(address(dc), 0);
          vm.stopPrank();
      }

      /// @dev Item 9. Proves the conditional second transaction is the right shape for a Safe that
      /// is not on userSignatureWhitelist: createCampaign reverts NotSigned, acceptConditions()
      /// fixes it, the identical call then succeeds. campaignData is deliberately left as the
      /// whitelisted Safe's -- the creator field alone makes the campaignId distinct, and on a
      /// fork there is no engine to resolve the config.
      function _assertUnsignedCreatorMustAcceptConditions(
          IMerklDistributionCreator dc,
          address usds,
          IMerklDistributionCreator.CampaignParameters memory params
      ) internal {
          address unsigned = makeAddr("unsignedCreator");
          assertEq(dc.userSignatureWhitelist(unsigned), 0, "Verify: the unsigned fixture address is whitelisted");
          deal(usds, unsigned, params.amount);

          IMerklDistributionCreator.CampaignParameters memory p = params;
          p.creator = unsigned;
          p.campaignId = bytes32(0);

          vm.startPrank(unsigned, unsigned);
          IERC20(usds).approve(address(dc), params.amount);
          vm.expectRevert(IMerklDistributionCreator.NotSigned.selector);
          dc.createCampaign(p);

          dc.acceptConditions();
          assertEq(dc.userSignatures(unsigned), dc.messageHash(), "Verify: acceptConditions did not record a signature");
          assertFalse(_needsAcceptConditions(dc, unsigned), "Verify: script would still ask a signed creator to sign");

          bytes32 unsignedId = dc.createCampaign(p);
          vm.stopPrank();
          // Same semantics as item 5: registration is proven by campaignLookup not reverting.
          try dc.campaignLookup(unsignedId) returns (uint256) {}
          catch {
              revert("Verify: campaign not registered after acceptConditions()");
          }
      }
  ```

- [ ] **Step 19: Run the fork verification to confirm it fails before the code is complete**

  ```
  SNAPSHOT_BLOCK=25800912 yarn verify:migration
  ```

  Run this **after writing the item 4–10 block but before adding the four helpers** to see the intended red state. Expected: compilation fails with `Undeclared identifier: _assertRejectsBelowMinimum` (and the two siblings). Add the helpers, then proceed to Step 20.

- [ ] **Step 20: Run the fork verification to verify it passes**

  ```
  forge build
  forge fmt --check
  SNAPSHOT_BLOCK=25800912 yarn verify:migration
  ```

  Expected: the script runs items 1–10 with no revert and no failed assertion. Printed, in order: `mintBatch` gas from `Distribute`; the `_log` block; `Safe batch transaction count (3 means acceptConditions() is included): 2`; then `createCampaign execution gas: <n>` and `createCampaign total estimated (execution + 21000 intrinsic + calldata): <n>`. **Write both numbers down — Task 5 Step 24 puts them in the run-book's §5 table.**

  If item 6's `feeRecipient` assertion fails by exactly the fee, re-read `defaultFees()`/`campaignSpecificFees(18)` on the fork block: `_merklFeeSplit` mirrors `_computeFees` and a mismatch means Merkl changed the fee schedule, not that the arithmetic is wrong.

- [ ] **Step 21: Confirm the working tree is clean**

  ```
  git status --porcelain -- script/deployments/1/config script/deployments/1/multisig
  ```

  Expected: no output. `Verify.s.sol` calls only internal entry points, so no `deploymentAddresses.json` write and no file under `script/deployments/1/multisig/`. Output from this scoped check is a failure of the structural rule. Untracked paths elsewhere in the tree (e.g. `script/safe-propose/`, `script/multisig/`) are pre-existing and unrelated — do not stage them, and do not read them as a failure.

- [ ] **Step 22: Commit**

  ```
  git add script/deployments/1/004-stry-migration/Verify.s.sol
  git commit -m "test(004-stry-migration): fork-verify the Merkl campaign end to end

  Executes the emitted batch's calls under vm.startPrank(safe, safe) against Merkl's
  real mainnet DistributionCreator: asserts the campaign registers with the expected
  fields and a fee-net amount, that Safe/Distributor/feeRecipient balances move by
  gross/net/fee and the allowance is fully consumed, and three negative paths --
  CampaignRewardTooLow (contract and script pre-condition), CampaignAlreadyExists, and
  NotSigned followed by acceptConditions() for a non-whitelisted creator. Logs
  createCampaign gas in the two-line execution/total format.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TZWFMQom5wUTiyQXvGtZSX"
  ```

---

## Task 5: Run-book and prior-document edits

Depends on Task 4 for the `createCampaign` gas number. There is **no UI**: `docs/ESPNv3_Runbook.md` is the entire operator- and holder-facing interface, and it currently documents a staking flow that no longer exists.

The numbering of Assumptions 1–13 is **kept** so every existing cross-reference stays valid; retired ones are struck in place, not renumbered.

**Files:**
- Modify: `docs/ESPNv3_Runbook.md` (§1, §2, §5, §6, §7, §9)
- Modify: `docs/superpowers/plans/2026-08-21-espnv3-redemption-migration-plan.md` (Task 5 file list, Steps 26–28, Definition of done, dependency section)
- Modify: `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md` (one superseded-by line)

**Interfaces:**
- Consumes: the batch path pattern `script/deployments/1/multisig/004-stry-migration/<NNN>-0x0cbe9bDD-multisig.json` with `NNN ≥ 002` (Task 3), the fixed transaction order (Task 3), the env contract `WEEKLY_YIELD_AMOUNT` + `WEEKLY_YIELD_START` (Task 3), and the measured `createCampaign` gas figures (Task 4 Step 20).
- Produces: documentation only; nothing imports it.

---

- [ ] **Step 23: Write the failing check**

  Run the greps that must come back empty once the docs are correct:

  ```
  grep -n "StakedStrat\|staked-stry\|stake(STRY)\|sSTRAT-v2\|syncRewards\|Deploy.s.sol" docs/ESPNv3_Runbook.md
  grep -n "staked-stry\|StakedStrat" docs/superpowers/plans/2026-08-21-espnv3-redemption-migration-plan.md | grep -v "ZERO code changes"
  grep -c "Supersede" docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md
  ```

  Expected now: the first grep prints roughly a dozen hits across §1 (Assumptions 2, 4, 12), §2 (rows 7–8 and the zero-staker paragraph), §5 (the four staking gas rows), §7 (the step-7 and step-8 rows and the prose below the table) and §9 (the whole section); the second prints the Task 5 file list and dependency-section hits; the third prints `0`.

- [ ] **Step 24: Edit `docs/ESPNv3_Runbook.md`**

  Apply exactly these, section by section:

  - **§1 header (lines 10–11).** Replace "These are Explicit Assumptions 1-13 from the design spec. All 13 need sign-off before mainnet. Five of them gate the schedule itself:" with:

    > These are Explicit Assumptions 1–13 from the design spec, of which **4 and 12 are retired — Merkl replaces the staking contract**. The remaining 11 need sign-off before mainnet. Four of them gate the schedule itself:

  - **§1 Assumption 2 — kept and restated, not dropped.** Replace the line with:

    > - [ ] 2. **Reward token for the weekly Merkl campaign = USDS.** Merkl-whitelisted, minimum 1 USDS per campaign-hour (≥ 168 USDS per 7-day campaign) — confirmed on-chain. Founder sign-off on USDS as the yield token: **still open.**

    The on-chain fact proves Merkl *accepts* USDS as an incentive token; it says nothing about whether USDS is the token the founder intends STRY holders to be paid in, which is what this assumption actually asks.

  - **§1 Assumptions 4 and 12 — retired in place.** Replace each line's body with a one-line strike, keeping the numbers:

    > - [x] 4. ~~Tripwire controller — BLOCKS TRACK B.~~ **Retired:** no `StakedStrat` instance is deployed; Merkl distributes directly to STRY holders.
    > - [x] 12. ~~`StakedStrat`'s new instance is cosmetically named "Staked STRAT v2".~~ **Retired:** no `StakedStrat` instance is deployed; Merkl distributes directly to STRY holders.

  - **§1 line 30.** "**Assumptions 1, 4, 7, 8 and 9 gate the schedule**" → "**Assumptions 1, 7, 8 and 9 gate the schedule**".

  - **§2 table row 0.** "Close Assumptions 1, 4, 7, 8, 9" → "Close Assumptions 1, 7, 8, 9".

  - **§2 table, new row 0b** (immediately after row 0), carrying the pre-flight the spec's Open Risk 4 requires:

    | 0b | Before the **first** `WeeklyYield.s.sol` run: message Merkl support with the STRY address so the campaign is displayed and priced. `ERC20LOGPROCESSOR` scores any ERC20 from its `Transfer` logs and needs no on-chain registration; this is a UI/API-recognition step only. | B |

  - **§2 table rows 7 and 8** become a single row:

    | 7 | Track B `WeeklyYield.s.sol` (Safe batch: `approve` [+ `acceptConditions`] + `createCampaign`), weekly, from step 4 onward | B |

    Renumber the former row 9 (`Cancel.s.sol`) to 8.

  - **§2.** Delete the paragraph "Step 8's order matters: yield deposited into `StakedStrat` with zero stakers is destroyed permanently."

  - **§5.** Replace the four staking rows (`stake`, `syncRewards` (WeeklyYield), `claim`, `unstake`) in the `verify:migration` table with one row carrying the two numbers measured in Task 4 Step 20:

    | `createCampaign` (Merkl, weekly) | *(execution gas from the verify run)* (*(total estimated)* total estimated) |

  - **§6.** Add a fourth bullet to the batch-path list and a fourth entry to the execution-order list:

    > - `script/deployments/1/multisig/004-stry-migration/<NNN>-0x0cbe9bDD-multisig.json`, `NNN ≥ 002` — `WeeklyYield.s.sol`, one new file per weekly run. The index is **allocated by the script as the first free one** (`001` belongs to `StopEspnYield.s.sol`); it is never an env var and an existing weekly batch is never overwritten. To redo a week whose batch was generated but not yet signed, delete that file first.
    >
    > 4. **`WeeklyYield.s.sol` batch:** `USDS.approve(DistributionCreator, amount)` **then** `DistributionCreator.acceptConditions()` — *included only when the live check demands it; with the redemption Safe on Merkl's `userSignatureWhitelist` today, the batch has two transactions, not three* — **then** `DistributionCreator.createCampaign(params)`.

  - **§7 env table.** Delete the step-7 row (`004-stry-migration/Deploy.s.sol`). Delete the step-8 `WeeklyYield.s.sol` row from this broadcast table entirely and move it to §6's Safe-batch list, since it no longer broadcasts; note there that its env is `WEEKLY_YIELD_AMOUNT` (plain decimal wei, changes every run) and `WEEKLY_YIELD_START` (hour-aligned unix seconds, more than 1 day ahead), and that **there is no index var**. Renumber the remaining `Cancel.s.sol` row from step 9 to step 8 to match §2.

  - **§7 prose (lines 224–227).** Replace with:

    > Steps 1, 5, 7, 8 (`StopEspnYield`, `BuildOrder`, `WeeklyYield`, `Cancel`) never broadcast — each writes a Safe batch instead (see section 6). Steps 3 and 4 broadcast directly from the deployer's own key: the two `Distribute` scripts mint and airdrop. `WeeklyYield.s.sol` writes a Safe batch that the redemption Safe executes — it never broadcasts and never moves USDS itself.

  - **§8.** Add a `WEEKLY_YIELD_START` entry after the `finalYieldAmount` paragraph:

    > `WEEKLY_YIELD_START` is Track B's stale-value forcing function, the same role `orderStartTime` plays for Track A. `WeeklyYield.s.sol` hard-reverts unless `start > block.timestamp + 1 day` **and** `start % 3600 == 0`, so a start left over from last week cannot produce a campaign that is already partly elapsed by the time the Safe funds it. Merkl's `createCampaign` does not check `startTimestamp` against the clock, which is why the script must.

  - **§9.** Replace the whole section with holder claim notes:

    > ## 9. Track B holder notes
    >
    > - **Hold STRY. That is the whole action.** There is no staking step, no position token, and no approval to give. Merkl reads STRY `Transfer` logs, time-weights each holder's balance over the campaign week, and splits the week's USDS pro-rata.
    > - **Claim on Merkl.** Use app.merkl.xyz, or call `Distributor.claim(users, tokens, amounts, proofs)` on `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` directly. Leaves are cumulative, and Merkl's API serves the proofs.
    > - **Timing.** The engine scores roughly every 2 hours and posts a merkle root roughly every 8 hours (4–12 h), with a 1–2 h dispute window before newly posted rewards become claimable. Expect rewards to appear ~8–12 h after each campaign hour is scored, not instantly.
    > - **Contracts that hold STRY and cannot call `claim` — LP pairs above all — accrue rewards they can never collect**, unless they are blacklisted from the campaign or the rewards are forwarded. `settings.json` ships `.espnv3.merkl.blacklist = []`, i.e. nothing is blacklisted today.
    > - **A 3% Merkl fee is deducted from each weekly amount** before it reaches the Distributor. The script logs gross, fee and net every run so the signer sees it.
    > - **`$100 is a nominal basis price, not a redemption guarantee.`** STRY nominally claims the full ESPN backing at the snapshot; it is not backed to the extent Track A's 700,000 USDS redemption pool is.
    > - **Merkl's off-chain half is not covered by `yarn verify:migration`** — scoring, merkle-root posting and holder claims cannot be exercised on a fork. The acceptance check is manual: within ~12 h of the Safe executing a weekly batch, confirm `GET https://api.merkl.xyz/v4/campaigns?chainId=1&creatorAddress=0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` lists the new campaign with `type: ERC20LOGPROCESSOR` and a non-zero `apr`/`dailyRewards`. If it does not, the campaign is funded but unscoreable — escalate before the next weekly run.

- [ ] **Step 25: Edit `docs/superpowers/plans/2026-08-21-espnv3-redemption-migration-plan.md`**

  Apply exactly these, and reset the checkboxes on every replaced step from `[x]` to `[ ]`:

  - **Task 5 preamble.** Delete the paragraph beginning "**`src/StakedStrat.sol` gets ZERO code changes.**" Delete the `.staked-stry` mention from the runtime-write sentence, leaving "(`.stry` here; `.espn-redemption-token` in Task 4)".
  - **Task 5 file list.** Remove `script/deployments/1/004-stry-migration/Deploy.s.sol`; add `script/deployments/1/004-stry-migration/interfaces/IMerklDistributionCreator.sol` and `script/deployments/1/004-stry-migration/MerklCampaignLib.sol`.
  - **Step 26.** Delete the step in full.
  - **Step 27.** Replace the body with: "Superseded. `WeeklyYield.s.sol` no longer transfers USDS to a staking contract; it emits a Safe batch creating a weekly Merkl campaign. See the Architecture section of [`../specs/2026-09-04-stry-merkl-yield-design.md`](../specs/2026-09-04-stry-merkl-yield-design.md) and Task 3 of [`2026-09-04-stry-merkl-yield-plan.md`](2026-09-04-stry-merkl-yield-plan.md)."
  - **Step 28.** Keep items 1–2 as written. Replace items 3–9 with: "Superseded by the Testing approach of [`../specs/2026-09-04-stry-merkl-yield-design.md`](../specs/2026-09-04-stry-merkl-yield-design.md) items 3–10, implemented in Tasks 3 and 4 of [`2026-09-04-stry-merkl-yield-plan.md`](2026-09-04-stry-merkl-yield-plan.md)." Delete the "Verify Task 5" paragraph's "all nine items" claim and its `TripwireController` sentence.
  - **Task dependency order section.** Delete the `.staked-stry` mention from the "One runtime write is shared" paragraph.
  - **Definition of done.** Change "`SNAPSHOT_BLOCK=<block> yarn verify:migration` **passes end to end, all nine steps.** There is no accepted early exit: the fork deploys its own `TripwireController`. An unresolved Assumption 4 blocks the mainnet broadcast of `Deploy.s.sol` and nothing else." to "`SNAPSHOT_BLOCK=<block> yarn verify:migration` **passes end to end** — see the Definition of done in [`2026-09-04-stry-merkl-yield-plan.md`](2026-09-04-stry-merkl-yield-plan.md)." Delete "No changes to `src/StakedStrat.sol`," from the final bullet, leaving "No changes to `src/EthStrategyPerpetualNote.sol`, or any other existing contract."

- [ ] **Step 26: Add the superseded-by line to `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md`**

  Insert one line immediately after the `- **Chain:**` bullet in the header block. No other change — this is a historical document and it is not rewritten:

  ```markdown
  - **Superseded (in part):** Track B's staking design is superseded by [`2026-09-04-stry-merkl-yield-design.md`](2026-09-04-stry-merkl-yield-design.md).
  ```

- [ ] **Step 27: Run the checks to verify they pass, then commit**

  ```
  grep -n "StakedStrat\|staked-stry\|stake(STRY)\|sSTRAT-v2\|syncRewards\|Deploy.s.sol" docs/ESPNv3_Runbook.md
  grep -n "api.merkl.xyz/v4/campaigns" docs/ESPNv3_Runbook.md
  grep -c "Supersede" docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md
  ```

  Expected: the first grep prints **nothing**; the second prints exactly **one** hit (the §9 manual acceptance check); the third prints `1`. Then:

  ```
  git add docs/ESPNv3_Runbook.md \
          docs/superpowers/plans/2026-08-21-espnv3-redemption-migration-plan.md \
          docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md
  git commit -m "docs: run-book and prior plan reflect Merkl yield, not StakedStrat

  Retires Assumptions 4 and 12 in place (numbering kept so cross-references stay
  valid), restates Assumption 2 as 'USDS is Merkl-accepted, founder sign-off still
  open', collapses the two Track B sequence rows into one weekly WeeklyYield row,
  replaces the four staking gas rows with the measured createCampaign figure,
  documents the never-overwritten weekly batch path and its fixed transaction order,
  moves WeeklyYield out of the broadcast table, adds WEEKLY_YIELD_START as Track B's
  stale-value forcing function, and rewrites the holder notes for self-claiming on
  Merkl. Points the 2026-08-21 plan's Steps 26-28 and the 2026-08-21 spec at the new
  design.

  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01TZWFMQom5wUTiyQXvGtZSX"
  ```

---

## Definition of done

- `forge build` succeeds with `src/StakedStrat.sol` absent.
- `FOUNDRY_PROFILE=integration forge build` clean.
- `yarn test` green, including the six `MerklCampaignLibTest` assertions (both mainnet-fixture hashes, the exact stored string, blacklist serialisation, amount sensitivity, the ISO window) and the four new/changed `ScriptLibsTest` assertions.
- `forge fmt --check` clean.
- `SNAPSHOT_BLOCK=25800912 yarn verify:migration` passes Testing items 1–10 end to end, with no accepted early exit, and prints both `createCampaign` gas figures.
- `git status --porcelain -- script/deployments/1/config script/deployments/1/multisig` is empty after the verify run — no `deploymentAddresses.json` write, no file under `script/deployments/1/multisig/`, no config file dirty. (Unrelated pre-existing untracked trees elsewhere, e.g. `script/safe-propose/`, are not part of this check.)
- `docs/ESPNv3_Runbook.md` §5 carries the measured `createCampaign` gas, and §1/§2/§6/§7/§8/§9 contain no reference to `StakedStrat`, `staked-stry`, staking, or `syncRewards`.
- `package.json` unchanged; still no `dependencies` block. `foundry.toml` unchanged.
- `src/lib/TripwireGuard.sol`, `src/lib/TripwireController.sol`, `src/interfaces/ITripwireController.sol`, `docs/StratETHTreasuryLend_User_Stories.md` and `internalAddresses.json` are untouched.

**Not testable on a fork, and stated as such rather than faked:** Merkl's off-chain scoring, root posting and holder claims. The acceptance check for that half is Open Risk 1 — after the first real batch executes, confirm within ~12 h that `GET https://api.merkl.xyz/v4/campaigns?chainId=1&creatorAddress=0x0cbe9bDD425a7d651e6D4FE292c8504eEa4ef26D` lists the campaign with `type: ERC20LOGPROCESSOR` and a non-zero `apr`/`dailyRewards`. If Merkl rejects the minimal config, the fallback is to obtain the JSON from `POST /v4/config/encode` once and commit its exact key set into `MerklCampaignLib`, keeping everything else. The 800-byte legacy ABI form the redemption Safe used in Dec 2025 is **not** a fallback.

**One operational prerequisite that is not code and not a fork assertion (Open Risk 4):** before the first real run, message Merkl support with the STRY address so the campaign is displayed and priced in their UI. `ERC20LOGPROCESSOR` scores any ERC20 from its `Transfer` logs and STRY needs no on-chain registration — `DUTCH_AUCTION` with `distributionSettings: {}` needs no target-token price to split rewards — but Merkl's docs recommend confirming API recognition before launching. Watch the first campaign's `apr` field as above. If STRY shows up unrecognised, the fix is on Merkl's side, not in this repo.

## Spec items deliberately handled differently, with reasons

Three, all recorded so a reviewer does not read them as drift:

1. **`MerklCampaignLib.campaignData` takes the JSON string, not a repeat of `canonicalJson`'s nine arguments.** It is `sha256(bytes(json))` and nothing else. Repeating nine arguments would create a second site where a transposed address could hide while both sites hashed consistently and the pinned test still passed. Every call is `campaignData(canonicalJson({…}))`, and every call uses named-argument syntax.

2. **`Verify.s.sol` item 3 does not `vm.warp`.** The spec says "`vm.warp` so that `WEEKLY_YIELD_START := (block.timestamp / 3600 + 48) * 3600` satisfies the pre-conditions". That derivation already satisfies both pre-conditions unconditionally — it is at least 47 hours ahead of the fork clock and hour-aligned by construction — so a warp would be dead code. The derivation is kept verbatim; only the redundant warp is dropped.

3. **`MerklCampaignLib.isoUtc` exists** so the spec's "start/end as ISO strings" signer log is real rather than a bare unix integer, and it is pinned by a unit assertion against the same Feb-2026 fixture the hash assertions use. It lives in `MerklCampaignLib` rather than in the script because that is where the folder's pure string code and its test already are.
