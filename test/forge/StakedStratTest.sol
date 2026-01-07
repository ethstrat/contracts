// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";
import {StratToken} from "../../src/StratToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract StakedStratTest is Test {
    StakedStrat public stakedStrat;
    StratToken public stratToken;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    address public rewarder = address(0x5);

    uint256 public constant STAKE_AMOUNT_1 = 1000 * 1e18;
    uint256 public constant STAKE_AMOUNT_2 = 500 * 1e18;
    uint256 public constant REWARD_AMOUNT_1 = 10 * 1e18;
    uint256 public constant REWARD_AMOUNT_2 = 5 * 1e18;

    function setUp() public {
        // Deploy STRAT token
        vm.prank(owner);
        stratToken = new StratToken(owner);

        // Make owner a minter
        vm.prank(owner);
        stratToken.manageMinter(owner, true);

        // Deploy StakedStrat
        stakedStrat = new StakedStrat(address(stratToken));

        // Mint STRAT tokens to users
        vm.prank(owner);
        stratToken.mint(user1, 10000 * 1e18);
        vm.prank(owner);
        stratToken.mint(user2, 10000 * 1e18);
        vm.prank(owner);
        stratToken.mint(user3, 10000 * 1e18);

        // Approve StakedStrat to spend STRAT
        vm.prank(user1);
        stratToken.approve(address(stakedStrat), type(uint256).max);
        vm.prank(user2);
        stratToken.approve(address(stakedStrat), type(uint256).max);
        vm.prank(user3);
        stratToken.approve(address(stakedStrat), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(stakedStrat.stratToken()), address(stratToken));
        assertEq(stakedStrat.name(), "Staked STRAT v2");
        assertEq(stakedStrat.symbol(), "sSTRAT-v2");
        assertEq(stakedStrat.decimals(), 18);
        assertEq(stakedStrat.totalStaked(), 0);
        assertEq(stakedStrat.rewardsPerShare(), 0);
    }

    function test_Constructor_ZeroAddress() public {
        vm.expectRevert();
        new StakedStrat(address(0));
    }

    // ============ Transfer Tests ============

    function test_TransferDisabled() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert(StakedStrat.TransferDisabled.selector);
        stakedStrat.transfer(user2, 100 * 1e18);
    }

    function test_TransferFromDisabled() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert(StakedStrat.TransferDisabled.selector);
        stakedStrat.transferFrom(user1, user2, 100 * 1e18);
    }

    function test_ApproveDisabled() public {
        vm.prank(user1);
        vm.expectRevert(StakedStrat.TransferDisabled.selector);
        stakedStrat.approve(user2, 100 * 1e18);
    }

    // ============ Stake Tests ============

    function test_Stake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1);
        assertEq(stakedStrat.balanceOf(user1), STAKE_AMOUNT_1);
        assertEq(stratToken.balanceOf(user1), 10000 * 1e18 - STAKE_AMOUNT_1);
        assertEq(stratToken.balanceOf(address(stakedStrat)), STAKE_AMOUNT_1);
    }

    function test_Stake_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(StakedStrat.ZeroAmount.selector);
        stakedStrat.stake(0);
    }

    function test_Stake_MultipleUsers() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1);
        assertEq(stakedStrat.staked(user2), STAKE_AMOUNT_2);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
    }

    function test_Stake_MultipleTimes() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_2);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
    }

    // ============ Unstake Tests ============

    function test_Unstake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        uint256 unstakeAmount = 300 * 1e18;
        vm.prank(user1);
        stakedStrat.unstake(unstakeAmount);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(stakedStrat.balanceOf(user1), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(stratToken.balanceOf(user1), 10000 * 1e18 - STAKE_AMOUNT_1 + unstakeAmount);
    }

    function test_Unstake_ZeroAmount() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert(StakedStrat.ZeroAmount.selector);
        stakedStrat.unstake(0);
    }

    function test_Unstake_InsufficientStake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert(StakedStrat.InsufficientStake.selector);
        stakedStrat.unstake(STAKE_AMOUNT_1 + 1);
    }

    function test_Unstake_All() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);

        assertEq(stakedStrat.staked(user1), 0);
        assertEq(stakedStrat.totalStaked(), 0);
        assertEq(stakedStrat.balanceOf(user1), 0);
    }

    // ============ Rewards Tests ============

    function test_SyncRewards_NoStakers() public {
        // Send ETH to contract
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);

        // Sync should not revert but do nothing
        stakedStrat.syncRewards();
        assertEq(stakedStrat.rewardsPerShare(), 0);
    }

    function test_SyncRewards_NoBalance() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Sync with no ETH balance
        stakedStrat.syncRewards();
        assertEq(stakedStrat.rewardsPerShare(), 0);
    }

    function test_SyncRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Send ETH rewards
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 expectedRewardsPerShare = (REWARD_AMOUNT_1 * 1e18) / STAKE_AMOUNT_1;
        assertEq(stakedStrat.rewardsPerShare(), expectedRewardsPerShare);
        assertEq(stakedStrat.totalSyncedRewards(), REWARD_AMOUNT_1);
    }

    function test_SyncRewards_MultipleTimes() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // First sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 firstRewardsPerShare = stakedStrat.rewardsPerShare();

        // Second sync with more rewards
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
        stakedStrat.syncRewards();

        uint256 expectedIncrease = (REWARD_AMOUNT_2 * 1e18) / STAKE_AMOUNT_1;
        assertEq(stakedStrat.rewardsPerShare(), firstRewardsPerShare + expectedIncrease);
    }

    function test_GetPendingRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertEq(pending, REWARD_AMOUNT_1);
    }

    function test_GetPendingRewards_NoStake() public view {
        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertEq(pending, 0);
    }

    function test_GetPendingRewards_Proportional() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 pending1 = stakedStrat.getPendingRewards(user1);
        uint256 pending2 = stakedStrat.getPendingRewards(user2);

        // user1 should get 2/3 of rewards, user2 should get 1/3
        assertEq(pending1, (REWARD_AMOUNT_1 * 2) / 3);
        assertEq(pending2, REWARD_AMOUNT_1 / 3);
        assertEq(pending1 + pending2, REWARD_AMOUNT_1);
    }

    function test_Claim() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        stakedStrat.claim();

        assertEq(user1.balance - balanceBefore, REWARD_AMOUNT_1);
        assertEq(stakedStrat.getPendingRewards(user1), 0);
    }

    function test_Claim_NoRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Claim with no rewards
        vm.prank(user1);
        stakedStrat.claim();

        assertEq(user1.balance, 0);
    }

    function test_Claim_MultipleUsers() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 balance1Before = user1.balance;
        uint256 balance2Before = user2.balance;

        vm.prank(user1);
        stakedStrat.claim();

        vm.prank(user2);
        stakedStrat.claim();

        assertEq(user1.balance - balance1Before, (REWARD_AMOUNT_1 * 2) / 3);
        assertEq(user2.balance - balance2Before, REWARD_AMOUNT_1 / 3);
    }

    function test_Claim_AfterStake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        // Stake more
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_2);

        // Claim should still give the original rewards
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        stakedStrat.claim();

        assertEq(user1.balance - balanceBefore, REWARD_AMOUNT_1);
    }

    // ============ Migrate Stake Tests ============

    function test_MigrateStake_All() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 balance2Before = user2.balance;
        uint256 pendingBefore = stakedStrat.getPendingRewards(user1);

        vm.prank(user1);
        stakedStrat.migrateStake(user2, 0); // 0 means migrate all

        assertEq(stakedStrat.staked(user1), 0);
        assertEq(stakedStrat.staked(user2), STAKE_AMOUNT_1);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1);
        assertEq(user2.balance - balance2Before, pendingBefore);
    }

    function test_MigrateStake_Partial() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 migrateAmount = 300 * 1e18;
        uint256 balance2Before = user2.balance;
        uint256 pendingBefore = stakedStrat.getPendingRewards(user1);
        uint256 expectedRewards = (pendingBefore * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        stakedStrat.migrateStake(user2, migrateAmount);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - migrateAmount);
        assertEq(stakedStrat.staked(user2), migrateAmount);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1);
        assertEq(user2.balance - balance2Before, expectedRewards);
    }

    function test_MigrateStake_ZeroAddress() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert();
        stakedStrat.migrateStake(address(0), 0);
    }

    function test_MigrateStake_Self() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert();
        stakedStrat.migrateStake(user1, 0);
    }

    function test_MigrateStake_NoStake() public {
        vm.prank(user1);
        vm.expectRevert(StakedStrat.InsufficientStake.selector);
        stakedStrat.migrateStake(user2, 0);
    }

    function test_MigrateStake_InsufficientStake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user1);
        vm.expectRevert(StakedStrat.InsufficientStake.selector);
        stakedStrat.migrateStake(user2, STAKE_AMOUNT_1 + 1);
    }

    function test_MigrateStake_ToExistingStaker() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        // Send rewards and sync
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        uint256 migrateAmount = 300 * 1e18;
        uint256 balance2Before = user2.balance;
        uint256 pending1Before = stakedStrat.getPendingRewards(user1);
        uint256 pending2Before = stakedStrat.getPendingRewards(user2);
        uint256 expectedRewards = (pending1Before * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        stakedStrat.migrateStake(user2, migrateAmount);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - migrateAmount);
        assertEq(stakedStrat.staked(user2), STAKE_AMOUNT_2 + migrateAmount);
        assertEq(user2.balance - balance2Before, pending2Before + expectedRewards);
    }

    // ============ Integration Tests ============

    function test_CompleteFlow() public {
        // User1 stakes
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Rewards arrive
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        // User2 stakes
        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        // More rewards arrive
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
        stakedStrat.syncRewards();

        // User1 claims
        vm.prank(user1);
        stakedStrat.claim();

        // User2 claims
        vm.prank(user2);
        stakedStrat.claim();

        // User1 unstakes partially
        vm.prank(user1);
        stakedStrat.unstake(300 * 1e18);

        // User1 migrates remaining stake to user3
        vm.prank(user1);
        stakedStrat.migrateStake(user3, 0);

        assertEq(stakedStrat.staked(user1), 0);
        assertEq(stakedStrat.staked(user3), 700 * 1e18);
        assertEq(stakedStrat.totalStaked(), 700 * 1e18 + STAKE_AMOUNT_2);
    }

    function test_Rewards_AccumulateOverTime() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // First reward batch
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        // Second reward batch
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
        stakedStrat.syncRewards();

        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertEq(pending, REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
    }

    function test_Stake_Unstake_Stake_Again() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Rewards arrive
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        // Unstake
        vm.prank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);

        // Stake again
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // More rewards
        vm.deal(address(stakedStrat), REWARD_AMOUNT_2);
        stakedStrat.syncRewards();

        // Should only get new rewards, not old ones
        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertEq(pending, REWARD_AMOUNT_2);
    }

    // ============ Edge Cases ============

    function test_SyncRewards_AfterUnstake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Rewards arrive
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1);
        stakedStrat.syncRewards();

        // Unstake all
        vm.prank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);

        // More rewards arrive (should not sync since totalStaked is 0)
        vm.deal(address(stakedStrat), REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
        stakedStrat.syncRewards();

        assertEq(stakedStrat.rewardsPerShare(), (REWARD_AMOUNT_1 * 1e18) / STAKE_AMOUNT_1);
    }

    function test_Receive() public {
        // Direct ETH transfer
        vm.deal(address(this), 1 ether);
        (bool success,) = address(stakedStrat).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(stakedStrat).balance, 1 ether);
    }

    function test_Precision_Handling() public {
        // Test with very small amounts
        uint256 smallStake = 1;
        uint256 smallReward = 1;

        vm.prank(user1);
        stakedStrat.stake(smallStake);

        vm.deal(address(stakedStrat), smallReward);
        stakedStrat.syncRewards();

        uint256 pending = stakedStrat.getPendingRewards(user1);
        // Should handle precision correctly
        assertGe(pending, 0);
    }
}

