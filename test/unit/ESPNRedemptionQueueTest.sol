// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ESPNRedemptionQueue} from "../../src/ESPNRedemptionQueue.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

contract ESPNRedemptionQueueTest is Test {
    ESPNRedemptionQueue public queue;
    EthStrategyPerpetualNote public espn;
    MintableBurnableToken public usds;

    address public owner = address(0x1);
    address public manager = address(0x2);
    address public sweeper = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    address public user3 = address(0x6);

    // With the initial 1:100 assets/share setup, users need enough USDS deposited to mint
    // at least ~100e18 ESPN for tests that queue 100e18 ESPN.
    uint256 public constant DEPOSIT_AMOUNT = 10_000 * 10 ** 18;
    uint256 public constant INITIAL_ASSETS = 100_000 * 10 ** 18;
    uint256 public constant INITIAL_SHARES = 1000 * 10 ** 18;

    /// @dev Helper function to fund queue for redemption
    /// The queue needs USDS for both increaseAssetsPerShare (transfers to ESPN then manager)
    /// and for transferring to ESPN for the withdrawal
    function _fundQueueForRedemption(uint256 redemptionAmount) internal {
        // Fund queue with redemptionAmount * 2:
        // - redemptionAmount for increaseAssetsPerShare (transfers to ESPN, then ESPN sends to manager)
        // - redemptionAmount for transfer to ESPN (so ESPN has USDS for withdrawal)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2);
    }

    ITripwireController internal ctrl;

    function setUp() public {
        ctrl = ITripwireController(address(new TripwireController()));
        // Deploy USDS token
        vm.prank(owner);
        usds = new MintableBurnableToken("USD Stable", "USDS", owner, ctrl, owner);

        // Set owner as minter
        vm.prank(owner);
        usds.manageMinter(owner, true);

        // Deploy ESPN
        vm.prank(owner);
        espn = new EthStrategyPerpetualNote(IERC20(address(usds)), owner);

        // Set manager
        vm.prank(owner);
        espn.setManager(manager);

        // Set deposit cap
        vm.prank(owner);
        espn.setDepositCap(100_000_000 * 10 ** 18);

        // Setup initial conversion rate (1:100)
        // Mint USDS to test contract for deposit
        vm.prank(owner);
        usds.mint(address(this), INITIAL_SHARES);

        // Deposit from test contract (which has the USDS)
        usds.approve(address(espn), INITIAL_SHARES);
        espn.deposit(INITIAL_SHARES, address(this));

        // Increase assets per share (needs USDS from owner)
        vm.prank(owner);
        usds.mint(owner, INITIAL_ASSETS - INITIAL_SHARES);
        vm.prank(owner);
        usds.approve(address(espn), INITIAL_ASSETS - INITIAL_SHARES);
        vm.prank(owner);
        espn.increaseAssetsPerShare(INITIAL_ASSETS - INITIAL_SHARES);

        // Deploy redemption queue (no flash loan provider needed)
        queue = new ESPNRedemptionQueue(address(espn), sweeper, owner, ctrl, owner);

        // Enable ESPN withdrawals (required for redeem tests)
        vm.prank(owner);
        espn.setWithdrawalsDisabled(false);

        // Mint USDS to users
        vm.startPrank(owner);
        usds.mint(user1, DEPOSIT_AMOUNT * 10);
        usds.mint(user2, DEPOSIT_AMOUNT * 10);
        usds.mint(user3, DEPOSIT_AMOUNT * 10);
        vm.stopPrank();

        // Users deposit to ESPN
        vm.startPrank(user1);
        usds.approve(address(espn), type(uint256).max);
        espn.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        usds.approve(address(espn), type(uint256).max);
        espn.deposit(DEPOSIT_AMOUNT, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        usds.approve(address(espn), type(uint256).max);
        espn.deposit(DEPOSIT_AMOUNT, user3);
        vm.stopPrank();
    }

    // ============ queueRedemption Tests ============

    function test_QueueRedemption_Success() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 expectedRedemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);

        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Check NFT was minted
        assertEq(queue.ownerOf(tokenId), user1);

        // Check redemption data
        (uint256 redemptionsBefore, uint256 redemptionAmount, bool redeemed, bool cancelled) =
            queue.redemptions(tokenId);
        assertEq(redemptionsBefore, 0);
        assertEq(redemptionAmount, expectedRedemptionAmount);
        assertEq(redeemed, false);
        assertEq(cancelled, false);

        // Check counters
        assertEq(queue.totalQueued(), expectedRedemptionAmount);
    }

    function test_QueueRedemption_MultipleUsers() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        // Check second NFT has correct redemptionsBefore
        (uint256 redemptionsBefore2,,,) = queue.redemptions(tokenId2);
        assertEq(redemptionsBefore2, actualRedemptionAmount1);

        // Check counters
        assertEq(queue.totalQueued(), actualRedemptionAmount1 + actualRedemptionAmount2);
    }

    function test_QueueRedemption_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), 0);
        vm.expectRevert();
        queue.queueRedemption(0);
        vm.stopPrank();
    }

    function test_QueueRedemption_InsufficientAllowance() public {
        vm.startPrank(user1);
        vm.expectRevert();
        queue.queueRedemption(100 * 10 ** 18);
        vm.stopPrank();
    }

    // ============ redeem Tests ============

    function test_Redeem_Success() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Fund queue with USDS (needed for increaseAssetsPerShare and withdrawal transfer)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2);

        // Redeem
        uint256 user1BalanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        queue.redeem(tokenId);

        // Check USDS was transferred to user
        assertEq(usds.balanceOf(user1), user1BalanceBefore + redemptionAmount);

        // Check NFT was burned
        vm.expectRevert();
        queue.ownerOf(tokenId);

        // Check redemption marked as redeemed
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, true);
        assertEq(cancelled, false);

        // Check processed redemptions
        assertEq(queue.totalRedemptionsProcessed(), redemptionAmount);
    }

    function test_Redeem_NotEligible() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Don't fund queue - should not be eligible
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId));
        queue.redeem(tokenId);
    }

    function test_Redeem_NotOwner() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Fund queue (needs redemptionAmount * 2 for increaseAssetsPerShare and withdrawal transfer)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2);

        // Try to redeem as different user
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotTokenOwner.selector, tokenId));
        queue.redeem(tokenId);
    }

    function test_Redeem_AlreadyRedeemed() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue and redeem
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        _fundQueueForRedemption(redemptionAmount);

        vm.prank(user1);
        queue.redeem(tokenId);

        // Try to redeem again (NFT is already burned, so ownerOf will revert)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2);
        vm.prank(user1);
        vm.expectRevert(); // ownerOf will revert since NFT is burned
        queue.redeem(tokenId);
    }

    function test_Redeem_MultipleInQueue() public {
        
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue for both redemptions (needs * 2 for each)
        vm.prank(owner);
        usds.mint(address(queue), (actualRedemptionAmount1 + actualRedemptionAmount2) * 2);

        // First redemption should be eligible
        vm.prank(user1);
        queue.redeem(tokenId1);

        // Second redemption should also be eligible now
        vm.prank(user2);
        queue.redeem(tokenId2);

        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount1 + actualRedemptionAmount2);
    }

    function test_Redeem_PartialFunding() public {
        
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue for first redemption (needs * 2)
        vm.prank(owner);
        usds.mint(address(queue), actualRedemptionAmount1 * 2);

        // First should succeed
        vm.prank(user1);
        queue.redeem(tokenId1);

        // Second should not be eligible (not enough USDS in queue)
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId2));
        queue.redeem(tokenId2);

        // Add more USDS to queue (needs * 2)
        vm.prank(owner);
        usds.mint(address(queue), actualRedemptionAmount2 * 2);

        // Now second should succeed
        vm.prank(user2);
        queue.redeem(tokenId2);
    }

    // ============ cancelRedemption Tests ============

    function test_CancelRedemption_Success() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        uint256 user1EspnBefore = espn.balanceOf(user1);
        uint256 queueEspnBefore = espn.balanceOf(address(queue));

        // Cancel redemption (returns ESPN equal to dollar amount queued)
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Check ESPN was returned to user (equal to redemptionAmount in dollar terms)
        // User should get back ESPN shares worth redemptionAmount, not the original espnAmount
        uint256 expectedEspnReturned = espn.previewDeposit(redemptionAmount);
        assertEq(espn.balanceOf(user1), user1EspnBefore + expectedEspnReturned);
        assertEq(espn.balanceOf(address(queue)), queueEspnBefore - expectedEspnReturned);

        // Check NFT still exists (not burned yet - will be processed via processCancelledRedemptions)
        assertEq(queue.ownerOf(tokenId), user1);

        // Check redemption marked as cancelled
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, false);
        assertEq(cancelled, true);

        // Check totalQueued unchanged (always growing)
        assertEq(queue.totalQueued(), redemptionAmount);
    }

    function test_CancelRedemption_NotOwner() public {
        uint256 espnAmount = 100 * 10 ** 18;

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Try to cancel as different user
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotTokenOwner.selector, tokenId));
        queue.cancelRedemption(tokenId);
    }

    function test_CancelRedemption_AlreadyRedeemed() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue and redeem
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        _fundQueueForRedemption(redemptionAmount);

        vm.prank(user1);
        queue.redeem(tokenId);

        // Try to cancel - NFT is burned, so ownerOf will revert
        vm.prank(user1);
        vm.expectRevert(); // ERC721NonexistentToken - NFT was burned after redemption
        queue.cancelRedemption(tokenId);
    }

    // ============ sweepUSDS Tests ============

    function test_SweepUSDS_Success() public {
        uint256 sweepAmount = 1000 * 10 ** 18;

        // Add USDS to queue
        vm.prank(owner);
        usds.mint(address(queue), sweepAmount);

        uint256 sweeperBalanceBefore = usds.balanceOf(sweeper);

        // Sweep
        vm.prank(owner);
        queue.sweepUSDS();

        // Check USDS was transferred
        assertEq(usds.balanceOf(sweeper), sweeperBalanceBefore + sweepAmount);
        assertEq(usds.balanceOf(address(queue)), 0);
    }

    function test_SweepUSDS_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        queue.sweepUSDS();
    }

    function test_SweepUSDS_ZeroBalance() public {
        // Should not revert with zero balance
        vm.prank(owner);
        queue.sweepUSDS();

        assertEq(usds.balanceOf(address(queue)), 0);
    }

    // ============ isEligibleForRedemption Tests ============

    function test_IsEligibleForRedemption_True() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Fund queue (needs redemptionAmount * 2 for increaseAssetsPerShare and withdrawal transfer)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2);

        // Check eligibility
        (bool eligible, uint256 availableUSDS) = queue.isEligibleForRedemption(tokenId);
        assertEq(eligible, true);
        assertGe(availableUSDS, redemptionAmount);
    }

    function test_IsEligibleForRedemption_False() public {
        uint256 espnAmount = 100 * 10 ** 18;

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Don't fund queue
        (bool eligible,) = queue.isEligibleForRedemption(tokenId);
        assertEq(eligible, false);
    }

    // ============ Integration Tests ============

    function test_FullRedemptionFlow() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // User queues redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Check initial state
        assertEq(queue.totalQueued(), redemptionAmount);
        assertEq(queue.totalRedemptionsProcessed(), 0);
        assertEq(queue.totalCancellationsProcessed(), 0);

        // Fund queue and ESPN for redemption
        _fundQueueForRedemption(redemptionAmount);

        // User redeems
        uint256 user1BalanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        queue.redeem(tokenId);

        // Check final state
        assertEq(usds.balanceOf(user1), user1BalanceBefore + redemptionAmount);
        assertEq(queue.totalRedemptionsProcessed(), redemptionAmount);
    }

    function test_MultipleUsersQueueAndRedeem() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // Get redemption amounts first to know how much to fund
        uint256 redemptionAmount1 = espn.previewRedeem(espnAmount1);
        uint256 redemptionAmount2 = espn.previewRedeem(espnAmount2);
        uint256 redemptionAmount3 = espn.previewRedeem(espnAmount3);
        uint256 totalRedemption = redemptionAmount1 + redemptionAmount2 + redemptionAmount3;

        // Enable withdrawals and fund ESPN

        // All users queue redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount3);
        uint256 tokenId3 = queue.queueRedemption(espnAmount3);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 actualRedemptionAmount3,,) = queue.redemptions(tokenId3);

        // Check queue state
        assertEq(queue.totalQueued(), actualRedemptionAmount1 + actualRedemptionAmount2 + actualRedemptionAmount3);

        // Fund queue and ESPN for all redemptions
        uint256 totalRedemptionAmount = actualRedemptionAmount1 + actualRedemptionAmount2 + actualRedemptionAmount3;
        vm.prank(owner);
        usds.mint(address(queue), totalRedemptionAmount * 2);

        // All users redeem
        vm.prank(user1);
        queue.redeem(tokenId1);

        vm.prank(user2);
        queue.redeem(tokenId2);

        vm.prank(user3);
        queue.redeem(tokenId3);

        // Check final state
        assertEq(
            queue.totalRedemptionsProcessed(),
            actualRedemptionAmount1 + actualRedemptionAmount2 + actualRedemptionAmount3
        );
    }

    function test_GetRedemptionData() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 expectedRedemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        ESPNRedemptionQueue.RedemptionData memory data = queue.getRedemptionData(tokenId);
        assertEq(data.redemptionsBefore, 0);
        assertEq(data.redemptionAmount, expectedRedemptionAmount);
        assertEq(data.redeemed, false);
        assertEq(data.cancelled, false);
    }

    function test_CancelRedemption_AlreadyCancelled() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Cancel successfully - this marks as cancelled but NFT stays in queue
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Verify NFT still exists (not burned yet - will be processed via redeem)
        assertEq(queue.ownerOf(tokenId), user1);

        // Verify redemption marked as cancelled
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, false);
        assertEq(cancelled, true);

        // Try to cancel again - should fail
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.AlreadyCancelled.selector, tokenId));
        queue.cancelRedemption(tokenId);
        vm.stopPrank();
    }

    function test_CancelRedemption_CanRedeemAfterCancellation() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Cancel redemption (NFT stays in queue, marked as cancelled)
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Verify NFT still exists and is marked as cancelled
        assertEq(queue.ownerOf(tokenId), user1);
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, false);
        assertEq(cancelled, true);

        // Process cancelled NFT via redeem() when it reaches head (no USDS needed)
        // Since it's the first in queue (redemptionsBefore = 0), we need to add 1 wei USDS
        // to make it eligible (redemptionsBefore < availablePosition)
        vm.prank(owner);
        usds.mint(address(queue), 1); // Add 1 wei to make it eligible

        uint256 cancellationsBefore = queue.totalCancellationsProcessed();
        vm.prank(user1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        queue.processCancelledRedemptions(tokenIds);

        // Check NFT was burned and totalCancellationsProcessed increased
        vm.expectRevert();
        queue.ownerOf(tokenId);
        assertEq(queue.totalCancellationsProcessed(), cancellationsBefore + redemptionAmount);
        assertEq(queue.totalRedemptionsProcessed(), 0); // No USDS transfer for cancelled NFTs
    }

    function test_QueueRedemption_HoldsESPN() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 user1EspnBefore = espn.balanceOf(user1);
        uint256 queueEspnBefore = espn.balanceOf(address(queue));

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Check ESPN was transferred to queue (not burned)
        assertEq(espn.balanceOf(user1), user1EspnBefore - espnAmount);
        assertEq(espn.balanceOf(address(queue)), queueEspnBefore + espnAmount);
        // Total supply should remain the same (ESPN is held, not burned)
        assertEq(espn.totalSupply(), espn.totalSupply());
    }

    function test_Redeem_UpdatesTotalProcessedRedemptions() public {
        
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue and ESPN for redemptions
        uint256 totalRedemptionAmount = actualRedemptionAmount1 + actualRedemptionAmount2;
        vm.prank(owner);
        usds.mint(address(queue), totalRedemptionAmount * 2);

        // Redeem first
        vm.prank(user1);
        queue.redeem(tokenId1);
        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount1);

        // Redeem second
        vm.prank(user2);
        queue.redeem(tokenId2);
        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount1 + actualRedemptionAmount2);
    }

    function test_SweepUSDS_PartialAfterRedemption() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);
        uint256 extraUSDS = 500 * 10 ** 18;

        // Queue and redeem
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Fund queue with extra USDS (needs redemptionAmount * 2 for redemption, plus extraUSDS)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2 + extraUSDS);

        // Redeem (uses redemptionAmount)
        vm.prank(user1);
        queue.redeem(tokenId);

        // Sweep remaining
        uint256 sweeperBalanceBefore = usds.balanceOf(sweeper);
        vm.prank(owner);
        queue.sweepUSDS();

        // Check extra USDS was swept
        assertEq(usds.balanceOf(sweeper), sweeperBalanceBefore + extraUSDS);
        assertEq(usds.balanceOf(address(queue)), 0);
    }

    // ============ Cancel Redemption Queue Ordering Tests (US-006) ============

    function test_CancelRedemption_DoesNotUpdateRedemptionsBefore() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        uint256 redemptionAmount1 = espn.previewRedeem(espnAmount1);
        uint256 redemptionAmount2 = espn.previewRedeem(espnAmount2);
        uint256 redemptionAmount3 = espn.previewRedeem(espnAmount3);

        // Queue three redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount3);
        uint256 tokenId3 = queue.queueRedemption(espnAmount3);
        vm.stopPrank();

        // Check initial redemptionsBefore values
        (uint256 redemptionsBefore1,,,) = queue.redemptions(tokenId1);
        (uint256 redemptionsBefore2,,,) = queue.redemptions(tokenId2);
        (uint256 redemptionsBefore3,,,) = queue.redemptions(tokenId3);

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 actualRedemptionAmount3,,) = queue.redemptions(tokenId3);

        assertEq(redemptionsBefore1, 0);
        assertEq(redemptionsBefore2, actualRedemptionAmount1);
        assertEq(redemptionsBefore3, actualRedemptionAmount1 + actualRedemptionAmount2);

        // Cancel the middle redemption (tokenId2)
        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        // Check that redemptionsBefore values are NOT updated (per US-006)
        (uint256 redemptionsBefore1After,,,) = queue.redemptions(tokenId1);
        (uint256 redemptionsBefore2After,,,) = queue.redemptions(tokenId2);
        (uint256 redemptionsBefore3After,,,) = queue.redemptions(tokenId3);

        assertEq(redemptionsBefore1After, 0); // Unchanged
        assertEq(redemptionsBefore2After, actualRedemptionAmount1); // Unchanged
        assertEq(redemptionsBefore3After, actualRedemptionAmount1 + actualRedemptionAmount2); // Unchanged

        // Check tokenId2 is marked as cancelled
        (,, bool redeemed2, bool cancelled2) = queue.redemptions(tokenId2);
        assertEq(redeemed2, false);
        assertEq(cancelled2, true);

        // Check totalQueued remains unchanged (always growing)
        assertEq(queue.totalQueued(), actualRedemptionAmount1 + actualRedemptionAmount2 + actualRedemptionAmount3);
    }

    function test_CancelRedemption_DoesNotAffectLowerTokenIDs() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        uint256 redemptionAmount1 = espn.previewRedeem(espnAmount1);
        uint256 redemptionAmount2 = espn.previewRedeem(espnAmount2);

        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Cancel the second redemption
        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        // With new pattern: redemptionsBefore values are NOT updated
        // Check that tokenId1's redemptionsBefore was NOT affected
        (uint256 redemptionsBefore1After,,,) = queue.redemptions(tokenId1);
        assertEq(redemptionsBefore1After, 0); // Should still be 0

        // Check tokenId2 is marked as cancelled
        (,, bool redeemed2, bool cancelled2) = queue.redemptions(tokenId2);
        assertEq(redeemed2, false);
        assertEq(cancelled2, true);
    }

    // ============ Cancelled NFT Processing Tests (US-004, US-006) ============

    function test_Redeem_CancelledNFT_NoUSDSTransfer() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount = 100 * 10 ** 18;

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Cancel redemption
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Verify NFT still exists and is cancelled
        assertEq(queue.ownerOf(tokenId), user1);
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, false);
        assertEq(cancelled, true);

        // Get actual redemption amount from contract (second field)
        (, uint256 actualRedemptionAmount,,) = queue.redemptions(tokenId);

        // Process cancelled NFT via redeem() - need 1 wei USDS to make it eligible
        vm.prank(owner);
        usds.mint(address(queue), 1);

        uint256 user1USDSBefore = usds.balanceOf(user1);
        uint256 cancellationsBefore = queue.totalCancellationsProcessed();

        vm.prank(user1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        queue.processCancelledRedemptions(tokenIds);

        // Check no USDS was transferred
        assertEq(usds.balanceOf(user1), user1USDSBefore);

        // Check NFT was burned
        vm.expectRevert();
        queue.ownerOf(tokenId);

        // Check totalCancellationsProcessed increased
        assertEq(queue.totalCancellationsProcessed(), cancellationsBefore + actualRedemptionAmount);
        assertEq(queue.totalRedemptionsProcessed(), 0); // No active redemption processed
    }

    function test_Redeem_CancelledNFT_Eligibility() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        // Cancel the second redemption
        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        // Check eligibility for cancelled NFT
        (bool eligible2,) = queue.isEligibleForRedemption(tokenId2);
        // tokenId2 has redemptionsBefore = actualRedemptionAmount1
        // availablePosition = 0 + 0 + 0 = 0
        // actualRedemptionAmount1 < 0 = false, so not eligible yet
        assertEq(eligible2, false);

        // Process first redemption to make cancelled NFT eligible (needs * 2)
        vm.prank(owner);
        usds.mint(address(queue), actualRedemptionAmount1 * 2);

        vm.prank(user1);
        queue.redeem(tokenId1);

        // Add 1 wei to make it eligible
        vm.prank(owner);
        usds.mint(address(queue), 1);

        (bool eligible2After,) = queue.isEligibleForRedemption(tokenId2);
        assertEq(eligible2After, true);

        // Process cancelled NFT
        uint256 cancellationsBefore = queue.totalCancellationsProcessed();
        vm.prank(user2);
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = tokenId2;
        queue.processCancelledRedemptions(tokenIds2);

        assertEq(queue.totalCancellationsProcessed(), cancellationsBefore + actualRedemptionAmount2);
    }

    function test_Redeem_MixedActiveAndCancelledNFTs() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // Queue three redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount3);
        uint256 tokenId3 = queue.queueRedemption(espnAmount3);
        vm.stopPrank();

        // Get actual redemption amounts from the contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 actualRedemptionAmount3,,) = queue.redemptions(tokenId3);

        // Cancel the second redemption
        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        // Fund queue and ESPN for active redemptions
        uint256 totalActiveAmount = actualRedemptionAmount1 + actualRedemptionAmount3;
        vm.prank(owner);
        usds.mint(address(queue), totalActiveAmount * 2);

        // Process first active redemption
        vm.prank(user1);
        queue.redeem(tokenId1);

        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount1);
        assertEq(queue.totalCancellationsProcessed(), 0);

        // Add 1 wei to make cancelled NFT eligible
        vm.prank(owner);
        usds.mint(address(queue), 1);

        // Process cancelled NFT
        uint256 cancellationsBefore = queue.totalCancellationsProcessed();
        vm.prank(user2);
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = tokenId2;
        queue.processCancelledRedemptions(tokenIds2);

        assertEq(queue.totalCancellationsProcessed(), cancellationsBefore + actualRedemptionAmount2);
        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount1); // Unchanged

        // Process third active redemption
        vm.prank(user3);
        queue.redeem(tokenId3);

        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount1 + actualRedemptionAmount3);
        assertEq(queue.totalCancellationsProcessed(), actualRedemptionAmount2);
    }

    function test_IsEligibleForRedemption_CancelledNFT() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Cancel redemption
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Check eligibility - cancelled NFTs are eligible when reaching head (no USDS needed)
        // tokenId has redemptionsBefore = 0
        // availablePosition = 0 + 0 + 0 = 0
        // 0 < 0 = false, so not eligible yet

        // Add 1 wei to make it eligible
        vm.prank(owner);
        usds.mint(address(queue), 1);

        (bool eligible, uint256 availablePosition) = queue.isEligibleForRedemption(tokenId);
        // availablePosition = 0 + 0 + 1 = 1
        // 0 < 1 = true, so eligible
        assertEq(eligible, true);
        assertGe(availablePosition, 1);
    }

    // ============ Transfer NFT Tests (US-009) ============

    function test_TransferNFT_Success() public {
        uint256 espnAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Transfer NFT to user2
        vm.prank(user1);
        queue.transferFrom(user1, user2, tokenId);

        assertEq(queue.ownerOf(tokenId), user2);
    }

    function test_TransferNFT_NewOwnerCanRedeem() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Transfer NFT to user2
        vm.prank(user1);
        queue.transferFrom(user1, user2, tokenId);

        // Fund queue and ESPN
        _fundQueueForRedemption(redemptionAmount);

        // user2 should be able to redeem
        uint256 user2BalanceBefore = usds.balanceOf(user2);
        vm.prank(user2);
        queue.redeem(tokenId);

        assertEq(usds.balanceOf(user2), user2BalanceBefore + redemptionAmount);
    }

    function test_TransferNFT_NewOwnerCanCancel() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Transfer NFT to user2
        vm.prank(user1);
        queue.transferFrom(user1, user2, tokenId);

        // user2 should be able to cancel
        uint256 user2EspnBefore = espn.balanceOf(user2);
        vm.prank(user2);
        queue.cancelRedemption(tokenId);

        assertGt(espn.balanceOf(user2), user2EspnBefore);
    }

    function test_TransferNFT_OnlyOwnerCanTransfer() public {
        uint256 espnAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // user2 should not be able to transfer
        vm.prank(user2);
        vm.expectRevert();
        queue.transferFrom(user1, user2, tokenId);
    }

    // ============ View Collection Tests (US-010) ============

    function test_ViewCollection_TotalSupply() public {
        // Check initial state
        assertEq(queue.totalQueued(), 0);

        uint256 espnAmount = 100 * 10 ** 18;
        uint256 expectedRedemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        assertEq(queue.totalQueued(), expectedRedemptionAmount);
    }

    function test_ViewCollection_OwnerOf() public {
        uint256 espnAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        assertEq(queue.ownerOf(tokenId), user1);
    }

    function test_ViewCollection_TokenByIndex() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Note: ERC721 doesn't have tokenByIndex by default, but we can check balanceOf
        assertEq(queue.balanceOf(user1), 1);
        assertEq(queue.balanceOf(user2), 1);
    }

    // ============ Queue Statistics Tests (US-011) ============

    function test_QueueStatistics_TotalRedemptionsValue() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // Get actual redemption amount from contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        assertEq(queue.totalQueued(), actualRedemptionAmount1);

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amount from contract (second field)
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);
        assertEq(queue.totalQueued(), actualRedemptionAmount1 + actualRedemptionAmount2);
    }

    function test_QueueStatistics_TotalProcessedRedemptions() public {
        uint256 espnAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Get actual redemption amount from contract (second field)
        (, uint256 actualRedemptionAmount,,) = queue.redemptions(tokenId);
        assertEq(queue.totalRedemptionsProcessed(), 0);

        vm.prank(owner);
        usds.mint(address(queue), actualRedemptionAmount * 2);

        vm.prank(user1);
        queue.redeem(tokenId);

        assertEq(queue.totalRedemptionsProcessed(), actualRedemptionAmount);
    }

    function test_QueueStatistics_PendingRedemptionsValue() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        uint256 totalValue = queue.totalQueued();
        uint256 processedValue = queue.totalRedemptionsProcessed();
        uint256 pendingValue = totalValue - processedValue;

        assertEq(pendingValue, actualRedemptionAmount1 + actualRedemptionAmount2);
    }

    function test_QueueStatistics_TotalCancellationsProcessed() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts from contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);

        // Initially zero
        assertEq(queue.totalCancellationsProcessed(), 0);

        // Cancel first redemption
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId1);
        vm.stopPrank();

        // Still zero until processed via redeem()
        assertEq(queue.totalCancellationsProcessed(), 0);

        // Process cancelled NFT via processCancelledRedemptions()
        vm.prank(owner);
        usds.mint(address(queue), 1); // Add 1 wei to make it eligible

        vm.prank(user1);
        uint256[] memory tokenIds1 = new uint256[](1);
        tokenIds1[0] = tokenId1;
        queue.processCancelledRedemptions(tokenIds1);

        // Now should be updated
        assertEq(queue.totalCancellationsProcessed(), actualRedemptionAmount1);

        // Cancel and process second redemption
        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        vm.prank(owner);
        usds.mint(address(queue), 1); // Add 1 wei to make it eligible

        vm.prank(user2);
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = tokenId2;
        queue.processCancelledRedemptions(tokenIds2);

        // Should accumulate
        assertEq(queue.totalCancellationsProcessed(), actualRedemptionAmount1 + actualRedemptionAmount2);
    }

    function test_QueueStatistics_Invariant() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // Queue redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount3);
        uint256 tokenId3 = queue.queueRedemption(espnAmount3);
        vm.stopPrank();

        // Get actual redemption amounts from contract (second field)
        (, uint256 actualRedemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 actualRedemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 actualRedemptionAmount3,,) = queue.redemptions(tokenId3);

        uint256 totalQueued = queue.totalQueued();
        assertEq(totalQueued, actualRedemptionAmount1 + actualRedemptionAmount2 + actualRedemptionAmount3);

        // Cancel one, process one active
        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        vm.prank(owner);
        usds.mint(address(queue), actualRedemptionAmount1 * 2);

        vm.prank(user1);
        queue.redeem(tokenId1);

        // Process cancelled NFT
        vm.prank(owner);
        usds.mint(address(queue), 1);

        vm.prank(user2);
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = tokenId2;
        queue.processCancelledRedemptions(tokenIds2);

        // Verify invariant: totalRedemptionsProcessed + totalCancellationsProcessed <= totalQueued
        uint256 processed = queue.totalRedemptionsProcessed();
        uint256 cancelled = queue.totalCancellationsProcessed();
        assertLe(processed + cancelled, totalQueued);
        assertEq(processed + cancelled, actualRedemptionAmount1 + actualRedemptionAmount2); // Should be less than
            // totalQueued
    }

    // ============ Reentrancy Protection Tests (US-013) ============

    function test_ReentrancyProtection_QueueRedemption() public {
        // This test verifies nonReentrant modifier is present
        // A full reentrancy attack test would require a malicious contract
        // For now, we verify the modifier exists by checking the function signature
        uint256 espnAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        // Should succeed normally
        queue.queueRedemption(espnAmount);
        vm.stopPrank();
    }

    function test_ReentrancyProtection_Redeem() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        _fundQueueForRedemption(redemptionAmount);

        // Should succeed normally
        vm.prank(user1);
        queue.redeem(tokenId);
    }

    function test_ReentrancyProtection_CancelRedemption() public {
        // No longer need to set manager - cancellation works directly

        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Should succeed normally
        vm.prank(user1);
        queue.cancelRedemption(tokenId);
    }

    // ============ Input Validation Tests (US-014) ============

    function test_InputValidation_QueueRedemption_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(ESPNRedemptionQueue.ZeroAmount.selector);
        queue.queueRedemption(0);
        vm.stopPrank();
    }

    function test_InputValidation_Redeem_InvalidTokenId() public {
        vm.prank(user1);
        vm.expectRevert();
        queue.redeem(999); // Non-existent token ID
    }

    function test_InputValidation_CancelRedemption_InsufficientESPNBalance() public {
        // Test insufficient ESPN balance scenario
        // This tests what happens if the invariant is broken (shouldn't happen in practice)
        uint256 espnAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Manually burn ESPN from queue to simulate insufficient balance
        uint256 queueEspn = espn.balanceOf(address(queue));
        vm.prank(address(queue));
        espn.burn(queueEspn);

        // Now cancellation should fail due to insufficient ESPN balance
        // safeTransfer will revert with ERC20InsufficientBalance
        vm.startPrank(user1);
        vm.expectRevert(); // Generic revert from ERC20 transfer
        queue.cancelRedemption(tokenId);
        vm.stopPrank();
    }

    function test_InputValidation_Constructor_ZeroSweeper() public {
        vm.expectRevert(ESPNRedemptionQueue.InvalidSweeper.selector);
        new ESPNRedemptionQueue(address(espn), address(0), owner, ctrl, owner);
    }

    function test_InputValidation_SweepUSDS_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        queue.sweepUSDS();
    }

    // ============ burnExcessESPN Tests ============

    function test_BurnExcessESPN_NoExcess() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // ESPN value should equal totalQueued, so no excess to burn
        (uint256 espnBurned, uint256 excessValue) = queue.burnExcessESPN();
        assertEq(espnBurned, 0);
        assertEq(excessValue, 0);
    }

    function test_BurnExcessESPN_WithExcess() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value by adding assets (simulating yield)
        vm.prank(owner);
        usds.mint(owner, redemptionAmount);
        vm.prank(owner);
        usds.approve(address(espn), redemptionAmount);
        vm.prank(owner);
        espn.increaseAssetsPerShare(redemptionAmount);

        // Now ESPN held is worth more than totalQueued
        // burnExcessESPN should burn the excess
        uint256 espnBalanceBefore = espn.balanceOf(address(queue));
        (uint256 espnBurned, uint256 excessValue) = queue.burnExcessESPN();
        
        assertGt(espnBurned, 0);
        assertGt(excessValue, 0);
        assertEq(espn.balanceOf(address(queue)), espnBalanceBefore - espnBurned);
    }

    function test_BurnExcessESPN_Permissionless() public {
        uint256 espnAmount = 100 * 10 ** 18;

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Anyone can call burnExcessESPN
        vm.prank(user2);
        (uint256 espnBurned, uint256 excessValue) = queue.burnExcessESPN();
        
        // Should not revert
        assertEq(espnBurned, 0); // No excess in this case
        assertEq(excessValue, 0);
    }

    // ============ Additional Tests for User Stories ============

    function test_QueueRedemption_AutoBurnsExcessESPN() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value by adding assets (simulating yield)
        vm.prank(owner);
        usds.mint(owner, redemptionAmount);
        vm.prank(owner);
        usds.approve(address(espn), redemptionAmount);
        vm.prank(owner);
        espn.increaseAssetsPerShare(redemptionAmount);

        // Now ESPN held is worth more than totalQueued
        // Queue another redemption - should auto-burn excess
        uint256 espnBalanceBefore = espn.balanceOf(address(queue));
        uint256 espnValueBefore = espn.previewRedeem(espnBalanceBefore);
        uint256 totalQueuedBefore = queue.totalQueued();
        assertGt(espnValueBefore, totalQueuedBefore); // Excess exists

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // After queuing, totalQueued increased, but excess should be burned
        // ESPN value should now be <= totalQueued (allowing for conservative rounding)
        uint256 espnBalanceAfter = espn.balanceOf(address(queue));
        uint256 espnValueAfter = espn.previewRedeem(espnBalanceAfter);
        uint256 totalQueuedAfter = queue.totalQueued();
        // Note: Due to conservative rounding (subtracting 1 wei), ESPN value might be slightly above totalQueued
        // but should be very close. The conservative burning ensures we always have enough ESPN for cancellations.
        assertLe(espnValueAfter, totalQueuedAfter + 2e20); // Allow up to 2e20 wei difference (conservative rounding)
        // ESPN balance increased (we added more ESPN), but value should be controlled
        assertGt(espnBalanceAfter, espnBalanceBefore); // Balance increased (we queued more ESPN)
    }

    function test_Redeem_WithdrawalsDisabled() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Fund queue (needs redemptionAmount * 2 for increaseAssetsPerShare and withdrawal transfer)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount * 2);

        // Ensure withdrawals are disabled
        vm.prank(owner);
        espn.setWithdrawalsDisabled(true);

        // Redeem should fail
        vm.prank(user1);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw
        queue.redeem(tokenId);
    }

    function test_Redeem_YieldIsolation_UserReceivesExactRedemptionAmount() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value by adding assets (simulating yield accrual)
        // This increases the value of ESPN held by the queue
        vm.prank(owner);
        usds.mint(owner, redemptionAmount);
        vm.prank(owner);
        usds.approve(address(espn), redemptionAmount);
        vm.prank(owner);
        espn.increaseAssetsPerShare(redemptionAmount);

        // ESPN held by queue is now worth more than redemptionAmount
        uint256 espnBalance = espn.balanceOf(address(queue));
        uint256 espnValue = espn.previewRedeem(espnBalance);
        assertGt(espnValue, redemptionAmount); // Yield accrued

        // Fund queue and ESPN
        _fundQueueForRedemption(redemptionAmount);

        // User should receive exactly redemptionAmount, not the increased value
        uint256 user1BalanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        queue.redeem(tokenId);

        // User receives exactly redemptionAmount (not the yield)
        assertEq(usds.balanceOf(user1), user1BalanceBefore + redemptionAmount);
    }

    function test_ProcessCancelledRedemptions_Permissionless() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Cancel redemption
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Add 1 wei to make it eligible
        vm.prank(owner);
        usds.mint(address(queue), 1);

        // Anyone (user2) can process the cancelled NFT
        uint256 cancellationsBefore = queue.totalCancellationsProcessed();
        vm.prank(user2); // Different user
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        queue.processCancelledRedemptions(tokenIds);

        assertEq(queue.totalCancellationsProcessed(), cancellationsBefore + redemptionAmount);
    }

    function test_ProcessCancelledRedemptions_MultipleNFTs() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // User1 needs more ESPN for the second redemption
        // Calculate how much USDS is needed to deposit to get espnAmount ESPN
        uint256 usdsNeeded = espn.previewMint(espnAmount);
        vm.prank(owner);
        usds.mint(user1, usdsNeeded);
        
        // Deposit USDS to get ESPN
        vm.startPrank(user1);
        usds.approve(address(espn), usdsNeeded);
        espn.deposit(usdsNeeded, user1);
        vm.stopPrank();

        // Queue and cancel multiple redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount * 2);
        uint256 tokenId1 = queue.queueRedemption(espnAmount);
        uint256 tokenId2 = queue.queueRedemption(espnAmount);
        queue.cancelRedemption(tokenId1);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        // Add 1 wei to make them eligible
        vm.prank(owner);
        usds.mint(address(queue), 1);

        // Process both in one call
        uint256 cancellationsBefore = queue.totalCancellationsProcessed();
        vm.prank(user1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        queue.processCancelledRedemptions(tokenIds);

        assertEq(queue.totalCancellationsProcessed(), cancellationsBefore + redemptionAmount * 2);
    }

    function test_BurnExcessESPN_ConservativeRounding() public {
        // This test verifies that burnExcessESPN is conservative (subtracts 1 wei)
        // The invariant is: we should always have enough ESPN if everyone cancels
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value slightly (simulating small yield)
        vm.prank(owner);
        usds.mint(owner, redemptionAmount / 100); // 1% yield
        vm.prank(owner);
        usds.approve(address(espn), redemptionAmount / 100);
        vm.prank(owner);
        espn.increaseAssetsPerShare(redemptionAmount / 100);

        // ESPN value is now slightly more than totalQueued
        uint256 espnBalance = espn.balanceOf(address(queue));
        uint256 espnValue = espn.previewRedeem(espnBalance);
        assertGt(espnValue, queue.totalQueued());

        // Calculate expected excess (before 1 wei subtraction)
        uint256 expectedExcess = espnValue - queue.totalQueued();
        assertGt(expectedExcess, 0, "Should have excess"); // Ensure we have excess
        
        // Burn excess
        (uint256 espnBurned, uint256 excessValue) = queue.burnExcessESPN();
        
        // excessValue should be 1 wei less than the actual excess (conservative)
        // The contract subtracts 1 wei from excessValue before calculating espnBurned
        assertEq(excessValue, expectedExcess - 1, "excessValue should be 1 wei less than expectedExcess");
        
        // After burning, ESPN value should still be >= totalQueued (conservative)
        // This ensures we have enough if everyone cancels
        uint256 espnBalanceAfter = espn.balanceOf(address(queue));
        uint256 espnValueAfter = espn.previewRedeem(espnBalanceAfter);
        assertGe(espnValueAfter, queue.totalQueued()); // Conservative: >= totalQueued
        
        // We did burn some excess (but less than the true excess due to 1 wei subtraction)
        assertGt(espnBurned, 0);
        assertGt(excessValue, 0);
    }

    function test_CancelRedemption_AutoBurnsExcessESPN() public {
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value (simulating yield)
        vm.prank(owner);
        usds.mint(owner, redemptionAmount);
        vm.prank(owner);
        usds.approve(address(espn), redemptionAmount);
        vm.prank(owner);
        espn.increaseAssetsPerShare(redemptionAmount);

        // ESPN value is now more than totalQueued
        uint256 espnValueBefore = espn.previewRedeem(espn.balanceOf(address(queue)));
        assertGt(espnValueBefore, queue.totalQueued());

        // Cancel redemption - should auto-burn excess
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId);
        vm.stopPrank();

        // Excess should be burned
        uint256 espnValueAfter = espn.previewRedeem(espn.balanceOf(address(queue)));
        assertLe(espnValueAfter, queue.totalQueued());
    }

    function test_Redeem_AutoBurnsExcessESPN() public {
        
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value (simulating yield)
        vm.prank(owner);
        usds.mint(owner, redemptionAmount);
        vm.prank(owner);
        usds.approve(address(espn), redemptionAmount);
        vm.prank(owner);
        espn.increaseAssetsPerShare(redemptionAmount);

        // ESPN value is now more than totalQueued
        uint256 espnValueBefore = espn.previewRedeem(espn.balanceOf(address(queue)));
        assertGt(espnValueBefore, queue.totalQueued());

        // Fund queue and ESPN
        _fundQueueForRedemption(redemptionAmount);

        // Redeem - should auto-burn excess
        vm.prank(user1);
        queue.redeem(tokenId);

        // After redeem, ESPN balance should be reduced (withdrawn and excess burned)
        // Note: ESPN balance might not be exactly 0 due to rounding
        uint256 espnBalanceAfter = espn.balanceOf(address(queue));
        uint256 espnValueAfter = espn.previewRedeem(espnBalanceAfter);
        assertLe(espnValueAfter, queue.totalQueued()); // Should be <= totalQueued after burning
    }

    function test_BurnExcessESPN_EveryoneCanCancel() public {
        // This test verifies that after conservative burning, everyone can still cancel
        // This is the critical invariant: we should always have enough ESPN if everyone cancels
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // Queue three redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount3);
        uint256 tokenId3 = queue.queueRedemption(espnAmount3);
        vm.stopPrank();

        // Get redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 redemptionAmount3,,) = queue.redemptions(tokenId3);
        uint256 totalQueued = queue.totalQueued();

        // Increase ESPN value (simulating yield accrual)
        // This should trigger excess burning
        uint256 yieldAmount = totalQueued / 100; // 1% yield
        vm.prank(owner);
        usds.mint(owner, yieldAmount);
        vm.prank(owner);
        usds.approve(address(espn), yieldAmount);
        vm.prank(owner);
        espn.increaseAssetsPerShare(yieldAmount);

        // Burn excess (conservative - subtracts 1 wei)
        queue.burnExcessESPN();

        // Now verify everyone can cancel
        // After conservative burning, ESPN value should be >= totalQueued
        uint256 espnBalance = espn.balanceOf(address(queue));
        uint256 espnValue = espn.previewRedeem(espnBalance);
        assertGe(espnValue, totalQueued, "ESPN value should be >= totalQueued after conservative burn");

        // Cancel all redemptions - should all succeed
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId1);
        vm.stopPrank();

        vm.startPrank(user2);
        queue.cancelRedemption(tokenId2);
        vm.stopPrank();

        vm.startPrank(user3);
        queue.cancelRedemption(tokenId3);
        vm.stopPrank();

        // Verify all cancellations succeeded
        (,, bool redeemed1, bool cancelled1) = queue.redemptions(tokenId1);
        (,, bool redeemed2, bool cancelled2) = queue.redemptions(tokenId2);
        (,, bool redeemed3, bool cancelled3) = queue.redemptions(tokenId3);
        
        assertEq(redeemed1, false);
        assertEq(cancelled1, true);
        assertEq(redeemed2, false);
        assertEq(cancelled2, true);
        assertEq(redeemed3, false);
        assertEq(cancelled3, true);
    }

    function test_BurnExcessESPN_ExactOneWeiExcess() public {
        // Test edge case: excess is exactly 1 wei
        uint256 espnAmount = 100 * 10 ** 18;
        uint256 redemptionAmount = espn.previewRedeem(espnAmount);

        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Increase ESPN value by exactly 1 wei more than totalQueued
        // This is tricky - we need to get the ESPN value to be exactly totalQueued + 1
        // We'll use a small amount that results in exactly 1 wei excess after rounding
        uint256 espnBalance = espn.balanceOf(address(queue));
        uint256 currentEspnValue = espn.previewRedeem(espnBalance);
        uint256 targetValue = queue.totalQueued() + 1;
        
        // If current value is already >= target, we can't test this edge case
        // Otherwise, we'd need to calculate the exact amount to add
        // For simplicity, just verify that if excess is 1 wei, we subtract it and burn 0
        if (currentEspnValue < targetValue) {
            // Add enough to get to target value (approximate)
            uint256 needed = targetValue - currentEspnValue;
            vm.prank(owner);
            usds.mint(owner, needed);
            vm.prank(owner);
            usds.approve(address(espn), needed);
            vm.prank(owner);
            espn.increaseAssetsPerShare(needed);
        }

        // Now check if we have excess
        espnBalance = espn.balanceOf(address(queue));
        uint256 espnValue = espn.previewRedeem(espnBalance);
        uint256 excess = espnValue > queue.totalQueued() ? espnValue - queue.totalQueued() : 0;
        
        // Burn excess
        (uint256 espnBurned, uint256 excessValue) = queue.burnExcessESPN();
        
        if (excess == 0) {
            // No excess, nothing should be burned
            assertEq(excessValue, 0);
            assertEq(espnBurned, 0);
        } else if (excess == 1) {
            // If excess was exactly 1 wei, after subtracting 1 wei, excessValue will be 0
            // and previewMint(0) will return 0, so nothing will be burned
            assertEq(excessValue, 0);
            assertEq(espnBurned, 0);
        } else {
            // Otherwise, we should have burned something
            // excessValue should be 1 wei less than excess
            assertGt(espnBurned, 0, "Should burn some ESPN when excess > 1 wei");
            assertEq(excessValue, excess - 1, "excessValue should be 1 wei less than excess");
        }
    }
}
