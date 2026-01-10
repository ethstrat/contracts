# ESPN (ETH Strategy Perpetual Note) User Stories

## User Stories

### Depositing Assets

**US-001: Deposit assets to mint ESPN shares**
- **As a** user holding USDS
- **I want to** deposit my assets into the ESPN vault to receive ESPN shares
- **So that** I can earn yield
- **Acceptance Criteria:**
  - Deposit must not exceed the deposit cap
  - Assets are transferred to the manager for deployment
  - ESPN shares are minted based on ERC4626 conversion rates
  - Total assets tracked by the contract increases
  - Event is emitted with deposit details

**US-002: Check maximum deposit amount**
- **As a** user considering depositing assets
- **I want to** query the maximum amount I can deposit
- **So that** I know if my deposit will be accepted
- **Acceptance Criteria:**
  - Can call `maxDeposit(address)` to get maximum depositable amount
  - Returns 0 if deposit cap is reached
  - Returns remaining capacity if under cap

**US-003: Preview deposit shares**
- **As a** user planning to deposit
- **I want to** preview how many ESPN shares I will receive for a given asset amount
- **So that** I can make an informed decision about my deposit
- **Acceptance Criteria:**
  - Can use `previewDeposit(assets)` to see shares that will be minted
  - Uses ERC4626 standard conversion logic

### Withdrawing Assets

**US-004: Withdraw assets by redeeming ESPN shares**
- **As a** user holding ESPN shares
- **I want to** redeem my ESPN shares for underlying assets
- **So that** I can exit my position and receive my assets back
- **Acceptance Criteria:**
  - Withdrawals must be enabled (not disabled)
  - Can only withdraw up to available contract balance
  - ESPN shares are burned proportional to assets withdrawn
  - Total assets tracked decreases
  - Assets are transferred to the user
  - Event is emitted with withdrawal details

**US-005: Check maximum withdrawal amount**
- **As a** user considering withdrawing
- **I want to** query the maximum amount I can withdraw
- **So that** I know my withdrawal limits
- **Acceptance Criteria:**
  - Returns 0 if withdrawals are disabled
  - Returns minimum of user's share value and contract balance
  - Can call `maxWithdraw(address)` to get maximum withdrawable amount

**US-006: Check maximum redeemable shares**
- **As a** user holding ESPN shares
- **I want to** query how many shares I can redeem
- **So that** I know my redemption limits
- **Acceptance Criteria:**
  - Returns 0 if withdrawals are disabled
  - Returns minimum of user's share balance and shares redeemable for contract balance
  - Can call `maxRedeem(address)` to get maximum redeemable shares

**US-007: Preview withdrawal assets**
- **As a** user planning to withdraw
- **I want to** preview how many assets I will receive for a given share amount
- **So that** I can make an informed decision about my withdrawal
- **Acceptance Criteria:**
  - Can use `previewRedeem(shares)` to see assets that will be received
  - Uses ERC4626 standard conversion logic

### Burning Shares

**US-008: Burn ESPN shares**
- **As a** protocol or contract holding ESPN
- **I want to** burn ESPN shares I hold
- **So that** I can reduce total supply (e.g., to boost yield for external holders)
- **Acceptance Criteria:**
  - Can only burn shares from own balance
  - Total supply decreases
  - Event is emitted with burn details

### Yield Management

**US-009: Increase assets per share**
- **As a** protocol or authorized party
- **I want to** deposit additional assets to increase the assets per share ratio
- **So that** I can boost the value of ESPN shares and distribute yield to holders
- **Acceptance Criteria:**
  - Assets are transferred from caller to contract
  - Assets are then transferred to manager
  - Total assets tracked increases
  - Assets per share ratio increases
  - Event is emitted with the increase details

### Vault Management (Owner)

**US-010: Set manager address**
- **As a** contract owner
- **I want to** set the manager address that receives deposited assets
- **So that** I can control where assets are deployed for yield generation
- **Acceptance Criteria:**
  - Can update manager address
  - Cannot set to zero address
  - Event is emitted on update

**US-011: Enable or disable withdrawals**
- **As a** contract owner
- **I want to** enable or disable withdrawals from the vault
- **So that** I can control exit liquidity and manage protocol risk
- **Acceptance Criteria:**
  - Can toggle withdrawals on/off
  - When disabled, maxWithdraw and maxRedeem return 0
  - When disabled, withdrawal attempts revert
  - Event is emitted on state change

**US-012: Set deposit cap**
- **As a** contract owner
- **I want to** set a maximum total assets that can be deposited
- **So that** I can limit protocol size and manage risk
- **Acceptance Criteria:**
  - Can set deposit cap (uint256 max = no cap)
  - Deposits exceeding cap are rejected
  - Event is emitted on cap update

### Token Features

**US-013: ERC4626 standard compliance**
- **As a** user or integrator
- **I want** ESPN to be fully ERC4626 compliant
- **So that** it works with standard DeFi protocols and tools
- **Acceptance Criteria:**
  - Implements all ERC4626 interface functions
  - Follows ERC4626 conversion standards
  - Compatible with ERC4626 tooling and integrations

**US-014: Perpetual note structure**
- **As a** user
- **I want** ESPN to function as a perpetual note (preferred stock-like)
- **So that** I have a flexible investment vehicle that allows strategy changes
- **Acceptance Criteria:**
  - Manager can be changed by owner
  - Strategy flexibility through manager updates
  - No fixed maturity date

### Security & Safety

**US-015: Reentrancy protection**
- **As a** user interacting with the contract
- **I want** withdrawal functions to be protected against reentrancy attacks
- **So that** my transactions are secure and cannot be exploited
- **Acceptance Criteria:**
  - `nonReentrant` modifier on withdrawal functions
  - Uses ReentrancyGuard from OpenZeppelin

**US-016: Input validation**
- **As a** user or contract owner
- **I want** the contract to validate all inputs
- **So that** invalid transactions are rejected with clear errors
- **Acceptance Criteria:**
  - Zero address checks for manager
  - Deposit cap validation
  - Withdrawal state validation
  - Clear error messages for each failure case

**US-017: Asset tracking**
- **As a** user or protocol
- **I want** the contract to accurately track total assets
- **So that** share conversions are correct and transparent
- **Acceptance Criteria:**
  - Total assets updated on deposit
  - Total assets updated on withdrawal
  - Total assets updated on yield increases
  - `totalAssets()` returns accurate value

## Technical Notes

- The contract implements ERC4626 standard for vault functionality
- Uses OpenZeppelin's Ownable2Step for secure ownership management
- Assets deposited are immediately transferred to the manager for deployment
- Withdrawals are disabled by default and can be enabled by owner
- Deposit cap can be set to limit total protocol size (uint256 max = unlimited)
- Manager receives all deposited assets for yield generation
- Total assets are explicitly tracked separate from contract balance
- Shares represent proportional ownership of total assets
- Yield is distributed by increasing total assets (via `increaseAssetsPerShare`)
