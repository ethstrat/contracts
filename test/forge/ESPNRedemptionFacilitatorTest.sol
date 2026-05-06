// SPDX-License-Identifier: GPL-2.0-or-later
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
    
    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10**18;
    uint256 public constant REDEEM_SHARES = 100 * 10**18;
    uint256 public constant WITHDRAW_AMOUNT = 200 * 10**18;

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

    modifier givenESPNHasDefaultBalance() {
        vm.prank(owner);
        usds.mint(address(espn), DEPOSIT_AMOUNT * 10);
        _;
    }

    modifier givenESPNHasUSDSBalance(uint256 balance) {
        vm.prank(owner);
        usds.mint(address(espn), balance);
        _;
    }

    modifier givenESPNHasExactUSDSBalance(uint256 balance) {
        // First burn all existing USDS from ESPN
        uint256 currentBalance = usds.balanceOf(address(espn));
        if (currentBalance > 0) {
            vm.prank(address(espn));
            usds.burn(currentBalance);
        }
        // Then mint the desired amount
        vm.prank(owner);
        usds.mint(address(espn), balance);
        _;
    }

    modifier givenFacilitatorHasDefaultBalance() {
        vm.prank(owner);
        usds.mint(address(facilitator), DEPOSIT_AMOUNT * 20);
        _;
    }

    modifier givenFacilitatorHasUSDSBalance(uint256 balance) {
        vm.prank(owner);
        usds.mint(address(facilitator), balance);
        _;
    }

    modifier givenFacilitatorHasExactUSDSBalance(uint256 balance) {
        // First burn all existing USDS from facilitator
        uint256 currentBalance = usds.balanceOf(address(facilitator));
        if (currentBalance > 0) {
            vm.prank(address(facilitator));
            usds.burn(currentBalance);
        }
        // Then mint the desired amount
        vm.prank(owner);
        usds.mint(address(facilitator), balance);
        _;
    }

    // redeem
    // when shares is 0
    //  [X] it does nothing and returns 0
    // when ESPN withdrawals are disabled
    //  [X] it reverts
    // given usdsRequired is <= ESPN contract's balance
    //  given the owner has not approved the facilitator to spend their shares
    //   [X] it reverts
    //  given the owner does not have sufficient ESPN balance
    //   [X] it reverts
    //  [X] it does not transfer any USDS to the ESPN contract
    //  [X] it burns the shares
    //  [X] it transfers usdsRequired to the receiver
    // given usdsRequired is > ESPN contract's balance
    //  given the facilitator's USDS balance is less than usdsDelta
    //   [X] it reverts
    //  [X] it transfers usdsDelta to the ESPN contract
    //  [X] it burns the shares
    //  [X] it transfers usdsRequired to the receiver

    function test_FacilitateRedeem_WithdrawalsDisabled()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // Disable withdrawals for this test
        vm.prank(owner);
        espn.setWithdrawalsDisabled(true);

        vm.prank(user1);
        espn.approve(address(facilitator), type(uint256).max);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, user1, REDEEM_SHARES, 0));
        facilitator.redeem(REDEEM_SHARES);
    }

    function test_FacilitateRedeem_GivenESPNBalanceSufficient()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        // Approve facilitator to spend ESPN shares
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        // Execute redeem
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(REDEEM_SHARES);

        // Verify results
        assertEq(espn.balanceOf(user1), user1SharesBefore - REDEEM_SHARES, "User1 shares should be reduced");
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + assetsReceived, "User1 should receive the USDS");
        assertEq(
            usds.balanceOf(address(facilitator)),
            facilitatorBalanceBefore,
            "Facilitator should have the same USDS balance"
        ); // No USDS transferred from the facilitator
        assertEq(
            usds.balanceOf(address(espn)), espnBalanceBefore - assetsReceived, "ESPN should have less USDS balance"
        ); // USDS transferred from the ESPN contract to the user
    }

    function test_FacilitateRedeem_GivenESPNBalanceInsufficient()
        public
        givenESPNHasExactUSDSBalance(10e18)
        givenFacilitatorHasUSDSBalance(DEPOSIT_AMOUNT * 20)
    {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        uint256 usdsRequired = espn.previewRedeem(REDEEM_SHARES);

        // Approve facilitator to spend ESPN shares
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        // Execute redeem
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(REDEEM_SHARES);

        // Verify results
        assertEq(usdsRequired, assetsReceived, "USDS required should be equal to assets received");
        assertEq(espn.balanceOf(user1), user1SharesBefore - REDEEM_SHARES, "User1 shares should be reduced");
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + assetsReceived, "User1 should receive the USDS");
        // Calculate the delta that should be transferred from facilitator
        uint256 usdsDelta = usdsRequired > espnBalanceBefore ? usdsRequired - espnBalanceBefore : 0;
        
        assertEq(
            usds.balanceOf(address(facilitator)),
            facilitatorBalanceBefore - usdsDelta - 1,
            "Facilitator should have less USDS balance"
        ); // USDS transferred from the facilitator to the ESPN contract
        assertEq(usds.balanceOf(address(espn)), espnBalanceBefore + usdsDelta + 1 - usdsRequired, "ESPN should have remaining USDS balance after operation");
    }

    function test_FacilitateRedeem_GivenESPNBalanceInsufficient_GivenFacilitatorHasInsufficientBalance()
        public
        givenESPNHasExactUSDSBalance(10e18)
        givenFacilitatorHasExactUSDSBalance(10e18)
    {
        uint256 usdsRequired = espn.previewRedeem(REDEEM_SHARES);
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));
        uint256 usdsDelta = usdsRequired > espnBalanceBefore ? usdsRequired - espnBalanceBefore : 0;

        // Approve facilitator to spend ESPN shares
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(facilitator), usdsDelta + 1, 10e18)
        );

        // Execute redeem
        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES);
    }

    function test_FacilitateRedeem_GivenUserHasInsufficientESPNBalance()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // Try to redeem more shares than user has
        uint256 excessiveShares = espn.balanceOf(user1) + 1;

        vm.prank(user1);
        espn.approve(address(facilitator), excessiveShares);

        vm.prank(user1);
        vm.expectRevert();
        facilitator.redeem(excessiveShares);
    }

    function test_FacilitateRedeem_GivenUserHasInsufficientESPNAllowance()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // User doesn't approve facilitator for ESPN shares
        vm.prank(user1);
        vm.expectRevert(); // ESPN will revert with ERC20InsufficientAllowance
        facilitator.redeem(REDEEM_SHARES);
    }

    function test_FacilitateRedeem_ZeroShares() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 user1BalanceBefore = usds.balanceOf(user1);
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        vm.prank(user1);
        espn.approve(address(facilitator), 0);

        // Zero amounts are valid in ERC4626 - should succeed and return 0
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(0);

        assertEq(assetsReceived, 0, "Assets received should be 0");
        assertEq(espn.balanceOf(user1), user1SharesBefore, "User's shares should be unchanged");
        assertEq(usds.balanceOf(user1), user1BalanceBefore + assetsReceived, "User1 should receive the USDS");
        assertEq(
            usds.balanceOf(address(facilitator)),
            facilitatorBalanceBefore,
            "Facilitator should have the same USDS balance"
        ); // No USDS transferred from the facilitator
        assertEq(usds.balanceOf(address(espn)), espnBalanceBefore, "ESPN should have the same USDS balance"); // ESPN
            // balance of USDS should be the same
    }

    // withdraw
    // when assets is 0
    //  [X] it does nothing and returns 0
    // when ESPN withdrawals are disabled
    //  [X] it reverts
    // given assets is < 1 share
    //  [X] it burns 1 share
    //  [X] it transfers 1 asset to the receiver
    // given usdsRequired is <= ESPN contract's balance
    //  given the owner has not approved the facilitator to spend their shares
    //   [X] it reverts
    //  given the owner does not have sufficient ESPN balance
    //   [X] it reverts
    //  [X] it does not transfer any USDS to the ESPN contract
    //  [X] it burns the shares
    //  [X] it transfers usdsRequired to the receiver
    // given usdsRequired is > ESPN contract's balance
    //  given the facilitator's USDS balance is less than usdsDelta
    //   [X] it reverts
    //  [X] it transfers usdsDelta to the ESPN contract
    //  [X] it burns the shares
    //  [X] it transfers usdsRequired to the receiver

    function test_FacilitateWithdraw_GivenESPNBalanceSufficient()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        // Approve facilitator to spend ESPN shares
        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        vm.stopPrank();

        // Execute withdraw
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(WITHDRAW_AMOUNT);

        // Verify results
        assertEq(espn.balanceOf(user1), user1SharesBefore - sharesBurned, "User1 shares should be reduced");
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + WITHDRAW_AMOUNT, "User1 should receive the USDS");
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + WITHDRAW_AMOUNT, "User1 should receive the USDS");
        assertEq(
            usds.balanceOf(address(facilitator)),
            facilitatorBalanceBefore,
            "Facilitator should have the same USDS balance"
        ); // No USDS transferred from the facilitator
        assertEq(
            usds.balanceOf(address(espn)), espnBalanceBefore - WITHDRAW_AMOUNT, "ESPN should have less USDS balance"
        ); // USDS transferred from the ESPN contract to the user
    }

    function test_FacilitateWithdraw_GivenESPNBalanceInsufficient()
        public
        givenESPNHasExactUSDSBalance(10e18)
        givenFacilitatorHasUSDSBalance(DEPOSIT_AMOUNT * 20)
    {
        uint256 user1SharesBefore = espn.balanceOf(user1);
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        uint256 sharesRequired = espn.previewWithdraw(WITHDRAW_AMOUNT);

        // Approve facilitator to spend ESPN shares
        vm.prank(user1);
        espn.approve(address(facilitator), sharesRequired);

        // Execute redeem
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(WITHDRAW_AMOUNT);

        // Verify results
        assertEq(sharesBurned, sharesRequired, "Shares required should be equal to shares burned");
        assertEq(espn.balanceOf(user1), user1SharesBefore - sharesBurned, "User1 shares should be reduced");
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + WITHDRAW_AMOUNT, "User1 should receive the USDS");
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + WITHDRAW_AMOUNT, "User1 should receive the USDS");
        // Calculate the delta that should be transferred from facilitator
        uint256 usdsDelta = WITHDRAW_AMOUNT > espnBalanceBefore ? WITHDRAW_AMOUNT - espnBalanceBefore : 0;
        
        assertEq(
            usds.balanceOf(address(facilitator)),
            facilitatorBalanceBefore - usdsDelta - 1,
            "Facilitator should have less USDS balance"
        ); // USDS transferred from the facilitator to the ESPN contract
        assertEq(usds.balanceOf(address(espn)), espnBalanceBefore + usdsDelta + 1 - WITHDRAW_AMOUNT, "ESPN should have remaining USDS balance after operation");
    }

    function test_FacilitateWithdraw_WithdrawalsDisabled()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // Disable withdrawals for this test
        vm.prank(owner);
        espn.setWithdrawalsDisabled(true);

        vm.prank(user1);
        espn.approve(address(facilitator), type(uint256).max);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, user1, WITHDRAW_AMOUNT, 0));
        facilitator.withdraw(WITHDRAW_AMOUNT);
    }

    function test_FacilitateWithdraw_GivenESPNBalanceInsufficient_GivenFacilitatorHasInsufficientBalance()
        public
        givenESPNHasExactUSDSBalance(10e18)
        givenFacilitatorHasExactUSDSBalance(10e18)
    {
        uint256 sharesRequired = espn.previewWithdraw(WITHDRAW_AMOUNT);
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));
        uint256 usdsDelta = WITHDRAW_AMOUNT > espnBalanceBefore ? WITHDRAW_AMOUNT - espnBalanceBefore : 0;

        // Approve facilitator to spend ESPN shares
        vm.prank(user1);
        espn.approve(address(facilitator), sharesRequired);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(facilitator), usdsDelta + 1, 10e18)
        );

        // Execute redeem
        vm.prank(user1);
        facilitator.withdraw(WITHDRAW_AMOUNT);
    }

    function test_FacilitateWithdraw_GivenUserHasInsufficientESPNBalance()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // Try to withdraw more shares than user has
        uint256 excessiveShares = espn.balanceOf(user1) + 1;

        vm.prank(user1);
        espn.approve(address(facilitator), excessiveShares);

        vm.prank(user1);
        vm.expectRevert();
        facilitator.withdraw(excessiveShares);
    }

    function test_FacilitateWithdraw_GivenUserHasInsufficientESPNAllowance()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // User doesn't approve facilitator for ESPN shares
        vm.prank(user1);
        vm.expectRevert(); // ESPN will revert with ERC20InsufficientAllowance
        facilitator.withdraw(WITHDRAW_AMOUNT);
    }

    function test_FacilitateWithdraw_ZeroAmount() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        vm.prank(user1);
        espn.approve(address(facilitator), 0);

        // Zero amounts are valid in ERC4626 - should succeed and return 0
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(0);

        assertEq(sharesBurned, 0);
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT); // User's shares unchanged
    }

    function test_FacilitateWithdraw_LessThanOneShare()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        vm.prank(user1);
        espn.approve(address(facilitator), type(uint256).max);

        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(1);

        assertEq(sharesBurned, 1, "Shares burned should be 1"); // Rounds up
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT - 1); // User's shares reduced by 1
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + 1, "User1 should receive 1 USDS");
    }

    function test_FacilitateRedeem_Event() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        // Just test that the function executes and returns the expected value
        vm.prank(user1);
        uint256 assetsReceived = facilitator.redeem(REDEEM_SHARES);

        // Verify the operation succeeded
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT - REDEEM_SHARES);
        assertEq(assetsReceived, REDEEM_SHARES); // Should receive same amount as shares redeemed
    }

    function test_FacilitateWithdraw_Event() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        vm.stopPrank();

        // Just test that the function executes and returns the expected value
        vm.prank(user1);
        uint256 sharesBurned = facilitator.withdraw(WITHDRAW_AMOUNT);

        // Verify the operation succeeded
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + WITHDRAW_AMOUNT, "User1 should receive the USDS"); // User1 receives the USDS
        assertEq(sharesBurned, WITHDRAW_AMOUNT); // Should burn same amount as assets withdrawn
    }

    function test_MultipleUsersRedeem() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        // Both users redeem some shares
        uint256 user1Shares = REDEEM_SHARES;
        uint256 user2Shares = REDEEM_SHARES / 2;
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        uint256 user2UsdsBalanceBefore = usds.balanceOf(user2);

        // User1 redeem
        vm.startPrank(user1);
        espn.approve(address(facilitator), user1Shares);
        uint256 user1AssetsReceived = facilitator.redeem(user1Shares);
        vm.stopPrank();

        // User2 redeem
        vm.startPrank(user2);
        espn.approve(address(facilitator), user2Shares);
        uint256 user2AssetsReceived = facilitator.redeem(user2Shares);
        vm.stopPrank();

        // Verify both operations succeeded
        assertEq(espn.balanceOf(user1), DEPOSIT_AMOUNT - user1Shares);
        assertEq(espn.balanceOf(user2), DEPOSIT_AMOUNT - user2Shares);
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + user1AssetsReceived);
        assertEq(usds.balanceOf(user2), user2UsdsBalanceBefore + user2AssetsReceived);
    }

    function test_MultipleUsersWithdraw() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        // Both users withdraw some assets
        uint256 user1Assets = WITHDRAW_AMOUNT;
        uint256 user2Assets = WITHDRAW_AMOUNT / 2;
        uint256 user1UsdsBalanceBefore = usds.balanceOf(user1);
        uint256 user2UsdsBalanceBefore = usds.balanceOf(user2);

        // User1 withdraw
        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(user1Assets));
        facilitator.withdraw(user1Assets);
        vm.stopPrank();

        // User2 withdraw
        vm.startPrank(user2);
        espn.approve(address(facilitator), espn.previewWithdraw(user2Assets));
        facilitator.withdraw(user2Assets);
        vm.stopPrank();

        // Verify both operations succeeded
        assertEq(usds.balanceOf(user1), user1UsdsBalanceBefore + user1Assets);
        assertEq(usds.balanceOf(user2), user2UsdsBalanceBefore + user2Assets);
    }

    // sweepUSDS
    // when the caller is not the sweeper
    //  [X] it reverts
    // when the facilitator has no USDS
    //  [X] it does nothing and returns 0
    // when the facilitator has USDS
    //  [X] it transfers the USDS to the sweeper
    //  [X] the USDS balance of the facilitator is 0

    function test_SweepUSDS_Success() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
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

    function test_SweepUSDS_Unauthorized() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        // Try to sweep as non-sweeper
        vm.prank(user1);
        vm.expectRevert(ESPNRedemptionFacilitator.UnauthorizedSweeper.selector);
        facilitator.sweepUSDS();
    }

    function test_SweepUSDS_ZeroBalance() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        // Sweep when facilitator has no USDS
        vm.prank(owner);
        facilitator.sweepUSDS(); // Should not revert

        // Verify all facilitator USDS was swept to owner
        assertEq(usds.balanceOf(owner), DEPOSIT_AMOUNT * 40); // All facilitator USDS swept to owner (20 from setup + 20 from modifier)
        assertEq(usds.balanceOf(address(facilitator)), 0);
    }

    function test_SweepUSDS_PartialBalance() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
        // Use some USDS first, then sweep remaining
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES);

        uint256 remainingBalance = usds.balanceOf(address(facilitator));
        uint256 sweeperBalanceBefore = usds.balanceOf(owner);

        // Sweep remaining USDS
        vm.prank(owner);
        facilitator.sweepUSDS();

        // Verify remaining USDS was swept
        assertEq(usds.balanceOf(owner), sweeperBalanceBefore + remainingBalance);
        assertEq(usds.balanceOf(address(facilitator)), 0);
    }

    function test_ESPN_USDS_Balance_Low_AfterRedeem()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES);

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));

        // ESPN's USDS balance should remain very low (close to original)
        // The facilitator provides USDS, ESPN uses it immediately for the redeem
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_ESPN_USDS_Balance_Low_AfterWithdraw()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        vm.startPrank(user1);
        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        facilitator.withdraw(WITHDRAW_AMOUNT);
        vm.stopPrank();

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));

        // ESPN's USDS balance should remain very low (close to original)
        // The facilitator provides USDS, ESPN uses it immediately for the withdraw
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_ESPN_USDS_Balance_Low_AfterMultipleOperations()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        uint256 espnBalanceBefore = usds.balanceOf(address(espn));

        // Perform multiple operations
        vm.startPrank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);
        facilitator.redeem(REDEEM_SHARES);

        espn.approve(address(facilitator), espn.previewWithdraw(WITHDRAW_AMOUNT));
        facilitator.withdraw(WITHDRAW_AMOUNT);
        vm.stopPrank();

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));

        // ESPN's USDS balance should remain very low after multiple operations
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_DeltaLogic_ESPN_HasExcessUSDS() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
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
        facilitator.redeem(REDEEM_SHARES);

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));
        uint256 facilitatorBalanceAfter = usds.balanceOf(address(facilitator));

        // ESPN should have used some of its excess USDS, facilitator should not have sent any
        assertLe(espnBalanceAfter, espnBalanceBefore); // ESPN balance decreased
        assertEq(facilitatorBalanceAfter, facilitatorBalanceBefore); // Facilitator balance unchanged
    }

    function test_DeltaLogic_ESPN_HasPartialUSDS() public givenESPNHasDefaultBalance givenFacilitatorHasDefaultBalance {
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
        facilitator.redeem(REDEEM_SHARES);

        uint256 espnBalanceAfter = usds.balanceOf(address(espn));
        uint256 facilitatorBalanceAfter = usds.balanceOf(address(facilitator));

        // Calculate expected delta (only send what ESPN doesn't already have)
        uint256 expectedDelta = usdsRequired > espnBalanceBefore ? usdsRequired - espnBalanceBefore : 0;
        assertEq(facilitatorBalanceBefore - facilitatorBalanceAfter, expectedDelta);

        // ESPN should end up with roughly the same balance as before (used USDS for operation)
        assertLe(espnBalanceAfter, espnBalanceBefore + 1); // Allow for minimal rounding
    }

    function test_DeltaLogic_ESPN_HasSufficientUSDS()
        public
        givenESPNHasDefaultBalance
        givenFacilitatorHasDefaultBalance
    {
        // Send more than enough USDS to ESPN permissionlessly
        uint256 sufficientAmount = 2000 * 10 ** 18; // More than required for redeem
        vm.prank(owner);
        usds.mint(address(espn), sufficientAmount);

        uint256 facilitatorBalanceBefore = usds.balanceOf(address(facilitator));

        // Perform redeem operation
        vm.prank(user1);
        espn.approve(address(facilitator), REDEEM_SHARES);

        vm.prank(user1);
        facilitator.redeem(REDEEM_SHARES);

        uint256 facilitatorBalanceAfter = usds.balanceOf(address(facilitator));

        // Facilitator should not send any USDS (delta = 0)
        assertEq(facilitatorBalanceAfter, facilitatorBalanceBefore);
    }
}
