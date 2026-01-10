# ESPN Redemption Queue User Stories

## User Stories

### Queueing Redemptions

**US-001: Queue a redemption by burning ESPN**
- **As a** user holding ESPN tokens
- **I want to** burn my ESPN tokens to mint an NFT representing my position in the redemption queue
- **So that** I can redeem my ESPN for USDS when my position becomes eligible
- **Acceptance Criteria:**
  - Must approve ESPN tokens to the contract first
  - ESPN amount must be greater than zero
  - ESPN tokens are burned (not just transferred)
  - NFT is minted to the user
  - Redemption data is recorded (redemptionsBefore, dollarBacking)
  - Total redemptions counter increments
  - Total redemptions value increases
  - Event is emitted with queue details

**US-002: Check redemption eligibility**
- **As a** user holding a redemption queue NFT
- **I want to** check if my NFT is eligible for redemption
- **So that** I know when I can redeem for USDS
- **Acceptance Criteria:**
  - Can call `isEligibleForRedemption(tokenId)` to check status
  - Returns eligibility boolean and available USDS amount
  - Eligibility based on: redemptionsBefore < (totalProcessedRedemptions + USDS balance)
  - Must have sufficient USDS balance in contract
  - NFT must not be already redeemed or cancelled

**US-003: View redemption data**
- **As a** user holding a redemption queue NFT
- **I want to** view the redemption data for my NFT
- **So that** I can understand my position in the queue
- **Acceptance Criteria:**
  - Can call `getRedemptionData(tokenId)` to view all redemption info
  - Returns redemptionsBefore, dollarBacking, redeemed status, cancelled status
  - Public mapping allows direct access to redemption data

### Fulfilling Redemptions

**US-004: Redeem NFT for USDS**
- **As a** user holding an eligible redemption queue NFT
- **I want to** redeem my NFT for USDS
- **So that** I can exit my ESPN position and receive the underlying asset
- **Acceptance Criteria:**
  - Must be the owner of the NFT
  - NFT must be eligible for redemption
  - NFT must not be already redeemed or cancelled
  - Contract must have sufficient USDS balance
  - USDS is transferred to the user
  - NFT is burned after redemption
  - Total processed redemptions increases
  - Event is emitted with redemption details

**US-005: Understand queue position**
- **As a** user in the redemption queue
- **I want to** understand my position relative to other redemptions
- **So that** I can estimate when my redemption will be fulfilled
- **Acceptance Criteria:**
  - `redemptionsBefore` shows cumulative dollar value of prior redemptions
  - Eligibility depends on available USDS vs redemptionsBefore
  - First-in-first-out (FIFO) queue based on redemptionsBefore value

### Cancelling Redemptions

**US-006: Cancel a redemption**
- **As a** user holding a redemption queue NFT
- **I want to** cancel my redemption and get my ESPN back
- **So that** I can exit the queue if I change my mind
- **Acceptance Criteria:**
  - Must be the owner of the NFT
  - NFT must not be already redeemed or cancelled
  - Uses flash loan to get USDS temporarily
  - Deposits USDS into ESPN to mint new ESPN shares
  - Returns minted ESPN to the user
  - Repays flash loan by pulling USDS from a well known address (redemption queue will have an approval to pull USDS from this address)
  - NFT is burned after cancellation
  - internal stake needs to be updated such that
      - any NFTs with a lower tokenID are not effected (as in, will be redeemed in order as expected)
      - any NFTs with a higher tokenID are now 'bumped up' the queue by the notional de-queued

### NFT Features

**US-009: Transfer redemption queue NFT**
- **As a** user holding a redemption queue NFT
- **I want to** transfer my NFT to another address
- **So that** I can sell or gift my queue position
- **Acceptance Criteria:**
  - Standard ERC721 transfer functionality
  - Only owner can transfer
  - New owner can redeem or cancel the redemption
  - NFT metadata includes queue position information

**US-010: View NFT collection**
- **As a** user or integrator
- **I want to** view all redemption queue NFTs
- **So that** I can track queue positions and activity
- **Acceptance Criteria:**
  - Standard ERC721 enumeration
  - Can query total supply
  - Can query owner of specific token ID
  - Can iterate through tokens

### Queue Management

**US-011: View queue statistics**
- **As a** user or protocol observer
- **I want to** view overall queue statistics
- **So that** I can understand queue health and activity
- **Acceptance Criteria:**
  - Can query `totalRedemptionsValue` (cumulative dollar value queued)
  - Can query `totalProcessedRedemptions` (cumulative dollar value fulfilled)
  - Can calculate pending redemptions value

### Protocol Management (Owner)

**US-012: Sweep USDS from contract**
- **As a** contract owner
- **I want to** sweep excess USDS from the redemption queue contract
- **So that** I can manage protocol funds and ensure proper operation
- **Acceptance Criteria:**
  - Only owner can call `sweepUSDS()`
  - Transfers all USDS balance to sweeper address
  - Event is emitted with sweep details
  - Sweeper address is set at construction and immutable

### Security & Safety

**US-013: Reentrancy protection**
- **As a** user interacting with the contract
- **I want** all state-changing functions to be protected against reentrancy attacks
- **So that** my transactions are secure and cannot be exploited
- **Acceptance Criteria:**
  - `nonReentrant` modifier on queueRedemption, redeem, and cancelRedemption
  - Uses ReentrancyGuard from OpenZeppelin
  - Flash loan callback uses temporary storage pattern

**US-014: Input validation**
- **As a** user or contract owner
- **I want** the contract to validate all inputs
- **So that** invalid transactions are rejected with clear errors
- **Acceptance Criteria:**
  - Zero amount checks
  - Zero address checks (sweeper)
  - Owner validation for NFT operations
  - Eligibility checks before redemption
  - Sufficient balance checks
  - Clear error messages for each failure case

**US-015: Flash loan security**
- **As a** user cancelling a redemption
- **I want** the flash loan mechanism to be secure
- **So that** my cancellation cannot be exploited or fail unexpectedly
- **Acceptance Criteria:**
  - Flash loan callback verifies initiator is contract
  - Redemption marked as cancelled before flash loan
  - Temporary storage cleared after use
  - Verifies sufficient USDS for repayment
  - ESPN manager must be set correctly

**US-016: Queue ordering integrity**
- **As a** user in the redemption queue
- **I want** the queue to maintain proper ordering
- **So that** redemptions are processed fairly in order
- **Acceptance Criteria:**
  - redemptionsBefore captures cumulative value at mint time
  - Eligibility check ensures FIFO processing
  - Total processed redemptions tracks fulfilled redemptions
  - Cannot redeem out of order

## Technical Notes

- The contract implements ERC721 standard for NFT functionality
- Uses OpenZeppelin's Ownable2Step for secure ownership management
- ESPN tokens are burned (not held) when queuing a redemption
- Dollar backing is calculated using ERC4626 `previewRedeem()` function
- Queue position is determined by cumulative dollar value (redemptionsBefore)
- Eligibility requires: redemptionsBefore < (totalProcessedRedemptions + USDS balance)
- Flash loan cancellation requires ESPN manager to be set to redemption queue contract
- Sweeper address is immutable and set at construction
- Supports Aave V3 flash loan interface for cancellations
- NFT is burned after redemption or cancellation
- Total redemptions tracks count, totalRedemptionsValue tracks cumulative dollar value
