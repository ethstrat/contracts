// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratTreasury.sol";

contract StratTreasuryTest is Test {
    StratTreasury public treasury;
    address public owner = address(0xABCD);
    address public nonOwner = address(0xBEEF);
    address public withdrawer = address(0xDEAD);
    address public treasuryVault = address(0xCAFE);

    function setUp() public {
        // Deploy the treasury contract with the initial vault and owner
        treasury = new StratTreasury(treasuryVault, owner);
        // Grant withdraw authorization to the 'withdrawer'
        vm.prank(owner);
        treasury.manageWithdrawer(withdrawer, true);
    }

    function testManageWithdrawer() public {
        vm.prank(owner);
        treasury.manageWithdrawer(nonOwner, true);
        assertTrue(treasury.canWithdraw(nonOwner));
    }

    function testSetTreasuryVault() public {
        address newVault = address(0xBEEF);
        vm.prank(owner);
        treasury.setTreasuryVault(newVault);
        assertEq(treasury.treasuryVault(), newVault);

        // Attempt update by non-owner should revert
        address anotherVault = address(0xDEAD);
        vm.prank(nonOwner);
        vm.expectRevert();
        treasury.setTreasuryVault(anotherVault);
    }

    function testSetDeployedEth() public {
        uint256 ethAmount = 1 ether;
        vm.prank(owner);
        treasury.setDeployedEth(ethAmount);
        assertEq(treasury.totalDeployedEth(), ethAmount);

        // Attempt update by non-owner should revert
        vm.prank(nonOwner);
        vm.expectRevert();
        treasury.setDeployedEth(ethAmount);
    }

    function testWithdrawAuthorized() public {
        uint256 withdrawAmount = 0.1 ether;
        address recipient = address(0x1234);
        // Fund the treasury contract with ETH
        deal(address(treasury), 1 ether);
        // Withdraw as an authorized address
        vm.prank(withdrawer);
        treasury.withdraw(withdrawAmount, recipient);
        // Verify that the recipient received the ETH
        assertEq(recipient.balance, withdrawAmount);
    }

    function testWithdrawUnauthorized() public {
        uint256 withdrawAmount = 0.1 ether;
        // Fund the treasury contract with ETH
        deal(address(treasury), 1 ether);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(StratTreasury.WithdrawUnauthorizedAccount.selector, nonOwner));
        treasury.withdraw(withdrawAmount, nonOwner);
    }

    function testTotal() public {
        // Set total deployed ETH
        uint256 deployedEth = 0.5 ether;
        vm.prank(owner);
        treasury.setDeployedEth(deployedEth);

        // Fund the treasury contract
        deal(address(treasury), 0.2 ether);

        // Fund the treasuryVault address as well
        deal(treasuryVault, 0.3 ether);

        // Calculate expected total: treasuryVault.balance + totalDeployedEth + treasury contract balance
        uint256 expectedTotal = 0.3 ether + deployedEth + 0.2 ether;
        uint256 total = treasury.total();
        assertEq(total, expectedTotal);
    }
}
