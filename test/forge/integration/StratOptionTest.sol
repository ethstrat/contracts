// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratOption.sol";

contract StratOptionTest is Test {
    StratOption internal collection;

    address internal owner = address(0x123);
    address internal minter = address(0x456);
    address internal approvedActor = address(0x556);
    address internal user = address(0x789);

    function setUp() external {
        vm.prank(owner);
        collection = new StratOption();
    }

    function testOnlyOwnerCanManageMinters() external {
        // Attempting to add a minter from non-owner should fail
        vm.startPrank(user);
        vm.expectRevert();
        collection.manageMinter(minter, true);

        // Owner can add a minter
        vm.startPrank(owner);
        collection.manageMinter(minter, true);
        assertTrue(collection.minters(minter));

        // Owner can remove a minter
        vm.startPrank(owner);
        collection.manageMinter(minter, false);
        assertFalse(collection.minters(minter));
    }

    function testOnlyMintersCanMint() external {
        // Add minter
        vm.startPrank(owner);
        collection.manageMinter(minter, true);

        // Non-minter mint should fail
        vm.startPrank(user);
        vm.expectRevert();
        collection.mint(1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);

        // Minter can mint
        vm.startPrank(minter);
        collection.mint(1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);

        // Revoked Minter can no longer mint
        vm.startPrank(owner);
        collection.manageMinter(minter, false);
        vm.startPrank(minter);
        vm.expectRevert();
        collection.mint(1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);

        // Check balance
        assertEq(collection.balanceOf(minter), 1);
    }

    function testBurnByHolder() external {
        // Owner mints tokens to user
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        collection.mint(1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);
        collection.safeTransferFrom(owner, user, 1);
        vm.stopPrank();

        // User burns option
        vm.startPrank(user);
        assertEq(collection.balanceOf(user), 1);
        collection.burn(1);
        assertEq(collection.balanceOf(user), 0);

        // User attempts to burn token that's already burned
        vm.expectRevert();
        collection.burn(1);
        vm.stopPrank();
    }

    function testBurnByApprovedActor() external {
        // Owner mints tokens to user and approves minter
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        collection.mint(1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);
        collection.safeTransferFrom(owner, user, 1);
        vm.stopPrank();

        vm.startPrank(user);
        collection.approve(approvedActor, 1);
        vm.stopPrank();

        // Approved actor burns option from user
        vm.startPrank(approvedActor);
        assertEq(collection.balanceOf(user), 1);
        collection.burn(1);
        assertEq(collection.balanceOf(user), 0);

        // Approved minter attempts to burn more than approved
        vm.expectRevert();
        collection.burn(1);
        vm.stopPrank();
    }
}
