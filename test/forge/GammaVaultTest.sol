// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/GammaVault.sol";
import "../../src/VaultRedemptionToken.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";

contract MockERC20 is MintableBurnableToken {
    constructor() MintableBurnableToken("MockToken", "MTK", msg.sender) {}
}

contract GammaVaultTest is Test {
    GammaVault public vault;
    VaultRedemptionToken public redemptionToken;
    MockERC20 public asset;
    MockERC20 public depositToken;
    address treasury = address(0xdead);
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        asset = new MockERC20();
        depositToken = new MockERC20();
        depositToken.manageMinter(address(this), true);
        redemptionToken = new VaultRedemptionToken(address(this), asset);

        vault = new GammaVault(redemptionToken, depositToken, treasury, address(this));
        redemptionToken.manageMinter(address(vault), true);
        vault.setYieldManager(address(this));

        depositToken.mint(user1, 100 ether);
        depositToken.mint(user2, 100 ether);
        depositToken.mint(address(this), 100 ether);
        depositToken.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        depositToken.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        depositToken.approve(address(vault), type(uint256).max);
    }

    function testYieldReleaseOnDeposit() public {
        vault.deposit(10 ether, user1);

        // Add 10 ether yield to be released over 10 seconds
        vault.addYield(10 ether, 10);

        // Advance 5 seconds, should trigger yield release
        vm.warp(block.timestamp + 5);
        vault.deposit(10 ether, user1);
        assertEq(redemptionToken.balanceOf(address(vault)), 25 ether);
    }

    function testYieldReleaseOnMint() public {
        vault.mint(10 ether, user1);

        // Add 10 ether yield to be released over 10 seconds
        vault.addYield(10 ether, 10);

        // Advance 5 seconds, should trigger yield release
        vm.warp(block.timestamp + 5);
        vault.mint(10 ether, user1);
        assertEq(redemptionToken.balanceOf(address(vault)), 30 ether);
    }

    function testYieldReleaseOnWithdraw() public {
        vault.deposit(10 ether, user1);
        vault.addYield(10 ether, 10);

        // Advance 11 seconds, all yield should be released on withdraw
        vm.warp(block.timestamp + 11);
        vm.prank(user1);
        uint256 withdrawnShares = vault.withdraw(20 ether - 1, user1, user1);
        assertEq(withdrawnShares, 10 ether);
        assertEq(redemptionToken.balanceOf(user1), 20 ether - 1);
    }

    function testYieldReleaseOnRedeem() public {
        vault.mint(10 ether, user1);
        vault.addYield(10 ether, 10);

        // Advance 11 seconds, all yield should be released on redeem
        vm.warp(block.timestamp + 11);
        vm.prank(user1);
        uint256 withdrawnAmount = vault.redeem(10 ether, user1, user1);
        assertApproxEqAbs(withdrawnAmount, 20 ether, 1);
        assertEq(redemptionToken.balanceOf(user1), withdrawnAmount);
    }

    function testYieldReleaseDoesNotExceedUnclaimed() public {
        vault.addYield(10 ether, 10);

        // Advance 20 seconds, but only 10 ether should be released
        vm.warp(block.timestamp + 20);
        vault.claimedUnreleasedYield();
        assertEq(redemptionToken.balanceOf(address(vault)), 10 ether);
    }

    function testYieldReleaseOverDuration() public {
        vault.deposit(10 ether, user1);

        // Add 10 ether yield to be released over 10 seconds
        vault.addYield(10 ether, 10);

        // No time passed, nothing released
        assertEq(redemptionToken.balanceOf(address(vault)), 10 ether);

        // Advance 5 seconds, should trigger yield release
        vm.warp(block.timestamp + 5);
        vault.deposit(10 ether, user2);
        assertEq(redemptionToken.balanceOf(address(vault)), 25 ether);

        // Advance another 6 seconds, should trigger remainder of yield to be release
        vm.warp(block.timestamp + 6);
        vault.claimedUnreleasedYield();
        assertEq(redemptionToken.balanceOf(address(vault)), 30 ether);

        // user1 should have more yield (represented as shares) than user2 since they deposited first
        assertGt(vault.balanceOf(user1), vault.balanceOf(user2));
    }

    function testDepositAndMintGoesToTreasury() public {
        vault.deposit(10 ether, treasury);
        assertEq(depositToken.balanceOf(treasury), 10 ether);

        vault.mint(10 ether, treasury);
        assertEq(depositToken.balanceOf(treasury), 20 ether);
        assertEq(depositToken.balanceOf(address(vault)), 0);
    }
}
