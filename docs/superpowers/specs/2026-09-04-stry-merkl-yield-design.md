# STRY yield via Merkl — Design Spec

- **Date:** 2026-09-04
- **Branch:** `espn-redemption`
- **Status:** Decided design (founder-approved in brainstorm); open items listed under Open Risks / Assumptions must be confirmed during implementation, none block starting it
- **Supersedes:** Track B's staking half in [`2026-08-21-espnv3-redemption-migration-design.md`](2026-08-21-espnv3-redemption-migration-design.md) and Task 5 Steps 26–28 of [`../plans/2026-08-21-espnv3-redemption-migration-plan.md`](../plans/2026-08-21-espnv3-redemption-migration-plan.md)
- **Chain:** Ethereum mainnet (chain id 1)
- **Toolchain:** Foundry + forge-std only. No `dependencies` block in `package.json`. `foundry.toml` already has `ffi = true` and `read-write` on `./script/deployments/`.

## Summary

Weekly USDS yield to STRY holders is distributed by **Merkl** (Angle Protocol's incentive service) instead of an on-chain staking contract. Holders do nothing but hold STRY; Merkl computes time-weighted balances off-chain and holders self-claim with a merkle proof on Merkl's `Distributor`. `src/StakedStrat.sol`, its test, its user stories and its deploy step are deleted. `script/deployments/1/004-stry-migration/WeeklyYield.s.sol` is rewritten in place: same manual, repeatable, `WEEKLY_YIELD_AMOUNT`-driven shape, but instead of broadcasting a transfer + `syncRewards()` from an EOA it emits a Safe Transaction Builder batch for the redemption multisig — `USDS.approve(DistributionCreator, amount)`, `acceptConditions()` (only if the Safe has not yet signed), `createCampaign(CampaignParameters)` — via the existing `SafeBatchLib`. `Verify.s.sol` executes the batch's calls under `vm.startPrank(safe)` on a mainnet fork against Merkl's real contracts and asserts the campaign is registered with the expected fields and balances.

One fact changes the implementation detail but not the decision: on the current Merkl engine, `campaignData` is **not** an ABI-encoded config. It is `sha256(canonicalJson(config))` and the JSON must be stored with Merkl (`POST https://api.merkl.xyz/v4/config/store`) so the engine can resolve the hash. Verified on-chain against the treasury's own February 2026 campaign (see Confirmed facts). The script therefore computes the hash in Solidity (a deterministic `string.concat` + `sha256`, unit-tested against that mainnet fixture) and `run()` performs the one HTTP `POST` via `vm.ffi(["curl", …])` — outside the internal function `Verify.s.sol` calls. No npm dependency is added; the repo's "zero dependencies" convention holds in the sense the existing plan meant it (no `dependencies` block, no JS runtime library), not in the sense "zero HTTP calls".

## Background / Motivation

The shipped Track B (`004-stry-migration`) pays yield through a new `StakedStrat` instance: holders `stake(STRY)`, `WeeklyYield.s.sol` transfers USDS and calls `syncRewards()`, holders `claim()`/`unstake()`. Costs of that design, all removed by this change:

- **A staking step for every holder** (approve STRY, `stake`, later `unstake`) with a non-transferable position token whose `approve` reverts — the run-book's §9 exists entirely to warn about it.
- **A permanent-loss footgun**: yield deposited with `totalStaked == 0` is destroyed (`StakedStrat.syncRewards()`; plan Step 27 item 0). The weekly script's only reason to exist was the guard against it.
- **Assumption 4 (TripwireController) blocks the mainnet broadcast.** `internalAddresses.json` carries a zero-address controller, no deployed controller is recorded anywhere, and `Deploy.s.sol` hard-reverts on it. With no staking contract there is nothing to guard; Assumption 4 disappears from Track B entirely.
- **Cosmetic debt** — the instance is named `"Staked STRAT v2"` / `"sSTRAT-v2"` while staking STRY (Assumption 12).
- **A second yield mechanism to operate.** The treasury already distributes wETH to sSTRAT holders through Merkl (three `ERC20LOGPROCESSOR` / `DUTCH_AUCTION` campaigns, Nov 2025–Mar 2026, created from both the main and the redemption Safe). STRY yield through Merkl is the same operation the team already runs, on a different token pair.

### Confirmed facts

Read via `cast` against mainnet at block **25,901,186** and via Merkl's public API on 2026-09-04. Values marked *(live)* move.

| Fact | Value |
|---|---|
| Merkl `DistributionCreator` (mainnet; same address on most EVM chains per developers.merkl.xyz/resources/chains-and-contracts) | `0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd` (has code) |
| Merkl `Distributor` = `DistributionCreator.distributor()` | `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` (has code) |
| `DistributionCreator.feeRecipient()` | `0xeaC6A75e19beB1283352d24c0311De865a867DAB` |
| `defaultFees()` | `30000000` = 3% of `BASE_9 = 1e9` |
| `campaignSpecificFees(18)` | `0` ⇒ default 3% applies (a value of `1` would mean zero fees) |
| `rewardTokenMinAmounts(USDS)` | `1e18` — **USDS is whitelisted**; minimum 1 USDS per campaign-hour ⇒ **≥ 168 USDS per 7-day campaign** |
| `userSignatureWhitelist(redemption Safe 0x0cbe9bDD…)` | `1` — **already whitelisted**, `hasSigned` passes without `acceptConditions()` |
| `userSignatureWhitelist(main Safe 0xC53CCed6…)` | `1` |
| `userSignatureWhitelist(address(1))` (control) | `0` |
| `userSignatures(redemption Safe)` / `messageHash()` | `0x0` / `0x229e2060…` — the Safe has never called `acceptConditions()`; it does not need to |
| `feeRebate(redemption Safe)`, `creatorBalance(redemption Safe, USDS)` | `0`, `0` |
| Campaign type for "hold an ERC20" (API `GET /v4/schemas/campaignType`) | **`18 = ERC20LOGPROCESSOR`** ("Processes on-chain ERC20 transfer logs to calculate time-weighted rewards"). `1 = ERC20` and `3 = ERC20_SNAPSHOT` are marked **DEPRECATED** in the same enum |
| Distribution method for a fixed budget shared pro-rata | `DUTCH_AUCTION` ("Shares a fixed reward amount per second proportionally among users based on their scores") |
| Newest `campaignList` index *(live)* | `6280`; every one of the ~220 most recent entries has a **32-byte** `campaignData` |
| Treasury precedent, main Safe, Feb 2026: campaign `0x2653bced…` | type 18, reward wETH, target `0xD6664390…` = **sSTRAT**, `DUTCH_AUCTION`, `campaignData = 0x687bd056…` (32 bytes). `GET /v4/config/hash/0x687bd056…` returns the stored JSON; `sha256` of that JSON re-serialised with **sorted keys and no whitespace** equals `0x687bd056…` (reproduced locally). Stored `amount` 23.2 wETH, on-chain `amount` 22.504 wETH = **3% fee** deducted |
| Treasury precedent, redemption Safe, Dec 2025: campaign `0xc65570af…` | type 18, same target; `campaignData` is the **legacy 800-byte ABI encoding** (`targetToken` first, then dynamic arrays). Merkl moved to the hash form between these two campaigns |
| Reward cadence (docs.merkl.xyz technical overview) | engine computes ~every 2 h; merkle root posted ~every 8 h (4–12 h); 1–2 h dispute window before newly posted rewards are claimable |
| `DistributionCreator._createCampaign` checks (github.com/AngleProtocol/merkl-contracts) | `duration >= 1`; `rewardTokenMinAmounts[token] != 0`; `amount * 3600 >= minAmount * duration`; then `_computeFees`, `_pullTokens` (`safeTransferFrom(msg.sender, distributor, amountMinusFees)` + fee leg to `feeRecipient`), `campaignId = keccak256(abi.encodePacked(CHAIN_ID, creator, rewardToken, campaignType, startTimestamp, duration, campaignData))`, revert `CampaignAlreadyExists` on a duplicate id. `creator == address(0)` defaults to `msg.sender`. Nothing checks `startTimestamp` against `block.timestamp` |
| `hasSigned` modifier | passes if `userSignatureWhitelist[msg.sender] != 0` **or** `userSignatureWhitelist[tx.origin] != 0` **or** `userSignatures[msg.sender] == messageHash` **or** the same for `tx.origin` |
| `Distributor.claim` | `claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)`; leaves are cumulative `(user, token, amount)`; proofs served by Merkl's API / app.merkl.xyz |

## Decisions

### D1. Merkl targets plain STRY holders directly

Campaign type `18 = ERC20LOGPROCESSOR`, `targetToken = STRY`, `distributionMethod = DUTCH_AUCTION`. Merkl reads STRY `Transfer` logs, computes each holder's time-weighted balance over the campaign window, splits the week's USDS pro-rata, and holders claim on `Distributor` when they choose. No deposit, no position token, no `stake`/`unstake`, no lock during a tripwire trip. This is the exact configuration of the treasury's three existing sSTRAT campaigns.

Rejected: keeping `StakedStrat` and pointing Merkl at the position token (`sSTRAT-v2`). Adds the staking step back for no benefit; the position token is non-transferable, which Merkl does not need.

### D2. `src/StakedStrat.sol` is removed entirely

Once nothing deploys or calls it, it is dead code. Deleted with it: `test/unit/StakedStratTest.sol`, `docs/StakedStrat_User_Stories.md`, `script/deployments/1/004-stry-migration/Deploy.s.sol`, the `.staked-stry` key in `deploymentAddresses.json`, and the plan's staking-deployment / verify steps plus the run-book line "Holders `stake(STRY)`, then the first `WeeklyYield.s.sol` run".

Two consequences to state, not hide:

- The live sSTRAT contract (`0xD6664390E0485Cd609d4D04b430e84e945a51994`, "Staked STRAT") **is** this source. It stays deployed and unaffected; its source stays in git history and on Etherscan's verified-source record. `docs/StratETHTreasuryLend_User_Stories.md:16` mentions it as an example and is left alone.
- `src/lib/TripwireGuard.sol`, `src/lib/TripwireController.sol` and `src/interfaces/ITripwireController.sol` stay — `StratToken`, `CdtToken`, `DesEthToken` and their tests use them.

Rejected: leaving the contract in place "in case". The plan's own rule (Step 13, "no single-recipient mint … its only consumer was its own unit tests") applies: a contract whose only caller is its test is not kept.

### D3. A repeatable Foundry script emitting a Safe batch per weekly run

Same operational shape as today's `WeeklyYield.s.sol` — manually triggered, no cron/keeper, amount from env `WEEKLY_YIELD_AMOUNT` (plain decimal wei) because it changes every run — but the sender is the redemption Safe, so the script **never broadcasts**; it writes a Safe Transaction Builder batch through `script/deployments/1/lib/SafeBatchLib.sol` exactly as `BuildOrder.s.sol`, `Cancel.s.sol` and `StopEspnYield.s.sol` do (`struct Tx { address to; bytes data; }`, raw-calldata form, `abi.encodeCall`, `"checksum": null`). Each run creates a **new 7-day campaign**; `createCampaign` is idempotent per `(creator, rewardToken, type, start, duration, campaignData)` and reverts `CampaignAlreadyExists` on an exact duplicate, so an accidentally re-imported batch fails rather than double-pays.

`CampaignParameters` is a plain struct — `(bytes32 campaignId, address creator, address rewardToken, uint256 amount, uint32 campaignType, uint32 startTimestamp, uint32 duration, bytes campaignData)` — and `abi.encodeCall(IMerklDistributionCreator.createCampaign, (params))` encodes it with no ABI introspection, the same way Step 10 encodes Seaport's nested `OrderParameters`. The only non-trivial field is `campaignData`, covered under Architecture.

Rejected, and why:

- **One long-duration campaign funded once.** Merkl cannot top up a live campaign — its own campaign-management docs: "To increase the total amount: Create an additional campaign running in parallel"; the reward token and total amount cannot be overridden. That loses the weekly-adjustable amount that is the whole point of `WEEKLY_YIELD_AMOUNT`, and parks a large USDS balance in `Distributor` up front (cancellation refunds undistributed rewards after 24 h, so it is recoverable, but it is capital idle for no reason).
- **Off-chain, API-driven campaign creation** (a Node script calling `POST /v4/config/encode/safe` or `/v4/campaigns/generate-payload` for a ready-made Safe payload). It works and is what Merkl Studio does, but it reintroduces exactly the dependency the existing plan dropped (`viem`, Task 3 rationale), makes the Verify script trust an opaque payload it cannot re-derive, and moves the source of truth for amounts and addresses out of `ConfigLib`. Kept as the fallback if Open Risk 1's minimal config is rejected by Merkl's engine.

### D4. `Verify.s.sol` follows the repo pattern: prank the Safe, call the internal entry point, assert on-chain state

`contract Verify is Script, StdCheats, StdAssertions, StopEspnYield, Distribute, WeeklyYield`, `vm.startPrank`, never `run()`. `WeeklyYield.weeklyYield(...)` is `internal`, returns the `CampaignParameters` it built plus the derived `campaignId`, and does **not** write files or call `vm.ffi`; `run()` alone calls `SafeBatchLib.write` and the config-store `curl`. `yarn verify:migration` therefore leaves `git status` clean, the same structural rule Steps 19–22 and 25–28 enforce.

## Architecture

```
 operator (weekly)                                       redemption Safe signers
 ──────────────────                                      ───────────────────────
 WEEKLY_YIELD_AMOUNT=… WEEKLY_YIELD_START=…
 forge script 004-stry-migration/WeeklyYield.s.sol
   │
   ├─ weeklyYield() [internal]                           ┌─────────────────────────────┐
   │    read USDS / STRY / Safe / Merkl addrs (ConfigLib) │ Safe Transaction Builder    │
   │    pre-assert live DistributionCreator state         │ import multisig/004-…/       │
   │    build canonical config JSON → sha256 = campaignData│ 00N-0x0cbe9bDD-multisig.json │
   │    build CampaignParameters, campaignId = DC.campaignId(p) │ verify to + selector, sign  │
   │    return (params, campaignId, json)                 └──────────────┬──────────────┘
   │                                                                     │ executes, in order
   └─ run() only:                                                        ▼
        vm.ffi curl POST api.merkl.xyz/v4/config/store  ──►  (1) USDS.approve(DistributionCreator, amount)
          assert returned hash == campaignData                (2) DistributionCreator.acceptConditions()  [only if not signed/whitelisted]
        SafeBatchLib.write(safe, "004-stry-migration", N, …) (3) DistributionCreator.createCampaign(params)
          N = first free index (vm.exists scan, never overwrite)
                                                                    │ pulls amount from Safe: 97% → Distributor, 3% → feeRecipient
                                                                    ▼
                                             Merkl engine: reads STRY Transfer logs, resolves campaignData → stored JSON,
                                             time-weights balances over [start, start+7d), posts merkle roots ~8-hourly
                                                                    ▼
                                             STRY holder: app.merkl.xyz or Distributor.claim(users, tokens, amounts, proofs)
```

### The Safe batch

Written to `script/deployments/1/multisig/004-stry-migration/<N padded to 3>-0x0cbe9bDD-multisig.json`. This is the repo's first **repeatable** batch producer — every prior batch (`003`'s 001/002, `004`'s 001) is one-shot — and `SafeBatchLib.write` ends in `vm.writeFile`, which overwrites silently. A stale index would therefore rewrite a previous week's batch in place, with a different `campaignData` and amount, with no error and no git conflict if that file was never committed; a batch mid-signature-collection in the Safe UI would no longer match what the next signer diffs against.

So there is **no index env var and no manual counter**: `N` is derived in `run()` by starting at `2` (`001` is taken by `StopEspnYield.s.sol`) and incrementing while `vm.exists(<that path>)` — the first free index wins. Overwriting an existing weekly batch is then not expressible: to redo a week whose batch was generated but not yet signed, the operator deletes that file first, which is a deliberate act on a named path. Transactions, raw calldata, in this order:

1. `USDS.approve(DistributionCreator, amount)` — `_pullTokens` does `safeTransferFrom(msg.sender, …)` for the fee leg and the net leg, both from the Safe. Exact amount, not `type(uint256).max`: the allowance is consumed in the same execution and nothing should be left standing (same reasoning as `Cancel.s.sol`'s revoke).
2. `DistributionCreator.acceptConditions()` — **included only when** `userSignatureWhitelist(safe) == 0 && userSignatures(safe) != messageHash()`, read live. Today the redemption Safe is whitelisted, so the emitted batch has two transactions; the branch exists so a change of creator Safe, or a Merkl `messageHash` rotation, produces a batch that still executes. `acceptConditions()` is per-address and permanent for the current `messageHash` (Open Risk 3, resolved).
3. `DistributionCreator.createCampaign(params)` with `creator = safe` (explicit, not `address(0)` — `campaignId` hashes the creator field and Verify compares against it), `rewardToken = USDS`, `amount = WEEKLY_YIELD_AMOUNT`, `campaignType = 18`, `startTimestamp = WEEKLY_YIELD_START`, `duration = 604800`, `campaignData = sha256(json)`.

### `campaignData`: the canonical config and its hash

Minimal config, modelled on the treasury's own stored Feb-2026 config with only the campaign-specific values changed. Keys in **sorted order**, no whitespace, addresses **EIP-55 checksummed**, `amount`/timestamps as JSON numbers or decimal strings exactly as the fixture has them:

```json
{"amount":"<amount wei, decimal string>","blacklist":[],"campaignType":18,"computeChainId":1,
 "computeScoreParameters":{"computeMethod":"genericTimeWeighted"},"creator":"<Safe, checksummed>",
 "distributionMethodParameters":{"distributionMethod":"DUTCH_AUCTION","distributionSettings":{}},
 "endTimestamp":<start+604800>,"forwarders":[],"hooks":[],"rewardToken":"<USDS, checksummed>",
 "startTimestamp":<start>,"targetToken":"<STRY, checksummed>",["url":"<page>",]"whitelist":[]}
```

`campaignData = sha256(bytes(thatString))`. Built in a small pure library, `script/deployments/1/004-stry-migration/MerklCampaignLib.sol`, with `string.concat` + the `sha256` precompile — no JSON library, no ffi. `blacklist` is read from `settings.json` (`.espnv3.merkl.blacklist`, default `[]`; see Assumptions) and serialised as a JSON array of checksummed addresses.

`url` is an **explicit argument** of `canonicalJson(...)`, emitted in sorted position between `targetToken` and `whitelist`, with `""` meaning "omit the key entirely". The production path passes `""` — the key is optional in Merkl's schema and there is no STRY page; adding it later changes the hash, nothing else. The argument exists because the Feb-2026 fixture the test pins **does** carry `"url":"https://app.ethstrat.xyz/strat"` inside the hashed string, so a library that could never emit `url` could not reproduce that hash at all.

The hash rule is not a guess: `sha256(json.dumps(config, sort_keys=True, separators=(",", ":")))` reproduces the on-chain `campaignData` of three independent mainnet campaigns, including the treasury's `0x2653bced…`. `test/unit/MerklCampaignLibTest.sol` pins that fixture with two assertions over the same Feb-2026 values (amount `23200000000000000000`, creator `0xC53CCed6…`, wETH, sSTRAT, start `1771160400`, end `1774789200`):

- with `url = "https://app.ethstrat.xyz/strat"` — the stored config's actual key set — the output equals `0x687bd05668bd74bd5b5bc83cd6c516f3a4cf32c991735da35670990e16f4d706`, the on-chain `campaignData` of campaign `0x2653bced…`;
- with `url = ""` — the shape actually shipped — the output equals `0x4e08c911037453c7e092198804fbbcfd7cfd01f0cb3b0ffa53eab0b19141c6b1`.

The first assertion is the one anchored to mainnet: it covers key ordering, number-vs-string choices, and — the likeliest thing to go wrong — whether `vm.toString(address)` emits the EIP-55 checksum casing the stored JSON uses. If it does not, the test fails and the library adds a checksum routine; the spec does not pre-decide that. The second pins the omission branch, which is what production hashes and what Merkl must store.

### Storing the config (the one off-chain call)

Merkl's engine resolves `campaignData` by looking the hash up in its config store; an unstored hash is a campaign the engine cannot score. `run()` — never `weeklyYield()` — executes

```
vm.ffi(["curl", "-sS", "-X", "POST", "https://api.merkl.xyz/v4/config/store",
        "-H", "content-type: application/json", "--data", json])
```

and `require`s that the `text/plain` response equals the locally computed hash (the endpoint is documented as "Stores campaign configurations keyed by their hash"). Storing is idempotent and has no on-chain effect, so re-running the script is harmless; the batch file is only written after the store succeeds, so a network failure yields no batch rather than an un-scoreable one. `ffi = true` is already set in `foundry.toml`. Alternative if `ffi` is judged unwanted in this script: the operator runs the same `curl` by hand and passes the hash as `MERKL_CAMPAIGN_DATA`, which the script asserts equals its own computation — same guarantee, one more manual step.

### Pre-conditions asserted by `weeklyYield()` (hard reverts, live reads)

- `ESPN.asset() == USDS` — carried over from `StopEspnYield` / `BuildOrder`; the only cheap on-chain proof the hand-copied USDS address is right.
- `DistributionCreator.code.length > 0`, `Distributor == DistributionCreator.distributor()` — the two Merkl addresses in `externalAddresses.json` relate to each other on-chain, same idea.
- `STRY.code.length > 0` and `STRY.totalSupply() > 0` — `.stry` must be a deployed, distributed token (Distribute has run). A campaign targeting an undeployed token is accepted by the contract and pays nobody.
- `rewardTokenMinAmounts(USDS) != 0` and `amount * 3600 >= rewardTokenMinAmounts(USDS) * duration` — mirrors `_createCampaign` so the failure message names the ≥ 168 USDS floor instead of a bare `CampaignRewardTooLow`.
- `USDS.balanceOf(safe) >= amount` — the Safe pays.
- `startTimestamp > block.timestamp + 1 days` and `startTimestamp % 3600 == 0` — the Safe executes hours or days after the script runs; the contract does not check `start` against the clock, so a stale start silently produces a campaign that is already partly elapsed when funded. Same forcing-function pattern as `orderStartTime`. Hour alignment matches every Merkl campaign observed and the engine's hourly minimum-amount arithmetic.
- `campaignLookup(campaignId)` reverts `CampaignDoesNotExist()` for an unregistered id — it never returns 0 — so a duplicate is surfaced as the lookup *not* reverting (try/catch), before the batch is signed rather than at execution.

Logged for the signer: `amount`, fee (`amount * fees / 1e9` with `fees = campaignSpecificFees(18) != 0 ? … : defaultFees`, rebate applied), net to `Distributor`, `campaignId`, `campaignData`, the canonical JSON, start/end as ISO strings, and the `GET https://api.merkl.xyz/v4/config/hash/<campaignData>` URL so a signer can confirm Merkl holds the config before signing.

## File-level changes

**Deleted**

- `src/StakedStrat.sol`
- `test/unit/StakedStratTest.sol`
- `docs/StakedStrat_User_Stories.md`
- `script/deployments/1/004-stry-migration/Deploy.s.sol`

**Added**

- `script/deployments/1/004-stry-migration/interfaces/IMerklDistributionCreator.sol` — minimal, mirroring `003-espn-redemption/interfaces/ISeaportMinimal.sol`: `struct CampaignParameters`, `createCampaign`, `acceptConditions`, `campaignId(CampaignParameters)`, `campaign(bytes32)`, `campaignLookup(bytes32)`, `distributor()`, `feeRecipient()`, `defaultFees()`, `campaignSpecificFees(uint32)`, `feeRebate(address)`, `rewardTokenMinAmounts(address)`, `userSignatureWhitelist(address)`, `userSignatures(address)`, `messageHash()`, and the errors `NotSigned`, `CampaignRewardTooLow`, `CampaignRewardTokenNotWhitelisted`, `CampaignAlreadyExists`. Nothing else.
- `script/deployments/1/004-stry-migration/MerklCampaignLib.sol` — pure: `canonicalJson(...) returns (string)`, `campaignData(...) returns (bytes32)`. Takes explicit arguments (including `string url`, `""` = omit the key), reads no config.
- `test/unit/MerklCampaignLibTest.sol` — the two mainnet-fixture assertions above (`url` set ⇒ `0x687bd056…`, `url == ""` ⇒ `0x4e08c911…`), plus: empty vs. non-empty `blacklist` serialisation, and that two configs differing only in `amount` hash differently.

**Rewritten in place**

- `script/deployments/1/004-stry-migration/WeeklyYield.s.sol` — per Architecture. Keeps the file name, the `WEEKLY_YIELD_AMOUNT` contract and the "repeatable, manually triggered, not automation" header; drops `vm.startBroadcast`, `SafeERC20`, the `StakedStrat` import and the `totalStaked` guard.
- `script/deployments/1/004-stry-migration/Verify.s.sol` — items 1–2 (StopEspnYield, Distribute STRY) unchanged; items 3–9 replaced by the Merkl sequence under Testing. Drops the `TripwireController`, `Deploy` and `StakedStrat` imports and the `ZERO_STAKER_DEPOSIT` / `CLAIM_TOLERANCE` constants.

**Modified**

- `script/deployments/1/config/externalAddresses.json` — add `"merkl": {"distributionCreator": "0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd", "distributor": "0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae"}`.
- `script/deployments/1/config/settings.json` — add `"merkl": {"campaignType": 18, "duration": "604800", "blacklist": []}` under `.espnv3`. `campaignType` and `duration` live here rather than as Solidity constants so a Merkl enum change or a cadence change is a config edit; `duration` is a quoted decimal string per the Step 7 unit convention.
- `script/deployments/1/config/deploymentAddresses.json` — remove the `"staked-stry"` key.
- `script/deployments/1/config/internalAddresses.json` — `.protocol.tripwire.controller` no longer has a consumer in Track B. Left in place (a config key with no reader is inert; removing it is unrelated churn on a file Track A does not touch).
- `test/unit/ScriptLibsTest.sol` — extend item 1 to assert the two Merkl addresses round-trip, and item 3 to assert `.espnv3.merkl.duration == 604800` and `.campaignType == 18`.
- `package.json` — no change; `verify:migration` already points at `004-stry-migration/Verify.s.sol`.
- `docs/ESPNv3_Runbook.md` — the complete edit inventory, section by section. The numbering of Assumptions 1–13 is **kept** so every existing cross-reference stays valid; retired ones are struck, not renumbered.
  - **§1 header (line 10–11):** "These are Explicit Assumptions 1-13 … All 13 need sign-off" becomes "Explicit Assumptions 1–13, of which **4 and 12 are retired — Merkl replaces the staking contract**. The remaining 11 need sign-off before mainnet. Four of them gate the schedule itself."
  - **§1 Assumption 2 — kept, restated, not dropped.** `rewardTokenMinAmounts(USDS) == 1e18` proves Merkl *accepts* USDS as an incentive token; it says nothing about whether USDS is the token the founder intends STRY holders to be paid in, which is what Assumption 2 actually asks. That question is orthogonal to the staking-vs-Merkl decision and survives it. New text: "2. **Reward token for the weekly Merkl campaign = USDS.** Merkl-whitelisted, minimum 1 USDS per campaign-hour (≥ 168 USDS per 7-day campaign) — confirmed on-chain. Founder sign-off on USDS as the yield token: **still open.**"
  - **§1 Assumptions 4 and 12 — retired**, each replaced in place by a one-line strike ("Retired: no `StakedStrat` instance is deployed; Merkl distributes directly to STRY holders"). 4 is about the tripwire controller `StakedStrat`'s constructor needs; 12 is about the `"Staked STRAT v2"` / `"sSTRAT-v2"` name. Both evaporate with the contract.
  - **§1 line 30:** "**Assumptions 1, 4, 7, 8 and 9 gate the schedule**" becomes "**Assumptions 1, 7, 8 and 9 gate the schedule**".
  - **§2 table row 0 (line 38):** "Close Assumptions 1, 4, 7, 8, 9" becomes "Close Assumptions 1, 7, 8, 9". Rows 7–8 become one row: "Track B `WeeklyYield.s.sol` (Safe batch: approve [+ acceptConditions] + createCampaign), weekly, from step 4 onward". The "Step 8's order matters: yield deposited into `StakedStrat` with zero stakers is destroyed permanently" paragraph is deleted.
  - **§5:** replace the `stake` / `syncRewards` / `claim` / `unstake` rows with a single `createCampaign` execution-gas row (measured by Testing item 10).
  - **§6:** add the weekly batch path pattern `script/deployments/1/multisig/004-stry-migration/<NNN>-0x0cbe9bDD-multisig.json`, `NNN` ≥ `002` allocated by the script as the first free index (never overwritten, see Architecture), and its fixed 2-or-3-transaction order: `USDS.approve(DistributionCreator, amount)`, `acceptConditions()` only when the live check demands it, `createCampaign(params)`.
  - **§7 env table:** delete the step-7 row (`004-stry-migration/Deploy.s.sol` | none (reverts if Assumption 4's controller has no code)) — the spec deletes that file. The `WeeklyYield.s.sol` row's env becomes `WEEKLY_YIELD_AMOUNT` (plain decimal wei, changes every run) and `WEEKLY_YIELD_START` (hour-aligned unix seconds, > now + 1 day); there is no index var. Move it out of the broadcast table into §6's Safe-batch list, since it no longer broadcasts.
  - **§7 prose (line 224–227):** "Steps 1, 5, 9 … never broadcast" becomes "Steps 1, 5, 8, 9 … never broadcast"; "Steps 3, 4, 7, 8 broadcast directly … `Deploy` deploys the new `StakedStrat` instance, and `WeeklyYield` transfers USDS and calls `syncRewards()`" becomes "Steps 3, 4 broadcast directly from the deployer's own key: the two `Distribute` scripts mint and airdrop. `WeeklyYield.s.sol` writes a Safe batch that the redemption Safe executes — it never broadcasts and never moves USDS itself."
  - **§8:** add a `WEEKLY_YIELD_START` entry. It is now the stale-value forcing function that `orderStartTime` is for Track A: the script hard-reverts unless `start > block.timestamp + 1 days` and `start % 3600 == 0`, so a start left over from last week cannot produce a campaign that is already partly elapsed when the Safe funds it.
  - **§9:** replace the staking notes with the holder claim notes — hold STRY in any address that can call `Distributor.claim` or use app.merkl.xyz; rewards appear ~8–12 h after each campaign hour is scored; contracts that hold STRY and cannot call `claim` (LP pairs above all) accrue rewards they can never collect unless blacklisted or forwarded; the 3% Merkl fee is taken from each weekly amount.
- `docs/superpowers/plans/2026-08-21-espnv3-redemption-migration-plan.md` — Task 5 file list: remove `Deploy.s.sol`, add the two new files; delete Step 26; replace Step 27's body with a pointer to this spec's Architecture; replace Step 28 items 3–9 with a pointer to this spec's Testing; Definition of Done: drop "all nine steps" and "No changes to `src/StakedStrat.sol`"; dependency section: drop the `.staked-stry` mention. Checkboxes for the replaced steps reset to `[ ]`.
- `docs/superpowers/specs/2026-08-21-espnv3-redemption-migration-design.md` — one line under the title: "Track B's staking design is superseded by `2026-09-04-stry-merkl-yield-design.md`." No rewrite of the historical document.

## Open Risks / Assumptions

None block implementation. Each has a concrete resolution step; the first two are the ones that can change code.

1. **`campaignData` encoding and campaign type — resolved as "sha256 of a stored canonical JSON, type 18", with one residual.** Verified: the type enum, the hash rule (three mainnet campaigns reproduced, including the treasury's own), the store endpoint, and that `_createCampaign` places no constraint on the bytes. **Residual:** the engine's acceptance of a config with exactly the key set above (no `url`, no `forwardingEnabled`/`forwardingList`, empty `hooks`) is inferred from the Feb-2026 treasury config having the same shape minus `url`; it is not something a fork can prove. *Resolution:* after the first real batch executes, confirm within ~12 h that `GET https://api.merkl.xyz/v4/campaigns?chainId=1&creatorAddress=<safe>` lists the campaign with `type: ERC20LOGPROCESSOR` and a non-zero `apr`/`dailyRewards`. If Merkl rejects the minimal config, the fallback is D3's rejected option 2 for the config step only: obtain the JSON from `POST /v4/config/encode` once, commit its exact key set into `MerklCampaignLib`, keep everything else. The 800-byte legacy ABI form the redemption Safe used in Dec 2025 is **not** a fallback — Merkl's current tooling no longer emits it and there is no evidence the engine still reads it.
2. **USDS whitelisting / minimum amount — resolved. USDS as *the chosen yield token* — still open (run-book Assumption 2).** `rewardTokenMinAmounts(USDS) == 1e18` on mainnet today: whitelisted, 1 USDS per campaign-hour, so ≥ 168 USDS per weekly campaign. The script reads the live value and asserts; if Merkl ever raises it the assertion message says by how much. That is a Merkl-side acceptance fact only — it is not founder sign-off that USDS is what STRY holders should be paid in, which stays as run-book Assumption 2 and gates a recurring, real outflow. *Residual:* the docs also state a "~$1/hour" dusting floor enforced off-chain; at any plausible weekly amount this is moot.
3. **`acceptConditions()` cadence — resolved.** Per creator address, once per `messageHash`; the redemption Safe is additionally on `userSignatureWhitelist`, so it is never required for it today. The batch includes the call only when the live check says it is needed. *Residual:* if Merkl rotates `messageHash`, whitelisted addresses are unaffected; non-whitelisted ones re-sign — the live check handles both.
4. **STRY eligibility as a target token — open, low.** `ERC20LOGPROCESSOR` scores any ERC20 from its `Transfer` logs and the treasury already targets a token (sSTRAT) that is not a DEX/lending receipt; STRY needs no on-chain registration. Merkl's docs recommend "contacting support to confirm API recognition before launching" so the campaign is displayed and priced. `DUTCH_AUCTION` with `distributionSettings: {}` needs no target-token price to split rewards. *Resolution:* message Merkl support with the STRY address before the first real run; watch the first campaign's `apr` field as in item 1. If STRY shows up as unrecognised the fix is on Merkl's side, not in this repo.
5. **Which Safe creates and pays.** Spec'd as `.protocol.multisigs.redemption` (`0x0cbe9bDD…`): it holds ~1.2M USDS, it is the payer for every other 004 batch, and it is whitelisted on Merkl. The main Safe also qualifies. Existing Assumption 1 (this Safe is confirmed as the treasury for this project) still stands and covers this.
6. **Blacklist.** `settings.json` ships `.espnv3.merkl.blacklist = []`: every STRY holder, including the redemption Safe's own STRY (~9.2% of supply via its ESPN) and any LP pair, earns. Blacklisting the treasury avoids paying yield to itself; blacklisting contract holders that cannot claim avoids stranding rewards in `Distributor`. Founder decision, same family as Assumption 5; overridable per campaign later via Merkl's blacklist override without a new campaign.
7. **3% Merkl fee.** `defaultFees = 3%`, no rebate for either Safe, confirmed by the treasury's own campaign (23.2 → 22.504 wETH). The script logs gross, fee and net so the signer sees it every week. Merkl's fee page mentions a 25% discount for pre-paid >$500k commitments — a commercial decision outside this repo.
8. **Deleting the source of a live contract.** `src/StakedStrat.sol` is the verified source of mainnet sSTRAT (`0xD6664390…`). Deletion changes nothing on-chain; anyone needing the source has git history and Etherscan. Recorded so the deletion is not mistaken for an oversight.
9. **`vm.ffi` in a script that also writes a Safe batch.** `ffi = true` is already global in `foundry.toml`; the call is a single `curl` to a public endpoint, made only from `run()`, and its response is asserted against a locally computed value, so a compromised response cannot alter the batch. If the reviewer prefers no ffi, the `MERKL_CAMPAIGN_DATA` env alternative under Architecture is the same guarantee.

## Testing approach

**Unit (`yarn test`, no fork)**

- `test/unit/MerklCampaignLibTest.sol` — the two mainnet-fixture assertions (`0x687bd056…` with `url`, `0x4e08c911…` without), blacklist serialisation, amount sensitivity. This is the one runnable check for the only non-trivial logic in the change; if canonicalisation is wrong, this fails before any fork run.
- `test/unit/ScriptLibsTest.sol` — Merkl addresses and the two new settings round-trip through `ConfigLib`.

**Fork (`SNAPSHOT_BLOCK=<block> yarn verify:migration`)**

Same harness and rules as plan Step 28: `vm.startPrank`, internal entry points, `git status` clean afterwards, no accepted early exit. The fork is pinned to the snapshot block for Distribute's sake; Merkl's contracts and state (`rewardTokenMinAmounts`, whitelist) are read at that block too, which is fine — both predate it.

1. **StopEspnYield** — unchanged.
2. **Distribute STRY** — unchanged; yields the fork-fresh STRY address that item 3 passes to `weeklyYield` as an argument (never via `deploymentAddresses.json`).
3. **Build** — `vm.warp` so that `WEEKLY_YIELD_START := (block.timestamp / 3600 + 48) * 3600` satisfies the pre-conditions; call `weeklyYield(safe, usds, stry, amount, start, blacklist)`; assert the returned `campaignId == DistributionCreator.campaignId(params)` and `params.campaignData == MerklCampaignLib.campaignData(...)` with the same inputs.
4. **Execute the batch's calls under `vm.startPrank(safe)`** in the emitted order (`deal(USDS, safe, amount)` only if the fork balance is short — it is ~1.2M USDS, so normally assert the real balance): `approve`, conditionally `acceptConditions` (skipped on this fork because the Safe is whitelisted — assert that the script's branch agrees with `userSignatureWhitelist(safe) == 1`), `createCampaign`. Record the returned id.
5. **Assert registration**: `campaignLookup(id)` no longer reverts `CampaignDoesNotExist()`; `campaign(id)` has `creator == safe`, `rewardToken == USDS`, `campaignType == 18`, `startTimestamp`, `duration == 604800`, `campaignData` all equal to the built params, and `amount == gross * (1e9 - fees) / 1e9` where `fees` is derived from `campaignSpecificFees(18)` / `defaultFees()` / `feeRebate(safe)` exactly as `_computeFees` does.
6. **Assert balances**: Safe USDS `−gross`, `Distributor` `+net`, `feeRecipient` `+fee`, `USDS.allowance(safe, DistributionCreator) == 0` afterwards.
7. **Negative: minimum amount** — `vm.expectRevert(CampaignRewardTooLow)` with `amount = rewardTokenMinAmounts(USDS) * 168 - 1` via a direct `createCampaign`, and separately assert the script's own pre-condition rejects the same amount with its named message.
8. **Negative: duplicate** — the same params again `vm.expectRevert(CampaignAlreadyExists)`.
9. **Negative: unsigned creator** — prank `makeAddr("unsignedCreator")` (not whitelisted, `deal` it USDS): `createCampaign` reverts `NotSigned`; call `acceptConditions()`; the same `createCampaign` succeeds. Proves the conditional second transaction is the right shape for a non-whitelisted Safe.
10. **Log gas** for `createCampaign` in the Step 23 two-line format (execution gas; execution + 21,000 + calldata), for the run-book's §5 table.

Not testable on a fork, and stated as such in the run-book rather than faked: Merkl's off-chain scoring, root posting and holder claims. The first live campaign's appearance in Merkl's API (Open Risk 1) is the acceptance check for that half.

**Definition of done delta** (relative to the plan's list): `yarn test` additionally green on `MerklCampaignLibTest`; `yarn verify:migration` passes items 1–10 above; the run-book's §5 has the measured `createCampaign` gas; no file under `script/deployments/1/multisig/` and no config file is dirty after the verify run; `forge build` succeeds with `src/StakedStrat.sol` absent.
