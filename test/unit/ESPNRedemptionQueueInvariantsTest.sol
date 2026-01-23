// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ESPNRedemptionQueue} from "../../src/ESPNRedemptionQueue.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashLender} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";

/**
 * @title Simple Flash Loan Provider (ERC-3156 compliant)
 * @dev Simple no-fee flash loan provider for unit testing
 */
contract SimpleFlashLoanProvider is IERC3156FlashLender {
    IERC20 public immutable token;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function maxFlashLoan(address tokenAddress) external view override returns (uint256) {
        if (tokenAddress != address(token)) {
            return 0;
        }
        return type(uint256).max;
    }

    function flashFee(address tokenAddress, uint256) external view override returns (uint256) {
        require(tokenAddress == address(token), "Wrong token");
        return 0;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address tokenAddress, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        require(tokenAddress == address(token), "Wrong token");

        uint256 fee = 0;

        // Transfer tokens to receiver
        token.transfer(address(receiver), amount);

        // Call the receiver's callback
        bytes32 result = receiver.onFlashLoan(msg.sender, tokenAddress, amount, fee, data);
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "Flash loan callback failed");

        // Take back tokens
        uint256 totalToRepay = amount + fee;
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(address(receiver), address(this), totalToRepay);
        require(token.balanceOf(address(this)) == balanceBefore + totalToRepay, "Repayment failed");

        return true;
    }

    receive() external payable {}
}

/**
 * @title ESPNRedemptionQueue Invariant Tests
 * @dev Tests for queue ordering invariants with multiple users
 *
 * Invariants tested:
 * 1. Users can only redeem USDS in order
 * 2. If a user can redeem before the preceding token has redeemed, this is only possible if:
 *    a. There is always enough USDS for that holder to redeem after
 *    b. That user cancelled their queue position
 * 3. If a user cancels their queue position, and another user joins, that user is still only able
 *    to redeem when all those in front of them have either redeemed or cancelled (and the cancellation processed)
 */
contract ESPNRedemptionQueueInvariantsTest is Test {
    ESPNRedemptionQueue public queue;
    EthStrategyPerpetualNote public espn;
    MintableBurnableToken public usds;
    SimpleFlashLoanProvider public flashLoanProvider;

    address public owner = address(0x1);
    address public manager = address(0x2);
    address public sweeper = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    address public user3 = address(0x6);
    address public user4 = address(0x7);
    address public user5 = address(0x8);

    uint256 public constant DEPOSIT_AMOUNT = 10_000 * 10 ** 18;
    uint256 public constant INITIAL_ASSETS = 100_000 * 10 ** 18;
    uint256 public constant INITIAL_SHARES = 1000 * 10 ** 18;

    function setUp() public {
        // Deploy USDS token
        vm.prank(owner);
        usds = new MintableBurnableToken("USD Stable", "USDS", owner);

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
        vm.prank(owner);
        usds.mint(address(this), INITIAL_SHARES);

        usds.approve(address(espn), INITIAL_SHARES);
        espn.deposit(INITIAL_SHARES, address(this));

        vm.prank(owner);
        usds.mint(owner, INITIAL_ASSETS - INITIAL_SHARES);
        vm.prank(owner);
        usds.approve(address(espn), INITIAL_ASSETS - INITIAL_SHARES);
        vm.prank(owner);
        espn.increaseAssetsPerShare(INITIAL_ASSETS - INITIAL_SHARES);

        // Deploy flash loan provider
        flashLoanProvider = new SimpleFlashLoanProvider(address(usds));

        // Deploy redemption queue
        queue = new ESPNRedemptionQueue(address(espn), address(flashLoanProvider), sweeper, owner);

        // Mint USDS to flash loan provider
        vm.prank(owner);
        usds.mint(address(flashLoanProvider), 10_000_000 * 10 ** 18);

        // Mint USDS to users and have them deposit to ESPN
        address[5] memory users = [user1, user2, user3, user4, user5];
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(owner);
            usds.mint(users[i], DEPOSIT_AMOUNT * 10);

            vm.startPrank(users[i]);
            usds.approve(address(espn), type(uint256).max);
            espn.deposit(DEPOSIT_AMOUNT, users[i]);
            vm.stopPrank();
        }
    }

    // ============ Invariant 1: Users can only redeem USDS in order ============

    /**
     * @dev Test that users must redeem in order when insufficient USDS
     * If user2 tries to redeem before user1 without enough USDS buffer, it should fail
     */
    function test_Invariant1_CannotRedeemOutOfOrder() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // User1 queues first
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // User2 queues second
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue with enough for user2 BUT NOT enough buffer for user1
        // User2's redemptionsBefore = redemptionAmount1
        // availablePosition = 0 + 0 + redemptionAmount2 = redemptionAmount2
        // redemptionAmount1 < redemptionAmount2 ? No, so user2 cannot redeem
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount2);

        // User2 tries to redeem first - should fail (not enough buffer)
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId2));
        queue.redeem(tokenId2);

        // Add enough for user1
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1);

        // User1 redeems successfully
        vm.prank(user1);
        queue.redeem(tokenId1);

        // Now user2 can redeem
        vm.prank(user2);
        queue.redeem(tokenId2);
    }

    /**
     * @dev Test that with 5 users, when there's enough USDS for all, they can all redeem
     * But when there's insufficient USDS, ordering is enforced
     */
    function test_Invariant1_FiveUsersRedeemInOrder() public {
        uint256 espnAmount = 100 * 10 ** 18;
        address[5] memory users = [user1, user2, user3, user4, user5];
        uint256[5] memory tokenIds;

        // All users queue in order
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            IERC20(address(espn)).approve(address(queue), espnAmount);
            tokenIds[i] = queue.queueRedemption(espnAmount);
            vm.stopPrank();
        }

        // Calculate total USDS needed
        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint256 redemptionAmount,,) = queue.redemptions(tokenIds[i]);
            totalNeeded += redemptionAmount;
        }

        // Fund queue with only enough for user5, not enough buffer for users 1-4
        (, uint256 redemptionAmount5,,) = queue.redemptions(tokenIds[4]);
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount5);

        // User5 should NOT be able to redeem (insufficient buffer)
        vm.prank(user5);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[4]));
        queue.redeem(tokenIds[4]);

        // Fund queue with total needed - now anyone can redeem
        vm.prank(owner);
        usds.mint(address(queue), totalNeeded - redemptionAmount5);

        // Redeem all in any order (all are eligible when enough USDS)
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            queue.redeem(tokenIds[i]);
        }
    }

    /**
     * @dev Test that partial funding prevents out-of-order redemptions
     */
    function test_Invariant1_PartialFundingEnforcesOrder() public {
        uint256 espnAmount = 100 * 10 ** 18;
        address[5] memory users = [user1, user2, user3, user4, user5];
        uint256[5] memory tokenIds;

        // All users queue
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            IERC20(address(espn)).approve(address(queue), espnAmount);
            tokenIds[i] = queue.queueRedemption(espnAmount);
            vm.stopPrank();
        }

        // Fund queue with only enough for first 2 redemptions
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenIds[0]);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenIds[1]);

        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1 + redemptionAmount2);

        // User3, 4, 5 cannot redeem yet
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[2]));
        queue.redeem(tokenIds[2]);

        // User1 redeems
        vm.prank(user1);
        queue.redeem(tokenIds[0]);

        // User2 redeems
        vm.prank(user2);
        queue.redeem(tokenIds[1]);

        // User3 still cannot redeem (no more USDS)
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[2]));
        queue.redeem(tokenIds[2]);
    }

    // ============ Invariant 2: Skipping ahead only if sufficient USDS or cancellation ============

    /**
     * @dev Test that a later user can redeem if there's sufficient USDS for everyone
     * This tests 2a: enough USDS for all holders
     */
    function test_Invariant2a_CanSkipIfSufficientUSDSForAll() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // Three users queue
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

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 redemptionAmount3,,) = queue.redemptions(tokenId3);

        // Fund queue with EXACTLY enough for all three
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1 + redemptionAmount2 + redemptionAmount3);

        // All users should be able to redeem in any order because there's enough for everyone
        // User3 can redeem first
        vm.prank(user3);
        queue.redeem(tokenId3);

        // User1 can still redeem
        vm.prank(user1);
        queue.redeem(tokenId1);

        // User2 can still redeem
        vm.prank(user2);
        queue.redeem(tokenId2);
    }

    /**
     * @dev Test that a later user CANNOT skip if there's insufficient USDS
     */
    function test_Invariant2a_CannotSkipIfInsufficientUSDS() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // Three users queue
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

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 redemptionAmount3,,) = queue.redemptions(tokenId3);

        // User3's redemptionsBefore = redemptionAmount1 + redemptionAmount2
        // To make user3 NOT eligible: availablePosition <= redemptionsBefore
        // availablePosition = totalRedemptionsProcessed + totalCancellationsProcessed + usds balance
        // availablePosition = 0 + 0 + usds balance
        // So we need: usds balance <= redemptionAmount1 + redemptionAmount2
        // Let's fund with exactly redemptionAmount1 + redemptionAmount2
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1 + redemptionAmount2);

        // User3 should NOT be able to redeem (availablePosition = redemptionAmount1 + redemptionAmount2,
        // which is NOT > redemptionsBefore3)
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId3));
        queue.redeem(tokenId3);
    }

    /**
     * @dev Test that user can skip ahead if preceding user cancelled
     * This tests 2b: preceding user cancelled their position
     */
    function test_Invariant2b_CanSkipIfPrecedingUserCancelled() public {
        // Set queue as ESPN manager for cancellation
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // User1 queues
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // User2 queues
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        // User1 cancels
        vm.prank(user1);
        queue.cancelRedemption(tokenId1);

        // Verify tokenId1 is marked as cancelled
        (,, bool redeemed1, bool cancelled1) = queue.redemptions(tokenId1);
        assertEq(cancelled1, true);
        assertEq(redeemed1, false);

        // Fund queue with only enough for user2's redemption (not enough for user1 if they hadn't cancelled)
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount2);

        // User2 should NOT be able to redeem yet because cancelled NFT hasn't been processed
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId2));
        queue.redeem(tokenId2);

        // Process the cancelled NFT
        vm.prank(owner);
        usds.mint(address(queue), 1); // Add 1 wei to make cancelled NFT eligible

        uint256[] memory cancelledIds = new uint256[](1);
        cancelledIds[0] = tokenId1;
        vm.prank(user1);
        queue.processCancelledRedemptions(cancelledIds);

        // Now user2 can redeem
        vm.prank(user2);
        queue.redeem(tokenId2);
    }

    /**
     * @dev Test complex scenario: multiple cancellations allow later users to redeem
     */
    function test_Invariant2b_MultipleCancellationsAllowSkipping() public {
        // Set queue as ESPN manager
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount = 100 * 10 ** 18;
        address[5] memory users = [user1, user2, user3, user4, user5];
        uint256[5] memory tokenIds;

        // All users queue
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            IERC20(address(espn)).approve(address(queue), espnAmount);
            tokenIds[i] = queue.queueRedemption(espnAmount);
            vm.stopPrank();
        }

        // Get redemption amounts
        (, uint256 redemptionAmount4,,) = queue.redemptions(tokenIds[3]);
        (, uint256 redemptionAmount5,,) = queue.redemptions(tokenIds[4]);

        // User1, 2, 3 cancel
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(users[i]);
            queue.cancelRedemption(tokenIds[i]);
        }

        // Fund queue with enough for user4 and user5, but NOT enough to cover cancelled positions
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount4 + redemptionAmount5);

        // User5 should NOT be able to redeem yet (cancelled NFTs block the queue)
        vm.prank(user5);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[4]));
        queue.redeem(tokenIds[4]);

        // User4 should also not be able to redeem yet
        vm.prank(user4);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[3]));
        queue.redeem(tokenIds[3]);

        // Process all cancelled NFTs
        vm.prank(owner);
        usds.mint(address(queue), 3); // Add 3 wei to make cancelled NFTs eligible

        uint256[] memory cancelledIds = new uint256[](3);
        cancelledIds[0] = tokenIds[0];
        cancelledIds[1] = tokenIds[1];
        cancelledIds[2] = tokenIds[2];
        vm.prank(user1);
        queue.processCancelledRedemptions(cancelledIds);

        // User4 should now be able to redeem
        vm.prank(user4);
        queue.redeem(tokenIds[3]);

        // User5 should now be able to redeem
        vm.prank(user5);
        queue.redeem(tokenIds[4]);
    }

    // ============ Invariant 3: New joiner must wait for all ahead to redeem/cancel ============

    /**
     * @dev Test that if user cancels and new user joins, new user must wait for cancellation to process
     */
    function test_Invariant3_NewJoinerWaitsForCancellationProcessing() public {
        // Set queue as ESPN manager
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;
        uint256 espnAmount3 = 75 * 10 ** 18;

        // User1 queues
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // User2 queues
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // User1 cancels
        vm.prank(user1);
        queue.cancelRedemption(tokenId1);

        // User3 joins AFTER user1 cancelled
        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount3);
        uint256 tokenId3 = queue.queueRedemption(espnAmount3);
        vm.stopPrank();

        // Get redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 redemptionAmount3,,) = queue.redemptions(tokenId3);

        // Fund queue with only enough for user2, not enough buffer for user1's cancelled position
        // User2's redemptionsBefore = redemptionAmount1
        // To make user2 NOT eligible: availablePosition <= redemptionAmount1
        // availablePosition = 0 + 0 + redemptionAmount2 = redemptionAmount2
        // We need redemptionAmount2 <= redemptionAmount1, which should be true since espnAmount1 > espnAmount2
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount2);

        // User3 should NOT be able to redeem yet (user1's cancelled position and user2 are ahead)
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId3));
        queue.redeem(tokenId3);

        // User2 should also NOT be able to redeem yet (user1's cancelled position is ahead)
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId2));
        queue.redeem(tokenId2);

        // Process user1's cancellation
        vm.prank(owner);
        usds.mint(address(queue), 1); // Add 1 wei to make cancelled NFT eligible

        uint256[] memory cancelledIds = new uint256[](1);
        cancelledIds[0] = tokenId1;
        vm.prank(user1);
        queue.processCancelledRedemptions(cancelledIds);

        // Now user2 can redeem
        vm.prank(user2);
        queue.redeem(tokenId2);

        // Add more USDS for user3 to redeem
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount3);

        // Now user3 can redeem
        vm.prank(user3);
        queue.redeem(tokenId3);
    }

    /**
     * @dev Test complex scenario: multiple users cancel, new users join, must process in order
     */
    function test_Invariant3_ComplexCancellationWithNewJoiners() public {
        // Set queue as ESPN manager
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount = 100 * 10 ** 18;

        // User1 and User2 queue
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId1 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId2 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // User1 cancels
        vm.prank(user1);
        queue.cancelRedemption(tokenId1);

        // User3 joins
        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId3 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // User2 cancels
        vm.prank(user2);
        queue.cancelRedemption(tokenId2);

        // User4 joins
        vm.startPrank(user4);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId4 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // User5 joins
        vm.startPrank(user5);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId5 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Get redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        // Don't fund queue yet - test that all are blocked without USDS

        // User5 cannot redeem yet (users 1-4 are ahead)
        vm.prank(user5);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId5));
        queue.redeem(tokenId5);

        // User4 cannot redeem yet (users 1-3 are ahead)
        vm.prank(user4);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId4));
        queue.redeem(tokenId4);

        // User3 cannot redeem yet (users 1-2 cancelled but not processed)
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId3));
        queue.redeem(tokenId3);

        // Process user1's cancellation
        vm.prank(owner);
        usds.mint(address(queue), 1);

        uint256[] memory cancelledIds1 = new uint256[](1);
        cancelledIds1[0] = tokenId1;
        vm.prank(user1);
        queue.processCancelledRedemptions(cancelledIds1);

        // User3 still cannot redeem (user2 cancelled but not processed, and no USDS)
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId3));
        queue.redeem(tokenId3);

        // Process user2's cancellation
        vm.prank(owner);
        usds.mint(address(queue), 1);

        uint256[] memory cancelledIds2 = new uint256[](1);
        cancelledIds2[0] = tokenId2;
        vm.prank(user2);
        queue.processCancelledRedemptions(cancelledIds2);

        // Add USDS for user3 to redeem
        (, uint256 redemptionAmount3,,) = queue.redemptions(tokenId3);
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount3);

        // Now user3 can redeem
        vm.prank(user3);
        queue.redeem(tokenId3);

        // Fund for user4 and user5
        (, uint256 redemptionAmount4,,) = queue.redemptions(tokenId4);
        (, uint256 redemptionAmount5,,) = queue.redemptions(tokenId5);
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount4 + redemptionAmount5);

        // Now user4 can redeem
        vm.prank(user4);
        queue.redeem(tokenId4);

        // Now user5 can redeem
        vm.prank(user5);
        queue.redeem(tokenId5);
    }

    /**
     * @dev Test that queue ordering is maintained throughout cancellations and new joins
     */
    function test_Invariant3_QueueOrderingMaintained() public {
        // Set queue as ESPN manager
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount = 100 * 10 ** 18;

        // User1 queues (position 0)
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId1 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        (uint256 redemptionsBefore1,,,) = queue.redemptions(tokenId1);
        assertEq(redemptionsBefore1, 0, "User1 should be at position 0");

        // User2 queues
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId2 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // User1 cancels
        vm.prank(user1);
        queue.cancelRedemption(tokenId1);

        // User3 joins AFTER cancellation
        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId3 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Check queue positions haven't changed
        (uint256 redemptionsBefore1After,,,) = queue.redemptions(tokenId1);
        (uint256 redemptionsBefore2,,,) = queue.redemptions(tokenId2);
        (uint256 redemptionsBefore3,,,) = queue.redemptions(tokenId3);

        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        assertEq(redemptionsBefore1After, 0, "User1's position unchanged");
        assertEq(redemptionsBefore2, redemptionAmount1, "User2's position unchanged");
        assertEq(redemptionsBefore3, redemptionAmount1 + redemptionAmount2, "User3 is after user1 and user2");

        // Verify user3 must wait for user1's cancellation to be processed and user2 to redeem
        assertGt(redemptionsBefore3, redemptionsBefore2, "User3 must be after user2");
        assertGt(redemptionsBefore3, redemptionsBefore1After, "User3 must be after user1");
    }

    /**
     * @dev Test comprehensive scenario with all invariants
     */
    function test_AllInvariants_ComprehensiveScenario() public {
        // Set queue as ESPN manager
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount = 100 * 10 ** 18;
        address[5] memory users = [user1, user2, user3, user4, user5];
        uint256[5] memory tokenIds;

        // Step 1: All 5 users queue
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            IERC20(address(espn)).approve(address(queue), espnAmount);
            tokenIds[i] = queue.queueRedemption(espnAmount);
            vm.stopPrank();
        }

        // Get redemption amounts
        uint256[5] memory redemptionAmounts;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, redemptionAmounts[i],,) = queue.redemptions(tokenIds[i]);
        }

        // Step 2: User2 cancels
        vm.prank(user2);
        queue.cancelRedemption(tokenIds[1]);

        // Step 3: Fund queue with only enough for user1, not enough buffer for cancelled position
        // User3's redemptionsBefore = redemptionAmounts[0] + redemptionAmounts[1]
        // To block user3, we need availablePosition <= redemptionAmounts[0] + redemptionAmounts[1]
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmounts[0]);

        // Step 4: Invariant 1 - User3 cannot skip ahead without enough buffer
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[2]));
        queue.redeem(tokenIds[2]);

        // Step 5: User1 redeems
        vm.prank(user1);
        queue.redeem(tokenIds[0]);

        // Step 6: Invariant 2b - User3 cannot redeem yet because user2's cancellation isn't processed
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[2]));
        queue.redeem(tokenIds[2]);

        // Step 7: Process user2's cancellation
        vm.prank(owner);
        usds.mint(address(queue), 1);

        uint256[] memory cancelledIds = new uint256[](1);
        cancelledIds[0] = tokenIds[1];
        vm.prank(user2);
        queue.processCancelledRedemptions(cancelledIds);

        // Step 8: Fund for user3 and redeem
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmounts[2]);

        vm.prank(user3);
        queue.redeem(tokenIds[2]);

        // Step 9: User4 cancels
        vm.prank(user4);
        queue.cancelRedemption(tokenIds[3]);

        // Step 10: Invariant 3 - User5 cannot redeem until user4's cancellation is processed
        vm.prank(user5);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenIds[4]));
        queue.redeem(tokenIds[4]);

        // Step 11: Process user4's cancellation
        vm.prank(owner);
        usds.mint(address(queue), 1);

        uint256[] memory cancelledIds2 = new uint256[](1);
        cancelledIds2[0] = tokenIds[3];
        vm.prank(user4);
        queue.processCancelledRedemptions(cancelledIds2);

        // Step 12: Fund for user5 and redeem
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmounts[4]);

        vm.prank(user5);
        queue.redeem(tokenIds[4]);

        // Verify final state
        assertEq(queue.totalRedemptionsProcessed(), redemptionAmounts[0] + redemptionAmounts[2] + redemptionAmounts[4]);
        assertEq(queue.totalCancellationsProcessed(), redemptionAmounts[1] + redemptionAmounts[3]);
    }

    /**
     * @dev Test that if ID 2 can redeem before ID 1, both orderings should work
     * This is a critical property: eligibility should be symmetric
     */
    function test_EligibilitySymmetry_BothOrderingsWork() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // User1 queues first
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // User2 queues second
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue with enough for both
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1 + redemptionAmount2);

        // Verify both are eligible
        (bool eligible1,) = queue.isEligibleForRedemption(tokenId1);
        (bool eligible2,) = queue.isEligibleForRedemption(tokenId2);
        assertEq(eligible1, true, "ID 1 should be eligible");
        assertEq(eligible2, true, "ID 2 should be eligible");

        // Path 1: ID 2 redeems first, then ID 1
        vm.prank(user2);
        queue.redeem(tokenId2);

        // After ID 2 redeems, ID 1 should still be eligible
        (bool eligible1After,) = queue.isEligibleForRedemption(tokenId1);
        assertEq(eligible1After, true, "ID 1 should still be eligible after ID 2 redeems");

        vm.prank(user1);
        queue.redeem(tokenId1);

        // Verify both redeemed successfully
        assertEq(queue.totalRedemptionsProcessed(), redemptionAmount1 + redemptionAmount2);
    }

    /**
     * @dev Test the reverse ordering: if both can redeem, ID 1 then ID 2 should also work
     */
    function test_EligibilitySymmetry_ReverseOrdering() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // User1 queues first
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // User2 queues second
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue with enough for both
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1 + redemptionAmount2);

        // Verify both are eligible
        (bool eligible1,) = queue.isEligibleForRedemption(tokenId1);
        (bool eligible2,) = queue.isEligibleForRedemption(tokenId2);
        assertEq(eligible1, true, "ID 1 should be eligible");
        assertEq(eligible2, true, "ID 2 should be eligible");

        // Path 2: ID 1 redeems first, then ID 2
        vm.prank(user1);
        queue.redeem(tokenId1);

        // After ID 1 redeems, ID 2 should still be eligible
        (bool eligible2After,) = queue.isEligibleForRedemption(tokenId2);
        assertEq(eligible2After, true, "ID 2 should still be eligible after ID 1 redeems");

        vm.prank(user2);
        queue.redeem(tokenId2);

        // Verify both redeemed successfully
        assertEq(queue.totalRedemptionsProcessed(), redemptionAmount1 + redemptionAmount2);
    }

    /**
     * @dev Test with minimal buffer - if both can redeem with exact amount, both orderings work
     */
    function test_EligibilitySymmetry_MinimalBuffer() public {
        uint256 espnAmount1 = 100 * 10 ** 18;
        uint256 espnAmount2 = 50 * 10 ** 18;

        // User1 queues first
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();

        // User2 queues second
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();

        // Get actual redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);

        // Fund queue with EXACTLY enough for both + 1 wei extra
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1 + redemptionAmount2 + 1);

        // Verify both are eligible with minimal buffer
        (bool eligible1,) = queue.isEligibleForRedemption(tokenId1);
        (bool eligible2,) = queue.isEligibleForRedemption(tokenId2);
        assertEq(eligible1, true, "ID 1 should be eligible");
        assertEq(eligible2, true, "ID 2 should be eligible");

        // Test ordering: ID 2 first, then ID 1
        vm.prank(user2);
        queue.redeem(tokenId2);

        (bool eligible1After,) = queue.isEligibleForRedemption(tokenId1);
        assertEq(eligible1After, true, "ID 1 should still be eligible after ID 2 redeems");

        vm.prank(user1);
        queue.redeem(tokenId1);

        assertEq(queue.totalRedemptionsProcessed(), redemptionAmount1 + redemptionAmount2);
    }

    /**
     * @dev Test with three users - if all can redeem, all orderings should work
     */
    function test_EligibilitySymmetry_ThreeUsers() public {
        uint256 espnAmount = 100 * 10 ** 18;
        address[3] memory users = [user1, user2, user3];
        uint256[3] memory tokenIds;

        // All users queue
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            IERC20(address(espn)).approve(address(queue), espnAmount);
            tokenIds[i] = queue.queueRedemption(espnAmount);
            vm.stopPrank();
        }

        // Calculate total needed
        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint256 redemptionAmount,,) = queue.redemptions(tokenIds[i]);
            totalNeeded += redemptionAmount;
        }

        // Fund queue with enough for all
        vm.prank(owner);
        usds.mint(address(queue), totalNeeded);

        // Test different ordering: 3, 1, 2
        vm.prank(user3);
        queue.redeem(tokenIds[2]);

        (bool eligible1,) = queue.isEligibleForRedemption(tokenIds[0]);
        assertEq(eligible1, true, "ID 1 should still be eligible after ID 3 redeems");

        vm.prank(user1);
        queue.redeem(tokenIds[0]);

        (bool eligible2,) = queue.isEligibleForRedemption(tokenIds[1]);
        assertEq(eligible2, true, "ID 2 should still be eligible after ID 1 redeems");

        vm.prank(user2);
        queue.redeem(tokenIds[1]);

        // Verify all redeemed successfully
        assertEq(queue.totalRedemptionsProcessed(), totalNeeded);
    }

    /**
     * @dev Test that availablePosition calculation is correct throughout queue operations
     */
    function test_AvailablePositionCalculation() public {
        // Set queue as ESPN manager
        vm.prank(owner);
        espn.setManager(address(queue));

        uint256 espnAmount = 100 * 10 ** 18;

        // User1 queues
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId1 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // User2 queues
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId2 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // User3 queues
        vm.startPrank(user3);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId3 = queue.queueRedemption(espnAmount);
        vm.stopPrank();

        // Get redemption amounts
        (, uint256 redemptionAmount1,,) = queue.redemptions(tokenId1);
        (, uint256 redemptionAmount2,,) = queue.redemptions(tokenId2);
        (, uint256 redemptionAmount3,,) = queue.redemptions(tokenId3);

        // Initial state: availablePosition = 0 + 0 + 0 = 0
        (bool eligible1, uint256 availablePosition1) = queue.isEligibleForRedemption(tokenId1);
        assertEq(availablePosition1, 0);
        assertEq(eligible1, false); // Not eligible (no USDS)

        // Add USDS
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount1);

        // availablePosition = 0 + 0 + redemptionAmount1
        (bool eligible1After, uint256 availablePosition1After) = queue.isEligibleForRedemption(tokenId1);
        assertEq(availablePosition1After, redemptionAmount1);
        assertEq(eligible1After, true); // Now eligible

        // User1 redeems
        vm.prank(user1);
        queue.redeem(tokenId1);

        // availablePosition = redemptionAmount1 + 0 + 0
        (bool eligible2, uint256 availablePosition2) = queue.isEligibleForRedemption(tokenId2);
        assertEq(availablePosition2, redemptionAmount1);
        assertEq(eligible2, false); // Not eligible (no USDS left)

        // User2 cancels
        vm.prank(user2);
        queue.cancelRedemption(tokenId2);

        // Process user2's cancellation
        vm.prank(owner);
        usds.mint(address(queue), 1);

        uint256[] memory cancelledIds = new uint256[](1);
        cancelledIds[0] = tokenId2;
        vm.prank(user2);
        queue.processCancelledRedemptions(cancelledIds);

        // availablePosition = redemptionAmount1 + redemptionAmount2 + 1
        (bool eligible3, uint256 availablePosition3) = queue.isEligibleForRedemption(tokenId3);
        assertEq(availablePosition3, redemptionAmount1 + redemptionAmount2 + 1);
        assertEq(eligible3, false); // Not eligible (only 1 wei USDS left, needs redemptionAmount3)

        // Add more USDS
        vm.prank(owner);
        usds.mint(address(queue), redemptionAmount3);

        // availablePosition = redemptionAmount1 + redemptionAmount2 + 1 + redemptionAmount3
        (bool eligible3After, uint256 availablePosition3After) = queue.isEligibleForRedemption(tokenId3);
        assertEq(availablePosition3After, redemptionAmount1 + redemptionAmount2 + 1 + redemptionAmount3);
        assertEq(eligible3After, true); // Now eligible

        // User3 redeems
        vm.prank(user3);
        queue.redeem(tokenId3);
    }
}
