// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StakedEthStrategyPerpetualNoteLP} from "../../src/StakedEthStrategyPerpetualNoteLP.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IYieldManager} from "../../src/interfaces/IYieldManager.sol";

contract MockLP is MockERC20 {
    constructor() {
        initialize("Mock LP Token", "LP", 18);
        _mint(msg.sender, 10000000 * 10**18);
    }
}

contract MockYieldManager is IYieldManager {
    IERC20 public token;
    uint256 public accruedYield; // Can be set explicitly for testing
    
    constructor(IERC20 _token) {
        token = _token;
    }
    
    function setAccruedYield(uint256 _accruedYield) external {
        accruedYield = _accruedYield;
    }
    
    function remit() external override {
        if (accruedYield > 0) {
            // Send the accrued yield to the caller (staking contract)
            token.transfer(msg.sender, accruedYield);
            // Reset accrued yield after remitting
            accruedYield = 0;
        }
    }

    function accrued() external view override returns (uint256) {
        return accruedYield;
    }
}

contract StakedEthStrategyPerpetualNoteLPTest is Test {
    StakedEthStrategyPerpetualNoteLP public vault;
    IERC20 public lpToken;
    MockYieldManager public yieldManager;
    
    address public owner = address(0x1);
    address public manager = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public randomUser = address(0x5);
    
    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10**18; // 1000 LP tokens
    uint256 public constant YIELD_AMOUNT = 20 * 10**18; // 20 LP tokens

    function setUp() public {
        // Deploy mock LP token
        lpToken = IERC20(address(new MockLP()));
        
        // Deploy yield manager
        yieldManager = new MockYieldManager(lpToken);
        
        // Fund the yield manager with tokens
        lpToken.transfer(address(yieldManager), 100000 * 10**18);
        
        // Deploy vault
        vault = new StakedEthStrategyPerpetualNoteLP(lpToken, address(yieldManager), owner);
        
        // Transfer tokens to users
        lpToken.transfer(user1, DEPOSIT_AMOUNT * 4);
        lpToken.transfer(user2, DEPOSIT_AMOUNT * 4);
        lpToken.transfer(address(yieldManager), DEPOSIT_AMOUNT * 4);

        // Approve vault to spend tokens
        lpToken.approve(address(vault), lpToken.totalSupply());
        vm.prank(user1);
        lpToken.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        lpToken.approve(address(vault), type(uint256).max);

        // Start with no accrued yield
        yieldManager.setAccruedYield(0);
    }

    function test_Constructor() external view {
        assertEq(vault.owner(), owner);
        assertEq(address(vault.asset()), address(lpToken));
        assertEq(vault.name(), "Staked ETH Strategy Perpetual Note LP");
        assertEq(vault.symbol(), "sESPN-LP");
        assertEq(vault.decimals(), 18);
        assertEq(vault.yieldManager(), address(yieldManager));
    }

    function test_OnlyOwnerCanSetYieldManager() public {
        address newYieldManager = address(0x6);
        
        // Owner can set yield manager
        vm.prank(owner);
        vault.setYieldManager(newYieldManager);
        assertEq(vault.yieldManager(), newYieldManager);
        
        // Non-owner cannot set yield manager
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        vault.setYieldManager(address(0x7));
        
        // Yield manager should remain unchanged
        assertEq(vault.yieldManager(), newYieldManager);
    }

    function test_YieldIncreasesTotalAssets() public {
        // Initial deposit
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 totalAssetsBefore = vault.totalAssets();
        
        // Set yield for next operation
        yieldManager.setAccruedYield(YIELD_AMOUNT);

        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT + YIELD_AMOUNT);
        assertGt(vault.totalAssets(), totalAssetsBefore);
    }

    //// Tests for regular ERC4626 behavior when yield manager is not set

    function test_MintWithoutYieldManager() public {
        // Set yield manager to zero address
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        uint256 mintAmount = 500 * 10**18; // 500 shares
        uint256 vaultBalanceBefore = vault.totalAssets();
        
        // Mint shares
        uint256 assetsRequired = vault.previewMint(mintAmount);
        vault.mint(mintAmount, user1);
        
        // Check that vault only received the required assets, no yield
        uint256 vaultBalanceAfter = vault.totalAssets();
        assertEq(vaultBalanceAfter - vaultBalanceBefore, assetsRequired);
        
        // Check that user received the correct shares
        assertEq(vault.balanceOf(user1), mintAmount);
    }

    function test_DepositWithoutYieldManager() public {
        // Set yield manager to zero address
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        uint256 depositAmount = 1000 * 10**18; // 1000 assets
        uint256 vaultBalanceBefore = vault.totalAssets();
        
        // Deposit assets
        uint256 sharesReceived = vault.deposit(depositAmount, user1);
        
        // Check that vault only received the deposit, no yield
        uint256 vaultBalanceAfter = vault.totalAssets();
        assertEq(vaultBalanceAfter - vaultBalanceBefore, depositAmount);
        
        // Check that user received shares
        assertEq(vault.balanceOf(user1), sharesReceived);
        assertGt(sharesReceived, 0);
    }

    function test_WithdrawWithoutYieldManager() public {
        // Set yield manager to zero address
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // First deposit to get some shares
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 withdrawAmount = 500 * 10**18; // 500 assets
        uint256 vaultBalanceBefore = vault.totalAssets();
        
        // Withdraw assets
        vm.prank(user1);
        uint256 sharesBurned = vault.withdraw(withdrawAmount, user1, user1);
        
        // Check that vault only lost the withdrawn amount, no yield received
        uint256 vaultBalanceAfter = vault.totalAssets();
        assertEq(vaultBalanceBefore - vaultBalanceAfter, withdrawAmount);
        
        // Check that shares were burned
        assertGt(sharesBurned, 0);
        assertLt(vault.balanceOf(user1), DEPOSIT_AMOUNT);
    }

    function test_RedeemWithoutYieldManager() public {
        // Set yield manager to zero address
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // First deposit to get some shares
        uint256 initialShares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 redeemAmount = initialShares / 2; // Redeem half the shares
        uint256 vaultBalanceBefore = vault.totalAssets();
        
        // Redeem shares
        vm.prank(user1);
        uint256 assetsReceived = vault.redeem(redeemAmount, user1, user1);
        
        // Check that vault only lost the redeemed assets, no yield received
        uint256 vaultBalanceAfter = vault.totalAssets();
        assertEq(vaultBalanceBefore - vaultBalanceAfter, assetsReceived);
        
        // Check that shares were burned
        assertEq(vault.balanceOf(user1), initialShares - redeemAmount);
        assertGt(assetsReceived, 0);
    }

    // Tests for multiple users with ERC4626 behavior (no yield manager)
    function test_MultipleUsersDepositAndWithdrawWithoutYieldManager() public {
        // Set yield manager to zero address to test pure ERC4626 behavior
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // User 1 deposits 1000 tokens
        uint256 user1Shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // User 2 deposits 500 tokens
        uint256 user2Deposit = 500 * 10**18;
        uint256 user2Shares = vault.deposit(user2Deposit, user2);
        
        // User 3 deposits 2000 tokens
        uint256 user3Deposit = 2000 * 10**18;
        uint256 user3Shares = vault.deposit(user3Deposit, randomUser);
        
        // Verify total assets and shares
        uint256 totalAssets = DEPOSIT_AMOUNT + user2Deposit + user3Deposit;
        uint256 totalShares = user1Shares + user2Shares + user3Shares;
        
        assertEq(vault.totalAssets(), totalAssets);
        assertEq(vault.totalSupply(), totalShares);
        
        // Verify individual balances
        assertEq(vault.balanceOf(user1), user1Shares);
        assertEq(vault.balanceOf(user2), user2Shares);
        assertEq(vault.balanceOf(randomUser), user3Shares);
        
        // User 1 withdraws half their assets
        uint256 user1WithdrawAmount = DEPOSIT_AMOUNT / 2;
        vm.prank(user1);
        uint256 user1SharesBurned = vault.withdraw(user1WithdrawAmount, user1, user1);
        
        // User 2 redeems half their shares
        uint256 user2RedeemShares = user2Shares / 2;
        vm.prank(user2);
        uint256 user2AssetsReceived = vault.redeem(user2RedeemShares, user2, user2);
        
        // Verify remaining balances
        assertEq(vault.balanceOf(user1), user1Shares - user1SharesBurned);
        assertEq(vault.balanceOf(user2), user2Shares - user2RedeemShares);
        assertEq(vault.balanceOf(randomUser), user3Shares);
        
        // Verify total assets decreased correctly
        uint256 expectedTotalAssets = totalAssets - user1WithdrawAmount - user2AssetsReceived;
        assertEq(vault.totalAssets(), expectedTotalAssets);
        
        // Verify total shares decreased correctly
        uint256 expectedTotalShares = totalShares - user1SharesBurned - user2RedeemShares;
        assertEq(vault.totalSupply(), expectedTotalShares);
    }

    function test_MultipleUsersMintAndRedeemWithoutYieldManager() public {
        // Set yield manager to zero address to test pure ERC4626 behavior
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // User 1 mints 100 shares
        uint256 user1MintShares = 100 * 10**18;
        uint256 user1AssetsRequired = vault.mint(user1MintShares, user1);
        
        // User 2 mints 200 shares
        uint256 user2MintShares = 200 * 10**18;
        uint256 user2AssetsRequired = vault.mint(user2MintShares, user2);
        
        // User 3 mints 50 shares
        uint256 user3MintShares = 50 * 10**18;
        uint256 user3AssetsRequired = vault.mint(user3MintShares, randomUser);
        
        // Verify total assets and shares
        uint256 totalAssets = user1AssetsRequired + user2AssetsRequired + user3AssetsRequired;
        uint256 totalShares = user1MintShares + user2MintShares + user3MintShares;
        
        assertEq(vault.totalAssets(), totalAssets);
        assertEq(vault.totalSupply(), totalShares);
        
        // Verify individual balances
        assertEq(vault.balanceOf(user1), user1MintShares);
        assertEq(vault.balanceOf(user2), user2MintShares);
        assertEq(vault.balanceOf(randomUser), user3MintShares);
        
        // User 1 redeems all their shares
        vm.prank(user1);
        uint256 user1AssetsReceived = vault.redeem(user1MintShares, user1, user1);
        
        // User 2 withdraws half their assets
        uint256 user2WithdrawAmount = user2AssetsRequired / 2;
        vm.prank(user2);
        uint256 user2SharesBurned = vault.withdraw(user2WithdrawAmount, user2, user2);
        
        // Verify remaining balances
        assertEq(vault.balanceOf(user1), 0);
        assertEq(vault.balanceOf(user2), user2MintShares - user2SharesBurned);
        assertEq(vault.balanceOf(randomUser), user3MintShares);
        
        // Verify total assets decreased correctly
        uint256 expectedTotalAssets = totalAssets - user1AssetsReceived - user2WithdrawAmount;
        assertEq(vault.totalAssets(), expectedTotalAssets);
        
        // Verify total shares decreased correctly
        uint256 expectedTotalShares = totalShares - user1MintShares - user2SharesBurned;
        assertEq(vault.totalSupply(), expectedTotalShares);
    }

    function test_MultipleUsersSharePriceConsistencyWithoutYieldManager() public {
        // Set yield manager to zero address to test pure ERC4626 behavior
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // User 1 deposits 1000 tokens
        uint256 user1Shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Calculate share price after first deposit
        uint256 sharePrice1 = (DEPOSIT_AMOUNT * 1e18) / user1Shares;
        
        // User 2 deposits 2000 tokens
        uint256 user2Deposit = 2000 * 10**18;
        uint256 user2Shares = vault.deposit(user2Deposit, user2);
        
        // Calculate share price after second deposit (should be same)
        uint256 totalAssets = DEPOSIT_AMOUNT + user2Deposit;
        uint256 totalShares = user1Shares + user2Shares;
        uint256 sharePrice2 = (totalAssets * 1e18) / totalShares;
        
        // Share prices should be equal (1:1 ratio)
        assertEq(sharePrice1, 1e18);
        assertEq(sharePrice2, 1e18);
        
        // User 3 mints 500 shares
        uint256 user3MintShares = 500 * 10**18;
        uint256 user3AssetsRequired = vault.mint(user3MintShares, randomUser);
        
        // Verify mint required correct assets (500 tokens for 500 shares)
        assertEq(user3AssetsRequired, user3MintShares);
        
        // Verify final state
        assertEq(vault.totalAssets(), totalAssets + user3AssetsRequired);
        assertEq(vault.totalSupply(), totalShares + user3MintShares);
        assertEq(vault.balanceOf(randomUser), user3MintShares);
    }

    function test_MultipleUsersWithdrawAndRedeemPrecisionWithoutYieldManager() public {
        // Set yield manager to zero address to test pure ERC4626 behavior
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // User 1 deposits 1000 tokens
        uint256 user1Shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // User 2 deposits 333 tokens (odd number to test precision)
        uint256 user2Deposit = 333 * 10**18;
        uint256 user2Shares = vault.deposit(user2Deposit, user2);
        
        // User 1 withdraws 100 tokens
        uint256 user1WithdrawAmount = 100 * 10**18;
        vm.prank(user1);
        uint256 user1SharesBurned = vault.withdraw(user1WithdrawAmount, user1, user1);
        
        // User 2 redeems 50 shares
        uint256 user2RedeemShares = 50 * 10**18;
        vm.prank(user2);
        uint256 user2AssetsReceived = vault.redeem(user2RedeemShares, user2, user2);
        
        // Verify precision: shares burned should equal assets withdrawn (1:1 ratio)
        assertEq(user1SharesBurned, user1WithdrawAmount);
        
        // Verify precision: assets received should equal shares redeemed (1:1 ratio)
        assertEq(user2AssetsReceived, user2RedeemShares);
        
        // Verify remaining balances
        assertEq(vault.balanceOf(user1), user1Shares - user1SharesBurned);
        assertEq(vault.balanceOf(user2), user2Shares - user2RedeemShares);
        
        // Verify total assets and shares are consistent
        uint256 expectedTotalAssets = DEPOSIT_AMOUNT + user2Deposit - user1WithdrawAmount - user2AssetsReceived;
        uint256 expectedTotalShares = user1Shares + user2Shares - user1SharesBurned - user2RedeemShares;
        
        assertEq(vault.totalAssets(), expectedTotalAssets);
        assertEq(vault.totalSupply(), expectedTotalShares);
        
        // Verify share price is still 1:1
        uint256 finalSharePrice = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertEq(finalSharePrice, 1e18);
    }

    function test_MultipleUsersMaxWithdrawAndRedeemWithoutYieldManager() public {
        // Set yield manager to zero address to test pure ERC4626 behavior
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // User 1 deposits 1000 tokens
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // User 2 deposits 500 tokens
        uint256 user2Deposit = 500 * 10**18;
        uint256 user2Shares = vault.deposit(user2Deposit, user2);
        
        // User 1 withdraws all their assets
        vm.prank(user1);
        uint256 user1SharesBurned = vault.withdraw(DEPOSIT_AMOUNT, user1, user1);
        
        // User 2 redeems all their shares
        vm.prank(user2);
        uint256 user2AssetsReceived = vault.redeem(user2Shares, user2, user2);
        
        // Verify both users have zero shares
        assertEq(vault.balanceOf(user1), 0);
        assertEq(vault.balanceOf(user2), 0);
        
        // Verify vault is empty
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        
        // Verify assets received match deposits
        assertEq(user1SharesBurned, DEPOSIT_AMOUNT);
        assertEq(user2AssetsReceived, user2Deposit);
    }

    // Tests for preview functions with unremitted yield
    function test_PreviewDepositWithUnremittedYield() public {
        // Initial deposit to establish baseline
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 depositAmount = 500 * 10**18; // 500 assets
        
        // Preview deposit with no unremitted yield
        yieldManager.setAccruedYield(0);
        uint256 sharesWithoutYield = vault.previewDeposit(depositAmount);
        
        // Preview deposit with unremitted yield
        yieldManager.setAccruedYield(YIELD_AMOUNT);
        uint256 sharesWithYield = vault.previewDeposit(depositAmount);
        
        // Should generate fewer shares when there is unremitted yield
        // because totalAssets includes the unremitted yield, making the same asset amount
        // represent a smaller percentage of total assets
        assertLe(sharesWithYield, sharesWithoutYield);
    }

    function test_PreviewMintWithUnremittedYield() public {
        // Initial deposit to establish baseline
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 mintShares = 200 * 10**18; // 200 shares
        
        // Preview mint with no unremitted yield
        yieldManager.setAccruedYield(0);
        uint256 assetsWithoutYield = vault.previewMint(mintShares);
        
        // Preview mint with unremitted yield
        yieldManager.setAccruedYield(YIELD_AMOUNT);
        uint256 assetsWithYield = vault.previewMint(mintShares);
        
        // Should require more assets when there is unremitted yield
        // because totalAssets includes the unremitted yield, making the same share amount
        // represent a smaller percentage of total supply
        assertGt(assetsWithYield, assetsWithoutYield);
    }

    function test_PreviewWithdrawWithUnremittedYield() public {
        // Initial deposit to establish baseline
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Second deposit to trigger yield remittance
        yieldManager.setAccruedYield(YIELD_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user2);
        
        uint256 withdrawAmount = 300 * 10**18; // 300 assets
        
        // Preview withdraw with no additional unremitted yield
        yieldManager.setAccruedYield(0);
        uint256 sharesWithoutYield = vault.previewWithdraw(withdrawAmount);
        
        // Preview withdraw with additional unremitted yield
        yieldManager.setAccruedYield(YIELD_AMOUNT);
        uint256 sharesWithYield = vault.previewWithdraw(withdrawAmount);
        
        // Should burn fewer shares when there is unremitted yield
        // because totalAssets includes the unremitted yield, making the same asset amount
        // represent a smaller percentage of total assets
        assertLe(sharesWithYield, sharesWithoutYield);
    }

    function test_PreviewRedeemWithUnremittedYield() public {
        // Initial deposit to establish baseline
        uint256 user1Shares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Second deposit to trigger yield remittance
        yieldManager.setAccruedYield(YIELD_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, user2);
        
        uint256 redeemShares = user1Shares / 4; // Redeem quarter of user1's shares
        
        // Preview redeem with no additional unremitted yield
        yieldManager.setAccruedYield(0);
        uint256 assetsWithoutYield = vault.previewRedeem(redeemShares);
        
        // Preview redeem with additional unremitted yield
        yieldManager.setAccruedYield(YIELD_AMOUNT);
        uint256 assetsWithYield = vault.previewRedeem(redeemShares);
        
        // Should return more assets when there is unremitted yield
        // because totalAssets includes the unremitted yield, making the same share amount
        // represent a larger percentage of total supply
        assertGt(assetsWithYield, assetsWithoutYield);
    }


    function test_PreviewFunctionsWithZeroYieldManager() public {
        // Set yield manager to zero address
        vm.prank(owner);
        vault.setYieldManager(address(0));
        
        // Initial deposit to establish baseline
        vault.deposit(DEPOSIT_AMOUNT, user1);
        
        uint256 depositAmount = 500 * 10**18;
        uint256 mintShares = 200 * 10**18;
        uint256 withdrawAmount = 300 * 10**18;
        uint256 redeemShares = 100 * 10**18;
        
        // Get preview values (should not be affected by yield manager)
        uint256 previewDepositShares = vault.previewDeposit(depositAmount);
        uint256 previewMintAssets = vault.previewMint(mintShares);
        uint256 previewWithdrawShares = vault.previewWithdraw(withdrawAmount);
        uint256 previewRedeemAssets = vault.previewRedeem(redeemShares);
        
        // Perform actual operations
        uint256 actualDepositShares = vault.deposit(depositAmount, user2);
        
        uint256 actualMintAssets = vault.mint(mintShares, randomUser);
        
        vm.prank(user1);
        uint256 actualWithdrawShares = vault.withdraw(withdrawAmount, user1, user1);
        
        vm.prank(user1);
        uint256 actualRedeemAssets = vault.redeem(redeemShares, user1, user1);
        
        // Verify preview functions match actual operations (1:1 ratio)
        assertEq(previewDepositShares, actualDepositShares);
        assertEq(previewMintAssets, actualMintAssets);
        assertEq(previewWithdrawShares, actualWithdrawShares);
        assertEq(previewRedeemAssets, actualRedeemAssets);
        
        // Verify 1:1 ratios when no yield manager
        assertEq(previewDepositShares, depositAmount);
        assertEq(previewMintAssets, mintShares);
        assertEq(previewWithdrawShares, withdrawAmount);
        assertEq(previewRedeemAssets, redeemShares);
    }

    // Tests for deposit/mint with yield manager and unremitted yield (double the deposit)

    function test_DepositWithYieldManagerDoubleUnremittedYield() public {
        // Initial deposit to establish baseline
        uint256 firstDepositShares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Set unremitted yield to the deposit amount
        yieldManager.setAccruedYield(DEPOSIT_AMOUNT);
        
        // Second deposit should result in half as many shares due to double unremitted yield
        uint256 secondDepositShares = vault.deposit(DEPOSIT_AMOUNT, user2);
        
        // Should generate exactly half the shares because unremitted yield doubles totalAssets
        assertEq(secondDepositShares, firstDepositShares / 2);
        
        // Verify total assets include both deposits plus remitted yield
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT * 3);
        
        // Verify total supply is sum of both deposits
        assertEq(vault.totalSupply(), firstDepositShares + secondDepositShares);
    }

    function test_MintWithYieldManagerDoubleUnremittedYield() public {
        // Initial deposit to establish baseline
        uint256 user1DepositedAssets = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Set unremitted yield to the deposit amount
        yieldManager.setAccruedYield(DEPOSIT_AMOUNT);

        // Second deposit should need twice as many assets
        uint256 user2DepositedAssets = vault.mint(DEPOSIT_AMOUNT, user2);
        assertEq(user2DepositedAssets, DEPOSIT_AMOUNT * 2);
        assertEq(user2DepositedAssets, user1DepositedAssets * 2);
        
        // Verify total assets include both deposits + yield
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT * 4);
    }

    function test_WithdrawWithYieldManagerDoubleUnremittedYield() public {
        // Initial deposit to establish baseline
        uint256 firstDepositShares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Set unremitted yield to the deposit amount
        yieldManager.setAccruedYield(DEPOSIT_AMOUNT);
        
        // Withdraw should burn half the shares when there is unremitted yield
        vm.startPrank(user1);
        vault.approve(address(vault), type(uint256).max);
        uint256 sharedRedeemed = vault.withdraw(DEPOSIT_AMOUNT, user1, user1);
        assertApproxEqAbs(sharedRedeemed, firstDepositShares / 2, 1);

        // Withdraw remainder should work (confirms yield is remitted on withdraw)
        vault.withdraw(vault.convertToAssets(vault.balanceOf(user1)), user1, user1);
        assertApproxEqAbs(vault.balanceOf(user1), 0, 1);
        vm.stopPrank();
    }

    function test_RedeemWithYieldManagerDoubleUnremittedYield() public {
        // Initial deposit to establish baseline
        uint256 firstDepositShares = vault.deposit(DEPOSIT_AMOUNT, user1);
        
        // Set unremitted yield to the deposit amount
        yieldManager.setAccruedYield(DEPOSIT_AMOUNT);
        
        // redeem half should return DEPOSIT_AMOUNT
        vm.startPrank(user1);
        vault.approve(address(vault), type(uint256).max);
        uint256 assetsReceived = vault.redeem(firstDepositShares / 2, user1, user1);
        assertApproxEqAbs(assetsReceived, DEPOSIT_AMOUNT, 1);

        // redeem remainder should work (confirms yield is remitted on redeem)
        assetsReceived = vault.redeem(vault.balanceOf(user1), user1, user1);
        assertApproxEqAbs(assetsReceived, DEPOSIT_AMOUNT, 1);
        assertEq(vault.balanceOf(user1), 0);
        vm.stopPrank();
    }
}
