// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenURIRenderer} from "../../src/interfaces/TokenURIRenderer.sol";
import "../../src/StratOption.sol";

contract MockRenderer is TokenURIRenderer {
    uint256 public tokenId;
    uint256 public strikeAmount;
    uint256 public notionalUnderlyingAmount;
    uint256 public notionalUSDAmount;
    uint256 public expiry;
    uint256 public timelock;

    constructor(
        uint256 _tokenId,
        uint256 _strikeAmount,
        uint256 _notionalUnderlyingAmount,
        uint256 _notionalUSDAmount,
        uint256 _expiry,
        uint256 _timelock
    ) {
        tokenId = _tokenId;
        strikeAmount = _strikeAmount;
        notionalUnderlyingAmount = _notionalUnderlyingAmount;
        notionalUSDAmount = _notionalUSDAmount;
        expiry = _expiry;
        timelock = _timelock;
    }

    function render(
        uint256 _tokenId,
        uint256 _strikeAmount,
        uint256 _notionalUnderlyingAmount,
        uint256 _notionalUSDAmount,
        uint256 _expiry,
        uint256 _timelock
    ) external view returns (string memory) {
        require(_tokenId == tokenId);
        require(_strikeAmount == strikeAmount);
        require(_notionalUnderlyingAmount == notionalUnderlyingAmount);
        require(_notionalUSDAmount == notionalUSDAmount);
        require(_expiry == expiry);
        require(_timelock == timelock);

        return "https://mocked-uri.com/";
    }
}

contract StratOptionTest is Test {
    StratOption internal collection;

    address internal owner = address(0x123);
    address internal minter = address(0x456);
    address internal approvedActor = address(0x556);
    address internal user = address(0x789);

    function setUp() external {
        vm.prank(owner);
        collection = new StratOption(owner);
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
        collection.mint(user, 1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);

        // Minter can mint
        vm.startPrank(minter);
        collection.mint(user, 1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);
        assertEq(collection.balanceOf(user), 1);

        // Revoked Minter can no longer mint
        vm.startPrank(owner);
        collection.manageMinter(minter, false);
        vm.startPrank(minter);
        vm.expectRevert();
        collection.mint(user, 1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);

        // Check balance
        assertEq(collection.balanceOf(user), 1);
    }

    function testBurnByHolder() external {
        // Owner mints tokens to user
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        collection.mint(user, 1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);
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
        collection.mint(user, 1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);
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

    struct InvalidTimelockOrExpiry_Cases {
        uint256 timelock;
        uint256 expiry;
    }

    function testInvalidTimelockOrExpiryReverts() external {
        // Attempt to mint with invalid timelock or expiry
        vm.startPrank(owner);
        collection.manageMinter(owner, true);

        vm.warp(block.timestamp + 200);
        InvalidTimelockOrExpiry_Cases[] memory testCases = new InvalidTimelockOrExpiry_Cases[](3);
        testCases[0] = InvalidTimelockOrExpiry_Cases(block.timestamp - 100, block.timestamp - 100); // Both in the past
        testCases[1] = InvalidTimelockOrExpiry_Cases(block.timestamp + 100, block.timestamp - 100); // Expiry in the
            // past
        testCases[2] = InvalidTimelockOrExpiry_Cases(block.timestamp - 100, block.timestamp + 100); // Timelock in the
            // past

        for (uint256 i = 0; i < testCases.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    StratOption.InvalidTimelockOrExpiry.selector, testCases[i].timelock, testCases[i].expiry
                )
            );
            collection.mint(user, 1, 1, 3000, testCases[i].expiry, testCases[i].timelock);
        }

        // finally, a valid case shouldn't revert
        collection.mint(user, 1, 1, 3000, block.timestamp, block.timestamp);
    }

    function testOnlyOwnerCanSetRenderer() external {
        MockRenderer mock = new MockRenderer(0, 0, 0, 0, 0, 0);

        // Non-owner tries to set renderer
        vm.startPrank(user);
        vm.expectRevert();
        collection.managerRenderer(address(mock));
        vm.stopPrank();

        // Owner sets the renderer
        vm.startPrank(owner);
        collection.managerRenderer(address(mock));
        vm.stopPrank();
    }

    function testTokenURIReturnsEmptyIfNoRendererSet() external {
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        collection.mint(user, 1, 1, 3000, block.timestamp + 100000, block.timestamp + 100);

        // No renderer => empty tokenURI
        assertEq(collection.tokenURI(1), "");
    }

    function testTokenURIUsesRendererIfPresent() external {
        MockRenderer mock = new MockRenderer(1, 10, 5, 3000, block.timestamp + 100000, block.timestamp + 100);

        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        collection.mint(user, 10, 5, 3000, block.timestamp + 100000, block.timestamp + 100);
        collection.managerRenderer(address(mock));
        vm.stopPrank();

        // Mock renderer => "mocked URI"
        vm.startPrank(owner);
        assertEq(collection.tokenURI(1), "https://mocked-uri.com/");
        vm.stopPrank();
    }
}
