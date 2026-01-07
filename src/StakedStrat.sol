// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Staked STRAT
 * @dev Users stake STRAT tokens and earn ETH yield proportional to their stake.
 *      Uses rewardDebt/rewardsPerShare accounting similar to MasterChef.
 *      StakedSTRAT is a non-transferrable ERC20 token.
 */
contract StakedStrat is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Precision factor for rewardsPerShare calculation
    uint256 private constant PRECISION = 1e18;

    /// @dev The STRAT token that users stake
    IERC20 public immutable stratToken;

    /// @dev Accumulated rewards per share, scaled by PRECISION
    uint256 public rewardsPerShare;

    /// @dev Total amount of STRAT staked
    uint256 public totalStaked;

    /// @dev Total amount of ETH that has been synced into rewardsPerShare
    uint256 public totalSyncedRewards;

    /// @dev Mapping from user address to their staked amount
    mapping(address => uint256) public staked;

    /// @dev Mapping from user address to their reward debt
    mapping(address => int256) public rewardDebt;

    /// @dev Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsSynced(uint256 newRewardsPerShare, uint256 totalRewards);
    event StakeMigrated(address indexed from, address indexed to, uint256 amount, uint256 rewards);

    error TransferDisabled();
    error ZeroAmount();
    error InsufficientStake();
    error InsufficientBalance();

    /**
     * @dev Constructor
     * @param _stratToken The STRAT token address
     */
    constructor(address _stratToken) ERC20("Staked STRAT v2", "sSTRAT-v2") {
        if (_stratToken == address(0)) revert();
        stratToken = IERC20(_stratToken);
    }

    /**
     * @dev Override transfer to disable transfers
     */
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /**
     * @dev Override transferFrom to disable transfers
     */
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /**
     * @dev Override approve to disable approvals (since transfers are disabled)
     */
    function approve(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    /**
     * @dev Permissionless function to sync rewards.
     *      Calculates new rewardsPerShare based on ETH balance in contract.
     *      Should be called before any stake/unstake/claim/migrateStake operations.
     */
    function syncRewards() public {
        uint256 currentBalance = address(this).balance;
        if (currentBalance == 0 || totalStaked == 0) {
            return;
        }

        // Calculate new rewards that haven't been synced yet
        uint256 newRewards = currentBalance - totalSyncedRewards;
        if (newRewards == 0) {
            return;
        }

        // Calculate new rewards per share
        // rewardsPerShare += (newRewards * PRECISION) / totalStaked
        uint256 rewardsPerShareIncrease = (newRewards * PRECISION) / totalStaked;
        rewardsPerShare += rewardsPerShareIncrease;
        totalSyncedRewards += newRewards;

        emit RewardsSynced(rewardsPerShare, newRewards);
    }

    /**
     * @dev Stake STRAT tokens
     * @param amount Amount of STRAT to stake
     */
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Sync rewards before updating user state
        syncRewards();

        // Update reward debt to account for any pending rewards before staking
        if (staked[msg.sender] > 0) {
            rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);
        }

        // Transfer STRAT from user
        stratToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update staking state
        staked[msg.sender] += amount;
        totalStaked += amount;

        // Update reward debt
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);

        // Mint sSTRAT tokens (non-transferrable, but still tracked)
        _mint(msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Unstake STRAT tokens
     * @param amount Amount of STRAT to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (staked[msg.sender] < amount) revert InsufficientStake();

        // Sync rewards before updating user state
        syncRewards();

        // Update reward debt to account for any pending rewards before unstaking
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);

        // Update staking state
        staked[msg.sender] -= amount;
        totalStaked -= amount;

        // Update reward debt
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);

        // Burn sSTRAT tokens
        _burn(msg.sender, amount);

        // Transfer STRAT back to user
        stratToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Claim pending ETH rewards
     */
    function claim() external nonReentrant {
        // Sync rewards before updating user state
        syncRewards();

        // Calculate and claim pending rewards
        uint256 claimable = _getPendingRewards(msg.sender);

        if (claimable == 0) {
            return;
        }

        // Update reward debt to reflect that rewards have been claimed
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);
        totalSyncedRewards -= claimable;

        // Transfer ETH rewards to user
        (bool success,) = msg.sender.call{value: claimable}("");
        if (!success) revert();

        emit RewardsClaimed(msg.sender, claimable);
    }

    /**
     * @dev Migrate stake and unclaimed rewards to a new address
     * @param to Address to migrate stake to
     * @param amount Amount of STRAT to migrate (0 = migrate all)
     */
    function migrateStake(address to, uint256 amount) external nonReentrant {
        if (to == address(0) || to == msg.sender) revert();
        if (staked[msg.sender] == 0) revert InsufficientStake();

        // Sync rewards before updating user state
        syncRewards();

        // Determine amount to migrate
        uint256 amountToMigrate = amount == 0 ? staked[msg.sender] : amount;
        if (amountToMigrate > staked[msg.sender]) revert InsufficientStake();

        // Calculate rewards to migrate (proportional to amount being migrated)
        // Do this before updating rewardDebt
        uint256 totalPendingRewards = _getPendingRewards(msg.sender);
        uint256 rewardsToMigrate = (totalPendingRewards * amountToMigrate) / staked[msg.sender];

        // Update sender's state
        staked[msg.sender] -= amountToMigrate;
        totalStaked -= amountToMigrate;
        rewardDebt[msg.sender] = int256((staked[msg.sender] * rewardsPerShare) / PRECISION);

        // Update recipient's state
        if (staked[to] > 0) {
            // If recipient already has stake, update their rewards first
            rewardDebt[to] = int256((staked[to] * rewardsPerShare) / PRECISION);
        }
        staked[to] += amountToMigrate;
        totalStaked += amountToMigrate;
        rewardDebt[to] = int256((staked[to] * rewardsPerShare) / PRECISION);

        // Transfer sSTRAT tokens
        _transfer(msg.sender, to, amountToMigrate);

        // Transfer ETH rewards if any
        if (rewardsToMigrate > 0) {
            totalSyncedRewards -= rewardsToMigrate;
            (bool success,) = to.call{value: rewardsToMigrate}("");
            if (!success) revert();
        }

        emit StakeMigrated(msg.sender, to, amountToMigrate, rewardsToMigrate);
    }

    /**
     * @dev Get pending rewards for a user
     * @param user Address to check pending rewards for
     * @return Pending ETH rewards
     */
    function getPendingRewards(address user) external view returns (uint256) {
        if (staked[user] == 0) {
            return 0;
        }

        // Calculate current rewardsPerShare if we synced now
        uint256 currentRewardsPerShare = rewardsPerShare;
        uint256 currentBalance = address(this).balance;
        uint256 unsyncedRewards = currentBalance > totalSyncedRewards ? currentBalance - totalSyncedRewards : 0;
        if (unsyncedRewards > 0 && totalStaked > 0) {
            currentRewardsPerShare += (unsyncedRewards * PRECISION) / totalStaked;
        }

        // Calculate pending rewards
        int256 pending = int256((staked[user] * currentRewardsPerShare) / PRECISION) - rewardDebt[user];
        return pending > 0 ? uint256(pending) : 0;
    }

    /**
     * @dev Internal function to update user's rewards and return claimable amount
     * @param user Address to update rewards for
     * @return claimable Amount of ETH rewards claimable
     */
    function _updateRewards(address user) internal returns (uint256) {
        if (staked[user] == 0) {
            return 0;
        }

        uint256 pending = _getPendingRewards(user);
        // Update reward debt to reflect that rewards have been accounted for
        // This prevents double-counting when user stakes/unstakes
        rewardDebt[user] = int256((staked[user] * rewardsPerShare) / PRECISION);

        return pending;
    }

    /**
     * @dev Internal function to get pending rewards for a user
     * @param user Address to check pending rewards for
     * @return Pending ETH rewards
     */
    function _getPendingRewards(address user) internal view returns (uint256) {
        if (staked[user] == 0) {
            return 0;
        }

        int256 pending = int256((staked[user] * rewardsPerShare) / PRECISION) - rewardDebt[user];
        return pending > 0 ? uint256(pending) : 0;
    }

    /**
     * @dev Receive ETH (rewards)
     */
    receive() external payable {}
}
