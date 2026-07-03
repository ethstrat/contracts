# Staked STRAT (sSTRAT-v2) User Stories

## User Stories

### Staking STRAT

**US-001: Stake STRAT to receive sSTRAT-v2**
- **As a** user holding STRAT
- **I want to** stake STRAT into the StakedStrat contract
- **So that** I can earn yield (in the reward token, e.g. esETH) proportional to my stake
- **Acceptance Criteria:**
  - Must have approved STRAT spending to the contract
  - Stake amount must be greater than zero (otherwise reverts with `ZeroAmount`)
  - STRAT is transferred from the user to the contract
  - User's `staked[user]` and `totalStaked` increase by `amount`
  - `amount` of `sSTRAT-v2` is minted to the user
  - Rewards are synced (`syncRewards()`) before state changes
  - Rewards accounting is updated so the user keeps any previously accrued rewards; new stake is anchored to the current `rewardsPerShare` so it only earns future drips
  - Event `Staked(user, amount)` is emitted

### Unstaking STRAT

**US-002: Unstake STRAT and burn sSTRAT-v2**
- **As a** staker
- **I want to** unstake some of my STRAT
- **So that** I can reduce or exit my position
- **Acceptance Criteria:**
  - Unstake amount must be greater than zero (otherwise reverts with `ZeroAmount`)
  - User must have at least `amount` staked (otherwise reverts with `InsufficientStake`)
  - Rewards are synced before state changes (`syncRewards()` is called)
  - **Pending rewards are automatically claimed** before modifying stake, so no accrued rewards are lost
  - User's `staked[user]` and `totalStaked` decrease by `amount`
  - `amount` of `sSTRAT-v2` is burned from the user
  - `amount` of STRAT is transferred back to the user
  - Event `Unstaked(user, amount)` is emitted
  - If rewards were claimed, `RewardsClaimed(user, amount)` is also emitted

### Claiming Rewards

**US-003: Claim accrued rewards (reward token, e.g. esETH)**
- **As a** staker
- **I want to** claim my pending rewards
- **So that** I can realize yield without changing my staked STRAT amount
- **Acceptance Criteria:**
  - Rewards are synced before claim calculation (`syncRewards()` is called)
  - Claimable rewards are calculated from `rewardsPerShare`, `staked[user]`, and `rewardDebt[user]`
  - If claimable is 0, the function returns without transferring reward tokens
  - If claimable is > 0:
    - `rewardDebt[user]` is updated so rewards cannot be double-claimed
    - `totalClaimed` is increased by the claimed amount
    - Reward tokens are transferred to the user
    - Event `RewardsClaimed(user, amount)` is emitted

**US-004: View pending rewards without state changes**
- **As a** user or integrator
- **I want to** query my pending rewards
- **So that** I can display expected yield and decide when to claim
- **Acceptance Criteria:**
  - Can call `getPendingRewards(user)` as a `view`
  - If the user has no stake, returns 0
  - The calculation projects the current reward stream drip forward to the current block timestamp (using `rewardRate` and time elapsed) without requiring a state update
  - Note: this only accounts for rewards already streaming; newly arrived reward tokens that haven't been synced yet are not included until `syncRewards()` is called

### Reward Streaming & Synchronization (Permissionless)

**US-005: Fund rewards by sending reward tokens to the contract**
- **As a** protocol operator or yield source
- **I want to** send reward tokens (e.g. esETH) to the StakedStrat contract
- **So that** stakers can accrue rewards
- **Acceptance Criteria:**
  - Reward tokens can be transferred to the contract
  - Reward tokens received are not automatically distributed; they begin streaming only after `syncRewards()` is called (directly or indirectly via stake/unstake/claim/migration)
  - Once synced, new rewards are distributed linearly over a `REWARD_DURATION` (7-day) streaming period, preventing frontrunning attacks

**US-006: Distribute yield fairly by stake amount and time**
- **As a** staker
- **I want** yield payouts to be proportional to how much I stake and how long I've been staked
- **So that** earlier stakers receive their share of yield accrued to date, and new stakers only receive yield emitted after they join
- **Acceptance Criteria:**
  - Rewards are accounted for using a cumulative "rewards per staked token" accumulator (`rewardsPerShare`)
  - When streaming rewards drip over time, `rewardsPerShare` increases for the whole pool pro-rata to stake size
  - A staker's claimable rewards are based on the change in `rewardsPerShare` since their last accounting update
  - When a user stakes, their accounting baseline is updated to the current `rewardsPerShare` so they do not receive previously accrued yield
  - When a user unstakes, claims, or migrates, their accounting is updated so previously accrued yield is preserved and cannot be double-counted
  - The 7-day linear drip prevents frontrunning: an attacker who stakes just before rewards arrive and exits immediately captures nothing; they must hold for the full period to earn a proportional share

**US-007: Sync incoming reward tokens into a linear reward stream**
- **As a** staker, keeper, or integrator
- **I want to** sync the contract's reward token balance into the streaming reward system
- **So that** rewards are properly attributed before stake/unstake/claim/migration actions
- **Acceptance Criteria:**
  - Anyone can call `syncRewards()`
  - The function first ticks `rewardsPerShare` forward based on elapsed time and the current `rewardRate`
  - It then detects new reward tokens: `newRewards = (currentBalance + totalClaimed) - totalNotifiedRewards`
  - If no new rewards, it returns without further state changes
  - If new rewards have arrived:
    - `totalNotifiedRewards` increases by `newRewards`
    - The new rewards are blended with any remaining undistributed tokens from the active stream
    - A new `rewardRate` and `periodFinish` are calculated using a value-weighted average duration:
      - `newDuration = (remaining * remainingTime + newRewards * REWARD_DURATION) / (remaining + newRewards)`
      - When remaining >> newRewards: `newDuration ≈ remainingTime` (dust attacks negligible)
      - When newRewards >> remaining: `newDuration ≈ REWARD_DURATION` (fresh batch gets full 7-day window)
    - `rewardRate = (remaining + newRewards) / newDuration`
    - `periodFinish = block.timestamp + newDuration`
  - Event `RewardsSynced(rewardRate, newRewards, periodFinish)` is emitted

### Stake Migration (Address Change)

**US-009: Migrate my stake (and proportional unclaimed rewards) to a new address**
- **As a** staker rotating wallets
- **I want to** move some or all of my stake and unclaimed rewards to a new address
- **So that** I can change custody without unstaking
- **Acceptance Criteria:**
  - `to` must be non-zero, must not equal the caller, and must not be the contract address
  - Caller must have a non-zero stake (otherwise reverts with `InsufficientStake`)
  - Rewards are synced before state changes (`syncRewards()` is called)
  - If `amount == 0`, migrates the caller's full staked balance; otherwise migrates the requested amount
  - Migrated rewards are proportional to the migrated stake amount
  - Recipient's existing pending rewards (if any) are paid out to the recipient during migration
  - `sSTRAT-v2` balance is moved from sender to recipient as part of migration
  - Event `StakeMigrated(from, to, amount, rewards)` is emitted

### Token Properties / Transfer Restrictions

**US-010: Prevent sSTRAT-v2 transfers and approvals**
- **As a** protocol designer
- **I want** sSTRAT-v2 to be non-transferable and non-approvable
- **So that** it acts as an accounting receipt token rather than a tradable asset
- **Acceptance Criteria:**
  - External `transfer`, `transferFrom`, and `approve` revert with `TransferDisabled`
  - Users cannot move sSTRAT-v2 via allowances
  - Migration remains possible via the dedicated `migrateStake()` flow (which performs an internal transfer)

### Security & Safety

**US-011: Reentrancy protection on state-changing functions**
- **As a** user
- **I want** staking and claiming operations protected from reentrancy
- **So that** reward transfers cannot be exploited to corrupt accounting
- **Acceptance Criteria:**
  - `stake`, `unstake`, `claim`, and `migrateStake` are guarded by `nonReentrant`

**US-012: Input validation and clear failure modes**
- **As a** user
- **I want** invalid actions to revert with explicit errors
- **So that** I can quickly understand why a transaction failed
- **Acceptance Criteria:**
  - Zero-amount stake/unstake reverts with `ZeroAmount`
  - Unstake/migrate above staked amount reverts with `InsufficientStake`
  - Transfers/approvals revert with `TransferDisabled`

## Technical Notes

- Rewards use a hybrid MasterChef + Synthetix-style streaming model:
  - **MasterChef accounting**: `rewardsPerShare` accumulator scaled by `PRECISION = 1e18`, with `rewardDebt[user]` tracked as `uint256`
  - **Synthetix streaming**: New reward batches are linearly dripped over `REWARD_DURATION` (7 days) via `rewardRate` / `periodFinish` / `lastUpdateTime` state
  - This combination prevents frontrunning: staking just before a large reward deposit and exiting immediately yields nothing, because rewards stream linearly over the full period
- Anti-griefing for dust deposits: the streaming duration for new batches is value-weighted with any remaining undistributed tokens. A dust deposit barely perturbs the ongoing stream, while a full-size batch gets close to the full 7-day window.
- Fairness invariant:
  - Existing stakers always retain their share of yield accrued up to the current `rewardsPerShare`
  - New stakers begin accruing from the current `rewardsPerShare` baseline (so they only earn yield emitted after they stake)
- `unstake()` auto-claims pending rewards before reducing stake (no silent forfeiture)
- `migrateStake()` preserves the sender's non-migrated proportional pending in their debt and remains claimable after migration
- `getPendingRewards()` projects the current stream drip to the current block timestamp without a state update, but does **not** account for newly arrived reward tokens that haven't been synced yet
- State variables for reward accounting:
  - `rewardRate`: reward tokens per second currently streaming
  - `periodFinish`: timestamp when the current stream ends
  - `lastUpdateTime`: timestamp of the last `rewardsPerShare` tick
  - `totalNotifiedRewards`: cumulative rewards ever accepted into the stream (monotonically increasing)
  - `totalClaimed`: cumulative rewards ever paid out to stakers

## Deployment Requirements

**IMPORTANT**: To ensure proper reward distribution, the contract must be deployed with an initial "seed stake" that is never fully withdrawn:

1. Deploy StakedStrat contract
2. Immediately stake a small amount of STRAT from a protocol-controlled address (recommended: at least 1 STRAT, or even 1 wei)
3. Never unstake this initial amount completely (maintain `totalStaked > 0` at all times)
4. Then set StakedStrat as the `yieldReceiver` in esETH and/or `interestRevenueRecipient` in StratETHTreasuryLend

**Rationale**: The contract assumes `totalStaked` is always greater than zero once rewards begin flowing. If `totalStaked` reaches 0 after rewards have been received, those rewards remain in the contract but cannot be fairly distributed. The seed stake prevents this scenario by ensuring there are always stakers to receive rewards.
