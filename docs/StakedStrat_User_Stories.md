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
  - User’s `staked[user]` and `totalStaked` increase by `amount`
  - `amount` of `sSTRAT-v2` is minted to the user
  - Rewards accounting is updated so the user keeps any previously accrued rewards
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
  - User’s `staked[user]` and `totalStaked` decrease by `amount`
  - `amount` of `sSTRAT-v2` is burned from the user
  - `amount` of STRAT is transferred back to the user
  - Event `Unstaked(user, amount)` is emitted

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
    - `totalSyncedRewards` is reduced by the claimed amount
    - Reward tokens are transferred to the user
    - Event `RewardsClaimed(user, amount)` is emitted

**US-004: View pending rewards without state changes**
- **As a** user or integrator
- **I want to** query my pending rewards
- **So that** I can display expected yield and decide when to claim
- **Acceptance Criteria:**
  - Can call `getPendingRewards(user)` as a `view`
  - If the user has no stake, returns 0
  - The calculation includes any “unsynced” reward tokens currently in the contract balance (as if a sync happened)

### Reward Synchronization (Permissionless)

**US-005: Fund rewards by sending reward tokens to the contract**
- **As a** protocol operator or yield source
- **I want to** send reward tokens (e.g. esETH) to the StakedStrat contract
- **So that** stakers can accrue rewards
- **Acceptance Criteria:**
  - Reward tokens can be transferred to the contract
  - Reward tokens received are not automatically distributed until incorporated into rewards accounting
  - Reward tokens become distributable to stakers after `syncRewards()` is called (directly or indirectly via other actions)

**US-006: Distribute yield fairly by stake amount and time**
- **As a** staker
- **I want** yield payouts to be proportional to how much I stake and how long I’ve been staked
- **So that** earlier stakers receive their share of yield accrued to date, and new stakers only receive yield emitted after they join
- **Acceptance Criteria:**
  - Rewards are accounted for using a cumulative “rewards per staked token” accumulator (`rewardsPerShare`)
  - When rewards arrive and are synced, `rewardsPerShare` increases for the whole pool pro-rata to stake size
  - A staker’s claimable rewards are based on the change in `rewardsPerShare` since their last accounting update
  - When a user stakes, their accounting baseline is updated to the current `rewardsPerShare` so they do not receive previously accrued yield
  - When a user unstakes, claims, or migrates, their accounting is updated so previously accrued yield is preserved and cannot be double-counted

**US-007: Sync incoming reward tokens into reward accounting**
- **As a** staker, keeper, or integrator
- **I want to** sync the contract’s reward token balance into `rewardsPerShare`
- **So that** rewards are properly attributed before stake/unstake/claim/migration actions
- **Acceptance Criteria:**
  - Anyone can call `syncRewards()`
  - If the reward token balance is 0 or `totalStaked == 0`, it returns without changing state
  - If new reward tokens have arrived since the last sync, `rewardsPerShare` increases proportionally to `newRewards / totalStaked`
  - `totalSyncedRewards` increases by the synced amount
  - Event `RewardsSynced(newRewardsPerShare, totalRewards)` is emitted

**US-008: Handle the case where synced rewards exceed current reward token balance**
- **As a** protocol observer
- **I want** the contract to remain consistent after rewards are paid out
- **So that** reward syncing doesn’t underflow or mis-account after claims
- **Acceptance Criteria:**
  - If reward token balance < `totalSyncedRewards`, calling `syncRewards()`:
    - Resets `totalSyncedRewards` to the current reward token balance
    - Does not increase `rewardsPerShare` in that call

### Stake Migration (Address Change)

**US-009: Migrate my stake (and proportional unclaimed rewards) to a new address**
- **As a** staker rotating wallets
- **I want to** move some or all of my stake and unclaimed rewards to a new address
- **So that** I can change custody without unstaking
- **Acceptance Criteria:**
  - `to` must be non-zero and must not equal the caller
  - Caller must have a non-zero stake (otherwise reverts with `InsufficientStake`)
  - Rewards are synced before state changes (`syncRewards()` is called)
  - If `amount == 0`, migrates the caller’s full staked balance; otherwise migrates the requested amount
  - Migrated rewards are proportional to the migrated stake amount
  - Recipient’s existing pending rewards (if any) are paid out to the recipient during migration
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

- Rewards use MasterChef-style accounting with:
  - `rewardsPerShare` scaled by `PRECISION = 1e18`
  - `rewardDebt[user]` tracked as `int256` to support safe subtraction
- Fairness invariant:
  - Existing stakers always retain their share of yield accrued up to the current `rewardsPerShare`
  - New stakers begin accruing from the current `rewardsPerShare` baseline (so they only earn yield emitted after they stake)
- Reward token rewards (e.g. esETH) are distributed on `syncRewards()`
- `getPendingRewards()` estimates pending rewards as if unsynced reward tokens were synced at the current time
- `totalSyncedRewards` tracks how much of the current reward token balance has been incorporated into `rewardsPerShare` (and is adjusted downward on payouts)

## Deployment Requirements

**IMPORTANT**: To ensure proper reward distribution, the contract must be deployed with an initial "seed stake" that is never fully withdrawn:

1. Deploy StakedStrat contract
2. Immediately stake a small amount of STRAT from a protocol-controlled address (recommended: at least 1 STRAT, or even 1 wei)
3. Never unstake this initial amount completely (maintain `totalStaked > 0` at all times)
4. Then set StakedStrat as the `yieldReceiver` in esETH and/or `interestRevenueRecipient` in StratETHTreasuryLend

**Rationale**: The contract assumes `totalStaked` is always greater than zero once rewards begin flowing. If `totalStaked` reaches 0 after rewards have been received, those rewards remain in the contract but cannot be fairly distributed. The seed stake prevents this scenario by ensuring there are always stakers to receive rewards.
