# StratETHTreasuryLend (TreasuryLend) User Stories

## User Stories

### Glossary / Actors

- **Borrower**: A user who brings **STRAT** and **CDT** as collateral and borrows ETH liquidity.
- **Position Owner**: The current owner of the ERC721 loan position NFT (transferable).
- **Liquidator**: Anyone who can liquidate an expired position (permissionless after expiry).
- **Owner**: The contract owner (governance root).
- **Rate Setter**: An address delegated to update the borrow interest rate parameter (initially the `owner`, but changeable).
- **Fee Setter**: An address delegated to update the delinquent fee parameter (initially the `owner`, but changeable).
- **Unencumbered Holdings**: An address holding unencumbered `esETH` used as the source of all loan payouts and the destination of all repayments. Reducing this balance reduces STRAT backing value.
- **Encumbered Holdings**: An address holding encumbered `esETH` (included in total backing for STRAT valuation but not used for loan payouts).
- **Interest Revenue Recipient**: An address that receives paid interest (e.g. a staking rewards pool).
- **STRAT Stakers**: Users staking STRAT (e.g. via `StakedStrat`) who should receive TreasuryLend interest revenue.

---

### Roles & Permissions

**US-000: Delegatable parameter roles (owner-managed)**
- **As a** protocol operator
- **I want** explicit non-owner roles for updating interest and delinquent fee parameters
- **So that** these knobs can be automated/delegated in the future without transferring ownership
- **Acceptance Criteria:**
  - `owner` can set `rateSetter` and `feeSetter` addresses
  - `rateSetter` is initialized to `owner`
  - `feeSetter` is initialized to `owner`
  - `owner` can update `rateSetter` and `feeSetter` at any time
  - `rateSetter` and `feeSetter` cannot be set to the zero address

**US-001: Owner-managed risk parameters**
- **As a** protocol operator
- **I want** governance to be able to tune core risk parameters
- **So that** the system can adapt to market conditions
- **Acceptance Criteria:**
  - `owner` can set `loanDuration` (default: 6 months / 180 days)
  - Changes apply to **new borrows / rolls** going forward (existing positions keep their recorded parameters where applicable)

---

### Position Model (ERC721)

**US-010: Loan positions are represented as transferable NFTs**
- **As a** borrower
- **I want** my loan position to be represented by a transferable NFT
- **So that** I can transfer ownership (e.g., to another wallet or to a contract that manages positions)
- **Acceptance Criteria:**
  - Opening a loan mints an ERC721 position NFT to the borrower
  - The position NFT fully determines who can repay and who can roll the position
  - Burning the NFT closes the position (repay) or destroys it (liquidation)

**US-011: Position records fixed-per-borrow interest rate**
- **As a** borrower
- **I want** my borrow interest rate to be fixed at the time I open (or roll) my position
- **So that** my repayment schedule is predictable for the full term
- **Acceptance Criteria:**
  - Each position stores an `rate` snapshot that is fixed for that term
  - Later governance changes to the global interest rate do **not** affect existing positions until they are rolled

**US-012: Position records delinquent fee at origination**
- **As a** borrower
- **I want** any delinquent-fee rules to be clear and fixed for my position
- **So that** I understand exactly what I will owe if I allow the loan to expire
- **Acceptance Criteria:**
  - Each position stores the `delinquentFee` amount (in esETH) reserved at origination
  - This amount is not charged on timely repayment; it is forfeited on liquidation (converted to EPS growth, see US-401)
  - The fee is computed as `ethBacking * delinquentFeeRate / SCALE` at the time the position is opened or rolled

---

### Borrowing

**US-100: Borrow ETH using STRAT + CDT collateral**
- **As a** borrower
- **I want to** deposit STRAT and CDT and borrow ETH against my covered collateral
- **So that** I can access ETH liquidity without selling STRAT
- **Acceptance Criteria:**
  - Borrower submits `maxStratIn` STRAT and `maxCdtIn` CDT. The protocol determines the covered (CDT-backed) portion:
    - `cdtIn = maxStratIn * CDT.totalSupply() / STRAT.totalSupply()`
    - If `cdtIn > maxCdtIn`, CDT is the limiting factor: `cdtIn = maxCdtIn`, `stratIn = cdtIn * STRAT.totalSupply() / CDT.totalSupply()`
    - Otherwise: `stratIn = maxStratIn`, `cdtIn` is as computed
  - The protocol values the covered collateral using current STRAT backing:
    - `totalHoldingsInETH = esETH.balanceOf(unencumberedHoldings) + esETH.balanceOf(encumberedHoldings)`
    - `ethBacking = totalHoldingsInETH * stratIn / STRAT.totalSupply()`
  - The borrow amounts are derived from `ethBacking`:
    - `delinquentFee = ethBacking * delinquentFeeRate / SCALE`
    - `termFactor = borrowRate * loanDuration / 365 days`
    - `borrowAmount = (ethBacking - delinquentFee) / (1 + termFactor)`
    - `maxTermInterest = borrowAmount * termFactor`
    - Invariant: `borrowAmount + maxTermInterest + delinquentFee = ethBacking`
  - **esETH flow:**
    1. The full `ethBacking` is transferred from `unencumberedHoldings` into `TreasuryLend` (held in reserve for the life of the position).
    2. Only the `borrowAmount` (principal) is forwarded from `TreasuryLend` to the borrower.
    3. `maxTermInterest + delinquentFee` remain in `TreasuryLend`, reserved for settlement.
  - The covered `stratIn` STRAT and `cdtIn` CDT are burned from the borrower.
  - A position NFT is minted that records all terms: collateral amounts, principal, maxTermInterest, delinquentFee, rate, startTime, expiry.
  - `borrowAmount` must meet a caller-supplied `minBorrowAmount` slippage guard.

**US-101: Preview borrow outcome**
- **As a** borrower or integrator
- **I want to** preview how much I can borrow for a given STRAT/CDT deposit
- **So that** I can make informed decisions and build good UX
- **Acceptance Criteria:**
  - `previewBorrow(maxStratIn, maxCdtIn)` returns:
    `(stratIn, cdtIn, ethBacking, borrowAmount, maxTermInterest, delinquentFee)`
  - The preview uses the **current** global parameters (current `borrowRate`, current `delinquentFeeRate`, current `loanDuration`)
  - The preview clearly indicates that the borrow rate is snapshotted when the borrow actually executes

---

### Interest Accrual & Repayment

**US-200: Interest accrues proportionally over time (linear)**
- **As a** borrower
- **I want** interest to be charged proportionally to time elapsed
- **So that** repaying earlier is cheaper than repaying at expiry
- **Acceptance Criteria:**
  - Each position has a fixed `rate` and fixed `expiry`
  - `accruedInterest(tokenId)` at time `t`:
    - `0` if `t <= startTime`
    - `maxTermInterest` if `t >= expiry`
    - `maxTermInterest * (t - startTime) / (expiry - startTime)` otherwise
  - Accrued interest is capped at `maxTermInterest` at expiry

**US-201: Repay at any time before expiry**
- **As a** position owner
- **I want to** repay my loan before expiry
- **So that** I can recover my STRAT and CDT collateral
- **Acceptance Criteria:**
  - Only the current position NFT owner can repay
  - Repayment is allowed when `block.timestamp < expiry`
  - **esETH flow on repay:**
    1. Pull `principal + accruedInterest` from the position owner into `TreasuryLend`
    2. Send `accruedInterest` to `interestRevenueRecipient`
    3. Return `principal + maxTermInterest + delinquentFee` (the full reserved backing) to `unencumberedHoldings`
  - Note: the borrower pays only `accruedInterest` (not `maxTermInterest`); the unused interest reserve (`maxTermInterest - accruedInterest`) is returned to unencumbered as a bonus, preserving the `ethPerStrat` invariant (see US-800)
  - On repay: position NFT is burned; borrower's `stratIn` STRAT and `cdtIn` CDT are minted back

---

### Rolling (Modify an existing position NFT)

**US-300: Roll a position (adjust STRAT/CDT and refresh the term)**
- **As a** position owner
- **I want to** roll my position in-place (same NFT) by adjusting STRAT/CDT and resetting the loan term
- **So that** I can maintain or resize exposure without closing and reopening a new NFT
- **Acceptance Criteria:**
  - Only the current position NFT owner can roll
  - Rolling settles accrued interest to date and re-originates the position with new parameters
  - NFT identity (token ID) is preserved
  - Rolling resets the expiry to `block.timestamp + loanDuration`
  - Rolling snapshots a new fixed `rate` for the rolled term

**US-301: Rolling adjusts esETH balance (netting approach)**
- **As a** position owner
- **I want** rolling to adjust my principal based on updated collateral and borrowing power
- **So that** I can increase borrow if I add collateral, or reduce principal if collateral value decreased
- **Acceptance Criteria:**
  - After roll, a new `newBorrowAmount` and `newEthBacking` are computed via `previewBorrow`
  - The old backing (`oldPrincipal + oldMaxTermInterest + oldDelinquentFee`) and new backing are netted to avoid unnecessary round-trips:
    - **Case A** (`oldPrincipal + accruedInterest > newBorrowAmount`): position owner pays in the shortfall; `TreasuryLend` returns the net backing reduction to `unencumberedHoldings`
    - **Case B** (`newBorrowAmount >= oldPrincipal + accruedInterest`): `TreasuryLend` pulls the net backing increase from `unencumberedHoldings` and pays the net surplus to the position owner
  - `accruedInterest` is sent to `interestRevenueRecipient` in both cases
  - Collateral (STRAT/CDT) is burned or minted for the delta between old and new covered amounts

**US-302: Rolling settles interest and routes it to stakers**
- **As a** STRAT staker
- **I want** interest paid during roll operations to be treated the same as repayment interest
- **So that** rolling does not bypass revenue distribution
- **Acceptance Criteria:**
  - Rolling computes and settles `accruedInterest` up to the roll timestamp
  - Settled interest is sent to `interestRevenueRecipient` (same as repayment, see US-600)

---

### Liquidation (Permissionless after expiry)

**US-400: Position is unliquidatable until expiry, then liquidatable by anyone**
- **As a** borrower
- **I want** my position to be safe from liquidation for the full term
- **So that** I can rely on a predictable window
- **Acceptance Criteria:**
  - Before expiry (`block.timestamp < expiry`), liquidation is not possible
  - At/after expiry (`block.timestamp >= expiry`), anyone can liquidate

**US-401: Liquidation settles reserved esETH and forfeits collateral**
- **As a** liquidator / STRAT holder
- **I want** expired positions to be cleanly closed
- **So that** reserved esETH is released and delinquent borrowers add EPS growth to remaining STRAT holders
- **Acceptance Criteria:**
  - **esETH flow on liquidation (TreasuryLend releases its reserved balance):**
    1. Send `maxTermInterest` to `interestRevenueRecipient` (books the full-term interest revenue)
    2. Send `delinquentFee` to `unencumberedHoldings` (adds EPS growth — increases `ethPerStrat` for all remaining STRAT holders, see US-801)
  - The position NFT is burned
  - The borrower's STRAT and CDT collateral is **forfeited** (was burned at origination and is not returned)
  - No liquidation fee is charged; the liquidator receives no reward
  - The `principal` is a permanent loss (the defaulting borrower retains it)

---

### Governance Parameters (Rate + Delinquent Fee)

**US-500: Rate setter updates the borrow interest rate parameter**
- **As a** rate setter (keeper/automation)
- **I want to** update the borrow interest rate parameter
- **So that** new borrows/rolls price risk appropriately
- **Acceptance Criteria:**
  - Only `rateSetter` can update the current `borrowRate`
  - Updates only affect **new borrows** and **rolls** (existing positions keep their snapshotted rate)

**US-501: Fee setter updates the delinquent fee parameter**
- **As a** fee setter (keeper/automation)
- **I want to** update the delinquent fee parameter
- **So that** late repayment penalties can be tuned over time
- **Acceptance Criteria:**
  - Only `feeSetter` can update the `delinquentFeeRate`
  - The new rate applies to all **new borrows and rolls**; existing positions store the fee amount computed at origination

---

### Interest Distribution to STRAT Stakers

**US-600: Interest revenue is routed to STRAT stakers**
- **As a** STRAT staker
- **I want** interest paid by TreasuryLend borrowers to accrue to STRAT stakers
- **So that** staking STRAT captures the protocol's lending revenue
- **Acceptance Criteria:**
  - Interest paid on repay/roll is transferred to `interestRevenueRecipient` (in `esETH`)
  - On liquidation, the full `maxTermInterest` is transferred to `interestRevenueRecipient`
  - `interestRevenueRecipient` is set by the `owner` and defaults to the owner address

---

### Security & Safety

**US-700: Clear failure modes and input validation**
- **As a** user or integrator
- **I want** invalid actions to revert with explicit reasons
- **So that** I can debug and build reliable UX
- **Acceptance Criteria:**
  - Zero-amount deposits are rejected
  - Only position owner can repay/roll
  - Repay/roll enforce `block.timestamp < expiry`
  - Liquidate enforces `block.timestamp >= expiry`
  - Parameter setters enforce non-zero addresses and role access control
  - Borrow enforces a `minBorrowAmount` slippage guard and a `deadline` staleness guard
  - Roll enforces a `minNewBorrowAmount` slippage guard and a `deadline` staleness guard

---

### Protocol Invariants

**US-800: ethPerStrat is preserved across borrow, repay, and roll**
- **As a** STRAT holder
- **I want** the ETH-backing value per STRAT token to be unaffected by the lending activity of other users
- **So that** opening, repaying, or rolling loans does not dilute or inflate my STRAT's value
- **Formal invariant:**
  - Let `ethPerStrat = (esETH.balanceOf(unencumberedHoldings) + esETH.balanceOf(encumberedHoldings)) / STRAT.totalSupply()`
  - After any borrow, repay, or roll: `ethPerStrat_after == ethPerStrat_before` (within 1 wei integer rounding)
- **Proof sketch:**
  - *Borrow*: `H` decreases by `H * stratIn / S`; `S` decreases by `stratIn`. Net: `(H - H*stratIn/S) / (S - stratIn) = H*(S-stratIn)/(S*(S-stratIn)) = H/S`.
  - *Repay*: inverse of borrow; `H` and `S` are both restored to pre-borrow values.
  - *Roll*: new backing `newEthBacking = H * newStratIn / S` is computed from current values; both `H` and `S` adjust by the covered proportion. The same factoring applies.
- **Critical constraint — `interestRevenueRecipient` must not be a holdings address:**
  - This invariant holds **only when** `interestRevenueRecipient ∉ {unencumberedHoldings, encumberedHoldings}`.
  - `_totalHoldingsInETH()` is the sum of balances at those two addresses. If interest is routed to either holdings address, the interest payment increases `H`, which increases `ethPerStrat`. For example, on repay with revenue = unencumberedHoldings: `H_new = H + ethBacking + interest` and `S_new = S + stratIn`, giving `ethPerStrat_new = (H_original + interest) / S_original ≠ H_original / S_original`.
  - In practice, `interestRevenueRecipient` should be a staker rewards pool or a distinct protocol address.
- **Additional caveats:**
  - External actions that change STRAT supply without proportionally adjusting holdings (e.g. minting STRAT as a reward without adding ETH backing) will change `ethPerStrat` — this is expected and by design.
  - The invariant holds exactly within 1–2 wei of integer division rounding.

**US-801: Liquidation increases ethPerStrat by delinquentFee / STRAT.totalSupply()**
- **As a** STRAT holder
- **I want** delinquent borrowers to provide a bonus to remaining STRAT holders
- **So that** default risk is compensated via EPS growth
- **Formal invariant:**
  - After a liquidation: `ethPerStrat_after - ethPerStrat_before == delinquentFee / STRAT.totalSupply()` (within 1 wei rounding)
- **Explanation:**
  - The defaulting borrower's STRAT collateral was already burned at origination and is **not** returned on liquidation. Therefore `STRAT.totalSupply()` is unchanged.
  - `delinquentFee` esETH (reserved in `TreasuryLend` since origination) is returned to `unencumberedHoldings`, increasing total holdings.
  - The net effect is `H_new / S = (H + delinquentFee) / S = H/S + delinquentFee/S`.
- **Critical constraint:** same as US-800 — `interestRevenueRecipient ∉ {unencumberedHoldings, encumberedHoldings}`. If the recipient is a holdings address, `maxTermInterest` also flows into holdings on liquidation, and the increase becomes `(maxTermInterest + delinquentFee) / S` instead of `delinquentFee / S`.
