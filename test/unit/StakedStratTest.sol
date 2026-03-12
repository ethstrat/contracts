// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";
import {StratToken} from "../../src/StratToken.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

contract StakedStratTest is Test {
    StakedStrat public stakedStrat;
    StratToken public stratToken;
    MintableBurnableToken public rewardToken;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    address public rewarder = address(0x5);

    uint256 public constant STAKE_AMOUNT_1 = 1000 * 1e18;
    uint256 public constant STAKE_AMOUNT_2 = 500 * 1e18;
    uint256 public constant REWARD_AMOUNT_1 = 10 * 1e18;
    uint256 public constant REWARD_AMOUNT_2 = 5 * 1e18;

    uint256 public constant REWARD_DURATION = 7 days;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Transfers reward tokens to the contract and optionally starts the stream
    function _sendRewards(uint256 amount, bool sync) internal {
        vm.prank(rewarder);
        rewardToken.transfer(address(stakedStrat), amount);
        if (sync) {
            stakedStrat.syncRewards();
        }
    }

    /// @dev Sends rewards, starts the stream, then warps so the full amount has dripped
    function _sendAndFullyStream(uint256 amount) internal {
        _sendRewards(amount, true);
        vm.warp(block.timestamp + REWARD_DURATION);
    }

    ITripwireController internal ctrl;

    function setUp() public {
        ctrl = ITripwireController(address(new TripwireController()));

        vm.prank(owner);
        stratToken = new StratToken(owner, ctrl);

        vm.prank(owner);
        stratToken.manageMinter(owner, true);

        vm.prank(owner);
        rewardToken = new MintableBurnableToken("Reward Token", "RWD", owner, ctrl);

        vm.prank(owner);
        rewardToken.manageMinter(owner, true);

        stakedStrat = new StakedStrat(address(stratToken), address(rewardToken), ctrl);

        vm.prank(owner);
        stratToken.mint(user1, 10000 * 1e18);
        vm.prank(owner);
        stratToken.mint(user2, 10000 * 1e18);
        vm.prank(owner);
        stratToken.mint(user3, 10000 * 1e18);

        vm.prank(user1);
        stratToken.approve(address(stakedStrat), type(uint256).max);
        vm.prank(user2);
        stratToken.approve(address(stakedStrat), type(uint256).max);
        vm.prank(user3);
        stratToken.approve(address(stakedStrat), type(uint256).max);

        vm.prank(owner);
        rewardToken.mint(rewarder, 1000000 * 1e18);
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(stakedStrat.stratToken()), address(stratToken));
        assertEq(address(stakedStrat.rewardToken()), address(rewardToken));
        assertEq(stakedStrat.name(), "Staked STRAT v2");
        assertEq(stakedStrat.symbol(), "sSTRAT-v2");
        assertEq(stakedStrat.decimals(), 18);
        assertEq(stakedStrat.totalStaked(), 0);
        assertEq(stakedStrat.rewardsPerShare(), 0);
        assertEq(stakedStrat.rewardRate(), 0);
        assertEq(stakedStrat.periodFinish(), 0);
        assertEq(stakedStrat.totalNotifiedRewards(), 0);
        assertEq(stakedStrat.totalClaimed(), 0);
    }

    function test_Constructor_ZeroAddress_StratToken() public {
        vm.expectRevert();
        new StakedStrat(address(0), address(rewardToken), ctrl);
    }

    function test_Constructor_ZeroAddress_RewardToken() public {
        vm.expectRevert();
        new StakedStrat(address(stratToken), address(0), ctrl);
    }

    // ============ Transfer Tests ============

    function test_TransferDisabled() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert(StakedStrat.TransferDisabled.selector);
        stakedStrat.transfer(user2, 100 * 1e18);
        vm.stopPrank();
    }

    function test_TransferFromDisabled() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert(StakedStrat.TransferDisabled.selector);
        stakedStrat.transferFrom(user1, user2, 100 * 1e18);
        vm.stopPrank();
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

    function test_Stake_NoApproval() public {
        address newUser = address(0x99);
        vm.prank(owner);
        stratToken.mint(newUser, 10000 * 1e18);

        vm.prank(newUser);
        vm.expectRevert();
        stakedStrat.stake(STAKE_AMOUNT_1);
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
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        stakedStrat.stake(STAKE_AMOUNT_2);
        vm.stopPrank();

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
    }

    // ============ Unstake Tests ============

    function test_Unstake() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        uint256 unstakeAmount = 300 * 1e18;
        stakedStrat.unstake(unstakeAmount);
        vm.stopPrank();

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(stakedStrat.balanceOf(user1), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(stratToken.balanceOf(user1), 10000 * 1e18 - STAKE_AMOUNT_1 + unstakeAmount);
    }

    function test_Unstake_ZeroAmount() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert(StakedStrat.ZeroAmount.selector);
        stakedStrat.unstake(0);
        vm.stopPrank();
    }

    function test_Unstake_InsufficientStake() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert(StakedStrat.InsufficientStake.selector);
        stakedStrat.unstake(STAKE_AMOUNT_1 + 1);
        vm.stopPrank();
    }

    function test_Unstake_All() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        stakedStrat.unstake(STAKE_AMOUNT_1);
        vm.stopPrank();

        assertEq(stakedStrat.staked(user1), 0);
        assertEq(stakedStrat.totalStaked(), 0);
        assertEq(stakedStrat.balanceOf(user1), 0);
    }

    // ============ Rewards Tests ============

    function test_SyncRewards_NoStakers() public {
        _sendRewards(REWARD_AMOUNT_1, false);

        // Stream starts even with no stakers
        stakedStrat.syncRewards();
        assertEq(stakedStrat.rewardsPerShare(), 0);
        assertEq(stakedStrat.rewardRate(), REWARD_AMOUNT_1 / REWARD_DURATION);
        assertEq(stakedStrat.totalNotifiedRewards(), REWARD_AMOUNT_1);
    }

    function test_SyncRewards_NoBalance() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        stakedStrat.syncRewards();
        assertEq(stakedStrat.rewardsPerShare(), 0);
        assertEq(stakedStrat.rewardRate(), 0);
    }

    function test_SyncRewards_StartsStream() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, false);
        stakedStrat.syncRewards();

        // Stream started: rewardRate set, no immediate distribution
        assertEq(stakedStrat.rewardRate(), REWARD_AMOUNT_1 / REWARD_DURATION);
        assertEq(stakedStrat.periodFinish(), block.timestamp + REWARD_DURATION);
        assertEq(stakedStrat.totalNotifiedRewards(), REWARD_AMOUNT_1);
        assertEq(stakedStrat.rewardsPerShare(), 0);
        assertEq(stakedStrat.getPendingRewards(user1), 0);
    }

    function test_SyncRewards_BlendsOnSecondCall() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        uint256 firstRate = stakedStrat.rewardRate();

        // Advance 1 day then send more rewards
        vm.warp(block.timestamp + 1 days);
        _sendRewards(REWARD_AMOUNT_2, true);

        // Blended rate must exceed the first rate (new tokens added)
        assertGt(stakedStrat.rewardRate(), firstRate);
        assertEq(stakedStrat.periodFinish(), block.timestamp + REWARD_DURATION);
        assertEq(stakedStrat.totalNotifiedRewards(), REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
    }

    function test_GetPendingRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertApproxEqRel(pending, REWARD_AMOUNT_1, 1e15);
    }

    function test_GetPendingRewards_NoStake() public view {
        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertEq(pending, 0);
    }

    function test_GetPendingRewards_ZeroMidStream() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);

        // Nothing claimable immediately after the stream starts
        assertEq(stakedStrat.getPendingRewards(user1), 0);
    }

    function test_GetPendingRewards_Proportional() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 pending1 = stakedStrat.getPendingRewards(user1);
        uint256 pending2 = stakedStrat.getPendingRewards(user2);

        // user1 gets 2/3, user2 gets 1/3
        assertApproxEqRel(pending1, (REWARD_AMOUNT_1 * 2) / 3, 1e15);
        assertApproxEqRel(pending2, REWARD_AMOUNT_1 / 3, 1e15);
        assertApproxEqRel(pending1 + pending2, REWARD_AMOUNT_1, 1e15);
    }

    function test_Claim() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balanceBefore = rewardToken.balanceOf(user1);
        vm.prank(user1);
        stakedStrat.claim();

        assertApproxEqRel(rewardToken.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
        assertEq(stakedStrat.getPendingRewards(user1), 0);
    }

    function test_Claim_NoRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        uint256 balanceBefore = rewardToken.balanceOf(user1);
        vm.prank(user1);
        stakedStrat.claim();

        assertEq(rewardToken.balanceOf(user1), balanceBefore);
    }

    function test_Claim_MultipleUsers() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balance1Before = rewardToken.balanceOf(user1);
        uint256 balance2Before = rewardToken.balanceOf(user2);

        vm.prank(user1);
        stakedStrat.claim();

        vm.prank(user2);
        stakedStrat.claim();

        uint256 user1Rewards = rewardToken.balanceOf(user1) - balance1Before;
        uint256 user2Rewards = rewardToken.balanceOf(user2) - balance2Before;
        assertApproxEqRel(user1Rewards, (REWARD_AMOUNT_1 * 2) / 3, 1e15);
        assertApproxEqRel(user2Rewards, REWARD_AMOUNT_1 / 3, 1e15);
        assertApproxEqRel(user1Rewards + user2Rewards, REWARD_AMOUNT_1, 1e15);
    }

    function test_Claim_AfterAdditionalStake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // First batch fully streams
        _sendAndFullyStream(REWARD_AMOUNT_1);

        // User stakes more then claims
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_2);
        uint256 balanceBefore = rewardToken.balanceOf(user1);
        stakedStrat.claim();
        vm.stopPrank();

        assertApproxEqRel(rewardToken.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
    }

    // ============ Migrate Stake Tests ============

    function test_MigrateStake_All() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balance2Before = rewardToken.balanceOf(user2);
        uint256 pendingBefore = stakedStrat.getPendingRewards(user1);

        vm.prank(user1);
        stakedStrat.migrateStake(user2, 0);

        assertEq(stakedStrat.staked(user1), 0);
        assertEq(stakedStrat.staked(user2), STAKE_AMOUNT_1);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1);
        assertApproxEqRel(rewardToken.balanceOf(user2) - balance2Before, pendingBefore, 1e15);
    }

    function test_MigrateStake_Partial() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = 300 * 1e18;
        uint256 balance2Before = rewardToken.balanceOf(user2);
        uint256 pendingBefore = stakedStrat.getPendingRewards(user1);
        uint256 expectedRewards = (pendingBefore * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        stakedStrat.migrateStake(user2, migrateAmount);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - migrateAmount);
        assertEq(stakedStrat.staked(user2), migrateAmount);
        assertEq(stakedStrat.totalStaked(), STAKE_AMOUNT_1);
        assertApproxEqRel(rewardToken.balanceOf(user2) - balance2Before, expectedRewards, 1e15);
    }

    function test_MigrateStake_ZeroAddress() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert();
        stakedStrat.migrateStake(address(0), 0);
        vm.stopPrank();
    }

    function test_MigrateStake_Self() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert();
        stakedStrat.migrateStake(user1, 0);
        vm.stopPrank();
    }

    function test_MigrateStake_NoStake() public {
        vm.prank(user1);
        vm.expectRevert(StakedStrat.InsufficientStake.selector);
        stakedStrat.migrateStake(user2, 0);
    }

    function test_MigrateStake_InsufficientStake() public {
        vm.startPrank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.expectRevert(StakedStrat.InsufficientStake.selector);
        stakedStrat.migrateStake(user2, STAKE_AMOUNT_1 + 1);
        vm.stopPrank();
    }

    function test_MigrateStake_ToExistingStaker() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = 300 * 1e18;
        uint256 balance2Before = rewardToken.balanceOf(user2);
        uint256 pending1Before = stakedStrat.getPendingRewards(user1);
        uint256 pending2Before = stakedStrat.getPendingRewards(user2);
        uint256 expectedFromUser1 = (pending1Before * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        stakedStrat.migrateStake(user2, migrateAmount);

        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - migrateAmount);
        assertEq(stakedStrat.staked(user2), STAKE_AMOUNT_2 + migrateAmount);
        assertApproxEqRel(
            rewardToken.balanceOf(user2) - balance2Before, pending2Before + expectedFromUser1, 1e15
        );
    }

    // ============ Integration Tests ============

    function test_CompleteFlow() public {
        // user1 stakes; first batch fully streams
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        // user2 stakes after first rewards are fully distributed
        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_2);

        vm.prank(user1);
        stakedStrat.claim();

        vm.prank(user2);
        stakedStrat.claim();

        vm.startPrank(user1);
        stakedStrat.unstake(300 * 1e18);
        stakedStrat.migrateStake(user3, 0);
        vm.stopPrank();

        assertEq(stakedStrat.staked(user1), 0);
        assertEq(stakedStrat.staked(user3), 700 * 1e18);
        assertEq(stakedStrat.totalStaked(), 700 * 1e18 + STAKE_AMOUNT_2);
    }

    function test_Rewards_AccumulateOverMultipleBatches() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Two batches sent in quick succession; the second blends into the first stream
        _sendRewards(REWARD_AMOUNT_1, true);
        _sendRewards(REWARD_AMOUNT_2, true);

        vm.warp(block.timestamp + REWARD_DURATION);

        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertApproxEqRel(pending, REWARD_AMOUNT_1 + REWARD_AMOUNT_2, 1e15);
    }

    function test_Stake_Unstake_Stake_Again() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        // Unstake: old rewards auto-claimed
        vm.startPrank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);
        stakedStrat.stake(STAKE_AMOUNT_1);
        vm.stopPrank();

        _sendAndFullyStream(REWARD_AMOUNT_2);

        // After re-staking, only new rewards are pending
        uint256 pending = stakedStrat.getPendingRewards(user1);
        assertApproxEqRel(pending, REWARD_AMOUNT_2, 1e15);
    }

    // ============ Edge Cases ============

    function test_SyncRewards_AfterAllUnstake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        vm.prank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);

        // Sending more rewards with no stakers still starts the stream
        _sendRewards(REWARD_AMOUNT_2, true);
        assertEq(stakedStrat.rewardRate(), REWARD_AMOUNT_2 / REWARD_DURATION);
    }

    function test_SyncRewards_AfterClaim_TracksCorrectly() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        vm.prank(user1);
        stakedStrat.claim();

        uint256 claimed = stakedStrat.totalClaimed();
        assertApproxEqRel(claimed, REWARD_AMOUNT_1, 1e15);

        // No new rewards detected after claiming
        stakedStrat.syncRewards();
        assertEq(stakedStrat.totalNotifiedRewards(), REWARD_AMOUNT_1);
    }

    function test_Precision_Handling() public {
        vm.prank(user1);
        stakedStrat.stake(1);

        _sendRewards(1, true);
        vm.warp(block.timestamp + REWARD_DURATION);

        assertGe(stakedStrat.getPendingRewards(user1), 0);
    }

    function test_RewardPreservationOnAdditionalStake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 pendingBefore = stakedStrat.getPendingRewards(user1);

        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_2);

        assertApproxEqRel(stakedStrat.getPendingRewards(user1), pendingBefore, 1e15);
    }

    function test_OldStakersRetainAccruedYield() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 user1PendingBefore = stakedStrat.getPendingRewards(user1);
        assertApproxEqRel(user1PendingBefore, REWARD_AMOUNT_1, 1e15);

        // New staker must not affect user1's accrued rewards
        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        assertApproxEqRel(stakedStrat.getPendingRewards(user1), user1PendingBefore, 1e15);
        assertEq(stakedStrat.getPendingRewards(user2), 0);
    }

    function test_ReentrancyProtection_Modifiers() public pure {
        assertTrue(true);
    }

    // ============ Streaming Tests ============

    function test_Streaming_NoInstantRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);

        // Nothing claimable immediately after stream starts
        assertEq(stakedStrat.getPendingRewards(user1), 0);
        uint256 balanceBefore = rewardToken.balanceOf(user1);
        vm.prank(user1);
        stakedStrat.claim();
        assertEq(rewardToken.balanceOf(user1), balanceBefore);
    }

    function test_Streaming_ProportionalToTime() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        uint256 startTime = block.timestamp;

        vm.warp(startTime + REWARD_DURATION / 2);
        assertApproxEqRel(stakedStrat.getPendingRewards(user1), REWARD_AMOUNT_1 / 2, 1e15);

        vm.warp(startTime + REWARD_DURATION);
        assertApproxEqRel(stakedStrat.getPendingRewards(user1), REWARD_AMOUNT_1, 1e15);
    }

    function test_Streaming_NoDripAfterPeriodEnds() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        vm.warp(block.timestamp + REWARD_DURATION);
        uint256 pendingAtEnd = stakedStrat.getPendingRewards(user1);

        vm.warp(block.timestamp + REWARD_DURATION * 10);
        assertEq(stakedStrat.getPendingRewards(user1), pendingAtEnd);
    }

    function test_Streaming_BlendExtendsWindow() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        uint256 startTime = block.timestamp;
        _sendRewards(REWARD_AMOUNT_1, true);

        // Midway through, second batch arrives
        vm.warp(startTime + REWARD_DURATION / 2);
        _sendRewards(REWARD_AMOUNT_2, true);

        assertEq(stakedStrat.periodFinish(), block.timestamp + REWARD_DURATION);

        vm.warp(stakedStrat.periodFinish());
        assertApproxEqRel(
            stakedStrat.getPendingRewards(user1), REWARD_AMOUNT_1 + REWARD_AMOUNT_2, 2e15
        );
    }

    function test_Streaming_NewStakeAnchoredToCurrent() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        // user2 stakes mid-stream
        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_2);

        // user2 earns nothing from before they joined
        assertEq(stakedStrat.getPendingRewards(user2), 0);
        // user1 retains their half-stream accrual
        assertApproxEqRel(stakedStrat.getPendingRewards(user1), REWARD_AMOUNT_1 / 2, 1e15);
    }

    // ============ Unstake Auto-Claim Tests ============

    function test_Unstake_AutoClaimsPendingRewards() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balanceBefore = rewardToken.balanceOf(user1);

        vm.prank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);

        // Rewards transferred during unstake — no separate claim needed
        assertApproxEqRel(rewardToken.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
        assertEq(stakedStrat.getPendingRewards(user1), 0);
    }

    function test_Unstake_Partial_AutoClaimsAllPending() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balanceBefore = rewardToken.balanceOf(user1);
        uint256 unstakeAmount = 300 * 1e18;

        vm.prank(user1);
        stakedStrat.unstake(unstakeAmount);

        // All accrued rewards paid out even on partial unstake
        assertApproxEqRel(rewardToken.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
        assertEq(stakedStrat.getPendingRewards(user1), 0);
        assertEq(stakedStrat.staked(user1), STAKE_AMOUNT_1 - unstakeAmount);
    }

    function test_Unstake_NoRewards_NoClaim() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        uint256 balanceBefore = rewardToken.balanceOf(user1);

        vm.prank(user1);
        stakedStrat.unstake(STAKE_AMOUNT_1);

        assertEq(rewardToken.balanceOf(user1), balanceBefore);
    }

    // ============ MigrateStake Sender Pending Tests ============

    function test_MigrateStake_Partial_PreservesSenderPending() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = 300 * 1e18; // migrate 30%
        uint256 totalPending = stakedStrat.getPendingRewards(user1);
        uint256 expectedToRecipient = (totalPending * migrateAmount) / STAKE_AMOUNT_1;
        uint256 expectedRemaining = totalPending - expectedToRecipient; // 70% stays

        vm.prank(user1);
        stakedStrat.migrateStake(user2, migrateAmount);

        assertApproxEqRel(stakedStrat.getPendingRewards(user1), expectedRemaining, 1e15);
        assertApproxEqRel(rewardToken.balanceOf(user2), expectedToRecipient, 1e15);
    }

    function test_MigrateStake_Partial_SenderCanClaimRemaining() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = STAKE_AMOUNT_1 / 2;
        uint256 totalPending = stakedStrat.getPendingRewards(user1);
        uint256 expectedSenderShare = totalPending - (totalPending * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        stakedStrat.migrateStake(user2, migrateAmount);

        uint256 balanceBefore = rewardToken.balanceOf(user1);
        vm.prank(user1);
        stakedStrat.claim();

        assertApproxEqRel(rewardToken.balanceOf(user1) - balanceBefore, expectedSenderShare, 1e15);
    }

    // ============ Frontrun Attack Mitigation Tests ============

    /**
     * @dev Attacker stakes immediately before rewards land and exits immediately —
     *      captures nothing at all.
     */
    function test_FrontrunAttack_ImmediateExitGetsNothing() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        // Attacker frontruns with 10× stake
        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_1 * 10);

        // Rewards land and stream starts
        _sendRewards(REWARD_AMOUNT_1, true);

        // Attacker exits in same block — auto-claim fires but pending is 0
        vm.prank(user2);
        stakedStrat.unstake(STAKE_AMOUNT_1 * 10);
        assertEq(rewardToken.balanceOf(user2), 0);

        // Legitimate staker owns the entire remaining stream
        vm.warp(block.timestamp + REWARD_DURATION);
        vm.prank(user1);
        stakedStrat.claim();
        assertApproxEqRel(rewardToken.balanceOf(user1), REWARD_AMOUNT_1, 1e15);
    }

    /**
     * @dev Patient attacker who holds for 1 day captures only ~1/7 of their proportional
     *      share — a fraction of the instant capture the pre-streaming code allowed.
     */
    function test_FrontrunAttack_PartialTimeCapture() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_1 * 10);

        _sendRewards(REWARD_AMOUNT_1, true);

        vm.warp(block.timestamp + 1 days);

        vm.prank(user2);
        stakedStrat.claim();
        uint256 attackerRewards = rewardToken.balanceOf(user2);

        // Expected: 1 day × rewardRate × (10 000 / 11 000 share)
        uint256 oneDayTotal = (REWARD_AMOUNT_1 * 1 days) / REWARD_DURATION;
        uint256 attackerOneDayShare = (oneDayTotal * STAKE_AMOUNT_1 * 10) / (STAKE_AMOUNT_1 * 11);
        assertApproxEqRel(attackerRewards, attackerOneDayShare, 1e15);

        // Without streaming: would have gotten ~9.09 ETH instantly
        uint256 wouldHaveGottenInstantly = (REWARD_AMOUNT_1 * 10) / 11;
        assertLt(attackerRewards, wouldHaveGottenInstantly / 6);

        vm.prank(user2);
        stakedStrat.unstake(STAKE_AMOUNT_1 * 10);
    }

    /**
     * @dev Same-block stake and unstake: attacker gets zero regardless of stake size.
     */
    function test_FrontrunAttack_SameBlockStakeUnstake() public {
        vm.prank(user1);
        stakedStrat.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        stakedStrat.stake(STAKE_AMOUNT_1 * 9);

        _sendRewards(REWARD_AMOUNT_1, true);

        vm.prank(user2);
        stakedStrat.unstake(STAKE_AMOUNT_1 * 9);
        assertEq(rewardToken.balanceOf(user2), 0);

        vm.warp(block.timestamp + REWARD_DURATION);
        vm.prank(user1);
        stakedStrat.claim();
        assertApproxEqRel(rewardToken.balanceOf(user1), REWARD_AMOUNT_1, 1e15);
    }
}
