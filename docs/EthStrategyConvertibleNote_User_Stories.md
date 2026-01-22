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
  - `pcf` is used in `conversionEntitlements(settlementEntitlementUsd)`

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
    - `pcf`
  - This function is used by `bond(...)` and thus must be stable enough for slippage checks

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

## Technical Notes (State on each tokenId)

- Each note NFT stores the remaining balances:
  - **Strike / CDT owed**: `amountOwedCdt[tokenId]`
  - **STRAT entitlement remaining**: `conversionEntitlementStrat[tokenId]`
  - **ETH(esETH) entitlement remaining**: `conversionEntitlementEth[tokenId]`
  - **USD settlement entitlement remaining**: `settlementEntitlementUsd[tokenId]`
  - `timelock[tokenId]` and `expiry[tokenId]`
- Conversion is **pro-rata** against remaining balances and can be repeated until fully settled; the NFT is burned when `amountOwedCdt[tokenId] == 0`.

