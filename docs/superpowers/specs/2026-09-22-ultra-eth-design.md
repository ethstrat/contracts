# ULTRA — Design Spec

Date: 2026-09-22
Branch: `ultra-eth` (== `main` @ afe86625)
Status: decisions final; numeric parameters marked TBD are deploy-time inputs, not spec decisions.

## 1. Overview

ULTRA is a fungible ERC20 that represents a fixed slice of a 2-year ETH call option the treasury holds off-chain (Safe-custodied / OTC). Each ULTRA token is a claim on `ethPerToken` ETH of notional under that option. An on-chain oracle (`UltraFairValue`) prices one ULTRA continuously via Black-Scholes from the live Chainlink ETH/USD spot, the option's immutable strike and expiry, and a multisig-published volatility. A permissionless minter (`UltraMinter`) sells new ULTRA for USDS at a ceiling above fair value, forwarding USDS to the treasury, which tops up the off-chain option. ULTRA trades freely in a Uniswap v3 ULTRA/USDS pool; the treasury defends a floor below fair value by manual Safe buybacks (swap at a price limit, then burn). At expiry, the settlement spot is latched on-chain once (§5.2.7) and holders redeem by filling a Safe-signed Seaport order paying intrinsic value at that latched price. The protocol never sells ULTRA itself: it only mints against incoming USDS.

**Solvency invariant (governs the whole design):**

```
totalSupply(ULTRA) * ethPerToken <= option ETH notional held off-chain
```

Every ULTRA in existence must be backed by option notional the treasury actually holds. `maxSupply` on `UltraMinter` is the on-chain enforcement of this invariant, and it is the rule governing every `setMaxSupply` call: the cap may only be raised to a level the currently-held notional supports (§5.5.3). It is inclusive of the treasury's own allocation, because it is measured against `totalSupply()`. The cap can never be disabled — `maxSupply == 0` and `maxSupply == type(uint256).max` are both rejected at construction and in the setter.

## 2. Scope

In scope (Solidity, `src/`, `test/`):

- `src/UltraToken.sol`
- `src/UltraFairValue.sol` + `src/lib/BlackScholes.sol` + `src/interfaces/AggregatorV3Interface.sol`
- `src/UltraMinter.sol`
- Unit tests under `test/unit/`, fork tests under `test/integration/` where a real feed/pool is exercised.

In scope (non-Solidity deliverables, `script/`): deploy script, setup Safe batch, buyback Safe batch template, settlement Seaport order (procedure only). See §7.

Out of scope, explicitly:

- Dapp / frontend of any kind. No app scaffolding. The only dapp-facing requirement is that `UltraFairValue` exposes the public views in §5.2.7.
- Any on-chain representation of the option itself (no option contract, no vault).
- Any on-chain buyback / `sellBack()` / `defend()` function. Rejected; buyback is Safe-manual.
- Any on-chain settlement / claim contract. Rejected; settlement is a Safe-signed Seaport order.
- Any TWAP or pool-price read, anywhere. See §4.
- Any on-chain claim on minted USDS. It is a plain transfer to the treasury.

## 3. Existing pieces being reused

| Piece | Existing file | What is reused |
|---|---|---|
| ERC20 base with minter role, permit, kill switch | `src/MintableBurnableToken.sol` | Inherited unchanged by `UltraToken`. `manageMinter`, `mint` (onlyMinter, whenNotTripped), `burn`, `burnFrom`. |
| Token subclass shape | `src/StratToken.sol`, `src/CdtToken.sol`, `src/DesEthToken.sol` | `UltraToken` is the same ~13-line subclass: `constructor(address owner, ITripwireController controller_, address guardian_)`. |
| Kill switch | `src/lib/TripwireGuard.sol`, `src/lib/TripwireController.sol`, `src/interfaces/ITripwireController.sol`, `src/interfaces/ITripwireGuard.sol` | Unchanged. `UltraMinter` inherits `TripwireGuard`; `UltraToken` gets it via the base. A `TripwireController` must be deployed on Robinhood Chain (none exists there). |
| Owner-bounded params, min-out + deadline, cap check, tripwire-guarded mint | `src/EthStrategyConvertibleNote.sol` (`bond()`, `setMaxDebt`, errors `TransactionStale`, `InsufficientOutput`, `DebtCeilingExceeded`) | Shape only, copied into `UltraMinter.mint`. NAV pricing math is not reused. |
| Delegated parameter-setter role | `src/StratETHTreasuryLend.sol` (`setRateSetter` onlyOwner, `setBorrowRate` gated on `rateSetter`, `UnauthorizedRateSetter`) | Shape copied as `volSetter` / `setVolSetter` / `setVol` in `UltraFairValue`. |
| Typed token interfaces | `src/interfaces/IERC20.sol` (`IERC20`, `IERC20MintableBurnable`) | `UltraMinter` references ULTRA as `IERC20MintableBurnable` and USDS as `IERC20`. |
| OpenZeppelin | `lib/openzeppelin-contracts` | `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`. |
| Safe batch tooling | `script/safe/propose-batch.mjs`, `script/safe/export-tx-builder.mjs`, `script/safe/batches/*.json` (schema example: `convertible-note-minter-grants.json`) | Setup batch and buyback batch use the same JSON schema and scripts. |
| Deploy script shape | `script/DeployConvertibleNote.s.sol` | `script/DeployUltra.s.sol` copies the constant-block + `vm.startBroadcast()` pattern. |
| Token test pattern | `test/unit/MintableBurnableTokenTest.sol` | `UltraTokenTest` follows it. |

Confirmed not reusable / not present (full `git log --all -S/--grep` sweep):

- `src/lib/EthUsdPriceFeedConsumer.sol` — Euler `IPriceOracle`; no confirmed Euler deployment on Robinhood Chain. Not used.
- No Black-Scholes, option-pricing, `ln`/`exp` fixed-point, erf, Chainlink `AggregatorV3` code anywhere in history. `lib/` contains only forge-std, halmos-cheatcodes, openzeppelin-contracts (+ v4), Locked_VestingTokenPlans. OpenZeppelin `Math` has no `ln`/`exp`.
- No Seaport code in this repo. The rage-quit / ESPN redemption Seaport orders were constructed off-chain; the precedent is operational, not a file.
- The deleted `StratOption.sol` NFT (removed in 04781aac / c4d6f522) is not a fit for a fungible token.

New dependency required: a fixed-point `ln`/`exp`/`sqrt` WAD library. Recommendation: `forge install vectorized/solady` (submodule `lib/solady`, add remapping `solady/=lib/solady/src/`), use `FixedPointMathLib.lnWad`, `expWad`, `sqrtWad`. Pin the submodule commit. Alternative: vendor only `FixedPointMathLib.sol` into `src/lib/` with its MIT header. The plan stage picks one; both are acceptable.

## 4. Chain / DEX context

- Chain: Robinhood Chain (Arbitrum-stack L2, mainnet since 2026-07-01). All three contracts, the pool, and the Safe live there.
- Oracle: Chainlink is native to Robinhood Chain (live from block zero). `UltraFairValue` reads `AggregatorV3Interface.latestRoundData()` directly. Euler's `IPriceOracle` path is not used because no Euler deployment on Robinhood Chain is confirmed.
- DEX: Uniswap v3, plain concentrated-liquidity ULTRA/USDS pool, no hooks (v4 not needed). Pool creation and seeding are treasury ops, not contract features.
- No TWAP anywhere. Reasons:
  - Mint prices off `UltraFairValue.ceiling()`, which is derived from Chainlink spot + fixed option terms + bounded vol. The pool price is never an input, so pool manipulation cannot change mint price.
  - Buyback is a manual Safe swap with `sqrtPriceLimitX96` set at `floor()`. A price limit on the swap itself bounds execution; a TWAP read would add a second oracle for no additional protection.
  - A TWAP would require a `UniswapV3Pool.observe()` consumer contract, cardinality management, and its own staleness / manipulation analysis. None of that protects anything in this design.

## 5. Contracts

Conventions (apply to all three): `pragma solidity ^0.8.24`; SPDX `GPL-2.0-or-later`; all USD amounts and prices are 1e18-scaled; custom errors, no revert strings; owner is the treasury Safe; `Ownable2Step` for ownership transfer.

### 5.1 `UltraToken` — `src/UltraToken.sol`

```solidity
contract UltraToken is MintableBurnableToken {
    constructor(address owner, ITripwireController controller_, address guardian_)
        MintableBurnableToken("ULTRA", "ULTRA", owner, controller_, guardian_)
    {}
}
```

- Name/symbol: `"ULTRA"` / `"ULTRA"` (placeholder wording; final strings are a deploy-time decision, §8). The name is **not** freely changeable after deploy: `MintableBurnableToken` passes it to `ERC20Permit(name)`, which bakes it into the EIP-712 domain separator, so changing it later would invalidate every outstanding permit signature and require a redeploy. Confirm both strings before `DeployUltra.s.sol` runs.
- No additional state, functions, errors, or events. Everything is inherited from `MintableBurnableToken`.
- Minters: exactly one is granted post-deploy — `UltraMinter` — via `manageMinter(address(ultraMinter), true)` in the setup Safe batch (§7.2). The treasury's initial allocation (§7.2) is minted through a temporary self-grant in the same batch, revoked in the same batch.
- Burn paths used by the product: `burn(uint256)` by the Safe after a buyback and again after each settlement fill; `burnFrom` is inherited but unused by the product. Seaport fills move ULTRA to the Safe via `transferFrom` against the holder's conduit approval, never via `burnFrom`; the Safe then calls `burn` on what it received (§7.4).

### 5.2 `UltraFairValue` — `src/UltraFairValue.sol`

Placement: `src/` not `src/lib/`. `src/lib/` holds abstract mixins and pure libraries (`EthUsdPriceFeedConsumer`, `TripwireGuard`, `DateString`); `UltraFairValue` is a deployed, owned contract like the others in `src/`. The pure math lives in `src/lib/BlackScholes.sol` (§5.3).

#### 5.2.1 Inheritance

```solidity
contract UltraFairValue is Ownable2Step
```

No `TripwireGuard`. The only non-view function that is not owner- or `volSetter`-gated is `latchSettlement()` (§5.2.7), and pausing it would be actively harmful: it is one-shot, idempotent in effect, and blocking it only delays settlement for holders. Everything else here is a view, and tripping a view protects nothing — `UltraMinter.mint` is where issuance is halted. No `ReentrancyGuard`: the only external call is the Chainlink view, and `latchSettlement` makes its single state write under a `settlementSpot == 0` guard that a re-entrant call cannot pass twice.

#### 5.2.2 Constructor

```solidity
constructor(
    address owner_,
    AggregatorV3Interface ethUsdFeed_,
    uint256 maxPriceAge_,          // seconds; Chainlink heartbeat + margin
    uint256 strikeUsd_,            // 1e18 USD per ETH
    uint256 expiry_,               // unix timestamp
    uint256 ethPerToken_,          // 1e18 ETH per ULTRA
    uint256 ceilingBps_,           // initial, must be within CEILING_BPS_MIN..MAX
    uint256 floorBps_              // initial, must be within FLOOR_BPS_MIN..MAX
) Ownable(owner_)
```

Constructor checks:

- `address(ethUsdFeed_) != 0`, else `ZeroAddress()`.
- `feedDecimals = ethUsdFeed_.decimals()`; must be `<= 18`, else `InvalidFeedDecimals(uint8)`.
- `maxPriceAge_ > 0`, else `ZeroAmount()`.
- `strikeUsd_ > 0`, `ethPerToken_ > 0`, else `ZeroAmount()`.
- `expiry_ > block.timestamp`, else `InvalidExpiry(uint256)`.
- `ceilingBps_`, `floorBps_` within bounds, else `CeilingOutOfBounds(uint256)` / `FloorOutOfBounds(uint256)`.
- Call `spot()` once to validate the feed (mirrors `EthUsdPriceFeedConsumer`'s constructor validation).
- `volSetter = owner_`.
- `settlementSpot = 0` (not latched; §5.2.7).
- `vol` and `volUpdatedAt` are left at 0. **Pre-expiry**, `ceiling()`/`floor()`/`fairValue()` revert with `VolStale` until the first `setVol` (done in the setup batch, §7.2). Post-expiry they do not read `vol` at all (§5.2.7), so `VolStale` cannot occur there.

`volSetter` is plain state, not derived from `owner()`. `Ownable2Step.acceptOwnership()` does **not** migrate it: after an ownership transfer the old owner still holds `setVol` unless it is explicitly re-pointed. Ops rule: any ownership-transfer Safe batch must include `setVolSetter(newOwner)` alongside `transferOwnership`/`acceptOwnership` (§7.5).

#### 5.2.3 Constants (hard bounds, compiled in)

All values below are the suggested defaults. The exact numbers are a reasonable-default judgment call; the plan/review stage may change them. They are constants because they protect against owner error on a scheduled process.

| Constant | Suggested | Meaning |
|---|---|---|
| `uint256 constant WAD = 1e18` | — | fixed-point scale |
| `uint256 constant BPS = 10_000` | — | basis-point scale |
| `uint256 constant CEILING_BPS_MIN` | `100` (+1%) | lower bound on `ceilingBps` |
| `uint256 constant CEILING_BPS_MAX` | `1_000` (+10%) | upper bound on `ceilingBps` |
| `uint256 constant FLOOR_BPS_MIN` | `200` (−2%) | lower bound on `floorBps` |
| `uint256 constant FLOOR_BPS_MAX` | `1_500` (−15%) | upper bound on `floorBps` |
| `uint256 constant VOL_MIN` | `0.10e18` (10% annualised) | lower bound on `vol` |
| `uint256 constant VOL_MAX` | `3.00e18` (300%) | upper bound on `vol` |
| `uint256 constant VOL_MAX_STEP` | `0.20e18` (20 vol points, absolute) | max `|newVol − vol|` per update after the first |
| `uint256 constant VOL_MIN_INTERVAL` | `1 days` | min seconds between updates |
| `uint256 constant VOL_MAX_AGE` | `14 days` | `fairValue()` reverts once `vol` is older than this |

Invariant: `VOL_MIN_INTERVAL < VOL_MAX_AGE` (otherwise the schedule cannot be kept). Enforce with a `static assert`-style check in a unit test, not at runtime.

**Sizing relation for `ceilingBps` (and symmetrically `floorBps`).** The ceiling is not a profit margin, it is the buffer that keeps permissionless minting from being a free option on oracle lag. A Chainlink feed only updates when price moves past its deviation threshold or the heartbeat elapses, so between updates the true spot can be up to the deviation threshold away from `spot()`, and `MAX_PRICE_AGE` permits further drift on top of that. The mint price moves with spot at the option's delta, so:

```
ceilingBps > (feed deviation threshold) x (option delta) + (drift allowed by MAX_PRICE_AGE) x (option delta)
```

Delta for a 2-year ATM call is roughly 0.6–0.7, so a 0.5% deviation feed implies a floor of ~35 bps from deviation alone before any margin. This is the reason `MAX_PRICE_AGE` must be **heartbeat plus a small margin measured in minutes, not hours** (§8): every extra hour of tolerated staleness widens the drift term and has to be paid for in `ceilingBps`. Check the chosen `CEILING_BPS` against the actual feed's published deviation threshold and heartbeat before deploy; the suggested 300 bps assumes a sub-1% deviation feed with a minutes-scale `MAX_PRICE_AGE`.

#### 5.2.4 Immutables

```solidity
AggregatorV3Interface public immutable ethUsdFeed;
uint8    public immutable feedDecimals;
uint256  public immutable maxPriceAge;
uint256  public immutable strikeUsd;
uint256  public immutable expiry;
uint256  public immutable ethPerToken;
```

#### 5.2.5 Mutable state

```solidity
address public volSetter;      // defaults to owner
uint256 public vol;            // 1e18 annualised volatility
uint256 public volUpdatedAt;   // timestamp of last setVol; 0 = never
uint256 public ceilingBps;
uint256 public floorBps;
uint256 public settlementSpot; // latched ETH/USD at settlement, 1e18; 0 = not latched (§5.2.7)
```

#### 5.2.6 Setters

```solidity
function setVolSetter(address newSetter) external onlyOwner
```
- `newSetter != 0`, else `ZeroAddress()`.
- Emits `VolSetterUpdated(address indexed old, address indexed new)`.

```solidity
function setVol(uint256 newVol) external
```
- `msg.sender == volSetter`, else `UnauthorizedVolSetter(address caller)`.
- `VOL_MIN <= newVol <= VOL_MAX`, else `VolOutOfBounds(uint256 newVol)`.
- If `volUpdatedAt != 0` (not the first update):
  - `block.timestamp >= volUpdatedAt + VOL_MIN_INTERVAL`, else `VolUpdateTooSoon(uint256 nextAllowedAt)`.
  - `|newVol − vol| <= VOL_MAX_STEP`, else `VolStepTooLarge(uint256 oldVol, uint256 newVol)`.
- Sets `vol = newVol`, `volUpdatedAt = block.timestamp`.
- Emits `VolUpdated(uint256 oldVol, uint256 newVol)`.
- Allowed after expiry (harmless; post-expiry pricing is intrinsic and ignores vol).
- Note: the step and interval checks are also skipped when `vol` has gone stale past `VOL_MAX_AGE`? **No.** They still apply. A lapsed schedule is recovered by one in-bounds step; if the required move exceeds `VOL_MAX_STEP`, it takes several updates spaced `VOL_MIN_INTERVAL` apart. This is intentional: it is the same rate limit that protects against a wrong value.
- **Catch-up rule (required, not optional).** The rate limit creates a window in which `vol` is known-wrong but not yet stale enough to revert, so `fairValue()`/`ceiling()` keep returning a stale-but-live price and `UltraMinter.mint` stays open at it. A 60-point move at `VOL_MAX_STEP = 0.20e18` and `VOL_MIN_INTERVAL = 1 days` takes three days to walk in. Therefore: **if a required vol move exceeds `VOL_MAX_STEP`, the guardian trips `UltraMinter.mint` for the duration of the catch-up and untrips only after the final step lands.** Secondary trading and `floor()`-based buybacks continue; only primary issuance at a price the treasury knows is wrong is halted. This is an operational obligation on the `volSetter`, mirrored in §7.5 and tested in §9.3.

```solidity
function setCeilingBps(uint256 newBps) external onlyOwner
function setFloorBps(uint256 newBps) external onlyOwner
```
- Within `[CEILING_BPS_MIN, CEILING_BPS_MAX]` / `[FLOOR_BPS_MIN, FLOOR_BPS_MAX]`, else `CeilingOutOfBounds(uint256)` / `FloorOutOfBounds(uint256)`.
- Emit `CeilingBpsUpdated(uint256 old, uint256 new)` / `FloorBpsUpdated(uint256 old, uint256 new)`.

#### 5.2.6a What `vol` is (and why `r = 0` is correct)

`vol` is **not** a realized-volatility estimate. It is a **calibrated implied parameter**: the single number `sigma` that makes `BlackScholes.callPrice(spot, strikeUsd, tYears, sigma)` reproduce the treasury's actual market quote for the option it holds. The `volSetter` publishes it by re-solving against a fresh dealer quote (or the dealer's own quoted implied vol, adjusted by the same calibration) on the `setVol` schedule — not by measuring historical ETH returns.

This is what justifies `r = 0` in `BlackScholes` (§5.3). Under a realized-vol reading, `r = 0` would structurally underprice: at `S = K = 4000`, `T = 2y`, `sigma = 0.60`, the `r = 0` price is ~1314 USD versus ~1423 USD at `r = 4%` — a ~7.6% shortfall, which would flow straight into `fairValue()` and hand every minter a persistent discount. Under the calibrated reading the discount cannot arise: the rate term is absorbed into the calibrated `sigma`. For that same option, `sigma ≈ 0.655` reproduces the `r = 4%` price exactly, comfortably inside `VOL_MAX = 3.0e18`, so the calibration never runs out of room at realistic rates.

Consequences the plan stage must carry through:

- The published number will sit **above** any realized-vol figure for the same underlying. That is expected, not an error; do not "sanity check" it against realized vol.
- `VOL_MIN`/`VOL_MAX` bound a calibrated parameter, not a volatility forecast. `VOL_MIN = 0.10e18` is a fat-finger floor.
- Recalibration is required whenever rates move materially, not only when vol does — a rate move changes the option's quote and therefore the `sigma` that reproduces it.
- Because of the catch-up rule above, a large recalibration step (a rate shock, say) trips `UltraMinter.mint` until it is fully walked in.

#### 5.2.7 Views (the dapp-facing surface) + `latchSettlement`

```solidity
function spot() public view returns (uint256)
```
- `(, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();`
- `answer > 0`, else `InvalidPrice(int256 answer)`.
- Staleness check, written to avoid underflow on a future-dated `updatedAt` (L2 sequencer clock skew would otherwise panic on the subtraction rather than reverting cleanly):
  ```solidity
  if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) revert StalePrice(updatedAt);
  ```
- Return `uint256(answer) * 1e18 / 10**feedDecimals`.
- No `answeredInRound`/`roundId` checks (deprecated in current Chainlink guidance; `updatedAt` staleness is the check).

```solidity
function timeToExpiry() public view returns (uint256)
```
- `expiry > block.timestamp ? expiry − block.timestamp : 0` (seconds).

```solidity
function latchSettlement() external   // permissionless, one-shot
```
- `block.timestamp >= expiry`, else `NotExpired(uint256 expiry)`.
- `settlementSpot == 0`, else `AlreadyLatched(uint256 settlementSpot)`.
- `settlementSpot = spot()` — propagates `StalePrice`/`InvalidPrice`, so a latch can only happen against a live, non-stale feed.
- Emits `SettlementLatched(uint256 settlementSpot, uint256 timestamp)`.
- Permissionless and unowned on purpose: any holder can fix the settlement price the moment the option expires, without waiting on the Safe. One-shot, so there is nothing to re-roll.

**Why this exists.** The option settles once, at expiry. Reading live spot after expiry would make every holder's payout depend on *when* they redeem, not on what the option was worth: a Seaport order the Safe sized against Monday's `fairValue()` is either overpaying or underpaying by Friday, and a holder who watches spot can arbitrage the Safe by filling only when live spot has run above the latched rate. Latching once converts settlement from a moving target into a fixed number that the order, the holders and the treasury all agree on.

```solidity
function fairValue() public view returns (uint256)   // USD per ULTRA, 1e18
```
- If `block.timestamp >= expiry` (**post-expiry branch**):
  - `settlementSpot != 0`, else `SettlementNotLatched()`. `fairValue()` **reverts between expiry and the latch**, and the fix is one permissionless call anybody can make.
  - `intrinsic = settlementSpot > strikeUsd ? settlementSpot − strikeUsd : 0`; return `intrinsic * ethPerToken / WAD`.
  - Uses the **latched** price, never live spot: once latched the value is constant forever. Does not read `vol`, and does not read the feed at all — so a feed that later goes stale or is deprecated cannot break settlement. The Safe sizes the settlement order from this value (§7.4).
- Else (pre-expiry):
  - `s = spot()`.
  - `volUpdatedAt != 0 && block.timestamp − volUpdatedAt <= VOL_MAX_AGE`, else `VolStale(uint256 volUpdatedAt)`.
  - `tYears = timeToExpiry() * WAD / 365 days`.
  - `c = BlackScholes.callPrice(s, strikeUsd, tYears, vol)` (USD per 1 ETH, `r = 0` — valid because `vol` is a calibrated implied parameter that absorbs the rate term, §5.2.6a).
  - Return `c * ethPerToken / WAD`.

```solidity
function ceiling() public view returns (uint256)   // fairValue() * (BPS + ceilingBps) / BPS
function floor()   public view returns (uint256)   // fairValue() * (BPS − floorBps) / BPS
```
- Both propagate any revert from `fairValue()` (`VolStale`, `StalePrice`, `InvalidPrice`, `SettlementNotLatched`). Consumers must not catch these. `UltraMinter` does not.
- Post-expiry both wrap the latched intrinsic value, so they revert `SettlementNotLatched` until `latchSettlement()` has run and are constant afterwards. `UltraMinter` is the component that blocks minting post-expiry, so this never gates issuance.

Other public getters (auto-generated): `strikeUsd()`, `expiry()`, `ethPerToken()`, `vol()`, `volUpdatedAt()`, `ceilingBps()`, `floorBps()`, `ethUsdFeed()`, `maxPriceAge()`, `volSetter()`, `settlementSpot()`.

#### 5.2.8 Errors and events (complete list)

Errors: `ZeroAddress()`, `ZeroAmount()`, `InvalidFeedDecimals(uint8)`, `InvalidExpiry(uint256)`, `InvalidPrice(int256)`, `StalePrice(uint256 updatedAt)`, `VolStale(uint256 volUpdatedAt)`, `VolOutOfBounds(uint256)`, `VolStepTooLarge(uint256 oldVol, uint256 newVol)`, `VolUpdateTooSoon(uint256 nextAllowedAt)`, `UnauthorizedVolSetter(address)`, `CeilingOutOfBounds(uint256)`, `FloorOutOfBounds(uint256)`, `NotExpired(uint256 expiry)`, `AlreadyLatched(uint256 settlementSpot)`, `SettlementNotLatched()`.

Events: `VolSetterUpdated(address indexed, address indexed)`, `VolUpdated(uint256, uint256)`, `CeilingBpsUpdated(uint256, uint256)`, `FloorBpsUpdated(uint256, uint256)`, `SettlementLatched(uint256 settlementSpot, uint256 timestamp)`.

### 5.3 `BlackScholes` — `src/lib/BlackScholes.sol`

Internal pure library so the math is directly fuzzable from tests without deploying the oracle.

```solidity
library BlackScholes {
    function callPrice(uint256 spot, uint256 strike, uint256 tYears, uint256 sigma) internal pure returns (uint256);
    function normCdf(int256 x) internal pure returns (uint256);
}
```

All inputs/outputs WAD (1e18). `r = 0` — not an approximation to be corrected later, but a consequence of `sigma` being a calibrated implied parameter that already absorbs the rate term (§5.2.6a). Do not add a rate argument; adding one while `vol` stays calibrated would double-count.

`callPrice`:
- Preconditions (revert with `InvalidInput()` if violated): `spot > 0`, `strike > 0`, `sigma > 0`.
- If `tYears == 0`: return `spot > strike ? spot − strike : 0` (intrinsic; also the numerical limit).
- `sqrtT = sqrtWad(tYears)`; `sigSqrtT = sigma * sqrtT / WAD` (> 0 given `sigma >= VOL_MIN` and `tYears >= 1e18/365days > 0`).
- `d1 = (lnWad(spot * WAD / strike) + (sigma * sigma / WAD) * tYears / WAD / 2) * WAD / sigSqrtT` (int256 arithmetic).
- `d2 = d1 − sigSqrtT`.
- `c = spot * normCdf(d1) / WAD − strike * normCdf(d2) / WAD` (computed in int256, returned as uint256).
- **Clamp to the no-arbitrage bounds before returning — mandatory, not a test-only assertion:**
  ```solidity
  uint256 intrinsic = spot > strike ? spot - strike : 0;
  if (c < intrinsic) c = intrinsic;
  if (c > spot)      c = spot;
  ```
  `normCdf` carries an absolute error of ~7.5e−8 (§`normCdf` below). At extreme moneyness that error is multiplied by `spot` and by `strike` separately, so the two-term difference can land *below* intrinsic or *above* spot even though the exact Black-Scholes value never does. Deep ITM with a large `strike` is the worst case: `strike * 7.5e-8` is a real dollar amount, and an unclamped result there prices ULTRA below the payoff a holder could get by exercising — a direct, free arbitrage against the treasury through `ceiling()`. The lower clamp also subsumes the old "clamp at 0 if rounding makes it negative" rule, since `intrinsic >= 0`.
- Postconditions the tests assert (§9): `max(spot − strike, 0) <= c <= spot`. With the clamp these hold by construction; the tests exist to catch a clamp that was removed or applied in the wrong order.

`normCdf(x)`:
- Clamp: `x >= 10e18` → return `WAD`; `x <= −10e18` → return `0`. This keeps `expWad(−x²/2)` inside Solady's domain and avoids overflow for deep ITM/OTM near expiry.
- Otherwise Abramowitz & Stegun 26.2.17 (`t = 1/(1 + p|x|)`, 5th-order polynomial × `expWad(−x²/2) / sqrt(2π)`), absolute error < 7.5e−8; use symmetry `N(−x) = 1 − N(x)`. An equivalent or better approximation (e.g. erf-based) is acceptable if it meets the same tolerance in §9. Constants are the published A&S values scaled to WAD.

Dependency: `lnWad`, `expWad`, `sqrtWad` from Solady `FixedPointMathLib` (§3).

### 5.4 `AggregatorV3Interface` — `src/interfaces/AggregatorV3Interface.sol`

Minimal Chainlink interface (OZ does not ship one):

```solidity
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
```

### 5.5 `UltraMinter` — `src/UltraMinter.sol`

#### 5.5.1 Inheritance

```solidity
contract UltraMinter is Ownable2Step, TripwireGuard, ReentrancyGuard
```

`ReentrancyGuard` from `openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol`. `SafeERC20` for the USDS pull.

#### 5.5.2 Constructor

```solidity
constructor(
    IERC20MintableBurnable ultra_,
    UltraFairValue fairValue_,
    IERC20 usds_,
    address treasury_,
    uint256 maxSupply_,
    address owner_,
    ITripwireController controller_,
    address guardian_
) Ownable(owner_) TripwireGuard(controller_, guardian_)
```

Checks:

- `ultra_`, `fairValue_`, `usds_`, `treasury_` non-zero, else `ZeroAddress()`.
- `usds_.decimals() != 18` → `InvalidTokenDecimals(uint8)`. Step 7 of `mint` divides `usdsIn * WAD` by an 18-decimal price and hands the result straight to an 18-decimal `ultra.mint`; a 6-decimal USDS would silently mint 1e12× too few ULTRA per dollar. Same fail-fast pattern as `UltraFairValue`'s `InvalidFeedDecimals` check, and it makes the §8 "confirm USDS is 18 decimals" item unmissable rather than a docs footnote. `IERC20` must expose `decimals()` for this (it does).
- `maxSupply_ != 0 && maxSupply_ != type(uint256).max`, else `InvalidMaxSupply(uint256)`. **This departs from `EthStrategyConvertibleNote.maxDebt`, deliberately.** There, an unbounded cap is merely permissive; here the cap *is* the on-chain enforcement of the §1 solvency invariant, and a disabled cap means unbounded permissionless minting against a fixed off-chain option — the one failure that makes every outstanding ULTRA unbacked. `type(uint256).max` is rejected because it is the "disabled" sentinel; `0` is rejected because it bricks the minter with no way to distinguish it from an uninitialised deploy. Every value in between is allowed (§5.5.3).

#### 5.5.3 State

```solidity
IERC20MintableBurnable public immutable ultra;
UltraFairValue          public immutable fairValue;
IERC20                  public immutable usds;
address public treasury;
uint256 public maxSupply;   // cap on ultra.totalSupply() after a mint; 1e18 ULTRA
```

`maxSupply` rationale: the option is off-chain and is backed only as fast as the treasury can trade. Minting must not outrun the treasury's ability to add to the option position, so the cap is raised in steps as the position is topped up. The cap counts the treasury's own allocation because it is measured against `totalSupply()`.

**The rule governing every `setMaxSupply` call is the §1 solvency invariant:**

```
totalSupply(ULTRA) * ethPerToken <= option ETH notional held off-chain
```

`maxSupply` may only be raised to `optionEthNotional / ethPerToken` for notional the treasury has *already* acquired — never in anticipation of a top-up. The USDS from minting arrives before the option is topped up, so raising the cap first inverts the ordering the invariant depends on. Sequence: top up the option, confirm the fill, then raise the cap.

`setMaxSupply` has **no upper hard bound in the contract** — the value that would be correct depends on off-chain notional the contract cannot see, so any compiled constant would be either wrong or meaningless. The owner is the safety control for the *level*. But "disabled" is not a level: `newMaxSupply == 0` and `newMaxSupply == type(uint256).max` are rejected with `InvalidMaxSupply(uint256)` in the setter exactly as in the constructor, so no single owner transaction (or a fat-fingered `--max` in a batch) can switch the invariant's only on-chain enforcement off. Within `(0, type(uint256).max)` the setter stays unbounded.

**Oracle immutability and the remediation path (deliberate).** `UltraMinter.fairValue` is `immutable`, so a defective or mispriced oracle cannot be swapped in place. This is intended — a settable oracle pointer is the single highest-value target on the whole system, since whoever controls it controls the mint price. Recorded remediation instead: **trip `UltraMinter.mint` via the tripwire, deploy a new `UltraFairValue` + a new `UltraMinter` pointed at it, `manageMinter(newMinter, true)`, `manageMinter(oldMinter, false)`.** The token, its supply and every holder balance survive untouched; only the issuance path is replaced. `maxSupply` on the new minter is set from current `totalSupply()` plus whatever headroom the invariant allows. The tripwire is what makes this safe to do unhurried — see §5.6 for the operator grant that lets it be done in one transaction.

#### 5.5.4 Functions

```solidity
function mint(address to, uint256 usdsIn, uint256 minUltraOut, uint256 deadline)
    external whenNotTripped nonReentrant returns (uint256 ultraOut)
```
Order of checks and effects:
1. `to != 0`, else `ZeroAddress()`.
2. `usdsIn > 0`, else `ZeroAmount()`.
3. `block.timestamp <= deadline`, else `TransactionStale(uint256 deadline)` (same shape as `EthStrategyConvertibleNote.bond`).
4. `block.timestamp < fairValue.expiry()`, else `Expired(uint256 expiry)`.
5. `price = fairValue.ceiling()` — any revert propagates (stale feed, stale vol). Not caught.
6. `if (price == 0) revert ZeroPrice();` — `ceiling()` returns 0 whenever the call is worthless (deep OTM near expiry, where `callPrice` floors at intrinsic 0), and `usdsIn * WAD / 0` would panic with `0x12` instead of a named error. A panic in the mint path is indistinguishable from a bug and cannot be handled by a caller; a named revert says "the option is currently worth nothing, there is nothing to buy".
7. `ultraOut = usdsIn * WAD / price`.
8. `if (ultraOut == 0) revert ZeroAmount();` — integer division truncates, so any `usdsIn < price / 1e18` dust mint rounds to zero ULTRA out. Without this check the USDS still transfers to the treasury at step 11 and `ultra.mint(to, 0)` succeeds: the caller pays and receives nothing. `minUltraOut` does not save them, because a caller passing `minUltraOut = 0` (the obvious value when you have not computed a quote) sails straight through step 9.
9. `ultraOut >= minUltraOut`, else `InsufficientOutput(uint256 minUltraOut, uint256 ultraOut)`.
10. `newSupply = ultra.totalSupply() + ultraOut`; `newSupply <= maxSupply`, else `SupplyCapExceeded(uint256 newSupply, uint256 maxSupply)`. This is the §1 solvency invariant's on-chain enforcement point.
11. `usds.safeTransferFrom(msg.sender, treasury, usdsIn)` — USDS goes straight to the treasury; the minter never holds USDS.
12. `ultra.mint(to, ultraOut)` (reverts via `UltraToken` if the minter role is missing or the token is tripped).
13. Emit `Minted(address indexed sender, address indexed to, uint256 usdsIn, uint256 ultraOut, uint256 price)`.

Units: USDS is required to be 18 decimals and the constructor rejects anything else (§5.5.2), so step 7 needs no normalisation. If the deployed USDS turns out not to be 18 decimals, the fix is a spec change, not a silent runtime path.

`whenNotTripped` uses `msg.sig` of `mint`; a trip on `UltraMinter.mint` halts primary issuance without touching the token. The token's own `mint` is also tripwire-guarded, so either trip halts issuance.

```solidity
function setMaxSupply(uint256 newMaxSupply) external onlyOwner
```
- `newMaxSupply != 0 && newMaxSupply != type(uint256).max`, else `InvalidMaxSupply(uint256)`. The cap cannot be disabled (§5.5.3).
- No upper bound otherwise; the level is the owner's call, governed off-chain by the §1 solvency invariant.
- Emits `MaxSupplyUpdated(uint256 old, uint256 new)`.
- Setting it below current `totalSupply()` is permitted: it halts further minting without touching existing holders, which is the intended emergency lever alongside the tripwire.

```solidity
function setTreasury(address newTreasury) external onlyOwner
```
- `newTreasury != 0`, else `ZeroAddress()`. Emits `TreasuryUpdated(address indexed old, address indexed new)`.

`quote()` — **dropped.** It was one division (`usdsIn * WAD / ceiling()`) that any caller can do itself from the already-public `ceiling()`. §2 commits to `UltraFairValue`'s views being the *only* dapp-facing surface; keeping `quote()` would have made `UltraMinter` a second one, permanently, for no capability. Callers compute `minUltraOut` from `UltraFairValue.ceiling()`.

Not present, by decision: any function that transfers ULTRA out of the minter, any sell/redeem/buyback path, any USDS custody.

#### 5.5.5 Errors and events (complete list)

Errors: `ZeroAddress()`, `ZeroAmount()` (used for both `usdsIn == 0` and `ultraOut == 0`), `ZeroPrice()`, `InvalidTokenDecimals(uint8)`, `InvalidMaxSupply(uint256)`, `TransactionStale(uint256 deadline)`, `Expired(uint256 expiry)`, `InsufficientOutput(uint256 minUltraOut, uint256 ultraOut)`, `SupplyCapExceeded(uint256 newSupply, uint256 maxSupply)`.

Events: `Minted(address indexed sender, address indexed to, uint256 usdsIn, uint256 ultraOut, uint256 price)`, `MaxSupplyUpdated(uint256, uint256)`, `TreasuryUpdated(address indexed, address indexed)`.

### 5.6 Roles summary

| Role | Address | Powers |
|---|---|---|
| Owner (all three) | Treasury Safe | `manageMinter`, `setVolSetter`, `setCeilingBps`, `setFloorBps`, `setMaxSupply`, `setTreasury`, ownership transfer (2-step). |
| `volSetter` | Defaults to Safe; may be delegated | `setVol` within bounds/step/interval. |
| Tripwire guardian | Safe (per `TripwireGuard` registration) | trip/untrip `UltraToken.mint/burn/burnFrom`, `UltraMinter.mint`. |
| Tripwire operator | One treasury-controlled hot key | trip/untrip the same selectors on `UltraToken` and `UltraMinter`, without a multisig round. Granted in the setup batch (§7.2). |
| Minter on `UltraToken` | `UltraMinter` only | `mint`. |
| Anyone | — | `UltraMinter.mint`, `UltraFairValue.latchSettlement`, `UltraToken.burn`, all views. |

**Why an operator is granted.** The tripwire is only worth what its response time is. Two of the mechanisms in this spec depend on tripping *promptly*, not eventually: the vol catch-up rule (§5.2.6) requires `UltraMinter.mint` to be tripped for the whole multi-day window in which the published vol is known-wrong, and the oracle-remediation path (§5.5.3) starts with a trip. Both would otherwise wait on Safe signer availability — the same signers who are mid-incident. A single hot key that can only *halt* (never mint, never move funds, never change a parameter) is the right trade: worst case an attacker with the key causes a denial of service on issuance that the Safe reverses with `untrip`, which is strictly better than an unbounded window of mispriced permissionless minting.

The setup batch therefore calls `TripwireController.addOperator(<contract>, <OPERATOR>)` — note the argument order is `(guardedContract, operator)`, per `ITripwireController` — for each **tripwire-guarded** contract (§7.2). That is `UltraToken` and `UltraMinter` only: `UltraFairValue` does not inherit `TripwireGuard` (§5.2.1, views only), so it is not registered with the controller and has no operator to grant. The Safe retains guardian rights throughout; the operator is additive, not a replacement.

## 6. Product flow mapped to components

| Step | Where it happens | Contract involvement |
|---|---|---|
| Treasury buys 2-year ETH call off-chain | Safe / OTC | None. Terms (strike, expiry, ETH notional) become `UltraFairValue` constructor args. |
| Fair value tracks spot continuously; vol updated on a schedule | `UltraFairValue` | `spot()` from Chainlink each call; `setVol` by `volSetter`. |
| Primary issuance at ceiling | `UltraMinter.mint` | USDS → treasury, ULTRA → buyer, capped by `maxSupply`. |
| Treasury tops up option with USDS | Off-chain | None. |
| Secondary trading | Uniswap v3 ULTRA/USDS | None (no pool reads). |
| Floor defence | Safe batch (§7.3) | Swap with `sqrtPriceLimitX96` at `floor()`, then `UltraToken.burn` of the measured delta. |
| Treasury's own ULTRA allocation | Setup batch (§7.2) | Plain token custody; counted against `maxSupply`. |
| Settlement price fixed at expiry | `UltraFairValue.latchSettlement()` | Permissionless one-shot; stores `settlementSpot = spot()` at/after `expiry`. Until it runs, `fairValue()` reverts `SettlementNotLatched`. |
| Settlement at expiry | Safe-signed Seaport order (§7.4) | `fairValue()` post-expiry gives the per-token payout for sizing, computed from the **latched** spot so every fill pays the same rate; `UltraMinter.mint` reverts `Expired`. |

## 7. Deliverables outside `src/`

These are not Solidity contracts and are intentionally under-specified here; the plan stage fills in mechanics. All Safe batches use the schema in `script/safe/batches/convertible-note-minter-grants.json` and are proposed with `script/safe/propose-batch.mjs` or exported with `script/safe/export-tx-builder.mjs`.

### 7.1 Deploy script — `script/DeployUltra.s.sol`

Modeled on `script/DeployConvertibleNote.s.sol` (constant block, `vm.startBroadcast()`, `console2.log` addresses). Deploys, in order:

1. `TripwireController` (new; none exists on Robinhood Chain).
2. `UltraToken(owner = SAFE, controller, guardian = SAFE)`.
3. `UltraFairValue(owner = SAFE, ETH_USD_FEED, MAX_PRICE_AGE, STRIKE_USD, EXPIRY, ETH_PER_TOKEN, CEILING_BPS, FLOOR_BPS)`.
4. `UltraMinter(ultra, fairValue, USDS, treasury = SAFE, MAX_SUPPLY, owner = SAFE, controller, guardian = SAFE)`.

Placeholders (named constants at the top of the script, values TBD per §8): `SAFE`, `ETH_USD_FEED`, `MAX_PRICE_AGE`, `USDS`, `STRIKE_USD`, `EXPIRY`, `ETH_PER_TOKEN`, `CEILING_BPS`, `FLOOR_BPS`, `MAX_SUPPLY`. The script does no role grants and sets no vol — those are Safe batches, matching the existing convention noted in `DeployConvertibleNote.s.sol`'s header.

### 7.2 Setup Safe batch — `script/safe/batches/ultra-setup.json`

Same shape as `convertible-note-minter-grants.json`. Transactions:

1. `UltraToken.manageMinter(ultraMinter, true)`.
2. `UltraFairValue.setVol(INITIAL_VOL)` (first update; step/interval checks skipped). `INITIAL_VOL` is the calibrated implied value per §5.2.6a, not a realized-vol figure.
3. `TripwireController.addOperator(ultraToken, OPERATOR)`.
4. `TripwireController.addOperator(ultraMinter, OPERATOR)`.
   - Argument order is `(guardedContract, operator)`. Only these two contracts are tripwire-guarded; `UltraFairValue` is not (§5.6).
   - `OPERATOR` is a §8 item. The incident-response paths in §5.2.6 (vol catch-up) and §5.5.3 (oracle remediation) both assume this grant exists.
5. Treasury allocation, if any: `UltraToken.manageMinter(SAFE, true)` → `UltraToken.mint(SAFE, ALLOCATION)` → `UltraToken.manageMinter(SAFE, false)`. Three transactions in the same batch so the grant never persists.
   - `ALLOCATION` is minted through `UltraToken` directly, bypassing `UltraMinter`, so **`maxSupply` is not checked on this path**. `MAX_SUPPLY >= ALLOCATION` must therefore hold by construction, verified before the batch is proposed (§8). If it does not, the deploy produces a minter that reverts `SupplyCapExceeded` on its very first public mint.

`chainId` must be Robinhood Chain's (§8).

### 7.3 Buyback Safe batch template — `script/safe/batches/ultra-buyback.template.json`

Manual floor defence. Not a contract. Filled by hand per buyback; the `description` field documents the fill-in procedure.

**Placeholder form.** Every value filled in by hand must be written as `<NAME>` — angle brackets, nothing else. `script/safe/propose-batch.mjs` guards against proposing an unfilled template with `PLACEHOLDER_RE = /^<.*>$/`, which matches that form and only that form. A placeholder written as `TODO_AMOUNT`, `{{amount}}` or `0` is invisible to the guard and will be proposed to the Safe verbatim.

Transactions:

1. `USDS.approve(SWAP_ROUTER, <AMOUNT_IN>)`.
2. `SwapRouter.exactInputSingle({tokenIn: USDS, tokenOut: ULTRA, fee: <POOL_FEE>, recipient: SAFE, deadline: <DEADLINE>, amountIn: <AMOUNT_IN>, amountOutMinimum: <AMOUNT_OUT_MIN>, sqrtPriceLimitX96: <SQRT_PRICE_LIMIT_X96>})` on the Uniswap v3 `SwapRouter` (or `SwapRouter02` — whichever is deployed on Robinhood Chain, §8).
   - `sqrtPriceLimitX96` is computed off-chain from `cast call <UltraFairValue> "floor()"` at construction time: `sqrt(P) * 2^96` where `P` is the pool price in token1-per-token0 units corresponding to `floor()` USD/ULTRA, respecting the pool's token0/token1 ordering (both 18 decimals, so no decimals adjustment beyond ordering). The template's description states the formula and both orderings.
   - **It is an upper bound on the price this swap will push the pool to — "keep buying until the pool price reaches `floor()`, then stop."** It is not a minimum, not a target, and not a guarantee of fill size. A buyback that only partially fills because the limit was reached did exactly what it was told to.
   - **If the pool price is already at or above `floor()` when the batch executes, Uniswap v3 reverts with `SPL`.** This is the expected and correct outcome — the floor does not need defending, so there is nothing to buy. It is not a bug in the template, a bad `sqrtPriceLimitX96`, or a reason to retry with a wider limit. Between building the batch and executing it the pool can easily recover on its own; rebuild from a fresh `floor()` read if a buyback is still wanted. The template's description must say this, because the instinct on seeing `SPL` is to loosen the limit, which is precisely the mistake.
   - The price limit is what bounds execution. No TWAP.
3. `UltraToken.burn(<AMOUNT_RECEIVED>)`.
   - **`<AMOUNT_RECEIVED>` is a measured delta: `ULTRA.balanceOf(SAFE)` after the swap minus `ULTRA.balanceOf(SAFE)` before it.** Never `burn(balanceOf(SAFE))`. The Safe holds its own treasury allocation from §7.2 in the same address, and burning the balance would destroy that allocation along with the bought-back tokens — an irreversible loss of treasury assets, on a path that looks correct right up until it executes.
   - The exact received amount is not known when the batch is built. Two options, either acceptable: (a) burn `<AMOUNT_OUT_MIN>` in this batch and burn the residual in a later batch; (b) a separate `ultra-burn.template.json` with a single `burn(<AMOUNT_RECEIVED>)` transaction proposed after the swap settles, with the delta read off the settled swap. The template ships with (b) as default — it is the option that can use the true measured delta — and notes the choice in the description.
4. `USDS.approve(SWAP_ROUTER, 0)`.
   - Clears the leftover allowance. `exactInputSingle` with a price limit routinely spends **less** than `<AMOUNT_IN>`, so transaction 1's approval survives the batch as a standing allowance on the treasury Safe's USDS, sized to the full intended buyback. Revoking it in the same batch keeps the approval's lifetime equal to the buyback's. Cheap, and it removes a persistent claim on treasury funds that nothing else in this design would ever clean up.

### 7.4 Settlement — Safe-signed Seaport order (procedure, no repo code)

- At/after `expiry`, **first** call `UltraFairValue.latchSettlement()` (permissionless — the Safe, an operator, or any holder can send it). This fixes `settlementSpot` at the live feed price at that moment. Until it lands, `fairValue()` reverts `SettlementNotLatched`.
- Then the Safe reads `UltraFairValue.fairValue()` (now intrinsic against the latched price: `max(settlementSpot − strike, 0) * ethPerToken / 1e18` USD per ULTRA). This value does not move again, so the order can be sized once and every fill pays the same rate no matter when it arrives — and a stale or deprecated feed later cannot block settlement, because the post-expiry branch does not read the feed at all.
- If the payout is zero (ETH below strike at the latch), no order is posted.
- Otherwise the Safe signs a Seaport order offering USDS (or ETH, at the Safe's choice) as offer, with ULTRA as consideration to the Safe, at the per-token rate above, partially fillable. Holders fill the order; ULTRA moves to the Safe by `transferFrom` against the holder's conduit approval, and the Safe burns what it received via `UltraToken.burn` — using a measured delta, for the same reason as §7.3 (the Safe's own allocation shares the address).
- Same operational pattern as the rage-quit / ESPN redemption orders. No Seaport code exists in this repo; do not add any. Nothing in this section is Solidity.

### 7.5 Ops items noted for completeness (not deliverables)

- Create the Uniswap v3 ULTRA/USDS pool and seed initial liquidity from the Safe.
- Schedule for `setVol` (the cadence must be < `VOL_MAX_AGE`; suggested weekly with `VOL_MAX_AGE = 14 days`). The published value is a recalibration against a fresh option quote, not a realized-vol reading (§5.2.6a).
- **Vol catch-up procedure.** If a scheduled recalibration requires a move larger than `VOL_MAX_STEP`, the guardian or operator **trips `UltraMinter.mint` before the first step and untrips only after the final step lands.** The rate limit means the published vol is knowingly wrong for `ceil(|delta| / VOL_MAX_STEP)` days, during which `ceiling()` still returns a live-looking price and permissionless minting would otherwise continue against it. Tripping issuance is not optional in this window (§5.2.6). Secondary trading and buybacks continue normally.
- **Ownership transfers must re-point `volSetter`.** `Ownable2Step.acceptOwnership()` moves `owner()` only; `UltraFairValue.volSetter` is independent state and keeps pointing at whoever held it before. Any ownership-transfer Safe batch must therefore include `UltraFairValue.setVolSetter(<NEW_OWNER>)` alongside `transferOwnership`/`acceptOwnership` on all three contracts, or the outgoing owner retains the power to publish vol (§5.2.2).
- **Settlement latch.** At/after expiry, call `UltraFairValue.latchSettlement()` before sizing the settlement order (§7.4). Permissionless, so it does not need to wait on the Safe, but the Safe should not assume someone else has done it — check `settlementSpot()` first.

## 8. Open / deferred items (pre-deploy verification)

Each is a named parameter or a verification, not a spec decision. None may be guessed at implementation time. Every row names an owner; a row with no owner is a row nobody does.

| Item | Where it lands | Owner | Status |
|---|---|---|---|
| `STRIKE_USD` | `UltraFairValue` ctor | Treasury | TBD from the executed option. |
| `EXPIRY` (unix ts) | `UltraFairValue` ctor | Treasury | TBD; must match the option's expiry. |
| `ETH_PER_TOKEN` | `UltraFairValue` ctor | Treasury | TBD; option ETH notional ÷ intended max ULTRA supply. |
| Token `name` / `symbol` (currently `"ULTRA"`/`"ULTRA"`, placeholder wording) | `UltraToken` ctor | Treasury, before deploy | **Not freely changeable post-deploy**: `ERC20Permit(name)` bakes the name into the EIP-712 domain separator, so a later change invalidates outstanding permit signatures and needs a redeploy. Confirm both strings before `DeployUltra.s.sol` runs (§5.1). |
| `ETH_USD_FEED` address | `UltraFairValue` ctor | Treasury ops, before deploy | Look up at https://docs.robinhood.com/chain/oracles-and-price-feeds/. Verify `decimals()` (expected 8). |
| Chainlink ETH/USD heartbeat **and deviation threshold** on Robinhood Chain → `MAX_PRICE_AGE`, `CEILING_BPS` sizing | `UltraFairValue` ctor | Treasury ops, before `DeployUltra.s.sol` is run | Look up with the feed. Set `MAX_PRICE_AGE = heartbeat + a small margin measured in **minutes, not hours**` — every extra hour of tolerated staleness has to be paid for in `ceilingBps` (§5.2.3). Check `CEILING_BPS` against the deviation threshold × option delta per §5.2.3. |
| **Chainlink L2 Sequencer Uptime feed on Robinhood Chain: does one exist?** | `UltraFairValue.spot()` | Treasury ops, before deploy | **Open.** Robinhood Chain is Arbitrum-stack (§4), so the standard L2 hazard applies: while a sequencer is down and restarting, the price feed can carry a pre-outage price that passes the `updatedAt` staleness check, and the backlog then executes against it — the exact conditions Chainlink's uptime feed exists to guard. If a feed is published, consume it in `spot()` with a grace period (revert while down, and for `GRACE_PERIOD` after recovery) and add it as a constructor arg. If none is published, record in the deploy notes **why the risk is accepted** — e.g. sequencer outage exposure bounded by `MAX_PRICE_AGE` plus the operator's ability to trip `UltraMinter.mint`. Do not leave this unanswered; "we did not check" is not an accepted risk. |
| `USDS` address on Robinhood Chain; confirm 18 decimals | `UltraMinter` ctor, batches | Treasury ops, before deploy | Verify. The constructor now **reverts** `InvalidTokenDecimals` on anything but 18 (§5.5.2), so a wrong address fails the deploy rather than mispricing silently. If USDS is genuinely not 18 decimals, that is a spec change, not an implementation workaround. |
| Robinhood Chain `chainId` | Safe batch JSON, `foundry.toml` fork profile | Whoever writes the batches | Verify. |
| Safe Transaction Service availability on Robinhood Chain | `propose-batch.mjs` vs `export-tx-builder.mjs` | Whoever writes the batches | Verify. If unsupported, batches are exported with `export-tx-builder.mjs` and uploaded manually to the Safe UI. |
| **Safe tooling round-trips a tuple argument and `payable`** | `script/safe/propose-batch.mjs`, `script/safe/export-tx-builder.mjs` | Plan stage, **before the buyback template is relied on** | **Open, and blocking for §7.3.** Every batch these scripts have carried so far takes flat scalar args. `exactInputSingle` takes a single `struct` (tuple) param, which is the first real exercise of tuple encoding in either script — verify it encodes and re-decodes identically rather than assuming. Also: `export-tx-builder.mjs:60` hardcodes `contractMethod.payable = false` and `value: "0"` for every transaction; confirm that is correct for the router call as written (non-payable `exactInputSingle` with ERC20 `tokenIn`) and that nothing in the flow needs a payable method. Write a round-trip check before the first buyback, not during one. |
| Uniswap v3 `SwapRouter` (or `SwapRouter02`) address + chosen pool fee tier | buyback template | Treasury ops | Verify. |
| `OPERATOR` — tripwire operator hot key | setup batch (§7.2) | Treasury | TBD. A key that can only halt, never move funds (§5.6). The §5.2.6 catch-up and §5.5.3 remediation paths assume it exists. |
| `INITIAL_VOL`, `CEILING_BPS` (suggested 300), `FLOOR_BPS` (suggested 500) | setup batch / ctor | Treasury | Suggested defaults only; owner-tunable within §5.2.3 bounds. `INITIAL_VOL` is a **calibrated implied** value reproducing the option's actual quote (§5.2.6a), not a realized-vol estimate, and `CEILING_BPS` must satisfy the §5.2.3 sizing relation. |
| Hard-bound constants in §5.2.3 | compiled constants | Plan/review stage | Suggested; may be adjusted. |
| `MAX_SUPPLY`, treasury `ALLOCATION` | `UltraMinter` ctor / setup batch | Treasury | TBD. **`MAX_SUPPLY` is inclusive of `ALLOCATION`** — it is checked against `ultra.totalSupply()`, which the allocation counts toward — so **`MAX_SUPPLY >= ALLOCATION` must hold**, and in practice must exceed it or the minter reverts `SupplyCapExceeded` on its first public mint. The allocation is minted directly through `UltraToken` (§7.2) and so is *not* itself cap-checked; this relation is verified by hand before the batch is proposed. Both values are governed by the §1 solvency invariant. |
| Solady: submodule vs vendored file | `lib/` or `src/lib/` | Plan stage | Decides per §3. |

## 9. Testing approach

Conventions: Foundry + forge-std; unit tests in `test/unit/` (default profile); fork tests in `test/integration/` (`integration` profile — note `package.json`'s `test:integration` fork URL is mainnet; a Robinhood Chain fork URL is needed if fork tests are written). Mocks in `test/mocks/`. Reference vectors are hardcoded in the test file (avoids widening `fs_permissions`).

### 9.1 `test/unit/BlackScholesTest.sol`

- Reference vectors: ~20–30 `(spot, strike, tYears, sigma) → callPrice` tuples generated offline (e.g. Python `scipy.stats.norm` / any standard BS implementation, r = 0), covering ATM, deep ITM, deep OTM, T from 1 day to 2 years, sigma from `VOL_MIN` to `VOL_MAX`.
- **Tolerance must scale with `spot + strike`, not `spot`.** `callPrice` is a difference of two terms, `spot * N(d1)` and `strike * N(d2)`, each carrying `normCdf`'s ~7.5e−8 absolute error independently. The error budget is therefore `~7.5e-8 * (spot + strike)`, and a tolerance written against `spot` alone fails spuriously on deep-OTM vectors where `strike >> spot`. Assert:
  ```
  |c − ref| <= max(1e-6 * (spot + strike), 1e-9 * 1e18)
  ```
  Keep reference vectors and fuzz bounds inside realistic moneyness (`0.2 <= spot/strike <= 5`) as well — outside that band the two-term cancellation dominates and the test measures `normCdf`'s tail behaviour rather than `callPrice`'s correctness. (The exact multiplier is a plan-stage choice; state it in the test. The `spot + strike` shape is not.)
- `normCdf` vectors: x ∈ {−10, −3, −1, −0.5, 0, 0.5, 1, 3, 10} against reference, abs tol 1e-6; clamp behaviour at ±10.
- Clamp tests (§5.3), targeted at the bound the clamp exists for: deep ITM with a large `strike` and small `tYears`, where the unclamped two-term difference can fall below intrinsic. Assert `c >= spot − strike` exactly at several such points, and `c <= spot` for deep ITM with long `tYears`.
- Fuzz properties over bounded inputs (`spot`, `strike` ∈ [1e15, 1e24] with `0.2 <= spot/strike <= 5`; `tYears` ∈ [0, 2e18]; `sigma` ∈ [VOL_MIN, VOL_MAX]):
  - `max(spot − strike, 0) <= c <= spot` (holds by construction given the clamp; the fuzz catches a removed or misordered clamp).
  - Monotone non-decreasing in `spot`, `tYears`, `sigma` (compare two evaluations). **Give the perturbation a floor of >= 1% of the varied input and allow a slack term** on the comparison: `c(x2) + slack >= c(x1)`. A fuzzer that picks `x2 = x1 + 1 wei` produces a true price difference far below the approximation's own error, so a strict comparison there tests rounding noise, not monotonicity.
  - `tYears == 0` returns intrinsic exactly.
  - No revert across the domain (catches `expWad`/`lnWad` domain issues).

### 9.2 `test/unit/UltraFairValueTest.sol`

**Adds `test/mocks/MockAggregatorV3.sol` (new file)** — settable `answer`, `updatedAt`, `decimals`. No Chainlink mock exists anywhere in the repo (`test/mocks/` holds only `MockGavToken`, `MockPriceOracle`, `MockWETH`, and `MockPriceOracle` is Euler's `IPriceOracle`, a different interface). Write it; do not go looking for one to reuse.

- Constructor: rejects zero feed, zero strike/ethPerToken, past expiry, out-of-bound bps, feed decimals > 18, non-positive initial answer.
- `spot()`: decimals normalisation (8 → 18); reverts `InvalidPrice` on `answer <= 0`; reverts `StalePrice` when `updatedAt` older than `maxPriceAge`; boundary at exactly `maxPriceAge`; **reverts `StalePrice` (not a `0x11` underflow panic) when `updatedAt > block.timestamp`** — set the mock's `updatedAt` into the future to cover the L2 clock-skew guard.
- `fairValue()` pre-expiry: reverts `VolStale` before first `setVol`; reverts `VolStale` once `VOL_MAX_AGE` elapses; matches `BlackScholes.callPrice(...) * ethPerToken / 1e18`.
- `latchSettlement()` / post-expiry `fairValue()`:
  - reverts `NotExpired` before `expiry`; succeeds at exactly `block.timestamp == expiry`.
  - second call reverts `AlreadyLatched`; callable by a random address (permissionless).
  - propagates `StalePrice` / `InvalidPrice` when the feed is bad at latch time.
  - `fairValue()` reverts `SettlementNotLatched` between `expiry` and the latch, and `ceiling()`/`floor()` propagate that.
  - after latching, `fairValue()` equals `max(settlementSpot − strike, 0) * ethPerToken / 1e18`, is **unchanged when the mock feed's answer is then moved**, and is **unchanged when the feed is made stale** (post-expiry must not read the feed at all).
  - intrinsic is 0 when `settlementSpot < strike`.
  - post-expiry does not read vol (works with stale vol).
- `ceiling()` / `floor()`: exact bps arithmetic; propagate reverts.
- `setVol`: unauthorized caller; out-of-bounds; first update skips step/interval; second update within `VOL_MIN_INTERVAL` reverts; step larger than `VOL_MAX_STEP` reverts (both directions); valid update emits event and stamps `volUpdatedAt`; `setVolSetter` delegation and zero check.
- `volSetter` survives ownership transfer: after `transferOwnership` + `acceptOwnership`, the **old** owner still passes the `setVol` authorization check and the new owner does not, until `setVolSetter` is called. Pins the coupling §5.2.2 and §7.5 warn about, so a future refactor cannot quietly "fix" it into implicit behaviour.
- `setCeilingBps` / `setFloorBps`: bounds inclusive at both ends; events; onlyOwner.
- Constant sanity: `VOL_MIN_INTERVAL < VOL_MAX_AGE`, `CEILING_BPS_MIN <= CEILING_BPS_MAX`, `FLOOR_BPS_MAX < BPS`.

### 9.3 `test/unit/UltraMinterTest.sol`

Uses `UltraToken`, `UltraFairValue` with mock feed, `TripwireController`, and **`lib/forge-std/src/mocks/MockERC20.sol`** for USDS — already vendored with forge-std, a plain 18-decimal ERC20, exactly what this needs. Do **not** use `test/mocks/MockGavToken.sol`: it is stale (it calls the `MintableBurnableToken` base with 3 args against the current 5-arg constructor, so it does not compile) and it is a mint/burn-role token, not a stand-in for an external stablecoin.

- Constructor: `InvalidTokenDecimals` when the USDS mock reports anything but 18 (a 6-decimal mock is the realistic case); `InvalidMaxSupply` for `maxSupply_ == 0` and for `type(uint256).max`; an ordinary in-between value succeeds.
- Happy path: USDS lands in treasury, ULTRA in `to`, `ultraOut == usdsIn * 1e18 / ceiling()`, event fields.
- Reverts: `ZeroAddress`, `ZeroAmount` for `usdsIn == 0`, `TransactionStale` (deadline in past; boundary `deadline == block.timestamp` succeeds), `Expired` (at and after `expiry`), `InsufficientOutput`, `SupplyCapExceeded` (boundary `newSupply == maxSupply` succeeds), `VolStale`/`StalePrice` propagate uncaught, `MinterUnauthorizedAccount` when the minter role is missing, `Tripped` when `UltraMinter.mint` is tripped and, separately, when `UltraToken.mint` is tripped.
- `ZeroPrice`: drive the mock feed deep OTM close to expiry so `ceiling()` returns 0, and assert `mint` reverts `ZeroPrice` rather than panicking `0x12` on the division.
- `ZeroAmount` on dust: `usdsIn` small enough that `usdsIn * 1e18 / price` truncates to 0, **with `minUltraOut = 0`**, asserting the revert — and asserting the treasury's USDS balance is unchanged, since the bug this guards is the caller paying for nothing.
- Vol catch-up window (§5.2.6): with a large pending vol move, trip `UltraMinter.mint` via the operator, assert `mint` reverts `Tripped` while `ceiling()` still returns a value, walk `setVol` in across several `VOL_MIN_INTERVAL` steps, untrip, and assert `mint` succeeds at the new price. Covers the operational rule the design depends on and pins that the trip does not affect `UltraToken.burn` or the views.
- Reentrancy: a malicious USDS mock that re-enters `mint` during `transferFrom` is rejected by `nonReentrant`.
- Setters: `setMaxSupply` (valid value + event; rejects 0 and `type(uint256).max`; permitted below current `totalSupply()`), `setTreasury` (zero check, event, subsequent mint pays new treasury), onlyOwner on both.
- Minter holds no USDS and no ULTRA after any sequence (invariant).

### 9.4 `test/unit/UltraTokenTest.sol`

Follows `test/unit/MintableBurnableTokenTest.sol`: name/symbol, only-owner `manageMinter`, minter-only `mint`, holder `burn`, `burnFrom` via allowance, tripwire on `mint`/`burn`. `burnFrom` is unused by the product (§5.1) but is still exercised here, because the base contract exposes it publicly and an inherited surface that nothing tests is an inherited surface nobody notices breaking.

### 9.5 Integration (`test/integration/`, optional, fork of Robinhood Chain)

Only if a Robinhood Chain RPC is available to CI: deploy `UltraFairValue` against the real ETH/USD feed and assert `spot()` is within a sane range and non-stale, and that `decimals()` is what §8 recorded. Unit coverage is sufficient for merge; the fork test is a pre-deploy check.

**Scope, deliberately narrowed:** the Chainlink half only. The previously-sketched `SwapRouter.exactInputSingle` half is cut. §2 excludes on-chain DEX interaction from this system entirely, and writing that test means introducing a Uniswap router interface — which is how a router interface ends up in `src/` six months later, next to a contract that never calls one. The buyback template's price-limit formula and token ordering are verified off-chain against the live pool as part of the first buyback's dry run (§7.3), which tests the thing that actually ships. If a future reviewer wants the fork test anyway, the interface it needs **lives only in `test/`, never in `src/`** — that is the condition, not a preference.

### 9.6 Not tested here

Seaport order construction (no repo code), Safe batch JSON contents beyond schema validity (existing `propose-batch.mjs` validation covers schema), the dapp (out of scope).
