// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/MintableBurnableToken.sol";

contract MintableBurnableTokenTest is Test {
    MintableBurnableToken internal token;

    address internal owner = address(0x123);
    address internal minter = address(0x456);
    address internal approvedActor = address(0x556);
    address internal user = address(0x789);

    function setUp() external {
        vm.prank(owner);
        token = new MintableBurnableToken("name", "symbol");
    }

    function testOnlyOwnerCanManageMinters() external {
        // Attempting to add a minter from non-owner should fail
        vm.startPrank(user);
        vm.expectRevert();
        token.manageMinter(minter, true);

        // Owner can add a minter
        vm.startPrank(owner);
        token.manageMinter(minter, true);
        assertTrue(token.minters(minter));

        // Owner can remove a minter
        vm.startPrank(owner);
        token.manageMinter(minter, false);
        assertFalse(token.minters(minter));
    }

    function testOnlyMintersCanMint() external {
        // Add minter
        vm.startPrank(owner);
        token.manageMinter(minter, true);

        // Non-minter mint should fail
        vm.startPrank(user);
        vm.expectRevert();
        token.mint(user, 100);

        // Minter can mint
        vm.startPrank(minter);
        token.mint(user, 200);

        // Revoked Minter can no longer mint
        vm.startPrank(owner);
        token.manageMinter(minter, false);
        vm.startPrank(minter);
        vm.expectRevert();
        token.mint(user, 200);

        // Check balance
        assertEq(token.balanceOf(user), 200);
    }

    function testBurnByHolder() external {
        // Owner mints tokens to user
        vm.startPrank(owner);
        token.manageMinter(owner, true);
        token.mint(user, 100);
        vm.stopPrank();

        // User burns 50 tokens
        vm.startPrank(user);
        token.burn(50);
        assertEq(token.balanceOf(user), 50);

        // User attempts to burn more than their balance
        vm.expectRevert();
        token.burn(60);
        vm.stopPrank();
    }

    function testBurnByApprovedActor() external {
        // Owner mints tokens to user and approves minter
        vm.startPrank(owner);
        token.manageMinter(owner, true);
        token.mint(user, 100);
        vm.stopPrank();

        vm.startPrank(user);
        token.approve(approvedActor, 50);
        vm.stopPrank();

        // // Approved actor burns 50 tokens from user
        vm.startPrank(approvedActor);
        token.burnFrom(user, 50);
        assertEq(token.balanceOf(user), 50);

        // Approved minter attempts to burn more than approved
        vm.expectRevert();
        token.burnFrom(user, 10);
        vm.stopPrank();
    }
}
