// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ITripwireController} from "./interfaces/ITripwireController.sol";
import {TripwireGuard} from "./lib/TripwireGuard.sol";

/**
 * @title Staked STRAT
 * @dev Users stake STRAT tokens and earn reward token yield (e.g. esETH) proportional to their
 *      stake. Uses rewardDebt/rewardsPerShare accounting (MasterChef-style) combined with
 *      Synthetix-style linear reward streaming.
 *
 *      When reward tokens are sent to this contract, syncRewards() detects the balance increase
 *      and begins a REWARD_DURATION (7-day) linear drip rather than distributing immediately.
 *      Any undistributed tokens from an active stream are blended into the new period. This
 *      prevents frontrunning: an attacker who stakes just before rewards arrive and exits
 *      immediately captures nothing; they must hold for the full period to earn a proportional
 *      share, tying up capital for marginal gain.
 *
 *      Invariants vs. plain MasterChef:
 *        - unstake() auto-claims pending rewards before reducing stake (no silent forfeiture).
 *        - migrateStake() preserves the sender's non-migrated proportional pending in their debt.
 *
 *      StakedSTRAT is a non-transferrable ERC20 token.
 */
contract StakedStrat is ERC20, ReentrancyGuard, TripwireGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;

    /// @dev Duration over which each detected reward batch is linearly streamed
    uint256 public constant REWARD_DURATION = 7 days;

    IERC20 public immutable stratToken;
    IERC20 public immutable rewardToken;

    // -------------------------------------------------------------------------
    // Per-share accumulator
    // -------------------------------------------------------------------------

    /// @dev Accumulated rewards per share, scaled by PRECISION. Updated lazily by
    ///      _tickRewardsPerShare() based on elapsed time and the current rewardRate.
    uint256 public rewardsPerShare;

    // -------------------------------------------------------------------------
    // Streaming state
    // -------------------------------------------------------------------------

    /// @dev Reward tokens per second currently streaming to stakers
    uint256 public rewardRate;

    /// @dev Timestamp when the current reward stream ends
    uint256 public periodFinish;

    /// @dev Timestamp of the last rewardsPerShare tick
    uint256 public lastUpdateTime;

    // -------------------------------------------------------------------------
    // Accounting
    // -------------------------------------------------------------------------

    uint256 public totalStaked;

    /// @dev Cumulative rewards ever accepted into the stream (monotonically increasing).
    ///      Used with totalClaimed to detect new balance arrivals without double-counting.
    uint256 public totalNotifiedRewards;

    /// @dev Cumulative rewards ever paid out to stakers
    uint256 public totalClaimed;

    mapping(address => uint256) public staked;

    /// @dev MasterChef-style signed reward debt per user
    mapping(address => int256) public rewardDebt;

    // -------------------------------------------------------------------------
    // Events / Errors
    // -------------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsSynced(uint256 rewardRate, uint256 newRewards, uint256 periodFinish);
    event StakeMigrated(address indexed from, address indexed to, uint256 amount, uint256 rewards);

    error TransferDisabled();
    error ZeroAmount();
    error InsufficientStake();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _stratToken, address _rewardToken, ITripwireController controller_, address guardian_) ERC20("Staked STRAT v2", "sSTRAT-v2") TripwireGuard(controller_, guardian_) {
        if (_stratToken == address(0)) revert();
        if (_rewardToken == address(0)) revert();
        stratToken = IERC20(_stratToken);
        rewardToken = IERC20(_rewardToken);
        lastUpdateTime = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Transfer overrides (sSTRAT is non-transferrable)
    // -------------------------------------------------------------------------

    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    // -------------------------------------------------------------------------
    // Internal streaming helpers
    // -------------------------------------------------------------------------

    /// @dev Returns the earlier of block.timestamp and periodFinish
    function _lastApplicableTime() internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @dev Computes rewardsPerShare projected to the current timestamp without writing storage
    function _currentRewardsPerShare() internal view returns (uint256) {
        if (totalStaked == 0 || rewardRate == 0) return rewardsPerShare;
        uint256 elapsed = _lastApplicableTime() - lastUpdateTime;
        if (elapsed == 0) return rewardsPerShare;
        return rewardsPerShare + (elapsed * rewardRate * PRECISION) / totalStaked;
    }

    /// @dev Ticks rewardsPerShare and lastUpdateTime forward to the current moment
    function _tickRewardsPerShare() internal {
        rewardsPerShare = _currentRewardsPerShare();
        lastUpdateTime = _lastApplicableTime();
    }

    // -------------------------------------------------------------------------
    // Sync
    // -------------------------------------------------------------------------

    /**
     * @dev Permissionless function that:
     *   1. Ticks rewardsPerShare forward based on elapsed time and the current rewardRate.
     *   2. Detects any new reward tokens in the contract balance and blends them into a fresh
     *      REWARD_DURATION linear stream, merging with any remaining undistributed tokens.
     *
     *      The 7-day stream ensures that a frontrunner who stakes just before rewards arrive
     *      and exits immediately captures nothing; they must hold for the full period to earn
     *      a proportional share.
     */
    function syncRewards() public whenNotTripped {
        _tickRewardsPerShare();

        // New rewards = total ever deposited minus total ever accepted into the stream
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        uint256 totalDeposited = currentBalance + totalClaimed;
        if (totalDeposited <= totalNotifiedRewards) return;

        uint256 newRewards = totalDeposited - totalNotifiedRewards;
        totalNotifiedRewards += newRewards;

        // Blend remaining undistributed tokens from any active stream with the new batch
        uint256 remaining = block.timestamp < periodFinish ? rewardRate * (periodFinish - block.timestamp) : 0;
        rewardRate = (remaining + newRewards) / REWARD_DURATION;
        periodFinish = block.timestamp + REWARD_DURATION;
        lastUpdateTime = block.timestamp;

        emit RewardsSynced(rewardRate, newRewards, periodFinish);
    }

    // -------------------------------------------------------------------------
    // Core actions
    // -------------------------------------------------------------------------

    /**
     * @dev Stake STRAT tokens
     */
    function stake(uint256 amount) external nonReentrant whenNotTripped {
        if (amount == 0) revert ZeroAmount();

        syncRewards();

        // Preserve existing reward debt so prior pending rewards are untouched
        int256 currentRewardDebt = rewardDebt[msg.sender];

        stratToken.safeTransferFrom(msg.sender, address(this), amount);

        staked[msg.sender] += amount;
        totalStaked += amount;

        // Anchor new stake to current rewardsPerShare so it earns only future drips
        int256 newStakeDebt = int256((amount * rewardsPerShare) / PRECISION);
        rewardDebt[msg.sender] = currentRewardDebt + newStakeDebt;

        _mint(msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Unstake STRAT tokens. Pending rewards are automatically claimed first.
     */
    function unstake(uint256 amount) external nonReentrant whenNotTripped {
        if (amount == 0) revert ZeroAmount();
        if (staked[msg.sender] < amount) revert InsufficientStake();

        syncRewards();

        // Auto-claim before modifying stake so no accrued rewards are lost
        uint256 claimable = _getPendingRewards(msg.sender);
        if (claimable > 0) {
            rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);
            totalClaimed += claimable;
            rewardToken.safeTransfer(msg.sender, claimable);
            emit RewardsClaimed(msg.sender, claimable);
        }

        staked[msg.sender] -= amount;
        totalStaked -= amount;
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);

        _burn(msg.sender, amount);
        stratToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Claim pending reward tokens
     */
    function claim() external nonReentrant whenNotTripped {
        syncRewards();

        uint256 claimable = _getPendingRewards(msg.sender);
        if (claimable == 0) return;

        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);
        totalClaimed += claimable;

        rewardToken.safeTransfer(msg.sender, claimable);
        emit RewardsClaimed(msg.sender, claimable);
    }

    /**
     * @dev Migrate stake and proportional pending rewards to another address.
     *      The sender's non-migrated pending rewards are preserved in their debt and
     *      remain claimable after the migration.
     */
    function migrateStake(address to, uint256 amount) external nonReentrant whenNotTripped {
        if (to == address(0) || to == msg.sender) revert();
        if (staked[msg.sender] == 0) revert InsufficientStake();

        syncRewards();

        uint256 amountToMigrate = amount == 0 ? staked[msg.sender] : amount;
        if (amountToMigrate > staked[msg.sender]) revert InsufficientStake();

        // Compute rewards to migrate before touching state
        uint256 totalPendingRewards = _getPendingRewards(msg.sender);
        uint256 rewardsToMigrate = (totalPendingRewards * amountToMigrate) / staked[msg.sender];

        // Update sender — preserve non-migrated pending via incremental debt adjustment
        staked[msg.sender] -= amountToMigrate;
        totalStaked -= amountToMigrate;
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION)
            - int256(totalPendingRewards - rewardsToMigrate);

        // Pay out any existing pending rewards for the recipient before updating their state
        uint256 recipientPendingRewards = 0;
        if (staked[to] > 0) {
            recipientPendingRewards = _getPendingRewards(to);
            if (recipientPendingRewards > 0) {
                rewardDebt[to] = int256((staked[to] * rewardsPerShare) / PRECISION);
            }
        }

        // Update recipient
        staked[to] += amountToMigrate;
        totalStaked += amountToMigrate;
        rewardDebt[to] = int256((staked[to] * rewardsPerShare) / PRECISION);

        _transfer(msg.sender, to, amountToMigrate);

        uint256 totalRewardsToPay = recipientPendingRewards + rewardsToMigrate;
        if (totalRewardsToPay > 0) {
            totalClaimed += totalRewardsToPay;
            rewardToken.safeTransfer(to, totalRewardsToPay);
        }

        emit StakeMigrated(msg.sender, to, amountToMigrate, rewardsToMigrate);
    }

    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    /**
     * @dev Returns pending claimable rewards for a user, projected to the current block.
     *      Accounts for the ongoing stream drip without requiring a state update.
     */
    function getPendingRewards(address user) external view returns (uint256) {
        if (staked[user] == 0) return 0;
        uint256 currentRewardsPerShare = _currentRewardsPerShare();
        int256 pending = int256((staked[user] * currentRewardsPerShare) / PRECISION) - rewardDebt[user];
        return pending > 0 ? uint256(pending) : 0;
    }

    /// @dev Internal version uses already-stored rewardsPerShare (call after _tickRewardsPerShare)
    function _getPendingRewards(address user) internal view returns (uint256) {
        if (staked[user] == 0) return 0;
        int256 pending = int256((staked[user] * rewardsPerShare) / PRECISION) - rewardDebt[user];
        return pending > 0 ? uint256(pending) : 0;
    }
}
