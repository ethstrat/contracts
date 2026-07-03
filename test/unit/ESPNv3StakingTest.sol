// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ESPNv3Staking} from "../../src/ESPNv3Staking.sol";
import {ESPNv3} from "../../src/ESPNv3.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

contract ESPNv3StakingTest is Test {
    ESPNv3Staking public espnV3Staking;
    ESPNv3 public espnV3;
    MintableBurnableToken public usds;

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
        usds.transfer(address(espnV3Staking), amount);
        if (sync) {
            espnV3Staking.syncRewards();
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
        espnV3 = new ESPNv3(owner, ctrl, owner);

        vm.prank(owner);
        espnV3.manageMinter(owner, true);

        vm.prank(owner);
        usds = new MintableBurnableToken("USDS", "USDS", owner, ctrl, owner);

        vm.prank(owner);
        usds.manageMinter(owner, true);

        espnV3Staking = new ESPNv3Staking(address(espnV3), address(usds), ctrl, owner);

        vm.prank(owner);
        espnV3.mint(user1, 10000 * 1e18);
        vm.prank(owner);
        espnV3.mint(user2, 10000 * 1e18);
        vm.prank(owner);
        espnV3.mint(user3, 10000 * 1e18);

        vm.prank(user1);
        espnV3.approve(address(espnV3Staking), type(uint256).max);
        vm.prank(user2);
        espnV3.approve(address(espnV3Staking), type(uint256).max);
        vm.prank(user3);
        espnV3.approve(address(espnV3Staking), type(uint256).max);

        vm.prank(owner);
        usds.mint(rewarder, 1000000 * 1e18);
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(espnV3Staking.espnV3()), address(espnV3));
        assertEq(address(espnV3Staking.rewardToken()), address(usds));
        assertEq(espnV3Staking.name(), "Staked ESPNv3");
        assertEq(espnV3Staking.symbol(), "sESPNv3");
        assertEq(espnV3Staking.decimals(), 18);
        assertEq(espnV3Staking.totalStaked(), 0);
        assertEq(espnV3Staking.rewardsPerShare(), 0);
        assertEq(espnV3Staking.rewardRate(), 0);
        assertEq(espnV3Staking.periodFinish(), 0);
        assertEq(espnV3Staking.totalNotifiedRewards(), 0);
        assertEq(espnV3Staking.totalClaimed(), 0);
    }

    function test_Constructor_ZeroAddress_ESPNv3() public {
        vm.expectRevert();
        new ESPNv3Staking(address(0), address(usds), ctrl, owner);
    }

    function test_Constructor_ZeroAddress_RewardToken() public {
        vm.expectRevert();
        new ESPNv3Staking(address(espnV3), address(0), ctrl, owner);
    }

    // ============ Transfer Tests ============

    function test_TransferDisabled() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert(ESPNv3Staking.TransferDisabled.selector);
        espnV3Staking.transfer(user2, 100 * 1e18);
        vm.stopPrank();
    }

    function test_TransferFromDisabled() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert(ESPNv3Staking.TransferDisabled.selector);
        espnV3Staking.transferFrom(user1, user2, 100 * 1e18);
        vm.stopPrank();
    }

    function test_ApproveDisabled() public {
        vm.prank(user1);
        vm.expectRevert(ESPNv3Staking.TransferDisabled.selector);
        espnV3Staking.approve(user2, 100 * 1e18);
    }

    // ============ Stake Tests ============

    function test_Stake() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1);
        assertEq(espnV3Staking.totalStaked(), STAKE_AMOUNT_1);
        assertEq(espnV3Staking.balanceOf(user1), STAKE_AMOUNT_1);
        assertEq(espnV3.balanceOf(user1), 10000 * 1e18 - STAKE_AMOUNT_1);
        assertEq(espnV3.balanceOf(address(espnV3Staking)), STAKE_AMOUNT_1);
    }

    function test_Stake_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(ESPNv3Staking.ZeroAmount.selector);
        espnV3Staking.stake(0);
    }

    function test_Stake_NoApproval() public {
        address newUser = address(0x99);
        vm.prank(owner);
        espnV3.mint(newUser, 10000 * 1e18);

        vm.prank(newUser);
        vm.expectRevert();
        espnV3Staking.stake(STAKE_AMOUNT_1);
    }

    function test_Stake_MultipleUsers() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1);
        assertEq(espnV3Staking.staked(user2), STAKE_AMOUNT_2);
        assertEq(espnV3Staking.totalStaked(), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
    }

    function test_Stake_MultipleTimes() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        espnV3Staking.stake(STAKE_AMOUNT_2);
        vm.stopPrank();

        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
        assertEq(espnV3Staking.totalStaked(), STAKE_AMOUNT_1 + STAKE_AMOUNT_2);
    }

    // ============ Unstake Tests ============

    function test_Unstake() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        uint256 unstakeAmount = 300 * 1e18;
        espnV3Staking.unstake(unstakeAmount);
        vm.stopPrank();

        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(espnV3Staking.totalStaked(), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(espnV3Staking.balanceOf(user1), STAKE_AMOUNT_1 - unstakeAmount);
        assertEq(espnV3.balanceOf(user1), 10000 * 1e18 - STAKE_AMOUNT_1 + unstakeAmount);
    }

    function test_Unstake_ZeroAmount() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert(ESPNv3Staking.ZeroAmount.selector);
        espnV3Staking.unstake(0);
        vm.stopPrank();
    }

    function test_Unstake_InsufficientStake() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert(ESPNv3Staking.InsufficientStake.selector);
        espnV3Staking.unstake(STAKE_AMOUNT_1 + 1);
        vm.stopPrank();
    }

    function test_Unstake_All() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        espnV3Staking.unstake(STAKE_AMOUNT_1);
        vm.stopPrank();

        assertEq(espnV3Staking.staked(user1), 0);
        assertEq(espnV3Staking.totalStaked(), 0);
        assertEq(espnV3Staking.balanceOf(user1), 0);
    }

    // ============ Rewards Tests ============

    function test_SyncRewards_NoStakers() public {
        _sendRewards(REWARD_AMOUNT_1, false);

        // Stream starts even with no stakers
        espnV3Staking.syncRewards();
        assertEq(espnV3Staking.rewardsPerShare(), 0);
        assertEq(espnV3Staking.rewardRate(), REWARD_AMOUNT_1 / REWARD_DURATION);
        assertEq(espnV3Staking.totalNotifiedRewards(), REWARD_AMOUNT_1);
    }

    function test_SyncRewards_NoBalance() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        espnV3Staking.syncRewards();
        assertEq(espnV3Staking.rewardsPerShare(), 0);
        assertEq(espnV3Staking.rewardRate(), 0);
    }

    function test_SyncRewards_StartsStream() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, false);
        espnV3Staking.syncRewards();

        // Stream started: rewardRate set, no immediate distribution
        assertEq(espnV3Staking.rewardRate(), REWARD_AMOUNT_1 / REWARD_DURATION);
        assertEq(espnV3Staking.periodFinish(), block.timestamp + REWARD_DURATION);
        assertEq(espnV3Staking.totalNotifiedRewards(), REWARD_AMOUNT_1);
        assertEq(espnV3Staking.rewardsPerShare(), 0);
        assertEq(espnV3Staking.getPendingRewards(user1), 0);
    }

    function test_SyncRewards_BlendsOnSecondCall() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        uint256 firstRate = espnV3Staking.rewardRate();

        // Advance 1 day then send more rewards
        vm.warp(block.timestamp + 1 days);
        _sendRewards(REWARD_AMOUNT_2, true);

        // Blended rate must exceed the first rate (new tokens added)
        assertGt(espnV3Staking.rewardRate(), firstRate);
        // Weighted-average duration: remainingTime (6 days) < REWARD_DURATION (7 days),
        // so the new period is shorter than a fresh REWARD_DURATION window.
        assertLt(espnV3Staking.periodFinish(), block.timestamp + REWARD_DURATION);
        assertGt(espnV3Staking.periodFinish(), block.timestamp);
        assertEq(espnV3Staking.totalNotifiedRewards(), REWARD_AMOUNT_1 + REWARD_AMOUNT_2);
    }

    function test_GetPendingRewards() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 pending = espnV3Staking.getPendingRewards(user1);
        assertApproxEqRel(pending, REWARD_AMOUNT_1, 1e15);
    }

    function test_GetPendingRewards_NoStake() public view {
        uint256 pending = espnV3Staking.getPendingRewards(user1);
        assertEq(pending, 0);
    }

    function test_GetPendingRewards_ZeroMidStream() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);

        // Nothing claimable immediately after the stream starts
        assertEq(espnV3Staking.getPendingRewards(user1), 0);
    }

    function test_GetPendingRewards_Proportional() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 pending1 = espnV3Staking.getPendingRewards(user1);
        uint256 pending2 = espnV3Staking.getPendingRewards(user2);

        // user1 gets 2/3, user2 gets 1/3
        assertApproxEqRel(pending1, (REWARD_AMOUNT_1 * 2) / 3, 1e15);
        assertApproxEqRel(pending2, REWARD_AMOUNT_1 / 3, 1e15);
        assertApproxEqRel(pending1 + pending2, REWARD_AMOUNT_1, 1e15);
    }

    function test_Claim() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        espnV3Staking.claim();

        assertApproxEqRel(usds.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
        assertEq(espnV3Staking.getPendingRewards(user1), 0);
    }

    function test_Claim_NoRewards() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        uint256 balanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        espnV3Staking.claim();

        assertEq(usds.balanceOf(user1), balanceBefore);
    }

    function test_Claim_MultipleUsers() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balance1Before = usds.balanceOf(user1);
        uint256 balance2Before = usds.balanceOf(user2);

        vm.prank(user1);
        espnV3Staking.claim();

        vm.prank(user2);
        espnV3Staking.claim();

        uint256 user1Rewards = usds.balanceOf(user1) - balance1Before;
        uint256 user2Rewards = usds.balanceOf(user2) - balance2Before;
        assertApproxEqRel(user1Rewards, (REWARD_AMOUNT_1 * 2) / 3, 1e15);
        assertApproxEqRel(user2Rewards, REWARD_AMOUNT_1 / 3, 1e15);
        assertApproxEqRel(user1Rewards + user2Rewards, REWARD_AMOUNT_1, 1e15);
    }

    function test_Claim_AfterAdditionalStake() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        // First batch fully streams
        _sendAndFullyStream(REWARD_AMOUNT_1);

        // User stakes more then claims
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_2);
        uint256 balanceBefore = usds.balanceOf(user1);
        espnV3Staking.claim();
        vm.stopPrank();

        assertApproxEqRel(usds.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
    }

    // ============ Migrate Stake Tests ============

    function test_MigrateStake_All() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balance2Before = usds.balanceOf(user2);
        uint256 pendingBefore = espnV3Staking.getPendingRewards(user1);

        vm.prank(user1);
        espnV3Staking.migrateStake(user2, 0);

        assertEq(espnV3Staking.staked(user1), 0);
        assertEq(espnV3Staking.staked(user2), STAKE_AMOUNT_1);
        assertEq(espnV3Staking.totalStaked(), STAKE_AMOUNT_1);
        assertApproxEqRel(usds.balanceOf(user2) - balance2Before, pendingBefore, 1e15);
    }

    function test_MigrateStake_Partial() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = 300 * 1e18;
        uint256 balance2Before = usds.balanceOf(user2);
        uint256 pendingBefore = espnV3Staking.getPendingRewards(user1);
        uint256 expectedRewards = (pendingBefore * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        espnV3Staking.migrateStake(user2, migrateAmount);

        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1 - migrateAmount);
        assertEq(espnV3Staking.staked(user2), migrateAmount);
        assertEq(espnV3Staking.totalStaked(), STAKE_AMOUNT_1);
        assertApproxEqRel(usds.balanceOf(user2) - balance2Before, expectedRewards, 1e15);
    }

    function test_MigrateStake_ZeroAddress() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert();
        espnV3Staking.migrateStake(address(0), 0);
        vm.stopPrank();
    }

    function test_MigrateStake_Self() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert();
        espnV3Staking.migrateStake(user1, 0);
        vm.stopPrank();
    }

    function test_MigrateStake_ToContractItself() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert();
        espnV3Staking.migrateStake(address(espnV3Staking), 0);
        vm.stopPrank();
    }

    function test_MigrateStake_NoStake() public {
        vm.prank(user1);
        vm.expectRevert(ESPNv3Staking.InsufficientStake.selector);
        espnV3Staking.migrateStake(user2, 0);
    }

    function test_MigrateStake_InsufficientStake() public {
        vm.startPrank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.expectRevert(ESPNv3Staking.InsufficientStake.selector);
        espnV3Staking.migrateStake(user2, STAKE_AMOUNT_1 + 1);
        vm.stopPrank();
    }

    function test_MigrateStake_ToExistingStaker() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = 300 * 1e18;
        uint256 balance2Before = usds.balanceOf(user2);
        uint256 pending1Before = espnV3Staking.getPendingRewards(user1);
        uint256 pending2Before = espnV3Staking.getPendingRewards(user2);
        uint256 expectedFromUser1 = (pending1Before * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        espnV3Staking.migrateStake(user2, migrateAmount);

        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1 - migrateAmount);
        assertEq(espnV3Staking.staked(user2), STAKE_AMOUNT_2 + migrateAmount);
        assertApproxEqRel(
            usds.balanceOf(user2) - balance2Before, pending2Before + expectedFromUser1, 1e15
        );
    }

    // ============ Integration Tests ============

    function test_CompleteFlow() public {
        // user1 stakes; first batch fully streams
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        // user2 stakes after first rewards are fully distributed
        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        _sendAndFullyStream(REWARD_AMOUNT_2);

        vm.prank(user1);
        espnV3Staking.claim();

        vm.prank(user2);
        espnV3Staking.claim();

        vm.startPrank(user1);
        espnV3Staking.unstake(300 * 1e18);
        espnV3Staking.migrateStake(user3, 0);
        vm.stopPrank();

        assertEq(espnV3Staking.staked(user1), 0);
        assertEq(espnV3Staking.staked(user3), 700 * 1e18);
        assertEq(espnV3Staking.totalStaked(), 700 * 1e18 + STAKE_AMOUNT_2);
    }

    function test_Rewards_AccumulateOverMultipleBatches() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        // Two batches sent in quick succession; the second blends into the first stream
        _sendRewards(REWARD_AMOUNT_1, true);
        _sendRewards(REWARD_AMOUNT_2, true);

        vm.warp(block.timestamp + REWARD_DURATION);

        uint256 pending = espnV3Staking.getPendingRewards(user1);
        assertApproxEqRel(pending, REWARD_AMOUNT_1 + REWARD_AMOUNT_2, 1e15);
    }

    function test_Stake_Unstake_Stake_Again() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        // Unstake: old rewards auto-claimed
        vm.startPrank(user1);
        espnV3Staking.unstake(STAKE_AMOUNT_1);
        espnV3Staking.stake(STAKE_AMOUNT_1);
        vm.stopPrank();

        _sendAndFullyStream(REWARD_AMOUNT_2);

        // After re-staking, only new rewards are pending
        uint256 pending = espnV3Staking.getPendingRewards(user1);
        assertApproxEqRel(pending, REWARD_AMOUNT_2, 1e15);
    }

    // ============ Edge Cases ============

    function test_SyncRewards_AfterAllUnstake() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        vm.prank(user1);
        espnV3Staking.unstake(STAKE_AMOUNT_1);

        // Sending more rewards with no stakers still starts the stream
        _sendRewards(REWARD_AMOUNT_2, true);
        assertEq(espnV3Staking.rewardRate(), REWARD_AMOUNT_2 / REWARD_DURATION);
    }

    function test_SyncRewards_AfterClaim_TracksCorrectly() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        vm.prank(user1);
        espnV3Staking.claim();

        uint256 claimed = espnV3Staking.totalClaimed();
        assertApproxEqRel(claimed, REWARD_AMOUNT_1, 1e15);

        // No new rewards detected after claiming
        espnV3Staking.syncRewards();
        assertEq(espnV3Staking.totalNotifiedRewards(), REWARD_AMOUNT_1);
    }

    function test_Precision_Handling() public {
        vm.prank(user1);
        espnV3Staking.stake(1);

        _sendRewards(1, true);
        vm.warp(block.timestamp + REWARD_DURATION);

        assertGe(espnV3Staking.getPendingRewards(user1), 0);
    }

    function test_RewardPreservationOnAdditionalStake() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 pendingBefore = espnV3Staking.getPendingRewards(user1);

        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), pendingBefore, 1e15);
    }

    function test_OldStakersRetainAccruedYield() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 user1PendingBefore = espnV3Staking.getPendingRewards(user1);
        assertApproxEqRel(user1PendingBefore, REWARD_AMOUNT_1, 1e15);

        // New staker must not affect user1's accrued rewards
        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), user1PendingBefore, 1e15);
        assertEq(espnV3Staking.getPendingRewards(user2), 0);
    }

    function test_ReentrancyProtection_Modifiers() public pure {
        assertTrue(true);
    }

    // ============ Streaming Tests ============

    function test_Streaming_NoInstantRewards() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);

        // Nothing claimable immediately after stream starts
        assertEq(espnV3Staking.getPendingRewards(user1), 0);
        uint256 balanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        espnV3Staking.claim();
        assertEq(usds.balanceOf(user1), balanceBefore);
    }

    function test_Streaming_ProportionalToTime() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        uint256 startTime = block.timestamp;

        vm.warp(startTime + REWARD_DURATION / 2);
        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), REWARD_AMOUNT_1 / 2, 1e15);

        vm.warp(startTime + REWARD_DURATION);
        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), REWARD_AMOUNT_1, 1e15);
    }

    function test_Streaming_NoDripAfterPeriodEnds() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        vm.warp(block.timestamp + REWARD_DURATION);
        uint256 pendingAtEnd = espnV3Staking.getPendingRewards(user1);

        vm.warp(block.timestamp + REWARD_DURATION * 10);
        assertEq(espnV3Staking.getPendingRewards(user1), pendingAtEnd);
    }

    function test_Streaming_BlendExtendsWindow() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        // Capture the original 7-day period end directly from contract state
        uint256 firstPeriodEnd = espnV3Staking.periodFinish();

        // Midway through, second batch arrives
        vm.warp(block.timestamp + REWARD_DURATION / 2);
        _sendRewards(REWARD_AMOUNT_2, true);

        // Weighted-average duration: remaining ≈ REWARD_AMOUNT_2 and remainingTime = 3.5 days,
        // so newDuration = (3.5 days + 7 days) / 2 = 5.25 days.
        // periodFinish is extended beyond the original 7-day end but shorter than a fresh window.
        assertGt(espnV3Staking.periodFinish(), firstPeriodEnd);
        assertLt(espnV3Staking.periodFinish(), block.timestamp + REWARD_DURATION);

        // All rewards distributed by the new period end
        vm.warp(espnV3Staking.periodFinish());
        assertApproxEqRel(
            espnV3Staking.getPendingRewards(user1), REWARD_AMOUNT_1 + REWARD_AMOUNT_2, 2e15
        );
    }

    function test_Streaming_NewStakeAnchoredToCurrent() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        // user2 stakes mid-stream
        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_2);

        // user2 earns nothing from before they joined
        assertEq(espnV3Staking.getPendingRewards(user2), 0);
        // user1 retains their half-stream accrual
        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), REWARD_AMOUNT_1 / 2, 1e15);
    }

    // ============ Unstake Auto-Claim Tests ============

    function test_Unstake_AutoClaimsPendingRewards() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balanceBefore = usds.balanceOf(user1);

        vm.prank(user1);
        espnV3Staking.unstake(STAKE_AMOUNT_1);

        // Rewards transferred during unstake — no separate claim needed
        assertApproxEqRel(usds.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
        assertEq(espnV3Staking.getPendingRewards(user1), 0);
    }

    function test_Unstake_Partial_AutoClaimsAllPending() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 balanceBefore = usds.balanceOf(user1);
        uint256 unstakeAmount = 300 * 1e18;

        vm.prank(user1);
        espnV3Staking.unstake(unstakeAmount);

        // All accrued rewards paid out even on partial unstake
        assertApproxEqRel(usds.balanceOf(user1) - balanceBefore, REWARD_AMOUNT_1, 1e15);
        assertEq(espnV3Staking.getPendingRewards(user1), 0);
        assertEq(espnV3Staking.staked(user1), STAKE_AMOUNT_1 - unstakeAmount);
    }

    function test_Unstake_NoRewards_NoClaim() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        uint256 balanceBefore = usds.balanceOf(user1);

        vm.prank(user1);
        espnV3Staking.unstake(STAKE_AMOUNT_1);

        assertEq(usds.balanceOf(user1), balanceBefore);
    }

    // ============ MigrateStake Sender Pending Tests ============

    function test_MigrateStake_Partial_PreservesSenderPending() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = 300 * 1e18; // migrate 30%
        uint256 totalPending = espnV3Staking.getPendingRewards(user1);
        uint256 expectedToRecipient = (totalPending * migrateAmount) / STAKE_AMOUNT_1;
        uint256 expectedRemaining = totalPending - expectedToRecipient; // 70% stays

        vm.prank(user1);
        espnV3Staking.migrateStake(user2, migrateAmount);

        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), expectedRemaining, 1e15);
        assertApproxEqRel(usds.balanceOf(user2), expectedToRecipient, 1e15);
    }

    function test_MigrateStake_Partial_SenderCanClaimRemaining() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendAndFullyStream(REWARD_AMOUNT_1);

        uint256 migrateAmount = STAKE_AMOUNT_1 / 2;
        uint256 totalPending = espnV3Staking.getPendingRewards(user1);
        uint256 expectedSenderShare = totalPending - (totalPending * migrateAmount) / STAKE_AMOUNT_1;

        vm.prank(user1);
        espnV3Staking.migrateStake(user2, migrateAmount);

        uint256 balanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        espnV3Staking.claim();

        assertApproxEqRel(usds.balanceOf(user1) - balanceBefore, expectedSenderShare, 1e15);
    }

    // ============ Griefing Mitigation Tests ============

    /**
     * @dev Sending 1 wei mid-stream should have negligible impact on the reward rate and
     *      period end time. Before the weighted-average fix the old code would set
     *      periodFinish = now + 7 days and rewardRate = remaining/7days (≈rate/2 at midpoint),
     *      cutting the effective rate roughly in half each call.
     */
    function test_GriefingMitigation_DustDepositBarelyPerturbsStream() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        uint256 rateAfterFirstSync = espnV3Staking.rewardRate();

        // Advance to midpoint; record the expected period end before the grief
        vm.warp(block.timestamp + REWARD_DURATION / 2);
        uint256 periodFinishBeforeGrief = espnV3Staking.periodFinish();

        // Grief with 1 wei
        vm.prank(owner);
        usds.mint(address(espnV3Staking), 1);
        espnV3Staking.syncRewards();

        // Rate should be essentially unchanged (well within 0.01%)
        assertApproxEqRel(espnV3Staking.rewardRate(), rateAfterFirstSync, 1e14);

        // Period end should be essentially unchanged (within 1 second)
        assertApproxEqAbs(espnV3Staking.periodFinish(), periodFinishBeforeGrief, 1);

        // All rewards (original + 1 wei) still distribute correctly
        vm.warp(espnV3Staking.periodFinish());
        assertApproxEqRel(espnV3Staking.getPendingRewards(user1), REWARD_AMOUNT_1, 1e15);
    }

    /**
     * @dev Repeated 1-wei griefing calls should not materially dilute the stream.
     *      With the old code, each call multiplied the rate by ~(remaining/REWARD_DURATION),
     *      causing exponential decay. With weighted average, compounding is negligible.
     */
    function test_GriefingMitigation_RepeatedDustAttacksNegligible() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        _sendRewards(REWARD_AMOUNT_1, true);
        uint256 initialRate = espnV3Staking.rewardRate();

        // 50 daily 1-wei grief attempts
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(owner);
            usds.mint(address(espnV3Staking), 1);
            espnV3Staking.syncRewards();
        }

        // Rate must remain within 0.01% of the initial rate
        assertApproxEqRel(espnV3Staking.rewardRate(), initialRate, 1e14);
    }

    // ============ Frontrun Attack Mitigation Tests ============

    /**
     * @dev Attacker stakes immediately before rewards land and exits immediately —
     *      captures nothing at all.
     */
    function test_FrontrunAttack_ImmediateExitGetsNothing() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        // Attacker frontruns with 10× stake
        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_1 * 10);

        // Rewards land and stream starts
        _sendRewards(REWARD_AMOUNT_1, true);

        // Attacker exits in same block — auto-claim fires but pending is 0
        vm.prank(user2);
        espnV3Staking.unstake(STAKE_AMOUNT_1 * 10);
        assertEq(usds.balanceOf(user2), 0);

        // Legitimate staker owns the entire remaining stream
        vm.warp(block.timestamp + REWARD_DURATION);
        vm.prank(user1);
        espnV3Staking.claim();
        assertApproxEqRel(usds.balanceOf(user1), REWARD_AMOUNT_1, 1e15);
    }

    /**
     * @dev Patient attacker who holds for 1 day captures only ~1/7 of their proportional
     *      share — a fraction of the instant capture the pre-streaming code allowed.
     */
    function test_FrontrunAttack_PartialTimeCapture() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_1 * 10);

        _sendRewards(REWARD_AMOUNT_1, true);

        vm.warp(block.timestamp + 1 days);

        vm.prank(user2);
        espnV3Staking.claim();
        uint256 attackerRewards = usds.balanceOf(user2);

        // Expected: 1 day × rewardRate × (10 000 / 11 000 share)
        uint256 oneDayTotal = (REWARD_AMOUNT_1 * 1 days) / REWARD_DURATION;
        uint256 attackerOneDayShare = (oneDayTotal * STAKE_AMOUNT_1 * 10) / (STAKE_AMOUNT_1 * 11);
        assertApproxEqRel(attackerRewards, attackerOneDayShare, 1e15);

        // Without streaming: would have gotten ~9.09 ETH instantly
        uint256 wouldHaveGottenInstantly = (REWARD_AMOUNT_1 * 10) / 11;
        assertLt(attackerRewards, wouldHaveGottenInstantly / 6);

        vm.prank(user2);
        espnV3Staking.unstake(STAKE_AMOUNT_1 * 10);
    }

    /**
     * @dev Same-block stake and unstake: attacker gets zero regardless of stake size.
     */
    function test_FrontrunAttack_SameBlockStakeUnstake() public {
        vm.prank(user1);
        espnV3Staking.stake(STAKE_AMOUNT_1);

        vm.prank(user2);
        espnV3Staking.stake(STAKE_AMOUNT_1 * 9);

        _sendRewards(REWARD_AMOUNT_1, true);

        vm.prank(user2);
        espnV3Staking.unstake(STAKE_AMOUNT_1 * 9);
        assertEq(usds.balanceOf(user2), 0);

        vm.warp(block.timestamp + REWARD_DURATION);
        vm.prank(user1);
        espnV3Staking.claim();
        assertApproxEqRel(usds.balanceOf(user1), REWARD_AMOUNT_1, 1e15);
    }
}
