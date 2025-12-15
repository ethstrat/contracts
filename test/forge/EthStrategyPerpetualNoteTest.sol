// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

contract MockUSDS is MockERC20 {
    constructor() {
        initialize("Mock USDS", "USDS", 18);
        _mint(msg.sender, 1000000 * 10 ** 18);
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}

contract EthStrategyPerpetualNoteTest is Test {
    EthStrategyPerpetualNote public pb;
    IERC20 public usds;

    address public owner = address(0x1);
    address public manager = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public randomUser = address(0x5);

    uint256 public constant DEPOSIT_AMOUNT = 1000 * 10 ** 18; // $1K
    uint256 public constant ADD_ASSETS_AMOUNT = 500 * 10 ** 18; // $500
    uint256 public constant INITIAL_DEPOSIT_CAP = 110_000 * 10 ** 18; // $110K
    uint256 public constant INITIAL_ASSETS = DEPOSIT_AMOUNT * 100; // $100K
    uint256 public constant INITIAL_SHARES = DEPOSIT_AMOUNT; // $1K

    uint256 public constant NO_DEPOSIT_CAP = type(uint256).max;

    function setUp() public {
        // Deploy mock ERC20 token
        usds = IERC20(address(new MockUSDS()));

        // Deploy pb
        pb = new EthStrategyPerpetualNote(usds, owner);

        // Set manager
        vm.prank(owner);
        pb.setManager(manager);

        // Transfer tokens to users
        usds.transfer(user1, DEPOSIT_AMOUNT);
        usds.transfer(user2, DEPOSIT_AMOUNT);

        // default approve all transfers of USDS into perpetual bond
        usds.approve(address(pb), usds.totalSupply());

        // initial deposit cap
        vm.prank(owner);
        pb.setDepositCap(INITIAL_DEPOSIT_CAP);

        // Setup initial conversion rate as 1 share is 100 assets
        pb.deposit(INITIAL_SHARES, address(this));
        pb.increaseAssetsPerShare(INITIAL_ASSETS - INITIAL_SHARES);
    }

    function test_Constructor() external view {
        assertEq(pb.owner(), owner);
        assertEq(address(pb.asset()), address(usds));
        assertEq(pb.name(), "ETH Strategy Perpetual Note");
        assertEq(pb.symbol(), "ESPN");
        assertEq(pb.decimals(), 18);
        assertEq(pb.manager(), manager);
        assertEq(pb.totalAssets(), INITIAL_ASSETS);
        assertEq(pb.withdrawalsDisabled(), true);
    }

    //// Only my own totalAsset calc is used to convert between shares/assets
    //// (sending _asset to the contract has no effect)

    function test_AssetTransferToContractHasNoEffectOnTotalAssets() public {
        // First, add some assets through the proper channel
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);
        assertEq(pb.totalAssets(), ADD_ASSETS_AMOUNT + INITIAL_ASSETS);

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
        assertApproxEqRel(assets, DEPOSIT_AMOUNT, 0.005e18);

        // Now send tokens directly to contract
        usds.transfer(address(pb), DEPOSIT_AMOUNT);

        // Conversion should still use the same totalAssets (not affected by direct transfer)
        uint256 assetsAfterTransfer = pb.convertToAssets(shares);
        assertEq(assets, assetsAfterTransfer);
    }

    //// Only the owner can toggle withdrawals
    //// and only the owner can change the manager

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
        uint256 totalAssetsBefore = pb.totalAssets();

        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);

        // Check that funds were transferred to manager
        assertEq(usds.balanceOf(manager), managerBalanceBefore + ADD_ASSETS_AMOUNT);

        // Check that totalAssets increased
        assertEq(pb.totalAssets(), totalAssetsBefore + ADD_ASSETS_AMOUNT);
    }

    //// Withdrawals tests

    function test_WithdrawFailsWhenDisabled() public {
        // Deposit assets
        pb.deposit(DEPOSIT_AMOUNT, user1);

        // Ensure withdrawals are disabled (default)
        assertEq(pb.withdrawalsDisabled(), true);

        // Try to withdraw, expect revert
        usds.transfer(address(pb), DEPOSIT_AMOUNT);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxWithdraw(address,uint256,uint256)", user1, DEPOSIT_AMOUNT, 0)
        );
        pb.withdraw(DEPOSIT_AMOUNT, user1, user1);
    }

    function test_WithdrawUpdatesTotalAssets() public {
        // First deposit and add assets
        pb.deposit(DEPOSIT_AMOUNT, user1);
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
        assertEq(totalAssetsAfter, totalAssetsBefore - DEPOSIT_AMOUNT);
        assertLt(totalAssetsAfter, totalAssetsBefore);

        // Remaining USDS in contract should be ADD_ASSETS_AMOUNT
        assertEq(usds.balanceOf(address(pb)), ADD_ASSETS_AMOUNT);
    }

    function test_RedeemUpdatesTotalAssets() public {
        // First deposit and add assets
        uint256 shares = pb.deposit(DEPOSIT_AMOUNT, user1);
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);
        uint256 totalAssetsAfterIncrease = pb.totalAssets();

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Transfer assets back to contract for redemption (simulating yield being returned)
        usds.transfer(address(pb), DEPOSIT_AMOUNT + ADD_ASSETS_AMOUNT);
        vm.prank(user1);
        uint256 assetsReceived = pb.redeem(shares, user1, user1);

        // Check that shares were burned and assets were received
        assertEq(pb.balanceOf(user1), 0);
        // Check that totalAssets decreased (allowing for rounding in ERC4626 calculations)
        assertEq(pb.totalAssets(), totalAssetsAfterIncrease - assetsReceived);
    }
    
    function test_OnlyShareOwnerCanRedeemOrWithdraw() public {
        // First deposit and add assets
        uint256 shares = pb.deposit(DEPOSIT_AMOUNT, user1);
        pb.increaseAssetsPerShare(ADD_ASSETS_AMOUNT);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        usds.transfer(address(pb), DEPOSIT_AMOUNT + ADD_ASSETS_AMOUNT);

        // Withdraw
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, shares));
        pb.redeem(shares, user2, user1);

        // redeem
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, shares));
        pb.redeem(shares, user2, user1);
    }

    function test_ShareOwnerCanDelegateRedeemOrWithdraw() public {
        // First deposit and add assets
        uint256 shares = pb.deposit(DEPOSIT_AMOUNT * 2, user1);
        pb.deposit(DEPOSIT_AMOUNT, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        usds.transfer(address(pb), DEPOSIT_AMOUNT);
        vm.prank(user1);
        pb.approve(user2, 3);

        // Withdraw
        vm.prank(user2);
        pb.withdraw(1, user2, user1);

        // redeem
        vm.prank(user2);
        pb.redeem(1, user2, user1);
    }

    //// Deposit Cap Tests

    function test_OwnerCanSetDepositCap() public {
        uint256 newCap = 5000 * 10 ** 18; // 5K tokens

        vm.prank(owner);
        pb.setDepositCap(newCap);

        assertEq(pb.depositCap(), newCap);
    }

    function test_NonOwnerCannotSetDepositCap() public {
        uint256 newCap = 5000 * 10 ** 18;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        pb.setDepositCap(newCap);

        // Cap should remain unchanged
        assertEq(pb.depositCap(), INITIAL_DEPOSIT_CAP);
    }

    function test_DepositSucceedsWithNoDepositCap() public {
        // Set no deposit cap
        vm.prank(owner);
        pb.setDepositCap(NO_DEPOSIT_CAP);

        // Deposit should succeed
        uint256 firstDeposit = 1000 * 10 ** 18; // 1K tokens
        pb.deposit(firstDeposit, user1);
        assertEq(pb.totalAssets(), INITIAL_ASSETS + firstDeposit);
    }

    function test_DepositFailsWhenCapExceeded() public {
        // Set a deposit cap
        uint256 cap = INITIAL_ASSETS + 2000 * 10 ** 18; // 2K tokens
        vm.prank(owner);
        pb.setDepositCap(cap);

        // First deposit should succeed (within cap)
        uint256 firstDeposit = 1000 * 10 ** 18; // 1K tokens
        pb.deposit(firstDeposit, user1);
        assertEq(pb.totalAssets(), INITIAL_ASSETS + firstDeposit);

        // Second deposit should also succeed (still within cap)
        uint256 secondDeposit = 800 * 10 ** 18; // 800 tokens
        pb.deposit(secondDeposit, user2);
        assertEq(pb.totalAssets(), INITIAL_ASSETS + firstDeposit + secondDeposit);

        // Third deposit should fail (would exceed cap)
        uint256 thirdDeposit = 500 * 10 ** 18; // 500 tokens
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC4626ExceededMaxDeposit(address,uint256,uint256)",
                randomUser,
                thirdDeposit,
                cap - INITIAL_ASSETS - firstDeposit - secondDeposit
            )
        );
        pb.deposit(thirdDeposit, randomUser);

        // Total assets should remain unchanged
        assertEq(pb.totalAssets(), INITIAL_ASSETS + firstDeposit + secondDeposit);
    }

    function test_DepositCapWithWithdrawals() public {
        // Set a deposit cap
        uint256 capIncrease = 3000 * 10 ** 18; // 3k
        uint256 cap = INITIAL_ASSETS + capIncrease;
        vm.prank(owner);
        pb.setDepositCap(cap);

        // Deposit up to cap
        pb.deposit(capIncrease, user1);
        assertEq(pb.totalAssets(), cap);

        // deposit should fail
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", user2, capIncrease, 0)
        );
        pb.deposit(capIncrease, user2);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Withdraw some assets
        uint256 withdrawal = 1000 * 10 ** 18; // 1K tokens
        usds.transfer(address(pb), withdrawal); // Ensure contract has tokens
        vm.prank(user1);
        pb.withdraw(withdrawal, user1, user1);

        // Capacity should be restored
        assertEq(pb.totalAssets(), cap - withdrawal);

        // Should be able to deposit again up to the restored capacity
        pb.deposit(withdrawal, user2);
        assertEq(pb.totalAssets(), cap);
    }

    function test_MaxDeposit_RespectsDepositCap() public {
        // Set no deposit cap
        vm.prank(owner);
        pb.setDepositCap(NO_DEPOSIT_CAP);

        // maxDeposit should be uint256 max since there is no cap
        assertEq(pb.maxDeposit(user1), type(uint256).max - INITIAL_ASSETS, "maxDeposit with no cap");

        // Set deposit cap to 2000 tokens
        uint256 cap = 2000 * 10 ** 18;
        vm.prank(owner);
        pb.setDepositCap(INITIAL_ASSETS + cap);

        // No deposits yet, maxDeposit should be cap
        assertEq(pb.maxDeposit(user1), cap);

        // Deposit 1500 tokens
        pb.deposit(1500 * 10 ** 18, user1);

        // maxDeposit should be cap - deposited
        assertEq(pb.maxDeposit(user1), 500 * 10 ** 18);

        // Deposit up to cap
        pb.deposit(500 * 10 ** 18, user2);

        // maxDeposit should now be 0
        assertEq(pb.maxDeposit(user1), 0);
    }

    function test_MaxMint_RespectsDepositCap() public {
        // Set deposit cap to 1000 tokens
        uint256 cap = 1000 * 10 ** 18;
        vm.prank(owner);
        pb.setDepositCap(INITIAL_ASSETS + cap);

        // For a fresh vault, 1:100, so maxDeposit should be 100x maxMint
        uint256 maxDepositAmount = pb.maxDeposit(user1);
        uint256 maxMintAmount = pb.maxMint(user1);
        assertApproxEqRel(maxMintAmount * 100, maxDepositAmount, 0.005e18);

        // Deposit 600 tokens
        pb.deposit(600 * 10 ** 18, user1);

        // maxMint should now be previewDeposit(400 tokens)
        uint256 expectedMint = pb.previewDeposit(400 * 10 ** 18);
        assertEq(pb.maxMint(user1), expectedMint);

        // Deposit up to cap
        pb.deposit(400 * 10 ** 18, user2);

        // maxMint should now be 0
        assertEq(pb.maxMint(user1), 0);
    }

    function test_MaxWithdraw_WithdrawalsDisabled() public {
        // Deposit for user1
        pb.deposit(1000 * 10 ** 18, user1);

        // Withdrawals are disabled by default
        assertEq(pb.maxWithdraw(user1), 0);
    }

    function test_MaxRedeem_WithdrawalsDisabled() public {
        // Deposit for user1
        pb.deposit(1000 * 10 ** 18, user1);

        // Withdrawals are disabled by default
        assertEq(pb.maxRedeem(user1), 0);
    }

    function test_MaxWithdraw_RespectsContractBalance() public {
        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Deposit for user1 and user2
        pb.deposit(1000 * 10 ** 18, user1);
        pb.deposit(1000 * 10 ** 18, user2);

        // Send only 500 tokens to contract
        usds.transfer(address(pb), 500 * 10 ** 18);

        // Each user has 10 shares, but only 500 tokens in contract
        // maxWithdraw for each should be at most 500
        assertEq(pb.maxWithdraw(user1), 500 * 10 ** 18);
        assertEq(pb.maxWithdraw(user2), 500 * 10 ** 18);

        // Send more tokens to contract
        usds.transfer(address(pb), 1500 * 10 ** 18);

        // Now contract has 2000 tokens, so each can withdraw up to their share
        assertApproxEqAbs(pb.maxWithdraw(user1), 1000 * 10 ** 18, 1);
        assertApproxEqAbs(pb.maxWithdraw(user2), 1000 * 10 ** 18, 1);
    }

    function test_MaxRedeem_RespectsContractBalance() public {
        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Deposit for user1 and user2
        pb.deposit(1000 * 10 ** 18, user1);
        pb.deposit(1000 * 10 ** 18, user2);

        // Only 500 tokens in contract
        usds.transfer(address(pb), 500 * 10 ** 18);

        // Each user has 10 shares, but only 500 tokens in contract
        // maxRedeem for each should be 5 shares (since 1:100)
        assertEq(pb.maxRedeem(user1), 5 * 10 ** 18);
        assertEq(pb.maxRedeem(user2), 5 * 10 ** 18);

        // Send more tokens to contract
        usds.transfer(address(pb), 1500 * 10 ** 18);

        // Now contract has 2000 tokens, so each can redeem up to their share
        assertEq(pb.maxRedeem(user1), 10 * 10 ** 18);
        assertEq(pb.maxRedeem(user2), 10 * 10 ** 18);
    }

    function test_BurnShares_DecreasesTotalSupply() public {
        // Mint 1000 shares to user1
        uint256 mintedShares = pb.deposit(1000 * 10 ** 18, user1);
        assertEq(mintedShares, 10 * 10 ** 18);
        assertEq(pb.totalSupply(), INITIAL_SHARES + 10 * 10 ** 18);
        uint256 totalAssetsBefore = pb.totalAssets();

        // Burn 500 shares
        vm.prank(user1);
        pb.burn(5 * 10 ** 18);

        // Now totalSupply should go down by 5, while totalAssets should remain the same
        assertEq(pb.totalSupply(), INITIAL_SHARES + 5 * 10 ** 18);
        assertEq(pb.totalAssets(), totalAssetsBefore);
    }

    // redeem tests
    // given withdrawals are disabled
    //  [X] it reverts

    function test_Redeem_WithdrawalsDisabled() public {
        // Deposit for user1
        uint256 shares = pb.deposit(1000 * 10 ** 18, user1);

        // Fund the contract with USDS
        usds.transfer(address(pb), 1000 * 10 ** 18);

        // Withdrawals are disabled by default
        assertEq(pb.maxRedeem(user1), 0);

        // Expect revert
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", user1, shares, 0));

        // Call function
        vm.prank(user1);
        pb.redeem(shares, user2, user1);
    }

    // when the caller is the token holder
    //  [X] it burns the shares
    //  [X] it transfers the assets to the receiver

    function test_Redeem_WhenCallerIsTokenHolder(address recipient_) public {
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 shares = pb.deposit(1000 * 10 ** 18, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), 1000 * 10 ** 18);
        uint256 expectedAssets = pb.previewRedeem(shares);
        uint256 recipientBalanceBefore = usds.balanceOf(recipient_);

        // Call function
        vm.prank(user1);
        pb.redeem(shares, recipient_, user1);

        // Check that the shares were burned
        assertEq(pb.balanceOf(user1), 0, "shares were not burned");

        // Check that the assets were transferred to the receiver
        assertEq(
            usds.balanceOf(recipient_),
            recipientBalanceBefore + expectedAssets,
            "assets were not transferred to the receiver"
        );
    }

    // when the caller is not the token holder
    //  given the token holder has not approved the caller to spend the shares
    //   [X] it reverts

    function test_Redeem_WhenCallerIsNotTokenHolder(address recipient_) public {
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 shares = pb.deposit(1000 * 10 ** 18, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), 1000 * 10 ** 18);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", user2, 0, shares)
        );

        // Call function
        vm.prank(user2);
        pb.redeem(shares, recipient_, user1);
    }

    // given the caller is not the approved spender
    //  [X] it reverts

    function test_Redeem_WhenCallerIsNotTokenHolder_GivenTokenHolderHasApproved_WhenCallerIsNotApprovedSpender(
        address caller_,
        address recipient_
    ) public {
        vm.assume(caller_ != user1 && caller_ != user2);
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 shares = pb.deposit(1000 * 10 ** 18, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), 1000 * 10 ** 18);

        // Approve user2 to spend shares
        vm.prank(user1);
        pb.approve(user2, shares);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", caller_, 0, shares)
        );

        // Call function
        vm.prank(caller_);
        pb.redeem(shares, recipient_, user1);
    }

    //  [X] it burns the shares
    //  [X] it transfers the assets to the receiver

    function test_Redeem_WhenCallerIsNotTokenHolder_GivenTokenHolderHasApproved(address recipient_) public {
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 shares = pb.deposit(1000 * 10 ** 18, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), 1000 * 10 ** 18);
        uint256 expectedAssets = pb.previewRedeem(shares);
        uint256 recipientBalanceBefore = usds.balanceOf(recipient_);

        // Approve user2 to spend shares
        vm.prank(user1);
        pb.approve(user2, shares);

        // Call function
        vm.prank(user2);
        pb.redeem(shares, recipient_, user1);

        // Check that the shares were burned
        assertEq(pb.balanceOf(user1), 0, "shares were not burned");

        // Check that the assets were transferred to the receiver
        assertEq(
            usds.balanceOf(recipient_),
            recipientBalanceBefore + expectedAssets,
            "assets were not transferred to the receiver"
        );
    }

    // withdraw tests
    // given withdrawals are disabled
    //  [X] it reverts

    function test_Withdraw_WithdrawalsDisabled() public {
        // Deposit for user1
        uint256 depositAmount = 1000 * 10 ** 18;
        pb.deposit(depositAmount, user1);

        // Withdrawals are disabled by default
        assertEq(pb.maxWithdraw(user1), 0);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxWithdraw(address,uint256,uint256)", user1, depositAmount, 0)
        );

        // Call function
        vm.prank(user1);
        pb.withdraw(depositAmount, user2, user1);
    }

    // when the caller is the token holder
    //  [X] it burns the shares
    //  [X] it transfers the assets to the receiver

    function test_Withdraw_WhenCallerIsTokenHolder(address recipient_) public {
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 shares = pb.deposit(depositAmount, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), depositAmount);
        uint256 sharesToAssets = pb.previewRedeem(shares);
        uint256 expectedShares = pb.previewWithdraw(sharesToAssets);
        uint256 recipientBalanceBefore = usds.balanceOf(recipient_);
        uint256 user1ShareBalanceBefore = pb.balanceOf(user1);

        // Call function
        vm.prank(user1);
        pb.withdraw(sharesToAssets, recipient_, user1);

        // Check that the shares were burned
        assertEq(pb.balanceOf(user1), user1ShareBalanceBefore - expectedShares, "shares were not burned");

        // Check that the assets were transferred to the receiver
        assertEq(
            usds.balanceOf(recipient_),
            recipientBalanceBefore + sharesToAssets,
            "assets were not transferred to the receiver"
        );
    }

    // when the caller is not the token holder
    //  given the token holder has not approved the caller to spend the shares
    //   [X] it reverts

    function test_Withdraw_WhenCallerIsNotTokenHolder(address recipient_) public {
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 shares = pb.deposit(depositAmount, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), depositAmount);
        uint256 sharesToAssets = pb.previewRedeem(shares);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", user2, 0, shares)
        );

        // Call function
        vm.prank(user2);
        pb.withdraw(sharesToAssets, recipient_, user1);
    }

    //  given the caller is not the approved spender
    //   [X] it reverts

    function test_Withdraw_WhenCallerIsNotTokenHolder_GivenTokenHolderHasApproved_WhenCallerIsNotApprovedSpender(
        address caller_,
        address recipient_
    ) public {
        vm.assume(caller_ != user1 && caller_ != user2);
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 shares = pb.deposit(depositAmount, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), depositAmount);
        uint256 sharesToAssets = pb.previewRedeem(shares);

        // Approve user2 to spend shares
        vm.prank(user1);
        pb.approve(user2, shares);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", caller_, 0, shares)
        );

        // Call function
        vm.prank(caller_);
        pb.withdraw(sharesToAssets, recipient_, user1);
    }

    //  [X] it burns the shares
    //  [X] it transfers the assets to the receiver

    function test_Withdraw_WhenCallerIsNotTokenHolder_GivenTokenHolderHasApproved(address recipient_) public {
        vm.assume(recipient_ != user1);

        // Deposit for user1
        uint256 depositAmount = 1000 * 10 ** 18;
        uint256 shares = pb.deposit(depositAmount, user1);

        // Enable withdrawals
        vm.prank(owner);
        pb.setWithdrawalsDisabled(false);

        // Fund the contract with USDS
        usds.transfer(address(pb), depositAmount);
        uint256 sharesToAssets = pb.previewRedeem(shares);
        uint256 expectedShares = pb.previewWithdraw(sharesToAssets);
        uint256 recipientBalanceBefore = usds.balanceOf(recipient_);
        uint256 user1ShareBalanceBefore = pb.balanceOf(user1);

        // Approve user2 to spend shares
        vm.prank(user1);
        pb.approve(user2, shares);

        // Call function
        vm.prank(user2);
        pb.withdraw(sharesToAssets, recipient_, user1);

        // Check that the shares were burned
        assertEq(pb.balanceOf(user1), user1ShareBalanceBefore - expectedShares, "shares were not burned");

        // Check that the assets were transferred to the receiver
        assertEq(
            usds.balanceOf(recipient_),
            recipientBalanceBefore + sharesToAssets,
            "assets were not transferred to the receiver"
        );
    }
}
