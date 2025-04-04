// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratOption.sol";
import {IStratOptionMinter} from "../../../src/interfaces/IStratOptionMinter.sol";
import {IERC1155Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

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
        // TODO restore checks
        // require(_tokenId == tokenId);
        // require(_strikeAmount == strikeAmount);
        // require(_notionalUnderlyingAmount == notionalUnderlyingAmount);
        // require(_notionalUSDAmount == notionalUSDAmount);
        // require(_expiry == expiry);
        // require(_timelock == timelock);

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
        // Needed so that historical timestamps can be tested
        vm.warp(1000000);

        vm.prank(owner);
        collection = new StratOption(owner);
    }

    // manageMinter
    // when the caller is not the owner
    //  [X] it reverts
    // when canMint is false
    //  [X] it removes the minter
    // [X] it adds the minter

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

    // mintFor
    // when the caller is not a minter
    //  [X] it reverts
    // when the timelock is in the past
    //  [X] it reverts
    // when the timelock is after the expiry
    //  [X] it reverts
    // [X] it mints the option

    function test_timelockAfterExpiry_reverts(uint48 timelock) external {
        // Set timelock to be on or after expiry
        timelock = uint48(bound(timelock, uint48(block.timestamp + 100000), uint48(block.timestamp + 200000)));

        // Add minter
        vm.startPrank(owner);
        collection.manageMinter(minter, true);

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(IStratOptionMinter.InvalidParams.selector, "timelock"));

        vm.startPrank(minter);
        collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), timelock, true);
        vm.stopPrank();
    }

    function test_timelockInPast_reverts(uint48 timelock) external {
        // Set timelock to be in the past
        timelock = uint48(bound(timelock, block.timestamp - 100000, block.timestamp - 1));

        // Add minter
        vm.startPrank(owner);
        collection.manageMinter(minter, true);

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(IStratOptionMinter.InvalidParams.selector, "timelock"));

        vm.startPrank(minter);
        collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), timelock, true);
        vm.stopPrank();
    }

    function testOnlyMintersCanMint() external {
        // Add minter
        vm.startPrank(owner);
        collection.manageMinter(minter, true);

        // Non-minter mint should fail
        vm.startPrank(user);
        vm.expectRevert();
        collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);

        // Minter can mint
        vm.startPrank(minter);
        uint256 tokenId =
            collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);
        assertEq(collection.balanceOf(user, tokenId), 1);

        // Revoked Minter can no longer mint
        vm.startPrank(owner);
        collection.manageMinter(minter, false);
        vm.startPrank(minter);
        vm.expectRevert();
        collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);

        // Check balance
        assertEq(collection.balanceOf(user, tokenId), 1);
    }

    // burn
    // when the caller has already burned the option
    //  [X] it reverts
    // when the caller is not the owner of the option
    //  given the owner has not approved the caller
    //   [X] it reverts
    //  [X] it burns the option
    // [X] it burns the option

    function testBurnByHolder() external {
        // Owner mints tokens to user
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        uint256 tokenId =
            collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);
        vm.stopPrank();

        // User burns option
        vm.startPrank(user);
        assertEq(collection.balanceOf(user, tokenId), 1);
        collection.burnFrom(user, tokenId, 1);
        assertEq(collection.balanceOf(user, tokenId), 0);

        // User attempts to burn token that's already burned
        vm.expectRevert();
        collection.burnFrom(user, tokenId, 1);
        vm.stopPrank();
    }

    function testBurnByApprovedActor() external {
        // Owner mints tokens to user and approves minter
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        uint256 tokenId =
            collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);
        vm.stopPrank();

        // Burn options from user without approval
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, approvedActor, user)
        );
        vm.startPrank(approvedActor);
        collection.burnFrom(user, tokenId, 1);
        vm.stopPrank();

        // Approve actor to burn
        vm.startPrank(user);
        collection.setApprovalForAll(approvedActor, true);
        vm.stopPrank();

        // Approved actor burns option from user
        vm.startPrank(approvedActor);
        assertEq(collection.balanceOf(user, tokenId), 1);
        collection.burnFrom(user, tokenId, 1);
        assertEq(collection.balanceOf(user, tokenId), 0);

        // Approved minter attempts to burn more than approved
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, user, 0, 1, tokenId));
        vm.startPrank(approvedActor);
        collection.burnFrom(user, tokenId, 1);
        vm.stopPrank();
    }

    // managerRenderer
    // when the caller is not the owner
    //  [X] it reverts
    // [X] it sets the renderer

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

    // tokenURI
    // when no renderer is set
    //  [X] it returns an empty string
    // [X] it returns the renderer's tokenURI

    function testTokenURIReturnsEmptyIfNoRendererSet() external {
        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        uint256 tokenId =
            collection.mintFor(user, 1, 1, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);

        // No renderer => empty tokenURI
        assertEq(collection.uri(tokenId), "");
    }

    function testTokenURIUsesRendererIfPresent() external {
        MockRenderer mock =
            new MockRenderer(1, 10, 5, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100));

        vm.startPrank(owner);
        collection.manageMinter(owner, true);
        uint256 tokenId =
            collection.mintFor(user, 10, 5, 3000, uint48(block.timestamp + 100000), uint48(block.timestamp + 100), true);
        collection.managerRenderer(address(mock));
        vm.stopPrank();

        // Mock renderer => "mocked URI"
        vm.startPrank(owner);
        assertEq(collection.uri(tokenId), "https://mocked-uri.com/");
        vm.stopPrank();
    }
}
