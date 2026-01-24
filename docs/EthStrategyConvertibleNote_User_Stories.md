# EthStrategyConvertibleNote (esCN) User Stories

## User Stories

### Glossary / Actors

- **Bonder**: User who sends ETH to `bond(...)` to mint (a) **CDT** and (b) an **ERC721 note NFT**.
- **Note Owner**: Current `ownerOf(tokenId)` of the ERC721 note NFT.
- **Owner**: Contract owner (governance root) for parameter/renderer management.
- **CDT**: ERC20 minted on bond and burned on conversion/redemption (supports ERC-2612 permit via `Permit` helper).
- **STRAT**: ERC20 minted on STRAT conversion.
- **esETH (`esETHToken`)**: ERC20-like token used as the system’s ETH representation (minted via `wrapAndMint`), moved between holdings and transferred to users as “ETH out”.
- **Unencumbered Holdings**: Address holding “free” esETH (protocol liquidity / backing).
- **Encumbered Holdings**: Address holding esETH reserved to back open/unexercised conversion-to-ETH rights.
- **Oracle**: ETH/USD oracle used to compute USD notionals and preview entitlements.

---

## Roles & Permissions

**US-000: Owner can update the premium control factor (PCF)**
- **As a** protocol operator (`owner`)
- **I want** to update `pcf`
- **So that** conversion entitlement calculations can be tuned over time
- **Acceptance Criteria:**
  - Only `owner` can call `setPCF(newVal)`
  - Emits `OwnerChangedPCF(oldVal, newVal)`
  - `pcf` is used in `conversionEntitlements(settlementEntitlementUsd)` to scale the premium term

**US-000a: Owner can update the GAV control factor (GCF)**
- **As a** protocol operator (`owner`)
- **I want** to update `gcf`
- **So that** conversion entitlement calculations can scale the gross asset value independently
- **Acceptance Criteria:**
  - Only `owner` can call `setGCF(newVal)`
  - Emits `OwnerChangedGCF(oldVal, newVal)`
  - `gcf` is used in `conversionEntitlements(settlementEntitlementUsd)` to scale the GAV term
  - `gcf` is initialized to `1 * SCALE` in the constructor (no scaling by default)

**US-001: Owner can set a tokenURI renderer**
- **As a** protocol operator (`owner`)
- **I want** to set `tokenURIRenderer`
- **So that** note NFTs can have rich metadata without upgrading core logic
- **Acceptance Criteria:**
  - Only `owner` can call `managerRenderer(renderer)`
  - Emits `RendererUpdated(renderer)`
  - If no renderer is set, `tokenURI(tokenId)` returns `""`

---

### Bonding (Create a Convertible Note)

**US-100: Bond ETH to mint CDT and a convertible note NFT**
- **As a** user (bonder)
- **I want to** deposit ETH to mint a note NFT plus CDT
- **So that** I can later convert CDT into STRAT or ETH before expiry, or redeem USD notional after expiry
- **Acceptance Criteria:**
  - `bond(bonder, minConversionAmountStrat, minConversionAmountEth, deadline)` reverts if:
    - `msg.value == 0` (`NoEthSent`)
    - `bonder == address(0)` (`ZeroAddress`)
    - `deadline < block.timestamp` (`TransactionStale(deadline)`)
  - The contract computes:
    - `settlementEntitlementUsd = msg.value * ethPriceUSD / ORACLE_SCALE`
    - `(conversionAmountStrat, conversionAmountEth) = conversionEntitlements(settlementEntitlementUsd)`
  - Slippage checks:
    - Revert `InsufficientOutput` if `conversionAmountStrat < minConversionAmountStrat`
    - Revert `InsufficientOutput` if `conversionAmountEth < minConversionAmountEth`
  - The contract mints an ERC721 to `bonder` and stores per-token state:
    - **CDT strike/repayment amount**: `amountOwedCdt[tokenId]` (the remaining CDT required to fully settle the note)
    - `conversionEntitlementStrat[tokenId]`
    - `conversionEntitlementEth[tokenId]`
    - `settlementEntitlementUsd[tokenId]`
    - `expiry[tokenId]`
    - `timelock[tokenId]`
  - The contract mints `CDT` to `bonder` equal to `settlementEntitlementUsd[tokenId]`
  - ETH flow uses esETH minting and splits the bond ETH into:
    - **Encumbered** portion: `esETHToken.wrapAndMint{value: conversionAmountEth}(encumberedHoldings)`
    - **Unencumbered** remainder: `esETHToken.wrapAndMint{value: msg.value - conversionAmountEth}(unencumberedHoldings)`
  - Emits `LongBond(bonder, tokenId, strike, notionalUnderlyingAmount, notionalUSDAmount, ethAmount, expiry, timelock)`
    - Where “strike / notional” values correspond to the stored per-token values computed above

**US-101: Bonding uses fixed timelock and expiry**
- **As a** bonder / integrator
- **I want** predictable timelock + expiry offsets
- **So that** UIs can render a consistent lifecycle
- **Acceptance Criteria:**
  - `expiry[tokenId] = now + ~4.2 years`
  - `timelock[tokenId] = now + ~6.9 days`
  - If the contract’s computed `timelock`/`expiry` are invalid, bonding reverts with `InvalidTimelockOrExpiry(timelock, expiry)`

**US-102: Bonding may revert on esETH minting if caller is not permitted**
- **As a** bonder / integrator
- **I want** to understand who is allowed to perform the esETH minting done during `bond`
- **So that** integrations can ensure the correct `treasuryManager` / whitelist configuration exists
- **Acceptance Criteria:**
  - `bond(...)` mints esETH via `esETHToken.wrapAndMint(...)`
  - If the `esETH` contract restricts minting (e.g., `treasuryManager` gating / token config), then `bond(...)` will revert if the caller is not authorized by `esETH`

---

## Lifecycle Gates (Timelock + Expiry)

**US-120: Timelock blocks conversion and redemption**
- **As a** note owner
- **I want** conversion and redemption blocked during timelock
- **So that** newly-issued notes cannot be immediately settled
- **Acceptance Criteria:**
  - If `timelock[tokenId] > block.timestamp`, conversion and redemption revert with `TimelockActive(account, tokenId)`

**US-121: Conversion is only available before expiry**
- **As a** note owner
- **I want** conversion to only be possible before expiry
- **So that** expired notes cannot be converted into STRAT/ETH
- **Acceptance Criteria:**
  - If `expiry[tokenId] < block.timestamp`, conversion reverts with `OptionExpired(account, tokenId)`

**US-122: Redemption is only available after expiry**
- **As a** note owner
- **I want** redemption to only be possible after expiry
- **So that** redemption is a post-expiry settlement path
- **Acceptance Criteria:**
  - If `expiry[tokenId] > block.timestamp`, redemption reverts with `OptionUnexpired(account, tokenId)`

---

## Conversion (Burn CDT → Receive STRAT or esETH), partial or full

Conversion supports **partial settlement** against the same `tokenId`: balances are decremented pro-rata, and the NFT is burned only once the position is fully settled.

**US-200: Only the note owner can convert/redeem**
- **As a** note owner
- **I want** only `ownerOf(tokenId)` to be able to convert or redeem
- **So that** settlement rights cannot be executed by third parties (even if approved for NFT transfer)
- **Acceptance Criteria:**
  - If `msg.sender != ownerOf(tokenId)`, conversion and redemption revert with `NotOwnerOrApproved(account, tokenId)`
  - (Note: ERC721 approvals exist for transfers but are intentionally **not** used for authorization in settlement paths.)

**US-201: Partial conversion burns CDT and pays out pro-rata STRAT or esETH**
- **As a** note owner
- **I want to** burn some CDT and receive a proportional amount of STRAT or esETH
- **So that** I can settle my position in chunks
- **Acceptance Criteria:**
  - Entry points:
    - `convertPartialWithPermit(tokenId, cdtToBurn, toEth, cdtPermitApproval)`
    - `convertPartial(tokenId, toEth, cdtToBurn)` (no permit)
  - Preconditions:
    - Timelock passed; not expired; caller is the note owner
    - `cdtToBurn` must satisfy `0 < cdtToBurn <= amountOwedCdt[tokenId]` else `InvalidExerciseAmount(amount, amountOwedCdt[tokenId])`
  - Output calculation is pro-rata against current stored balances:
    - `stratOut = conversionEntitlementStrat[tokenId] * cdtToBurn / amountOwedCdt[tokenId]`
    - `ethOut   = conversionEntitlementEth[tokenId]   * cdtToBurn / amountOwedCdt[tokenId]`
  - The contract burns `cdtToBurn` CDT from the caller (using permit validation if provided)
  - The contract moves backing esETH:
    - `esETHToken.transferFrom(encumberedHoldings, unencumberedHoldings, ethOut)`
  - Payout path:
    - If `toEth == true`: transfer `ethOut` esETH from `unencumberedHoldings` to the note owner
    - Else: mint `stratOut` STRAT to the note owner
  - Stored balances are decremented:
    - `amountOwedCdt[tokenId] -= cdtToBurn`
    - `conversionEntitlementStrat[tokenId] -= stratOut`
    - `conversionEntitlementEth[tokenId] -= ethOut`
    - `settlementEntitlementUsd[tokenId] -= cdtToBurn`
  - Emits `Conversion(optionOwner, tokenId, cdtBurned, stratOut, ethOut, remainingStrat, remainingEth, remainingUsd)`

**US-202: Full conversion burns the NFT once fully settled**
- **As a** note owner
- **I want** the NFT burned when all strike has been settled
- **So that** the position is cleanly closed on full settlement
- **Acceptance Criteria:**
  - Entry points:
    - `convertWithPermit(tokenId, permit)` (full convert to STRAT)
    - `convert(tokenId, toEth)` (full convert to STRAT or ETH)
  - When `amountOwedCdt[tokenId] == 0` after a conversion:
    - The contract clears `expiry[tokenId]` and `timelock[tokenId]`
    - The contract burns the NFT (`_burn(tokenId)`)

**US-203: Conversion can use ERC-2612 permit for CDT approval**
- **As a** note owner
- **I want** conversion to support permit-based CDT approval
- **So that** I can convert without a separate CDT `approve()` transaction
- **Acceptance Criteria:**
  - Conversion validates the permit using the CDT token + `Permit` helper, then burns CDT from the caller
  - If permit validation fails, conversion fails (via the CDT/permit validation path)

---

## Post-expiry Redemption (Burn CDT → Receive esETH), single-shot

**US-300: Redeem USD notional in esETH after expiry**
- **As a** note owner
- **I want to** redeem the remaining USD notional after expiry
- **So that** I can receive an ETH-denominated payout after the conversion window ends
- **Acceptance Criteria:**
  - Entry points:
    - `redeemCdtForUsdNotionalWithPermit(tokenId, permit)`
    - `redeemCdtForUsdNotional(tokenId)` (no permit)
  - Preconditions:
    - Timelock passed; option expired; caller is the note owner
  - The contract redeems based on the note’s remaining `settlementEntitlementUsd[tokenId]`
  - The contract moves esETH backing for the note from encumbered to unencumbered:
    - `esETHToken.transferFrom(encumberedHoldings, unencumberedHoldings, conversionEntitlementEth[tokenId])`
  - Redemption payout is computed from unencumbered holdings and total CDT debt:
    - Let `treasuryInETH = esETHToken.balanceOf(unencumberedHoldings)`
    - Let `treasuryInUSD = treasuryInETH * ethPriceUSD / ORACLE_SCALE`
    - Let `totalDebt = cdtToken.totalSupply()`
    - If `treasuryInUSD > totalDebt`: pay the full USD notional at current price
    - Else: pay pro-rata share of unencumbered holdings: `settlementUsd * treasuryInETH / totalDebt`
  - The contract burns the NFT and clears all per-token balances (strike, entitlements, timestamps)
  - The contract burns CDT equal to `settlementEntitlementUsd[tokenId]` from the caller (permit-supported)
  - The contract transfers `ethAmount` esETH from `unencumberedHoldings` to the note owner
  - Emits `Redemption(optionOwner, tokenId, notionalUSDAmount, ethAmount)`

**US-301: Redemption can use ERC-2612 permit for CDT approval**
- **As a** note owner
- **I want** redemption to support permit-based CDT approval
- **So that** I can redeem without a separate CDT `approve()` transaction
- **Acceptance Criteria:**
  - Redemption validates the permit using the CDT token + `Permit` helper, then burns CDT from the caller

---

## NFT Behavior

**US-400: Note positions are transferable ERC721s**
- **As a** note owner
- **I want** to transfer my note NFT
- **So that** I can sell/transfer the position
- **Acceptance Criteria:**
  - Standard ERC721 transfer functions apply (`transferFrom` / `safeTransferFrom`)
  - Settlement payout always goes to `ownerOf(tokenId)` at the time of conversion/redemption

---

## Pricing / Entitlement Preview

**US-500: Frontends can preview conversion entitlements from USD notional**
- **As a** frontend / integrator
- **I want** a view function to preview STRAT and ETH entitlements for a USD notional
- **So that** I can quote bonding terms and show expected conversion outcomes
- **Acceptance Criteria:**
  - `conversionEntitlements(settlementEntitlementUsd)` returns `(stratAmount, ethAmount)`
  - The computation uses:
    - ETH/USD oracle price (`_getEthUsdPrice()`)
    - System balances (`esETHToken.balanceOf(unencumberedHoldings)` and `esETHToken.balanceOf(encumberedHoldings)`)
    - Token supplies (`stratToken.totalSupply()`, `cdtToken.totalSupply()`)
    - `pcf` (Premium Control Factor) - scales the premium term
    - `gcf` (GAV Control Factor) - scales the gross asset value (GAV) term
  - **STRAT pricing formula**: 
    - `numeratorUsd = (gav * gcf / SCALE) + premiumUsd`
    - `stratConversionRate = numeratorUsd * SCALE / stratTotalSupply`
    - `stratAmount = settlementUsd * SCALE / stratConversionRate`
    - Where `gav = totalEth * ethPriceUSD / ORACLE_SCALE`
    - And `premiumUsd = (pcf * adjustedCdtSupply) / SCALE`
  - **ETH pricing formula** (based on NAV per STRAT):
    - `debtInEth = cdtTotalSupply * ORACLE_SCALE / ethPriceUSD`
    - If `debtInEth > totalEth` (protocol underwater): `ethAmount = 0`
    - Otherwise: `navETH = totalEth - debtInEth`, `ethConversionRate = numeratorUsd * SCALE / navETH`, `ethAmount = settlementUsd * SCALE / ethConversionRate`
  - This function is used by `bond(...)` and thus must be stable enough for slippage checks

**US-500a: ETH conversion entitlements reflect net asset backing per STRAT**
- **As a** bonder
- **I want** my ETH conversion entitlement to reflect the actual net ETH backing available per STRAT
- **So that** I receive fair value accounting for existing debt obligations
- **Acceptance Criteria:**
  - ETH conversion entitlement is calculated as: `ethAmount = stratAmount × (navETH / stratTotalSupply)`
  - Where `navETH = totalEth - debtInEth` (net assets after existing debt)
  - This ensures bonders receive their pro-rata share of **unencumbered** ETH backing
  - If protocol is underwater (`debtInEth > totalEth`), then `ethAmount = 0` (no ETH conversion rights, only STRAT)
  - This protects existing creditors from dilution and prevents claiming non-existent backing

**US-500b: Bonding continues even when protocol is underwater**
- **As a** protocol operator / bonder
- **I want** bonding to remain active even when debt exceeds assets
- **So that** the protocol can accept fresh capital to aid recovery
- **Acceptance Criteria:**
  - When `debtInEth > totalEth`, bonding does NOT revert
  - New bonds receive full STRAT conversion rights (`stratAmount` calculated normally)
  - New bonds receive zero ETH conversion rights (`ethAmount = 0`)
  - This allows capital inflows during crisis while protecting existing creditors
  - Bonders can see upfront via `conversionEntitlements()` that `ethAmount = 0`

---

## Control Factors (GCF and PCF)

**US-501: GCF scales the perceived value of the treasury's gross asset value**
- **As a** protocol operator
- **I want** to scale the GAV independently from the actual ETH holdings
- **So that** pricing can be adjusted for risk, growth expectations, or market conditions
- **Acceptance Criteria:**
  - `gcf` (GAV Control Factor) multiplies the treasury's GAV in the conversion pricing formula
  - `gcf = 1 * SCALE` (default): GAV used as-is
  - `gcf > 1 * SCALE`: GAV is scaled up → higher price per token → fewer tokens per USD bonded
  - `gcf < 1 * SCALE`: GAV is scaled down → lower price per token → more tokens per USD bonded
  - `gcf = 0`: Only premium term affects pricing (GAV term becomes zero)

**US-502: PCF scales the premium component of the pricing**
- **As a** protocol operator
- **I want** to scale the premium term independently from the CDT supply
- **So that** the cost/value of conversion rights can be adjusted
- **Acceptance Criteria:**
  - `pcf` (Premium Control Factor) multiplies the adjusted CDT supply in the premium calculation
  - `pcf = 1 * SCALE` (default): Premium calculated directly from adjusted CDT supply
  - `pcf > 1 * SCALE`: Premium is scaled up → higher price per token → fewer tokens per USD bonded
  - `pcf < 1 * SCALE`: Premium is scaled down → lower price per token → more tokens per USD bonded

**US-503: GCF and PCF effects are mathematically predictable**
- **As a** protocol operator / auditor
- **I want** the pricing effects of GCF and PCF to be well-defined
- **So that** I can reason about the impact of parameter changes
- **Acceptance Criteria:**
  - Doubling `gcf` from 1 to 2 has the same effect on numerator as doubling the ETH in the treasury (when premium term is small relative to GAV term)
  - Doubling `pcf` from 1 to 2 has a similar effect as doubling the CDT supply
  - Both factors affect the numerator in the conversion rate formula: `rate = numeratorUsd / tokenSupply`
  - Higher numerator → higher rate → fewer tokens received per USD
  - Lower numerator → lower rate → more tokens received per USD

---

## Notes on Spec vs. Implementation-in-progress

- The contract currently defines an error `EthTransferFailed`, but the current spec flow in `EthStrategyConvertibleNote.sol` uses `esETHToken.wrapAndMint(...)` instead of raw ETH forwarding; `EthTransferFailed` is not used by the current function bodies.
- This doc intentionally reflects **the behaviors that exist in the current function bodies**: PCF setter + renderer management + bond/convert/redeem mechanics.

---

## Safety / Failure Modes

**US-700: Clear reverts for invalid user actions**
- **As a** user/integrator
- **I want** predictable revert reasons
- **So that** I can build reliable UX
- **Acceptance Criteria:**
  - Bonding: `NoEthSent`, `ZeroAddress`, `TransactionStale`, `InsufficientOutput`, `InvalidTimelockOrExpiry`
  - Conversion: `TimelockActive`, `OptionExpired`, `NotOwnerOrApproved`, `InvalidExerciseAmount`
  - Redemption: `TimelockActive`, `OptionUnexpired`, `NotOwnerOrApproved`

---

## Technical Notes

### Per-tokenId State

- Each note NFT stores the remaining balances:
  - **Strike / CDT owed**: `amountOwedCdt[tokenId]`
  - **STRAT entitlement remaining**: `conversionEntitlementStrat[tokenId]`
  - **ETH(esETH) entitlement remaining**: `conversionEntitlementEth[tokenId]`
  - **USD settlement entitlement remaining**: `settlementEntitlementUsd[tokenId]`
  - `timelock[tokenId]` and `expiry[tokenId]`
- Conversion is **pro-rata** against remaining balances and can be repeated until fully settled; the NFT is burned when `amountOwedCdt[tokenId] == 0`.

### Global State (Affects All New Bonds)

- **Control Factors** (both scaled by `SCALE = 1e18`):
  - `pcf` (Premium Control Factor): Scales the premium term in conversion pricing
  - `gcf` (GAV Control Factor): Scales the gross asset value term in conversion pricing
- **Token Addresses**:
  - `cdtToken`: The debt token minted on bonding
  - `stratToken`: The token that can be minted on conversion
  - `esETHToken`: The ETH representation used for internal accounting and payouts
- **Holdings Addresses**:
  - `unencumberedHoldings`: Holds protocol liquidity / free backing
  - `encumberedHoldings`: Holds esETH reserved for open conversion-to-ETH rights
- **Pricing Oracle**: `ethUsdOracle` for USD-denominated calculations
