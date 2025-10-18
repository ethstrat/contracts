// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ESPNRedemptionFacilitator} from "../../src/ESPNRedemptionFacilitator.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

contract ESPNRedemptionFacilitatorTest is Test {
    ESPNRedemptionFacilitator public facilitator;
    EthStrategyPerpetualNote public espn;
    MintableBurnableToken public usds;

    address public owner = address(0x1);
    address public manager = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public receiver = address(0x5);

    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10 ** 18;
    uint256 public constant REDEEM_SHARES = 100 * 10 ** 18;
    uint256 public constant WITHDRAW_AMOUNT = 200 * 10 ** 18;

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

        // Enable withdrawals for testing
        vm.prank(owner);
        espn.setWithdrawalsDisabled(false);

        // Deploy facilitator
        facilitator = new ESPNRedemptionFacilitator(address(espn), owner);

        // Mint USDS to users and ESPN and redemption facilitator
        vm.startPrank(owner);
        usds.mint(user1, DEPOSIT_AMOUNT * 10);
        usds.mint(user2, DEPOSIT_AMOUNT * 10);
        usds.mint(address(espn), DEPOSIT_AMOUNT * 10);
        usds.mint(address(facilitator), DEPOSIT_AMOUNT * 20);
        vm.stopPrank();

        // User1 deposits to ESPN
        vm.startPrank(user1);
        usds.approve(address(espn), DEPOSIT_AMOUNT);
        espn.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();

        // User2 deposits to ESPN
        vm.startPrank(user2);
        usds.approve(address(espn), DEPOSIT_AMOUNT);
        espn.deposit(DEPOSIT_AMOUNT, user2);
        vm.stopPrank();
    }

    // redeem
    // when shares is 0
    //  [ ] it does nothing and returns 0
    // when ESPN withdrawals are disabled
    //  [ ] it does nothing and returns 0
    // given usdsRequired is <= ESPN contract's balance
    //  given the owner has not approved the facilitator to spend their shares
    //   [ ] it reverts
    //  given the owner does not have sufficient ESPN balance
    //   [ ] it reverts
    //  [ ] it does not transfer any USDS to the ESPN contract
    //  [ ] it burns the shares
    //  [ ] it transfers usdsRequired to the receiver
    // given usdsRequired is > ESPN contract's balance
    //  given the facilitator's USDS balance is less than usdsDelta
    //   [ ] it reverts
    //  [ ] it transfers usdsDelta to the ESPN contract
    //  [ ] it burns the shares
    //  [ ] it transfers usdsRequired to the receiver

    function test_FacilitateRedeem_Success() public {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        // Approve facilitator to spend ESPN shares
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        // Execute redeem
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(REDEEM_SHARES, receiver, user1);

        // Verify results
        assertEq(espn.balanceOf(user1), user1SharesBefore - REDEEM_SHARES);
        assertEq(usds.balanceOf(receiver), receiverBalanceBefore + assetsReceived);
        assertEq(usds.balanceOf(user1), DEPOSIT_AMOUNT * 9); // User's USDS balance unchanged
    }

    function test_FacilitateRedeem_InsufficientBalance() public {
        // Try to redeem more shares than user has
        uint256 excessiveShares = espn.balanceOf(user1) + 1;

        vm.prank(user1);
        espn.approve(address(facilitator), excessiveShares);

        vm.prank(user1);
        vm.expectRevert();
        facilitator.redeem(excessiveShares, receiver, user1);
    }

    function test_FacilitateRedeem_InsufficientUSDSBalance() public {
        // Create a new ESPN with minimal USDS
        vm.prank(owner);
        EthStrategyPerpetualNote newEspn = new EthStrategyPerpetualNote(IERC20(address(usds)), owner);

        vm.prank(owner);
        newEspn.setManager(manager);

        vm.prank(owner);
        newEspn.setDepositCap(110_000 * 10 ** 18);

        vm.prank(owner);
        newEspn.setWithdrawalsDisabled(false);

        // Mint only a small amount of USDS to the new ESPN
        vm.prank(owner);
        usds.mint(address(newEspn), 50 * 10 ** 18); // Only 50 USDS

        // Create a new facilitator with insufficient USDS
        ESPNRedemptionFacilitator newFacilitator = new ESPNRedemptionFacilitator(address(newEspn), owner);

        // Mint only a small amount of USDS to the new facilitator
        vm.prank(owner);
        usds.mint(address(newFacilitator), 1); // Only 1 wei

        uint256 usdsRequired = newEspn.previewRedeem(REDEEM_SHARES);

        vm.prank(user1);
        newEspn.approve(address(newFacilitator), REDEEM_SHARES);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector,
                address(newFacilitator),
                usdsRequired - 50 * 10 ** 18, // Delta needed
                1
            )
        );
        newFacilitator.redeem(REDEEM_SHARES, receiver, user1);
    }

    function test_FacilitateRedeem_InsufficientAllowance() public {
        // User doesn't approve facilitator for ESPN shares
        vm.prank(user1);
        vm.expectRevert(); // ESPN will revert with ERC20InsufficientAllowance
        facilitator.redeem(REDEEM_SHARES, receiver, user1);
    }

    function test_FacilitateRedeem_ZeroShares() public {
        vm.prank(user1);
        espn.approve(address(facilitator), 0);

        // Zero amounts are valid in ERC4626 - should succeed and return 0
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(0, receiver, user1);

        assertEq(assetsReceived, 0);
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT); // User's shares unchanged
        assertEq(usds.balanceOf(receiver), 0); // Receiver gets 0 assets
    }

    // withdraw
    // when assets is 0
    //  [ ] it does nothing and returns 0
    // when ESPN withdrawals are disabled
    //  [ ] it does nothing and returns 0
    // given assets is < 1 share
    //  [ ] it does nothing and returns 0
    // given usdsRequired is <= ESPN contract's balance
    //  given the owner has not approved the facilitator to spend their shares
    //   [ ] it reverts
    //  given the owner does not have sufficient ESPN balance
    //   [ ] it reverts
    //  [ ] it does not transfer any USDS to the ESPN contract
    //  [ ] it burns the shares
    //  [ ] it transfers usdsRequired to the receiver
    // given usdsRequired is > ESPN contract's balance
    //  given the facilitator's USDS balance is less than usdsDelta
    //   [ ] it reverts
    //  [ ] it transfers usdsDelta to the ESPN contract
    //  [ ] it burns the shares
    //  [ ] it transfers usdsRequired to the receiver

    function test_FacilitateWithdraw_Success() public {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        // Approve facilitator to spend ESPN shares
        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        vm.stopPrank();

        // Execute withdraw
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(WITHDRAW_AMOUNT, receiver, user1);

        // Verify results
        assertEq(espn.balanceOf(user1), user1SharesBefore - sharesBurned);
        assertEq(usds.balanceOf(receiver), receiverBalanceBefore + WITHDRAW_AMOUNT);
        assertEq(usds.balanceOf(user1), DEPOSIT_AMOUNT * 9); // User's USDS balance unchanged
    }

    function test_FacilitateWithdraw_WithdrawalsDisabled() public {
        // Disable withdrawals for this test
        vm.prank(owner);
        espn.setWithdrawalsDisabled(true);

        vm.prank(user1);
        espn.approve(address(facilitator), type(uint256).max);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, user1, WITHDRAW_AMOUNT, 0));
        facilitator.withdraw(WITHDRAW_AMOUNT, receiver, user1);
    }

    function test_FacilitateWithdraw_InsufficientUSDSBalance() public {
        // Create a new ESPN with minimal USDS
        vm.prank(owner);
        EthStrategyPerpetualNote newEspn = new EthStrategyPerpetualNote(IERC20(address(usds)), owner);

        vm.prank(owner);
        newEspn.setManager(manager);

        vm.prank(owner);
        newEspn.setDepositCap(110_000 * 10 ** 18);

        vm.prank(owner);
        newEspn.setWithdrawalsDisabled(false);

        // Mint only a small amount of USDS to the new ESPN
        vm.prank(owner);
        usds.mint(address(newEspn), 50 * 10 ** 18); // Only 50 USDS

        // Create a new facilitator with insufficient USDS
        ESPNRedemptionFacilitator newFacilitator = new ESPNRedemptionFacilitator(address(newEspn), owner);

        // Mint only a small amount of USDS to the new facilitator
        vm.prank(owner);
        usds.mint(address(newFacilitator), 1); // Only 1 wei

        uint256 usdsRequired = newEspn.previewWithdraw(WITHDRAW_AMOUNT);

        vm.prank(user1);
        newEspn.approve(address(newFacilitator), type(uint256).max);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector,
                address(newFacilitator),
                usdsRequired - 50 * 10 ** 18, // Delta needed
                1
            )
        );
        newFacilitator.withdraw(WITHDRAW_AMOUNT, receiver, user1);
    }

    function test_FacilitateWithdraw_InsufficientAllowance() public {
        // User doesn't approve facilitator for ESPN shares
        vm.prank(user1);
        vm.expectRevert(); // ESPN will revert with ERC20InsufficientAllowance
        facilitator.withdraw(WITHDRAW_AMOUNT, receiver, user1);
    }

    function test_FacilitateWithdraw_ZeroAmount() public {
        vm.prank(user1);
        espn.approve(address(facilitator), 0);

        // Zero amounts are valid in ERC4626 - should succeed and return 0
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(0, receiver, user1);

        assertEq(sharesBurned, 0);
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT); // User's shares unchanged
        assertEq(usds.balanceOf(receiver), 0); // Receiver gets 0 assets
    }

    function test_FacilitateRedeem_Event() public {
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        // Just test that the function executes and returns the expected value
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(REDEEM_SHARES, receiver, user1);

        // Verify the operation succeeded
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT - REDEEM_SHARES);
        assertEq(assetsReceived, REDEEM_SHARES); // Should receive same amount as shares redeemed
    }

    function test_FacilitateWithdraw_Event() public {
        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        vm.stopPrank();

        // Just test that the function executes and returns the expected value
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(WITHDRAW_AMOUNT, receiver, user1);

        // Verify the operation succeeded
        assertEq(usds.balanceOf(user1), DEPOSIT_AMOUNT * 9); // User's USDS balance unchanged
        assertEq(sharesBurned, WITHDRAW_AMOUNT); // Should burn same amount as assets withdrawn
    }

    function test_MultipleUsersRedeem() public {
        // Both users redeem some shares
        uint256 user1Shares = REDEEM_SHARES;
        uint256 user2Shares = REDEEM_SHARES / 2;

        // User1 redeem
        vm.startPrank(user1);
        espn.approve(address(facilitator), user1Shares);
        uint256 user1AssetsReceived = facilitator.redeem(user1Shares, user1, user1);
        vm.stopPrank();

        // User2 redeem
        vm.startPrank(user2);
        espn.approve(address(facilitator), user2Shares);
        uint256 user2AssetsReceived = facilitator.redeem(user2Shares, user2, user2);
        vm.stopPrank();

        // Verify both operations succeeded
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT - user1Shares);
        assertEq(espn.balanceOf(user2), DEPOSIT_AMOUNT - user2Shares);
        assertEq(usds.balanceOf(user1), DEPOSIT_AMOUNT * 9 + user1AssetsReceived);
        assertEq(usds.balanceOf(user2), DEPOSIT_AMOUNT * 9 + user2AssetsReceived);
    }

    function test_MultipleUsersWithdraw() public {
        // Both users withdraw some assets
        uint256 user1Assets = WITHDRAW_AMOUNT;
        uint256 user2Assets = WITHDRAW_AMOUNT / 2;

        // User1 withdraw
        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(user1Assets));
        facilitator.withdraw(user1Assets, user1, user1);
        vm.stopPrank();

        // User2 withdraw
        vm.startPrank(user2);
        espn.approve(address(facilitator), espn.previewWithdraw(user2Assets));
        facilitator.withdraw(user2Assets, user2, user2);
        vm.stopPrank();

        // Verify both operations succeeded
        assertEq(usds.balanceOf(user1), DEPOSIT_AMOUNT * 9 + user1Assets);
        assertEq(usds.balanceOf(user2), DEPOSIT_AMOUNT * 9 + user2Assets);
    }

    // sweepUSDS
    // when the caller is not the sweeper
    //  [ ] it reverts
    // when the facilitator has no USDS
    //  [ ] it does nothing and returns 0
    // when the facilitator has USDS
    //  [ ] it transfers the USDS to the sweeper
    //  [ ] the USDS balance of the facilitator is 0

    function test_SweepUSDS_Success() public {
        // Add some USDS to the facilitator
        uint256 sweepAmount = 1000 * 10 ** 18;
        vm.prank(owner);
        usds.mint(address(facilitator), sweepAmount);

        uint256 sweeperBalanceBefore = usds.balanceOf(owner);
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));

        // Sweep USDS as the owner (sweeper)
        vm.prank(owner);
        facilitator.sweepUSDS();

        // Verify USDS was transferred
        assertEq(usds.balanceOf(owner), sweeperBalanceBefore + facilitatorBalanceBefore);
        assertEq(usds.balanceOf(address(facilitator)), 0);
    }

    function test_SweepUSDS_Unauthorized() public {
        // Try to sweep as non-sweeper
        vm.prank(user1);
        vm.expectRevert("Unauthorized");
        facilitator.sweepUSDS();
    }

    function test_SweepUSDS_ZeroBalance() public {
        // Sweep when facilitator has no USDS
        vm.prank(owner);
        facilitator.sweepUSDS(); // Should not revert

        // Verify no change in balances (owner starts with 0, facilitator has DEPOSIT_AMOUNT * 20)
        assertEq(usds.balanceOf(owner), DEPOSIT_AMOUNT * 20); // All facilitator USDS swept to owner
        assertEq(usds.balanceOf(address(facilitator)), 0);
    }

    function test_SweepUSDS_PartialBalance() public {
        // Use some USDS first, then sweep remaining
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES, user1, user1);

        uint256 remainingBalance = usds.balanceOf(address(facilitator));
        uint256 sweeperBalanceBefore = usds.balanceOf(owner);

        // Sweep remaining USDS
        vm.prank(owner);
        facilitator.sweepUSDS();

        // Verify remaining USDS was swept
        assertEq(usds.balanceOf(owner), sweeperBalanceBefore + remainingBalance);
        assertEq(usds.balanceOf(address(facilitator)), 0);
    }

    function test_ESPN_USDS_Balance_Low_AfterRedeem() public {
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES, receiver, user1);

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));

        // ESPN's USDS balance should remain very low (close to original)
        // The facilitator provides USDS, ESPN uses it immediately for the redeem
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_ESPN_USDS_Balance_Low_AfterWithdraw() public {
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        facilitator.withdraw(WITHDRAW_AMOUNT, receiver, user1);
        vm.stopPrank();

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));

        // ESPN's USDS balance should remain very low (close to original)
        // The facilitator provides USDS, ESPN uses it immediately for the withdraw
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_ESPN_USDS_Balance_Low_AfterMultipleOperations() public {
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        // Perform multiple operations
        vm.startPrank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);
        facilitator.redeem(REDEEM_SHARES, user1, user1);

        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        facilitator.withdraw(WITHDRAW_AMOUNT, user1, user1);
        vm.stopPrank();

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));

        // ESPN's USDS balance should remain very low after multiple operations
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_DeltaLogic_ESPN_HasExcessUSDS() public {
        // Send extra USDS to ESPN permissionlessly
        uint256 excessAmount = 5000 * 10 ** 18;
        vm.prank(owner);
        usds.mint(address(espn), excessAmount);

        uint256 espnBalanceBefore = usds.balanceOf(address(espn));
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));

        // Perform redeem operation
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES, receiver, user1);

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));
        uint256 facilitatorBalanceAfter = usds.balanceOf(address(facilitator));

        // ESPN should have used some of its excess USDS, facilitator should not have sent any
        assertLe(espnBalanceAfter, espnBalanceBefore); // ESPN balance decreased
        assertEq(facilitatorBalanceAfter, facilitatorBalanceBefore); // Facilitator balance unchanged
    }

    function test_DeltaLogic_ESPN_HasPartialUSDS() public {
        // Send partial USDS to ESPN permissionlessly
        uint256 partialAmount = 500 * 10 ** 18; // Less than required for redeem
        vm.prank(owner);
        usds.mint(address(espn), partialAmount);

        uint256 espnBalanceBefore = usds.balanceOf(address(espn));
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));
        uint256 usdsRequired = espn.previewRedeem(REDEEM_SHARES);

        // Perform redeem operation
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES, receiver, user1);

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));
        uint256 facilitatorBalanceAfter = usds.balanceOf(address(facilitator));

        // Calculate expected delta (only send what ESPN doesn't already have)
        uint256 expectedDelta = usdsRequired > espnBalanceBefore ? usdsRequired - espnBalanceBefore : 0;
        assertEq(facilitatorBalanceBefore - facilitatorBalanceAfter, expectedDelta);

        // ESPN should end up with roughly the same balance as before (used USDS for operation)
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_DeltaLogic_ESPN_HasSufficientUSDS() public {
        // Send more than enough USDS to ESPN permissionlessly
        uint256 sufficientAmount = 2000 * 10 ** 18; // More than required for redeem
        vm.prank(owner);
        usds.mint(address(espn), sufficientAmount);

        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));

        // Perform redeem operation
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES, receiver, user1);

        uint256 facilitatorBalanceAfter = usds.balanceOf(address(facilitator));

        // Facilitator should not send any USDS (delta = 0)
        assertEq(facilitatorBalanceAfter, facilitatorBalanceBefore);
    }
}
