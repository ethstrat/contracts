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
  - Redemption data is recorded (redemptionsBefore, redemptionAmount)
  - `totalQueued` increases (always growing, never decreases)
  - Event is emitted with queue details

**US-002: Check redemption eligibility**
- **As a** user holding a redemption queue NFT
- **I want to** check if my NFT is eligible for redemption
- **So that** I know when I can redeem for USDS
- **Acceptance Criteria:**
  - Can call `isEligibleForRedemption(tokenId)` to check status
  - Returns eligibility boolean and available position
  - Eligibility based on: redemptionsBefore < (totalRedemptionsProcessed + totalCancellationsProcessed + USDS balance)
  - For active NFTs: must have sufficient USDS balance in contract
  - For cancelled NFTs: eligible when reaching head of queue (no USDS needed)
  - NFT must not be already redeemed

**US-003: View redemption data**
- **As a** user holding a redemption queue NFT
- **I want to** view the redemption data for my NFT
- **So that** I can understand my position in the queue
- **Acceptance Criteria:**
  - Can call `getRedemptionData(tokenId)` to view all redemption info
  - Returns redemptionsBefore, redemptionAmount, redeemed status, cancelled status
  - Public mapping allows direct access to redemption data

### Fulfilling Redemptions

**US-004: Redeem active NFT for USDS**
- **As a** user holding an eligible redemption queue NFT
- **I want to** redeem my NFT for USDS
- **So that** I can exit my ESPN position and receive the underlying asset
- **Acceptance Criteria:**
  - Function accepts a single tokenId
  - Must be the owner of the NFT
  - NFT must be eligible for redemption
  - NFT must not be already redeemed
  - NFT must not be cancelled (use `processCancelledRedemptions()` for cancelled NFTs)
  - Contract must have sufficient USDS balance
  - USDS is transferred to the user
  - `totalRedemptionsProcessed` increases
  - NFT is burned after redemption
  - Event is emitted with redemption details

**US-004b: Process cancelled NFTs (permissionless)**
- **As a** anyone (user, protocol, or third party)
- **I want to** process cancelled NFTs to advance the queue
- **So that** active redemptions behind cancelled NFTs can be fulfilled with less USDS
- **Acceptance Criteria:**
  - Function accepts an array of cancelled tokenIds
  - Permissionless - anyone can call this function
  - Each NFT must be cancelled (not active)
  - Each NFT must be eligible for processing
  - NFT must not be already processed
  - No USDS transfer (ESPN already returned via cancellation)
  - `totalCancellationsProcessed` increases for each NFT
  - NFTs are burned after processing
  - Event is emitted with processing details
  - Improves capital efficiency by allowing active redemptions to be fulfilled sooner

**US-005: Understand queue position**
- **As a** user in the redemption queue
- **I want to** understand my position relative to other redemptions
- **So that** I can estimate when my redemption will be fulfilled
- **Acceptance Criteria:**
  - `redemptionsBefore` shows cumulative dollar value of prior redemptions at mint time
  - Eligibility depends on: redemptionsBefore < (totalRedemptionsProcessed + totalCancellationsProcessed + USDS balance)
  - First-in-first-out (FIFO) queue based on redemptionsBefore value
  - Cancelled NFTs stay in queue and are processed naturally when they reach the head

### Cancelling Redemptions

**US-006: Cancel a redemption**
- **As a** user holding a redemption queue NFT
- **I want to** cancel my redemption and get my ESPN back
- **So that** I can exit the queue if I change my mind
- **Acceptance Criteria:**
  - Must be the owner of the NFT
  - NFT must not be already redeemed or cancelled
  - ESPN tokens are returned to the user (equivalent amount to what was burned)
  - NFT is marked as cancelled but stays in queue (not burned immediately)
  - `totalQueued` remains unchanged (always growing)
  - Queue ordering maintained without loops:
      - NFTs with lower tokenIDs are not affected
      - Cancelled NFTs naturally advance when processed via `redeem()` 
      - No need to update `redemptionsBefore` for other NFTs
  - Cancelled NFT will be processed via `redeem()` when it reaches the head of the queue (no USDS transfer)

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
  - Can query `totalQueued` (cumulative dollar value queued, always growing)
  - Can query `totalRedemptionsProcessed` (cumulative dollar value fulfilled, always growing)
  - Can query `totalCancellationsProcessed` (cumulative dollar value cancelled, always growing)
  - Invariant: `totalRedemptionsProcessed + totalCancellationsProcessed <= totalQueued`
  - Can calculate pending redemptions value: `totalQueued - totalRedemptionsProcessed - totalCancellationsProcessed`

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
  - `nonReentrant` modifier on queueRedemption, redeem, processCancelledRedemptions, and cancelRedemption
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


**US-016: Queue ordering integrity**
- **As a** user in the redemption queue
- **I want** the queue to maintain proper ordering
- **So that** redemptions are processed fairly in order
- **Acceptance Criteria:**
  - `redemptionsBefore` captures cumulative value at mint time (never updated)
  - Eligibility check ensures FIFO processing: `redemptionsBefore < (totalRedemptionsProcessed + totalCancellationsProcessed + USDS balance)`
  - `totalRedemptionsProcessed` tracks fulfilled active redemptions
  - `totalCancellationsProcessed` tracks processed cancelled redemptions
  - Cannot redeem out of order
  - Cancelled NFTs processed naturally when reaching head of queue

## Technical Notes

- The contract implements ERC721 standard for NFT functionality
- Uses OpenZeppelin's Ownable2Step for secure ownership management
- ESPN tokens are burned (not held) when queuing a redemption
- Dollar backing is calculated using ERC4626 `previewRedeem()` function
- Queue position is determined by cumulative dollar value (`redemptionsBefore`) at mint time
- Eligibility requires: `redemptionsBefore < (totalRedemptionsProcessed + totalCancellationsProcessed + USDS balance)`
- State variables (all always growing, never decreasing):
  - `totalQueued`: Cumulative dollar value of all redemptions queued
  - `totalRedemptionsProcessed`: Cumulative dollar value of fulfilled active redemptions
  - `totalCancellationsProcessed`: Cumulative dollar value of processed cancelled redemptions
  - Invariant: `totalRedemptionsProcessed + totalCancellationsProcessed <= totalQueued`
- `redeem()` function accepts a single tokenId for active (non-cancelled) redemptions
- `processCancelledRedemptions()` function accepts an array of cancelled tokenIds and is permissionless
- Cancelled NFTs stay in queue and are processed via `processCancelledRedemptions()` when they reach the head
- Processing cancelled NFTs improves capital efficiency by reducing USDS requirements for active redemptions
- Queue ordering maintained without loops - cancelled NFTs naturally advance when processed
- Sweeper address is immutable and set at construction
- NFT is burned after redemption/processing, not immediately on cancellation

### Cancellation Implementation Details

When a user cancels their redemption, they need to receive ESPN tokens back. However, since ESPN tokens were burned when queuing the redemption (not held by the contract), the contract must remint ESPN to return it to the user.

ESPN's implementation does not allow direct minting. Instead, ESPN tokens are minted by depositing USDS into the ESPN contract (via the ERC4626 `deposit()` function). To cancel a redemption:

1. The contract temporarily borrows USDS via a flash loan (using Sky protocol for USDS flash loans)
2. The flashed USDS is deposited into ESPN, which mints ESPN shares
3. The minted ESPN is transferred to the user
4. The flash loan is repaid using USDS received from ESPN (when ESPN's manager is set to this contract, ESPN sends the deposited USDS to the manager during the deposit process)

This flash loan mechanism is an implementation detail required by ESPN's architecture - there is no other way to remint ESPN after it has been burned, since ESPN only mints through deposits. The contract uses Sky flash loans specifically for USDS, which typically charge zero fees and have sufficient liquidity.

**Security considerations:**
- Flash loan callback verifies the initiator is the authorized Sky flash loan contract
- Redemption is marked as cancelled before initiating the flash loan to prevent reentrancy
- Temporary storage is cleared after the flash loan completes
- The contract verifies sufficient USDS balance for repayment before completing the operation
- ESPN manager must be set to this contract for cancellation to work properly

### Capital Efficiency: Processing Cancelled NFTs

When redemptions are cancelled, the NFTs remain in the queue but don't require USDS to process (the ESPN was already returned to the user). However, until these cancelled NFTs are processed, they block active redemptions behind them from being fulfilled efficiently.

**Example:**
- NFT #1: redemptionsBefore = 0, amount = 100 USDS (CANCELLED)
- NFT #2: redemptionsBefore = 100, amount = 50 USDS (ACTIVE - yours)

Without processing NFT #1, you need 101+ USDS in the contract to redeem NFT #2. But if NFT #1 is processed first (burning the NFT and incrementing `totalCancellationsProcessed`), you only need 50 USDS.

The `processCancelledRedemptions()` function is **permissionless**, allowing anyone to process cancelled NFTs to improve capital efficiency. This creates an economic incentive: users with active redemptions can process cancelled NFTs ahead of them to enable their own redemptions with less USDS in the contract.
