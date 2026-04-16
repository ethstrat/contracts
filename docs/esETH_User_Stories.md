# esETH User Stories

## User Stories

### Roles & Permissions

**US-000: Roles are explicit and owner-managed**
- **As a** protocol operator
- **I want** explicit roles for where privileged behavior occurs
- **So that** governance can tighten or expand permissions cleanly over time
- **Acceptance Criteria:**
  - `owner` can update token configs and role addresses
  - `yieldReceiver` is initialized to `owner` and is owner-settable
  - `treasuryManager` is initialized to `owner` and is owner-settable
  - `treasuryManager` can mint/redeem any **supported** token regardless of `isMintable/isRedeemable`
  - **Unsupported tokens never work for anyone** (users or `treasuryManager`)

### Minting esETH

**US-001: Mint esETH with LST**
- **As a** user holding liquid staking tokens (LST)
- **I want to** deposit my LST tokens (wstETH, rETH, weETH, or ERC20 tokens) to mint esETH
- **So that** I can get a unified token representing a basket of staked ETH positions
- **Acceptance Criteria:**
  - Token must be **supported** (`TokenType != UNSUPPORTED`)
  - Token must be **whitelisted for minting** (`isMintable == true`)
  - Amount must be greater than zero
  - Caller specifies a `receiver` address for the minted esETH
  - esETH amount minted is calculated based on ETH value of the deposited LST
  - `receiver` receives the minted esETH
  - Event is emitted with mint details

**US-001A: Mint esETH with raw ETH**
- **As a** user holding raw ETH
- **I want to** deposit ETH directly to mint esETH
- **So that** I can mint esETH without first manually wrapping to WETH
- **Acceptance Criteria:**
  - User calls `wrapAndMint(receiver)` with `msg.value > 0`
  - Contract wraps `msg.value` into the configured `WETH`
  - `WETH` must be **supported** and **whitelisted for minting** (`isMintable == true`) unless caller is `treasuryManager`
  - esETH minted is based on the ETH value of the wrapped `WETH` backing
  - `receiver` receives the minted esETH
  - Event is emitted with mint details

**US-002: Check ETH value before minting**
- **As a** user considering minting esETH
- **I want to** query the ETH value of my LST tokens before minting
- **So that** I can understand how much esETH I will receive
- **Acceptance Criteria:**
  - Can call `getETHValue(token, amount)` to get ETH equivalent
  - Reverts for unsupported tokens

### Redeeming esETH

**US-003: Redeem esETH for LST**
- **As a** user holding esETH tokens
- **I want to** redeem my esETH for any whitelisted LST token
- **So that** I can exit my position and receive the underlying LST of my choice
- **Acceptance Criteria:**
  - Token must be **supported** (`TokenType != UNSUPPORTED`)
  - Token must be **whitelisted for redemption** (`isRedeemable == true`)
  - Amount must be greater than zero
  - Caller specifies a `receiver` address for the redeemed LST
  - Contract must have sufficient balance of the requested LST
  - esETH is burned proportional to the ETH value of the redeemed LST
  - `receiver` receives the requested LST tokens
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
- **So that** yield generated from staked positions is captured and distributed to the yield receiver
- **Acceptance Criteria:**
  - Can call `harvestYield(tokens)` with array of token addresses
  - Calculates yield for each token (backing - `totalMinted`)
  - Mints yield esETH to yield receiver
  - Updates `totalMinted` for each token
  - Event is emitted when yield is harvested

**US-006: Burn excess esETH**
- **As a** ESEth holder (in practice protocol operators, but there is no strong reason to make this permissioned)
- **I want to** burn excess esETH when total supply exceeds backing
- **So that** the token maintains proper backing ratio and user confidence
- **Acceptance Criteria:**
  - Calculates excess for each token (`totalMinted` - backing)
  - Burns excess esETH from caller's balance
  - Updates `totalMinted` for each token
  - Event is emitted when excess is burned

### Token Management (Owner)

**US-007: Configure LST tokens**
- **As a** contract owner
- **I want to** configure which LST tokens can be used for minting and redemption
- **So that** I can control which tokens are supported and manage protocol risk
- **Acceptance Criteria:**
  - Can set token type (ERC20, WSTETH, RETH, WEETH)
  - Can enable/disable minting per token
  - Can enable/disable redemption per token
  - Preserves totalMinted value when updating config
  - Event is emitted on configuration change

**US-008: Set yield receiver**
- **As a** contract owner
- **I want to** set the address that receives harvested yield (minted esETH)
- **So that** I can direct protocol revenue to the appropriate treasury or distribution mechanism
- **Acceptance Criteria:**
  - Can update yield receiver address
  - Cannot set to zero address
  - Event is emitted on update

**US-009: Set treasury manager**
- **As a** contract owner
- **I want to** set the `treasuryManager`
- **So that** the protocol can delegate supported-token mint/redeem operations without granting full ownership
- **Acceptance Criteria:**
  - Can update treasury manager address
  - Cannot set to zero address
  - Event is emitted on update

### Token Features

**US-010: Non-rebasing token**
- **As a** user holding esETH
- **I want** esETH to be a non-rebasing token
- **So that** my token balance remains stable and predictable (unlike stETH which rebases)
- **Acceptance Criteria:**
  - Token balance does not change automatically
  - Yield is captured through harvest mechanism instead

**US-011: Unified LST representation**
- **As a** user
- **I want** esETH to represent a basket of different LST types
- **So that** I can have a single token that abstracts away the complexity of managing multiple LST positions
- **Acceptance Criteria:**
  - Can mint with multiple LST types
  - Can redeem for multiple LST types
  - All LSTs are converted to ETH value for consistency

**US-012: Treasury manager can mint/redeem supported tokens regardless of allowlist flags**
- **As a** protocol treasury operator (`treasuryManager`)
- **I want to** mint and redeem any supported token (configured with a non-`UNSUPPORTED` `TokenType`), regardless of `isMintable/isRedeemable`
- **So that** the treasury can operationally rebalance the backing without opening up public mint/redeem on those tokens
- **Acceptance Criteria:**
  - `treasuryManager` calling `mint()` does not require `isMintable == true`
  - `treasuryManager` calling `redeem()` does not require `isRedeemable == true`
  - Calls still revert for unsupported tokens
  - All normal balance and amount checks still apply (zero amount, sufficient backing for redeem, etc.)

### Security & Safety

**US-013: Reentrancy protection**
- **As a** user interacting with the contract
- **I want** mint/redeem functions to be protected against reentrancy attacks
- **So that** my transactions are secure and cannot be exploited
- **Acceptance Criteria:**
  - `nonReentrant` modifier on `mint`, `wrapAndMint`, and `redeem`
  - Uses ReentrancyGuard from OpenZeppelin

**US-014: Input validation**
- **As a** user or contract owner
- **I want** the contract to validate all inputs
- **So that** invalid transactions are rejected with clear errors
- **Acceptance Criteria:**
  - Zero amount checks
  - Zero address checks
  - Token supported-type validation (`UnsupportedToken`)
  - Token whitelist validation (`TokenNotWhitelistedForMint` / `TokenNotWhitelistedForRedeem`)
  - Sufficient balance checks
  - Clear error messages for each failure case

## Technical Notes

- The contract implements ERC20 standard for token functionality
- Uses OpenZeppelin's Ownable2Step for secure ownership management
- Supports multiple LST types with different conversion mechanisms:
  - ERC20: 1:1 (e.g. WETH — no exchange rate applied)
  - wstETH: Uses Lido `getStETHByWstETH(uint256)` (stETH amount for a given wstETH amount; avoids double truncation from `amount * stEthPerToken / 1e18`)
  - rETH: Uses Rocket Pool `getEthValue(uint256)` (ETH value for a given rETH amount; avoids double truncation from `amount * getExchangeRate / 1e18`)
  - weETH (ether.fi): Uses `getEETHByWeETH(uint256)`
- Redemption rounds up esETH burned by +1 wei to prevent rounding exploits; `totalMinted` only tracks the base value (without the rounding protection wei)
- Yield is harvested periodically rather than continuously rebasing

