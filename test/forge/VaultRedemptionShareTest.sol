// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/VaultRedemptionShare.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";

contract MockERC20 is MintableBurnableToken {
    constructor() MintableBurnableToken("MockToken", "MTK", msg.sender) {}
}

contract VaultRedemptionShareTest is Test {
    VaultRedemptionShare public vaultRedemptionShare;
    MockERC20 public asset;
    uint256 ONE_PERCENT = 1e16; // 1% relative delta for precision
    uint256 POINT_TWO_PERCENT = 2e14; // 0.2% relative delta for precision

    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        asset = new MockERC20();
        asset.manageMinter(address(this), true);

        vaultRedemptionShare = new VaultRedemptionShare(address(this), asset);
        vaultRedemptionShare.manageMinter(address(this), true);

        asset.mint(address(this), 1000 ether);
        asset.approve(address(vaultRedemptionShare), type(uint256).max);
    }

    function mintClaimableShares(address user, uint256 amount) public {
        vaultRedemptionShare.mint(user, amount);
        vaultRedemptionShare.increaseClaimableSharesFor(user, amount);
    }

    function testSingleUserFullRedemption() public {
        mintClaimableShares(user1, 100 ether);

        // nothing should be nothing to redeem if there are no assets
        // to redeem
        uint256 redeemed = vaultRedemptionShare.redeem(user1, user1);
        assertEq(redeemed, 0);
        assertEq(vaultRedemptionShare.balanceOf(user1), 100 ether);

        // If there is a single asset to redeem, and a single user, they
        // should be able to redeem all of the asset
        vaultRedemptionShare.increaseClaimableAmount(1 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionShare.redeem(user1, user1);
        assertEq(redeemed, 1 ether);
        assertEq(vaultRedemptionShare.balanceOf(user1), 99 ether);
        assertEq(vaultRedemptionShare.redeemOffsetOf(user1), 1 ether);
        assertEq(asset.balanceOf(user1), 1 ether);
        assertEq(asset.balanceOf(address(vaultRedemptionShare)), 0);

        // If we increase the claimable amount to the remaining 99
        // shares, the user should be able to redeem their entire balance
        vaultRedemptionShare.increaseClaimableAmount(99 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionShare.redeem(user1, user1);
        assertApproxEqRel(redeemed, 99 ether, POINT_TWO_PERCENT);
        assertApproxEqRel(vaultRedemptionShare.redeemOffsetOf(user1), 100 ether, POINT_TWO_PERCENT);
        assertApproxEqRel(asset.balanceOf(user1), 100 ether, POINT_TWO_PERCENT);
    }

    function test_multipleMintAndRedeems() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(100 ether);
        vaultRedemptionShare.redeem(user1, user1);

        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(100 ether);
        vaultRedemptionShare.redeem(user1, user1);
        assertEq(asset.balanceOf(user1), 200 ether);

        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(50 ether);
        vaultRedemptionShare.redeem(user1, user1);
        assertEq(asset.balanceOf(user1), 250 ether);

        mintClaimableShares(user1, 50 ether);
        vaultRedemptionShare.increaseClaimableAmount(50 ether);
        vaultRedemptionShare.redeem(user1, user1);
        assertEq(asset.balanceOf(user1), 300 ether);

        vaultRedemptionShare.increaseClaimableAmount(50 ether);
        vaultRedemptionShare.redeem(user1, user1);
        assertEq(asset.balanceOf(user1), 350 ether);
    }

    function xtestNoClaimAfterMaxClaim() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(100 ether);
        vm.prank(user1);
        uint256 redeemed = vaultRedemptionShare.redeem(user1, user1);

        assertEq(redeemed, 100 ether);
        assertEq(vaultRedemptionShare.balanceOf(user1), 0 ether);
        assertEq(vaultRedemptionShare.redeemOffsetOf(user1), 100 ether);
        assertEq(asset.balanceOf(user1), 100 ether);
        assertEq(asset.balanceOf(address(vaultRedemptionShare)), 0);

        // If we increase the shares again, there should be nothing to redeem
        mintClaimableShares(user1, 100 ether);
        assertEq(vaultRedemptionShare.maxRedeemableBy(user1), 0);
        assertEq(vaultRedemptionShare.balanceOf(user1), 100 ether);
        assertEq(vaultRedemptionShare.redeemOffsetOf(user1), 100 ether);
        //assertEq(asset.balanceOf(user1), 100 ether);
        //assertEq(asset.balanceOf(address(vaultRedemptionShare)), 0);
    }

    function xtestTwoUsersProportionalRedemption() public {
        mintClaimableShares(user1, 100 ether);
        mintClaimableShares(user2, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(2 ether);
        uint256 redeemed = 0;

        // Both users should be able to redeem 1 asset each
        vm.prank(user1);
        redeemed = vaultRedemptionShare.redeem(user1, user1);
        assertEq(redeemed, 1 ether);

        vm.prank(user2);
        redeemed = vaultRedemptionShare.redeem(user2, user2);
        assertEq(redeemed, 1 ether);

        assertEq(vaultRedemptionShare.balanceOf(user1), 99 ether);
        assertEq(vaultRedemptionShare.balanceOf(user2), 99 ether);
        assertEq(asset.balanceOf(user1), 1 ether);
        assertEq(asset.balanceOf(user2), 1 ether);
        assertEq(asset.balanceOf(address(vaultRedemptionShare)), 0);

        // Remains proportional after increasing claimable amount
        // if only one user redeems
        vaultRedemptionShare.increaseClaimableAmount(2 ether);
        redeemed = vaultRedemptionShare.redeem(user1, user1);
        assertApproxEqRel(redeemed, 1 ether, ONE_PERCENT);

        vaultRedemptionShare.increaseClaimableAmount(2 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionShare.redeem(user1, user1);
        assertApproxEqRel(redeemed, 1 ether, ONE_PERCENT);

        vm.prank(user2);
        redeemed = vaultRedemptionShare.redeem(user2, user2);
        assertApproxEqRel(redeemed, 2 ether, ONE_PERCENT);

        assertApproxEqRel(vaultRedemptionShare.balanceOf(user1), 97 ether, ONE_PERCENT);
        assertApproxEqRel(vaultRedemptionShare.balanceOf(user2), 97 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user1), 3 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user2), 3 ether, ONE_PERCENT);
    }

    function xtestProportionalAfterPartialRedemptionAndNewJoiner() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(50 ether);

        // user1 redeems 50
        vm.prank(user1);
        vaultRedemptionShare.redeem(user1, user1);

        // user2 joins with 50 shares
        mintClaimableShares(user2, 50 ether);

        // Add an additional 50 units to redeem
        vaultRedemptionShare.increaseClaimableAmount(50 ether);

        // Both redeem max
        vm.prank(user1);
        uint256 redeem1 = vaultRedemptionShare.redeem(user1, user1);
        vm.prank(user2);
        uint256 redeem2 = vaultRedemptionShare.redeem(user2, user2);

        // user1: 50 shares, user2: 50 shares, 30 units to redeem
        // Each should get 15 units
        assertApproxEqRel(redeem1, 25 ether, ONE_PERCENT);
        assertApproxEqRel(redeem2, 25 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user1), 75 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user2), 25 ether, ONE_PERCENT);
    }

    function testClaimedTransferredOnTransfer() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(50 ether);

        // user1 redeems 50
        vm.prank(user1);
        vaultRedemptionShare.redeem(user1, user1);

        // Transfer 25 shares to user2
        vm.prank(user1);
        vaultRedemptionShare.transfer(user2, 25 ether);

        // user2 should inherit half of user1's claimed
        assertApproxEqRel(
            vaultRedemptionShare.redeemOffsetOf(user2),
            vaultRedemptionShare.redeemOffsetOf(user1),
            ONE_PERCENT,
            "Claimed transferred not proportional"
        );

        // Transfer remaining shares to user2
        vm.prank(user1);
        vaultRedemptionShare.transfer(user2, 25 ether);

        // user2 should inherit all of user1's claimed
        assertEq(vaultRedemptionShare.redeemOffsetOf(user1), 0);
        assertEq(vaultRedemptionShare.redeemOffsetOf(user2), 50 ether);
    }

    function xtestRevertsClaimableExceedsBalance() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionShare.increaseClaimableAmount(50 ether);

        // Try to increase claimable shares by 50
        vm.expectRevert(VaultRedemptionShare.ClaimableExceedsBalance.selector);
        vaultRedemptionShare.increaseClaimableSharesFor(user1, 50 ether);
    }
}
