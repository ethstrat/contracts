# StratETHTreasuryLend (TreasuryLend) User Stories

## User Stories

### Glossary / Actors

- **Borrower**: A user who brings **STRAT** and **CDT** as collateral and borrows ETH liquidity.
- **Position Owner**: The current owner of the ERC721 loan position NFT (transferable).
- **Liquidator**: Anyone who can liquidate an expired position (permissionless after expiry).
- **Owner**: The contract owner (governance root).
- **Rate Setter**: An address delegated to update the borrow interest rate parameter (initially the `owner`, but changeable).
- **Fee Setter**: An address delegated to update the delinquent fee parameter (initially the `owner`, but changeable).
- **Unencumbered Holdings**: An address holding unencumbered `esETH` used as the source of all loan payouts and the destination of all principal repayments.
- **Encumbered Holdings**: An address holding encumbered `esETH` (included in total backing for STRAT valuation).
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
  - `owner` can set `maxLTV` (default target: 90%)
  - `owner` can set `loanDuration` (default target: 6 months)
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
  - Each position stores an `interestRate` snapshot that is fixed for that term
  - Later governance changes to the global interest rate do **not** affect existing positions until they are rolled

**US-012: Position records delinquent fee parameter context**
- **As a** borrower
- **I want** any delinquent-fee rules to be clear for my position
- **So that** I understand the cost of repaying late (if late repayment is supported)
- **Acceptance Criteria:**
  - If late repayment is supported, the position records the delinquent fee terms that will apply (either a fixed amount or a formula reference)
  - If late repayment is not supported, the position explicitly treats expiry as “liquidatable immediately”

---

### Borrowing

**US-100: Borrow ETH using STRAT + CDT collateral (with debt-per-STRAT coverage)**
- **As a** borrower
- **I want to** deposit STRAT and CDT and borrow ETH against my covered collateral
- **So that** I can access ETH liquidity without selling STRAT
- **Acceptance Criteria:**
  - Borrower deposits STRAT and CDT as collateral.
  - The protocol determines how much of the STRAT collateral is actively backed by CDT (the "covered" portion) according to protocol rules.
  - Only this covered STRAT is used to calculate how much can be borrowed, and pulled from the user (with associated CDT)
  - The protocol values the collateral using the backing value for STRAT derived from holdings:
    - `totalHoldingsInETH = esETH.balanceOf(unencumberedHoldings) + esETH.balanceOf(encumberedHoldings)`
    - `stratBackingValue = totalHoldingsInETH * coveredStrat / STRAT.totalSupply()`
  - The maximum amount available to borrow is calculated as maxLTV of backing value, net of reserved amounts:
    - `maxBorrowBeforeInterest = stratBackingValue * maxLTV`
    - `borrowAmount` is computed such that `borrowAmount + maxTermInterest + delinquentFee = maxBorrowBeforeInterest`
  - An interest rate for the position is set when the loan is opened and does not change for that position.
  - Borrowing costs (interest for the full term) are subtracted upfront from the borrowable amount, but are charged linearly over the loan term
  - The user receives `esETH` when the loan is opened, transferred from `unencumberedHoldings`
  - A position NFT is minted that records all terms relevant to the position (collateral amounts, borrowed amount, rate, times, etc).

**US-101: Preview borrow outcome**
- **As a** borrower or integrator
- **I want to** preview how much I can borrow for a given STRAT/CDT deposit
- **So that** I can make informed decisions and build good UX
- **Acceptance Criteria:**
  - A view method exists to compute `coveredStrat`, `maxBorrowBeforeInterest`, `maxTermInterest`, and resulting `borrowAmount`
  - The preview uses the **current** global parameters (`maxLTV`, current borrow rate, current debt-per-STRAT)
  - The preview clearly indicates that the interest rate is snapshotted when the borrow actually executes

---

### Interest Accrual & Repayment

**US-200: Interest accrues proportionally over time (linear)**
- **As a** borrower
- **I want** interest to be charged proportionally to time elapsed
- **So that** repaying earlier is cheaper than repaying at expiry
- **Acceptance Criteria:**
  - Each position has a fixed `positionRate` and fixed `expiry`
  - Interest accrued at time \(t\) is:
    - `accruedInterest = principal * positionRate * (elapsed / 365 days)`
  - Accrued interest is capped at the full-term amount at expiry

**US-201: Repay at any time before expiry**
- **As a** position owner
- **I want to** repay my loan before expiry
- **So that** I can recover my STRAT and CDT collateral
- **Acceptance Criteria:**
  - Only the current position NFT owner can repay
  - Repayment is allowed when `block.timestamp < expiry`
  - Repay amount is:
    - `principal + accruedInterest`
  - On repay:
    - The position NFT is burned
    - The borrower receives back their deposited STRAT and CDT
    - Principal repayment is transferred to `unencumberedHoldings`
    - Interest is transferred to `interestRevenueRecipient` (see “Interest Distribution”)

### Rolling (Modify an existing position NFT)

**US-300: Roll a position (adjust STRAT/CDT and refresh the term)**
- **As a** position owner
- **I want to** roll my position in-place (same NFT) by adding/removing STRAT and adjusting CDT coverage
- **So that** I can maintain or resize exposure without closing and reopening a new NFT
- **Acceptance Criteria:**
  - Only the current position NFT owner can roll
  - Rolling updates the position as if:
    - accrued interest to date is settled, and
    - a new position is originated,
    - but the NFT identity is preserved
  - The user can:
    - add STRAT or withdraw STRAT (subject to maintaining required coverage rules)
    - add CDT if coverage is insufficient, or withdraw CDT if excess coverage exists
  - Rolling recomputes `coveredStrat` under the **current** `debtPerStrat` and current `maxLTV`
  - Rolling snapshots a new fixed `positionRate` for the rolled term
  - Rolling resets the expiry to `block.timestamp + loanDuration`

**US-301: Rolling adjusts the borrowed ETH balance (may require pay-in or may pay out)**
- **As a** position owner
- **I want** rolling to adjust my principal based on updated collateral and borrowing power
- **So that** I can increase borrow if I add collateral, or reduce principal if collateral requirements increased
- **Acceptance Criteria:**
  - After recomputation, the position has a new `principal'` derived from the same borrow calculation as origination
  - If `principal' > principal`, the protocol pays the difference to the user
  - If `principal' < principal`, the user must pay in the difference (in ETH or the protocol’s ETH-representation, e.g. `esETH`)
  - Rolling may result in net ETH sent to the user if collateral value increased enough (as you described)

**US-302: Rolling settles interest and routes it to stakers**
- **As a** STRAT staker
- **I want** interest paid during roll operations to be treated the same as repayment interest
- **So that** rolling does not bypass revenue distribution
- **Acceptance Criteria:**
  - Rolling computes and settles accrued interest up to the roll timestamp
  - Settled interest is accounted for as “distributable revenue” under the same mechanism as **US-600**

---

### Liquidation (Permissionless after expiry)

**US-400: Position is unliquidatable until expiry, then liquidatable by anyone**
- **As a** borrower
- **I want** my position to be safe from liquidation for the full term
- **So that** I can rely on a predictable 6-month window
- **Acceptance Criteria:**
  - Before expiry (`block.timestamp < expiry`), liquidation is not possible
  - At/after expiry (`block.timestamp >= expiry`), anyone can liquidate

**US-401: Liquidation burns the position NFT and associated collateral (no liquidation fee)**
- **As a** liquidator
- **I want to** liquidate expired positions in a simple, fee-free way
- **So that** the system can clean up overdue positions without complicated incentives
- **Acceptance Criteria:**
  - On liquidation:
    - the position NFT is burned
    - the associated STRAT and CDT collateral are burned/forfeited (protocol-defined handling; intent is that the user loses them)
  - No liquidation fee is charged to any party
  - The liquidator does not receive a fee or collateral payout (permissionless “cleanup”)

---

### Governance Parameters (Rate + Delinquent Fee)

**US-500: Rate setter updates the borrow interest rate parameter**
- **As a** rate setter (keeper/automation)
- **I want to** update the borrow interest rate parameter
- **So that** new borrows/rolls price risk appropriately
- **Acceptance Criteria:**
  - Only `rateSetter` can update the current borrow interest rate parameter
  - Updates only affect **new borrows** and **rolls** (existing positions keep their snapshotted rate)

**US-501: Fee setter updates the delinquent fee parameter**
- **As a** fee setter (keeper/automation)
- **I want to** update the delinquent fee parameter
- **So that** late repayment penalties can be tuned over time
- **Acceptance Criteria:**
  - Only `feeSetter` can update the delinquent fee parameter
  - If late repayment is enabled, the fee applies according to **US-202**

---

### Interest Distribution to STRAT Stakers (intent; implementation TBD)

**US-600: Interest revenue is routed to STRAT stakers**
- **As a** STRAT staker
- **I want** interest paid by TreasuryLend borrowers to accrue to STRAT stakers
- **So that** staking STRAT captures the protocol’s lending revenue
- **Acceptance Criteria:**
  - Interest paid on repay/roll is transferred to `interestRevenueRecipient` (in `esETH`)
  - The system provides a mechanism to deliver that revenue to stakers (method TBD), e.g.:
    - transfer/mint `esETH` to the staked-STRAT rewards pool, or
    - send ETH to a distributor that converts to `esETH` and funds staker rewards
  - The distribution mechanism is modular / upgradable at the governance layer (exact design TBD)

---

### Security & Safety (baseline expectations)

**US-700: Clear failure modes and input validation**
- **As a** user or integrator
- **I want** invalid actions to revert with explicit reasons
- **So that** I can debug and build reliable UX
- **Acceptance Criteria:**
  - Zero-amount deposits are rejected
  - Only position owner can repay/roll
  - Repay/roll/liquidate enforce expiry rules cleanly
  - Parameter setters enforce non-zero addresses and access control

