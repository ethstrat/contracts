// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ESPNRedemptionQueue} from "../../src/ESPNRedemptionQueue.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

/**
 * @title Mock Flash Loan Provider
 * @dev Simple mock flash loan provider for testing
 */
contract MockFlashLoanProvider {
    IERC20 public immutable token;
    uint256 public constant PREMIUM_BPS = 9; // 0.09% premium (Aave-like)
    
    constructor(address _token) {
        token = IERC20(_token);
    }
    
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external {
        require(assets.length == 1 && amounts.length == 1, "Single asset only");
        require(assets[0] == address(token), "Wrong asset");
        
        uint256 amount = amounts[0];
        uint256 premium = (amount * PREMIUM_BPS) / 10000;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premium;
        
        // Transfer tokens to receiver
        token.transfer(receiverAddress, amount);
        
        // Call the receiver's callback
        ESPNRedemptionQueue receiver = ESPNRedemptionQueue(receiverAddress);
        bool success = receiver.executeOperation(
            assets,
            amounts,
            premiums,
            onBehalfOf,
            params
        );
        require(success, "Flash loan callback failed");
        
        // Take back tokens + premium (executeOperation should have approved this contract)
        uint256 totalToRepay = amount + premium;
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(receiverAddress, address(this), totalToRepay);
        require(token.balanceOf(address(this)) == balanceBefore + totalToRepay, "Repayment failed");
    }
    
    // Allow this contract to receive tokens for flash loans
    receive() external payable {}
}

contract ESPNRedemptionQueueTest is Test {
    ESPNRedemptionQueue public queue;
    EthStrategyPerpetualNote public espn;
    MintableBurnableToken public usds;
    MockFlashLoanProvider public flashLoanProvider;
    
    address public owner = address(0x1);
    address public manager = address(0x2);
    address public sweeper = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    address public user3 = address(0x6);
    
    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10**18;
    uint256 public constant INITIAL_ASSETS = 100_000 * 10**18;
    uint256 public constant INITIAL_SHARES = 1000 * 10**18;

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
        espn.setDepositCap(100_000_000 * 10**18);
        
        // Setup initial conversion rate (1:100)
        vm.startPrank(owner);
        usds.mint(address(this), INITIAL_SHARES);
        usds.approve(address(espn), INITIAL_SHARES);
        espn.deposit(INITIAL_SHARES, address(this));
        espn.increaseAssetsPerShare(INITIAL_ASSETS - INITIAL_SHARES);
        vm.stopPrank();
        
        // Deploy redemption queue
        queue = new ESPNRedemptionQueue(address(espn), sweeper, owner);
        
        // Deploy mock flash loan provider
        flashLoanProvider = new MockFlashLoanProvider(address(usds));
        
        // Mint USDS to flash loan provider
        vm.prank(owner);
        usds.mint(address(flashLoanProvider), 10_000_000 * 10**18);
        
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
        uint256 espnAmount = 100 * 10**18;
        uint256 expectedDollarBacking = espn.previewRedeem(espnAmount);
        
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Check NFT was minted
        assertEq(queue.ownerOf(tokenId), user1);
        
        // Check redemption data
        (uint256 redemptionsBefore, uint256 dollarBacking, bool redeemed, bool cancelled) = 
            queue.redemptions(tokenId);
        assertEq(redemptionsBefore, 0);
        assertEq(dollarBacking, expectedDollarBacking);
        assertEq(redeemed, false);
        assertEq(cancelled, false);
        
        // Check counters
        assertEq(queue.totalRedemptions(), 1);
        assertEq(queue.totalRedemptionsValue(), expectedDollarBacking);
    }

    function test_QueueRedemption_MultipleUsers() public {
        uint256 espnAmount1 = 100 * 10**18;
        uint256 espnAmount2 = 50 * 10**18;
        
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();
        
        // Check second NFT has correct redemptionsBefore
        (uint256 redemptionsBefore2,,,) = queue.redemptions(tokenId2);
        uint256 expectedValue1 = espn.previewRedeem(espnAmount1);
        assertEq(redemptionsBefore2, expectedValue1);
        
        // Check counters
        assertEq(queue.totalRedemptions(), 2);
        assertEq(queue.totalRedemptionsValue(), expectedValue1 + espn.previewRedeem(espnAmount2));
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
        queue.queueRedemption(100 * 10**18);
        vm.stopPrank();
    }

    // ============ redeem Tests ============

    function test_Redeem_Success() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Fund queue with USDS
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        
        // Redeem
        uint256 user1BalanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        queue.redeem(tokenId);
        
        // Check USDS was transferred
        assertEq(usds.balanceOf(user1), user1BalanceBefore + dollarBacking);
        
        // Check NFT was burned
        vm.expectRevert();
        queue.ownerOf(tokenId);
        
        // Check redemption marked as redeemed
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, true);
        assertEq(cancelled, false);
        
        // Check processed redemptions
        assertEq(queue.totalProcessedRedemptions(), dollarBacking);
    }

    function test_Redeem_NotEligible() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
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
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Fund queue
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        
        // Try to redeem as different user
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotTokenOwner.selector, tokenId));
        queue.redeem(tokenId);
    }

    function test_Redeem_AlreadyRedeemed() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // Queue and redeem
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        
        vm.prank(user1);
        queue.redeem(tokenId);
        
        // Try to redeem again
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.AlreadyRedeemed.selector, tokenId));
        queue.redeem(tokenId);
    }

    function test_Redeem_MultipleInQueue() public {
        uint256 espnAmount1 = 100 * 10**18;
        uint256 espnAmount2 = 50 * 10**18;
        uint256 dollarBacking1 = espn.previewRedeem(espnAmount1);
        uint256 dollarBacking2 = espn.previewRedeem(espnAmount2);
        
        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();
        
        // Fund queue with enough for both
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking1 + dollarBacking2);
        
        // First redemption should be eligible
        vm.prank(user1);
        queue.redeem(tokenId1);
        
        // Second redemption should also be eligible now
        vm.prank(user2);
        queue.redeem(tokenId2);
        
        assertEq(queue.totalProcessedRedemptions(), dollarBacking1 + dollarBacking2);
    }

    function test_Redeem_PartialFunding() public {
        uint256 espnAmount1 = 100 * 10**18;
        uint256 espnAmount2 = 50 * 10**18;
        uint256 dollarBacking1 = espn.previewRedeem(espnAmount1);
        uint256 dollarBacking2 = espn.previewRedeem(espnAmount2);
        
        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();
        
        // Fund queue with only enough for first
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking1);
        
        // First should succeed
        vm.prank(user1);
        queue.redeem(tokenId1);
        
        // Second should not be eligible (not enough USDS)
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotEligibleForRedemption.selector, tokenId2));
        queue.redeem(tokenId2);
        
        // Add more USDS
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking2);
        
        // Now second should succeed
        vm.prank(user2);
        queue.redeem(tokenId2);
    }

    // ============ cancelRedemption Tests ============

    function test_CancelRedemption_Success() public {
        // Set queue as ESPN manager (required for cancellation)
        vm.prank(owner);
        espn.setManager(address(queue));
        
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Calculate flash loan amount (dollarBacking + premium)
        uint256 premium = (dollarBacking * 9) / 10000;
        uint256 flashLoanAmount = dollarBacking + premium;
        
        // Generate flash loan calldata
        bytes memory flashLoanCalldata = queue.generateAaveV3FlashLoanCalldata(
            tokenId,
            flashLoanAmount,
            premium
        );
        
        uint256 user1EspnBefore = espn.balanceOf(user1);
        
        // Cancel redemption
        vm.startPrank(user1);
        queue.cancelRedemption(tokenId, address(flashLoanProvider), flashLoanAmount, flashLoanCalldata);
        vm.stopPrank();
        
        // Check ESPN was returned to user
        assertGt(espn.balanceOf(user1), user1EspnBefore);
        
        // Check NFT was burned
        vm.expectRevert();
        queue.ownerOf(tokenId);
        
        // Check redemption marked as cancelled
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(redeemed, false);
        assertEq(cancelled, true);
    }

    function test_CancelRedemption_NotOwner() public {
        uint256 espnAmount = 100 * 10**18;
        
        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Try to cancel as different user
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.NotTokenOwner.selector, tokenId));
        queue.cancelRedemption(tokenId, address(flashLoanProvider), 0, "");
    }

    function test_CancelRedemption_AlreadyRedeemed() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // Queue and redeem
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        
        vm.prank(user1);
        queue.redeem(tokenId);
        
        // Try to cancel
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.AlreadyRedeemed.selector, tokenId));
        queue.cancelRedemption(tokenId, address(flashLoanProvider), 0, "");
    }

    // ============ sweepUSDS Tests ============

    function test_SweepUSDS_Success() public {
        uint256 sweepAmount = 1000 * 10**18;
        
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
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Fund queue
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        
        // Check eligibility
        (bool eligible, uint256 availableUSDS) = queue.isEligibleForRedemption(tokenId);
        assertEq(eligible, true);
        assertGe(availableUSDS, dollarBacking);
    }

    function test_IsEligibleForRedemption_False() public {
        uint256 espnAmount = 100 * 10**18;
        
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
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        
        // User queues redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Check initial state
        assertEq(queue.totalRedemptions(), 1);
        assertEq(queue.totalRedemptionsValue(), dollarBacking);
        assertEq(queue.totalProcessedRedemptions(), 0);
        
        // Owner funds queue
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking);
        
        // User redeems
        uint256 user1BalanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        queue.redeem(tokenId);
        
        // Check final state
        assertEq(usds.balanceOf(user1), user1BalanceBefore + dollarBacking);
        assertEq(queue.totalProcessedRedemptions(), dollarBacking);
    }

    function test_MultipleUsersQueueAndRedeem() public {
        uint256 espnAmount1 = 100 * 10**18;
        uint256 espnAmount2 = 50 * 10**18;
        uint256 espnAmount3 = 75 * 10**18;
        
        uint256 dollarBacking1 = espn.previewRedeem(espnAmount1);
        uint256 dollarBacking2 = espn.previewRedeem(espnAmount2);
        uint256 dollarBacking3 = espn.previewRedeem(espnAmount3);
        
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
        
        // Check queue state
        assertEq(queue.totalRedemptions(), 3);
        assertEq(queue.totalRedemptionsValue(), dollarBacking1 + dollarBacking2 + dollarBacking3);
        
        // Fund queue
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking1 + dollarBacking2 + dollarBacking3);
        
        // All users redeem
        vm.prank(user1);
        queue.redeem(tokenId1);
        
        vm.prank(user2);
        queue.redeem(tokenId2);
        
        vm.prank(user3);
        queue.redeem(tokenId3);
        
        // Check final state
        assertEq(queue.totalProcessedRedemptions(), dollarBacking1 + dollarBacking2 + dollarBacking3);
    }

    function test_GetRedemptionData() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 expectedDollarBacking = espn.previewRedeem(espnAmount);
        
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        ESPNRedemptionQueue.RedemptionData memory data = queue.getRedemptionData(tokenId);
        assertEq(data.redemptionsBefore, 0);
        assertEq(data.dollarBacking, expectedDollarBacking);
        assertEq(data.redeemed, false);
        assertEq(data.cancelled, false);
    }

    function test_CancelRedemption_AlreadyCancelled() public {
        uint256 espnAmount = 100 * 10**18;
        
        // Queue redemption
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Mark as cancelled manually (simulating a failed cancellation)
        // In practice, this would happen if cancelRedemption is called but flash loan fails
        // For this test, we'll simulate by calling cancelRedemption with invalid calldata
        vm.startPrank(user1);
        vm.expectRevert(); // Flash loan will fail
        queue.cancelRedemption(tokenId, address(flashLoanProvider), 0, "");
        vm.stopPrank();
        
        // Try to cancel again
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ESPNRedemptionQueue.AlreadyCancelled.selector, tokenId));
        queue.cancelRedemption(tokenId, address(flashLoanProvider), 0, "");
    }

    function test_QueueRedemption_BurnsESPN() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 user1EspnBefore = espn.balanceOf(user1);
        uint256 totalSupplyBefore = espn.totalSupply();
        
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Check ESPN was burned
        assertEq(espn.balanceOf(user1), user1EspnBefore - espnAmount);
        assertEq(espn.totalSupply(), totalSupplyBefore - espnAmount);
    }

    function test_Redeem_UpdatesTotalProcessedRedemptions() public {
        uint256 espnAmount1 = 100 * 10**18;
        uint256 espnAmount2 = 50 * 10**18;
        uint256 dollarBacking1 = espn.previewRedeem(espnAmount1);
        uint256 dollarBacking2 = espn.previewRedeem(espnAmount2);
        
        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        IERC20(address(espn)).approve(address(queue), espnAmount2);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();
        
        // Fund queue
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking1 + dollarBacking2);
        
        // Redeem first
        vm.prank(user1);
        queue.redeem(tokenId1);
        assertEq(queue.totalProcessedRedemptions(), dollarBacking1);
        
        // Redeem second
        vm.prank(user2);
        queue.redeem(tokenId2);
        assertEq(queue.totalProcessedRedemptions(), dollarBacking1 + dollarBacking2);
    }

    function test_SweepUSDS_PartialAfterRedemption() public {
        uint256 espnAmount = 100 * 10**18;
        uint256 dollarBacking = espn.previewRedeem(espnAmount);
        uint256 extraUSDS = 500 * 10**18;
        
        // Queue and redeem
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        // Fund queue with extra USDS
        vm.prank(owner);
        usds.mint(address(queue), dollarBacking + extraUSDS);
        
        // Redeem (uses dollarBacking)
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
}
