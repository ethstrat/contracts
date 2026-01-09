# esETH User Stories

## User Stories

### Minting esETH

**US-001: Mint esETH with LST**
- **As a** user holding liquid staking tokens (LST)
- **I want to** deposit my LST tokens (wstETH, rETH, cETH, aETHv2, ankrETH, cbETH, or ERC4626 tokens) to mint esETH
- **So that** I can get a unified token representing a basket of staked ETH positions
- **Acceptance Criteria:**
  - Token must be whitelisted for minting
  - Amount must be greater than zero
  - esETH amount minted is calculated based on ETH value of the deposited LST
  - User receives esETH tokens in their wallet
  - Event is emitted with mint details

**US-002: Check ETH value before minting**
- **As a** user considering minting esETH
- **I want to** query the ETH value of my LST tokens before minting
- **So that** I can understand how much esETH I will receive
- **Acceptance Criteria:**
  - Can call `getETHValue(token, amount)` to get ETH equivalent
  - Works for all supported token types

### Redeeming esETH

**US-003: Redeem esETH for LST**
- **As a** user holding esETH tokens
- **I want to** redeem my esETH for any whitelisted LST token
- **So that** I can exit my position and receive the underlying LST of my choice
- **Acceptance Criteria:**
  - Token must be whitelisted for redemption
  - Amount must be greater than zero
  - Contract must have sufficient balance of the requested LST
  - esETH is burned proportional to the ETH value of the redeemed LST
  - User receives the requested LST tokens
  - Event is emitted with redemption details

**US-004: Choose redemption token**
- **As a** user redeeming esETH
- **I want to** choose which LST token I receive (wstETH, rETH, cETH, etc.)
- **So that** I can select the LST that best fits my needs or preferences
- **Acceptance Criteria:**
  - Can specify any whitelisted redeemable token
  - Receives the exact token type requested

### Yield Harvesting

**US-005: Harvest yield as protocol**
- **As a** protocol operator or authorized party
- **I want to** mint additional esETH when the total backing exceeds total supply
- **So that** yield generated from staked positions is captured and distributed to the harvest receiver
- **Acceptance Criteria:**
  - Can call `mintDeficit(tokens)` with array of token addresses
  - Calculates deficit for each token (backing - totalMinted)
  - Mints deficit esETH to harvest receiver
  - Updates totalMinted for each token
  - Event is emitted when deficit is minted

**US-006: Burn surplus esETH**
- **As a** ESEth holder (in practice protocol operators, but there is no strong reason to make this permissioned)
- **I want to** burn surplus esETH when total supply exceeds backing
- **So that** the token maintains proper backing ratio and user confidence
- **Acceptance Criteria:**
  - Calculates surplus for each token (totalMinted - backing)
  - Burns surplus esETH from caller's balance
  - Updates totalMinted for each token
  - Event is emitted when surplus is burned

### Token Management (Owner)

**US-007: Configure LST tokens**
- **As a** contract owner
- **I want to** configure which LST tokens can be used for minting and redemption
- **So that** I can control which tokens are supported and manage protocol risk
- **Acceptance Criteria:**
  - Can set token type (ERC4626, WSTETH, RETH, CETH, AETHV2, ANKRETH, CBETH, ERC20)
  - Can enable/disable minting per token
  - Can enable/disable redemption per token
  - Preserves totalMinted value when updating config
  - Event is emitted on configuration change

**US-008: Set harvest receiver**
- **As a** contract owner
- **I want to** set the address that receives harvested yield (minted esETH)
- **So that** I can direct protocol revenue to the appropriate treasury or distribution mechanism
- **Acceptance Criteria:**
  - Can update harvest receiver address
  - Cannot set to zero address
  - Event is emitted on update

### Token Features

**US-009: Non-rebasing token**
- **As a** user holding esETH
- **I want** esETH to be a non-rebasing token
- **So that** my token balance remains stable and predictable (unlike stETH which rebases)
- **Acceptance Criteria:**
  - Token balance does not change automatically
  - Yield is captured through harvest mechanism instead

**US-010: Unified LST representation**
- **As a** user
- **I want** esETH to represent a basket of different LST types
- **So that** I can have a single token that abstracts away the complexity of managing multiple LST positions
- **Acceptance Criteria:**
  - Can mint with multiple LST types
  - Can redeem for multiple LST types
  - All LSTs are converted to ETH value for consistency

### Security & Safety

**US-011: Reentrancy protection**
- **As a** user interacting with the contract
- **I want** mint and redeem functions to be protected against reentrancy attacks
- **So that** my transactions are secure and cannot be exploited
- **Acceptance Criteria:**
  - `nonReentrant` modifier on mint and redeem functions
  - Uses ReentrancyGuard from OpenZeppelin

**US-012: Input validation**
- **As a** user or contract owner
- **I want** the contract to validate all inputs
- **So that** invalid transactions are rejected with clear errors
- **Acceptance Criteria:**
  - Zero amount checks
  - Zero address checks
  - Token whitelist validation
  - Sufficient balance checks
  - Clear error messages for each failure case

## Technical Notes

- The contract implements ERC20 standard for token functionality
- Uses OpenZeppelin's Ownable2Step for secure ownership management
- Supports multiple LST types with different conversion mechanisms:
  - ERC4626: Uses `convertToAssets()` standard
  - wstETH: Uses `stEthPerToken()`
  - rETH: Uses `getExchangeRate()`
  - cETH: Uses `exchangeRateStored()`
  - aETHv2: Uses scaled balance calculation
  - ankrETH: Uses `ratio()`
  - cbETH: Uses `exchangeRate()`
- Yield is harvested periodically rather than continuously rebasing

