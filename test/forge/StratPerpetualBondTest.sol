// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StratPerpetualBond} from "../../src/StratPerpetualBond.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDS is MockERC20 {
    constructor() {
        initialize("Mock USDS", "USDS", 18);
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract StratPerpetualBondTest is Test {
    StratPerpetualBond public pb;
    IERC20 public usds;
    
    address public owner = address(0x1);
    address public manager = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public randomUser = address(0x5);
    
    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10**18; // 1K tokens
    uint256 public constant ADD_ASSETS_AMOUNT = 500 * 10**18; // 500 tokens
    uint256 public constant INITIAL_DEPOSIT_CAP = DEPOSIT_AMOUNT * 10; // 10K tokens
    
    function setUp() public {
        // Deploy mock ERC20 token
        usds = IERC20(address(new MockUSDS()));
        
        // Deploy pb
        pb = new StratPerpetualBond(usds, owner);
        
        // Set manager
        vm.prank(owner);
        pb.setManager(manager);
        
        // Transfer tokens to users
        usds.transfer(user1, DEPOSIT_AMOUNT);
        usds.transfer(user2, DEPOSIT_AMOUNT);

        // default approve all transfers of USDS into perpetual bond
        usds.approve(address(pb), usds.totalSupply());

        vm.prank(owner);
        pb.setDepositCap(INITIAL_DEPOSIT_CAP);
    }

    function test_Constructor() external view {
        assertEq(pb.owner(), owner);
        assertEq(address(pb.asset()), address(usds));
        assertEq(pb.name(), "STRAT Perpetual Bond");
        assertEq(pb.symbol(), "PBS");
        assertEq(pb.decimals(), 18);
        assertEq(pb.manager(), manager);
        assertEq(pb.totalAssets(), 0);
        assertEq(pb.withdrawalsDisabled(), true);
    }

    //// Test 1: Only my own totalAsset calc is used to convert between shares/assets
    //// (sending _asset to the contract has no effect)
    
    function test_AssetTransferToContractHasNoEffectOnTotalAssets() public {
        // First, add some assets through the proper channel
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);
        assertEq(pb.totalAssets(), ADD_ASSETS_AMOUNT);
        
        // Now send tokens directly to the contract (this should NOT affect totalAssets)
        uint256 totalAssetsBefore = pb.totalAssets();
        usds.transfer(address(pb), DEPOSIT_AMOUNT);
        assertEq(pb.totalAssets(), totalAssetsBefore);
        
        // The contract should have received the tokens but totalAssets is unchanged
        assertEq(usds.balanceOf(address(pb)), DEPOSIT_AMOUNT);
    }

    function test_ConvertToSharesUsesCustomTotalAssets() public {
        // Add assets through proper channel
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);
        
        // Test conversion using custom totalAssets
        uint256 shares = pb.convertToShares(DEPOSIT_AMOUNT);
        
        // Now send tokens directly to contract
        usds.transfer(address(pb), DEPOSIT_AMOUNT);
        
        // Conversion should still use the same totalAssets (not affected by direct transfer)
        uint256 sharesAfterTransfer = pb.convertToShares(DEPOSIT_AMOUNT);
        assertEq(shares, sharesAfterTransfer);
    }

    function test_ConvertToAssetsUsesCustomTotalAssets() public {
        // First deposit to get some shares
        uint256 shares = pb.deposit(DEPOSIT_AMOUNT, user1);
        
        // Add assets through proper channel
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);

        // Test conversion using custom totalAssets
        uint256 assets = pb.convertToAssets(shares);
        assertApproxEqRel(assets, DEPOSIT_AMOUNT + ADD_ASSETS_AMOUNT, 0.001e18);

        // Now send tokens directly to contract
        usds.transfer(address(pb), DEPOSIT_AMOUNT);
        
        // Conversion should still use the same totalAssets (not affected by direct transfer)
        uint256 assetsAfterTransfer = pb.convertToAssets(shares);
        assertEq(assets, assetsAfterTransfer);
    }

    //// Test 2: Only the manager can toggle withdrawals
    //// and only the manager can change the manager
    
    function test_OnlyOwnerCanSetManager() public {
        address newManager = address(0x6);
        
        // Owner can set manager
        vm.prank(owner);
        pb.setManager(newManager);
        assertEq(pb.manager(), newManager);
        
        // Non-owner cannot set manager
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        pb.setManager(address(0x7));
        
        // Manager should remain unchanged
        assertEq(pb.manager(), newManager);
    }

    function test_OnlyOwnerCanToggleWithdrawals() public {
        // Owner can enable/disable withdrawals
        vm.startPrank(owner);
        pb.setWithdrawalsDisabled(false);
        assertEq(pb.withdrawalsDisabled(), false);
        pb.setWithdrawalsDisabled(true);
        assertEq(pb.withdrawalsDisabled(), true);
        vm.stopPrank();
        
        // Non-owner cannot change withdrawal state
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        pb.setWithdrawalsDisabled(false);
        
        // Withdrawal state should remain unchanged
        assertEq(pb.withdrawalsDisabled(), true);
    }

    //// Deposits transfer funds to the manager
    
    function test_DepositTransfersFundsToManager() public {
        uint256 managerBalanceBefore = usds.balanceOf(manager);
        uint256 userBalanceBefore = usds.balanceOf(user1);
        
        vm.startPrank(user1);
        usds.approve(address(pb), DEPOSIT_AMOUNT);
        uint256 shares = pb.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();
        
        // Check that funds were transferred to manager
        uint256 managerBalanceAfter = usds.balanceOf(manager);
        assertEq(managerBalanceAfter, managerBalanceBefore + DEPOSIT_AMOUNT);
    
        // Check that user's balance decreased
        uint256 userBalanceAfter = usds.balanceOf(user1);
        assertEq(userBalanceAfter, userBalanceBefore - DEPOSIT_AMOUNT);
    
        // Check that user received shares
        assertGt(shares, 0);
        assertEq(pb.balanceOf(user1), shares);
    }

    function test_AddAssetsTransfersFundsToManager() public {
        uint256 managerBalanceBefore = usds.balanceOf(manager);
        
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);
        
        // Check that funds were transferred to manager
        uint256 managerBalanceAfter = usds.balanceOf(manager);
        assertEq(managerBalanceAfter, managerBalanceBefore + ADD_ASSETS_AMOUNT);
        
        // Check that totalAssets increased
        assertEq(pb.totalAssets(), ADD_ASSETS_AMOUNT);
    }

    // Withdrawals tests

    function test_WithdrawFailsWhenDisabled() public {
        // Deposit assets
        pb.deposit(DEPOSIT_AMOUNT, user1);

        // Ensure withdrawals are disabled (default)
        assertEq(pb.withdrawalsDisabled(), true);

        // Try to withdraw, expect revert
        usds.transfer(address(pb), DEPOSIT_AMOUNT);
        vm.prank(user1);
        vm.expectRevert("WithdrawalsDisabled()");
        pb.withdraw(DEPOSIT_AMOUNT, user1, user1);
    }
    
    function test_WithdrawUpdatesTotalAssets() public {
        // First deposit and add assets
        vm.startPrank(user1);
        usds.approve(address(pb), DEPOSIT_AMOUNT);
        pb.deposit(DEPOSIT_AMOUNT, user1);
        vm.stopPrank();
        
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);
        
        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);
        
        // Withdraw
        uint256 totalAssetsBefore = pb.totalAssets();
        usds.transfer(address(pb), DEPOSIT_AMOUNT + ADD_ASSETS_AMOUNT);
        vm.prank(user1);
        pb.withdraw(DEPOSIT_AMOUNT, user1, user1);
        
        // Check that totalAssets decreased
        uint256 totalAssetsAfter = pb.totalAssets();
        assertEq(totalAssetsAfter, ADD_ASSETS_AMOUNT);
        assertLt(totalAssetsAfter, totalAssetsBefore);
     }

    // Deposit Cap Tests

    function test_OwnerCanSetDepositCap() public {
        uint256 newCap = 5000 * 10**18; // 5K tokens
        
        vm.prank(owner);
        pb.setDepositCap(newCap);
        
        assertEq(pb.depositCap(), newCap);
    }

    function test_NonOwnerCannotSetDepositCap() public {
        uint256 newCap = 5000 * 10**18;
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        pb.setDepositCap(newCap);
        
        // Cap should remain unchanged
        assertEq(pb.depositCap(), INITIAL_DEPOSIT_CAP);
    }

    function test_DepositFailsWhenCapExceeded() public {
        // Set a deposit cap
        uint256 cap = 2000 * 10**18; // 2K tokens
        vm.prank(owner);
        pb.setDepositCap(cap);
        
        // First deposit should succeed (within cap)
        uint256 firstDeposit = 1000 * 10**18; // 1K tokens
        pb.deposit(firstDeposit, user1);
        assertEq(pb.totalAssets(), firstDeposit);
        
        // Second deposit should also succeed (still within cap)
        uint256 secondDeposit = 800 * 10**18; // 800 tokens
        pb.deposit(secondDeposit, user2);
        assertEq(pb.totalAssets(), firstDeposit + secondDeposit);
        
        // Third deposit should fail (would exceed cap)
        uint256 thirdDeposit = 500 * 10**18; // 500 tokens
        vm.expectRevert("DepositCapExceeded()");
        pb.deposit(thirdDeposit, randomUser);
        
        // Total assets should remain unchanged
        assertEq(pb.totalAssets(), firstDeposit + secondDeposit);
    }

    function test_DepositCapWithWithdrawals() public {
        // Set a deposit cap
        uint256 cap = 3000 * 10**18; // 3K tokens
        vm.prank(owner);
        pb.setDepositCap(cap);
        
        // Deposit up to cap
        pb.deposit(cap, user1);
        assertEq(pb.totalAssets(), cap);

        // deposit should fail
        vm.expectRevert("DepositCapExceeded()");
        pb.deposit(cap, user2);
        
        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);
        
        // Withdraw some assets
        uint256 withdrawal = 1000 * 10**18; // 1K tokens
        usds.transfer(address(pb), withdrawal); // Ensure contract has tokens
        vm.prank(user1);
        pb.withdraw(withdrawal, user1, user1);

        // Capacity should be restored
        assertEq(pb.totalAssets(), cap - withdrawal);
        
        // Should be able to deposit again up to the restored capacity
        pb.deposit(withdrawal, user2);
        assertEq(pb.totalAssets(), cap);
    }
}