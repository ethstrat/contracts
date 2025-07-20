// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/VaultRedemptionToken.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";

contract MockERC20 is MintableBurnableToken {
    constructor() MintableBurnableToken("MockToken", "MTK", msg.sender) {}
}

contract VaultRedemptionTokenTest is Test {
    VaultRedemptionToken public vaultRedemptionToken;
    MockERC20 public asset;
    uint256 ONE_PERCENT = 1e16; // 1% relative delta for precision

    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        asset = new MockERC20();
        asset.manageMinter(address(this), true);

        vaultRedemptionToken = new VaultRedemptionToken(address(this), asset);
        vaultRedemptionToken.manageMinter(address(this), true);

        asset.mint(address(this), 1000 ether);
        asset.approve(address(vaultRedemptionToken), type(uint256).max);
    }

    function mintClaimableShares(address user, uint256 amount) public {
        vaultRedemptionToken.mint(user, amount);
        vaultRedemptionToken.increaseClaimableSharesFor(user, amount);
    }

    function testSingleUserFullRedemption() public {
        mintClaimableShares(user1, 100 ether);

        // nothing should be nothing to redeem if there are no assets
        // to redeem
        uint256 redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 0);
        assertEq(vaultRedemptionToken.balanceOf(user1), 100 ether);

        // If there is a single asset to redeem, and a single user, they
        // should be able to redeem all of the asset
        vaultRedemptionToken.increaseClaimableAmount(1 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 1 ether);
        assertEq(vaultRedemptionToken.balanceOf(user1), 99 ether);
        assertEq(asset.balanceOf(user1), 1 ether);
        assertEq(asset.balanceOf(address(vaultRedemptionToken)), 0);

        // If we increase the claimable amount to the remaining 99
        // shares, the user should be able to redeem their entire balance
        vaultRedemptionToken.increaseClaimableAmount(99 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 99 ether);
        assertEq(vaultRedemptionToken.balanceOf(user1), 0);
        assertEq(asset.balanceOf(user1), 100 ether);
        assertEq(asset.balanceOf(address(vaultRedemptionToken)), 0);
    }

    function testTwoUsersProportionalRedemption() public {
        mintClaimableShares(user1, 100 ether);
        mintClaimableShares(user2, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(2 ether);
        uint256 redeemed = 0;

        // Both users should be able to redeem 1 asset each
        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 1 ether);

        vm.prank(user2);
        redeemed = vaultRedemptionToken.redeem(user2, user2);
        assertEq(redeemed, 1 ether);

        assertEq(vaultRedemptionToken.balanceOf(user1), 99 ether);
        assertEq(vaultRedemptionToken.balanceOf(user2), 99 ether);
        assertEq(asset.balanceOf(user1), 1 ether);
        assertEq(asset.balanceOf(user2), 1 ether);
        assertEq(asset.balanceOf(address(vaultRedemptionToken)), 0);

        // Remains proportional after increasing claimable amount
        // if only one user redeems
        vaultRedemptionToken.increaseClaimableAmount(2 ether);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertApproxEqRel(redeemed, 1 ether, ONE_PERCENT);

        vaultRedemptionToken.increaseClaimableAmount(2 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertApproxEqRel(redeemed, 1 ether, ONE_PERCENT);

        vm.prank(user2);
        redeemed = vaultRedemptionToken.redeem(user2, user2);
        assertApproxEqRel(redeemed, 2 ether, ONE_PERCENT);

        assertApproxEqRel(vaultRedemptionToken.balanceOf(user1), 97 ether, ONE_PERCENT);
        assertApproxEqRel(vaultRedemptionToken.balanceOf(user2), 97 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user1), 3 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user2), 3 ether, ONE_PERCENT);
    }

    function testProportionalAfterPartialRedemptionAndNewJoiner() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // user1 redeems 50
        vm.prank(user1);
        vaultRedemptionToken.redeem(user1, user1);

        // user2 joins with 50 shares
        mintClaimableShares(user2, 50 ether);

        // Add an additional 50 units to redeem
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // Both redeem max
        vm.prank(user1);
        uint256 redeem1 = vaultRedemptionToken.redeem(user1, user1);
        vm.prank(user2);
        uint256 redeem2 = vaultRedemptionToken.redeem(user2, user2);

        // user1: 50 shares, user2: 50 shares, 30 units to redeem
        // Each should get 15 units
        assertApproxEqRel(redeem1, 25 ether, ONE_PERCENT);
        assertApproxEqRel(redeem2, 25 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user1), 75 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user2), 25 ether, ONE_PERCENT);
    }

    function testClaimedTransferredOnTransfer() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // user1 redeems 50
        vm.prank(user1);
        vaultRedemptionToken.redeem(user1, user1);

        // Transfer 50 shares to user2
        vm.prank(user1);
        vaultRedemptionToken.transfer(user2, 50 ether);

        // user2 should inherit half of user1's claimed
        assertApproxEqRel(
            vaultRedemptionToken.redeemOffsetOf(user2),
            vaultRedemptionToken.redeemOffsetOf(user1),
            ONE_PERCENT,
            "Claimed transferred not proportional"
        );
    }
}
