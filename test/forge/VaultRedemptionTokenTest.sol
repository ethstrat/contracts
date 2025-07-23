// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/VaultRedemptionToken.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";

import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

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

        assertEq(vaultRedemptionToken.totalClaimableShares(), 100 ether, "post-mint totalClaimableShares"); // Matches
            // claimable shares
        assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 0, "post-mint redeemOffsetOf"); // Nothing redeemed
        assertEq(vaultRedemptionToken.accClaimPerShare(), 0, "post-mint accClaimPerShare"); // No claimable amount

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0, "post-mint maxRedeemableBy"); // 100% of claimable
            // amount (0 ether)

        // nothing to redeem if there are no assets
        uint256 redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 0, "redeemed");
        assertEq(vaultRedemptionToken.balanceOf(user1), 100 ether, "post-redeem balanceOf");

        // If there is a single asset to redeem, and a single user, they
        // should be able to redeem all of the asset
        vaultRedemptionToken.increaseClaimableAmount(1 ether);

        assertEq(
            vaultRedemptionToken.totalClaimableShares(), 100 ether, "post-increaseClaimableAmount totalClaimableShares"
        ); // Matches claimable shares
        assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 0, "post-increaseClaimableAmount redeemOffsetOf"); // Nothing
            // redeemed
        assertEq(
            vaultRedemptionToken.accClaimPerShare(),
            1e18 * 1e18 / 100e18,
            "post-increaseClaimableAmount accClaimPerShare"
        ); // 1 ether / 100 ether = 0.01

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 1 ether, "post-increaseClaimableAmount maxRedeemableBy"); // 100%
            // of claimable amount (1 ether)

        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 1 ether, "redeemed2");
        assertEq(vaultRedemptionToken.balanceOf(user1), 99 ether, "post-redeem2 balanceOf");
        assertEq(asset.balanceOf(user1), 1 ether, "post-redeem2 asset.balanceOf(user1)");
        assertEq(
            asset.balanceOf(address(vaultRedemptionToken)), 0, "post-redeem2 asset.balanceOf(vaultRedemptionToken)"
        );

        assertEq(vaultRedemptionToken.totalClaimableShares(), 99 ether, "post-redeem2 totalClaimableShares"); // 100
            // ether - 1 ether redeemed
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 1 ether, "post-redeem2 redeemOffsetOf"); // 1 ether
        // redeemed
        assertEq(vaultRedemptionToken.accClaimPerShare(), 1e18 * 1e18 / 100e18, "post-redeem2 accClaimPerShare"); // 1
            // ether / 100 ether = 0.01

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0, "post-redeem2 maxRedeemableBy"); // 100% of remaining
            // claimable amount (0 ether)

        // If we increase the claimable amount to the remaining 99
        // shares, the user should be able to redeem their entire balance
        vaultRedemptionToken.increaseClaimableAmount(99 ether);

        assertEq(
            vaultRedemptionToken.totalClaimableShares(), 99 ether, "post-increaseClaimableAmount2 totalClaimableShares"
        ); // 100 ether - 1 ether redeemed
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 1 ether, "post-increaseClaimableAmount2
        // redeemOffsetOf"); // 1 ether redeemed
        assertEq(
            vaultRedemptionToken.accClaimPerShare(),
            1e18 * 1e18 / 100e18 + 99e18 * 1e18 / 99e18,
            "post-increaseClaimableAmount2 accClaimPerShare"
        ); // 1.01e18 = 101e16

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 99e18, "post-increaseClaimableAmount2 maxRedeemableBy"); // 100%
            // of remaining claimable amount (99 ether)

        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 99 ether, "redeemed3");
        assertEq(vaultRedemptionToken.balanceOf(user1), 0, "post-redeem3 balanceOf");
        assertEq(asset.balanceOf(user1), 100 ether, "post-redeem3 asset.balanceOf(user1)");
        assertEq(
            asset.balanceOf(address(vaultRedemptionToken)), 0, "post-redeem3 asset.balanceOf(vaultRedemptionToken)"
        );

        assertEq(vaultRedemptionToken.totalClaimableShares(), 0, "post-redeem3 totalClaimableShares"); // 100 ether - 1
            // ether - 99 ether = 0
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 100 ether, "post-redeem3 redeemOffsetOf"); // 100 ether
        // redeemed
        assertEq(
            vaultRedemptionToken.accClaimPerShare(),
            1e18 * 1e18 / 100e18 + 99e18 * 1e18 / 99e18,
            "post-redeem3 accClaimPerShare"
        ); // 1.01e18 = 101e16

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0, "post-redeem3 maxRedeemableBy"); // 100% of remaining
            // claimable amount (0 ether)
    }

    function testTwoUsersProportionalRedemption() public {
        mintClaimableShares(user1, 100 ether);
        mintClaimableShares(user2, 100 ether);

        assertEq(vaultRedemptionToken.totalClaimableShares(), 200 ether, "post-mint totalClaimableShares"); // Matches
            // claimable shares
        assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 0, "post-mint redeemOffsetOf.user1"); // Nothing redeemed
        assertEq(vaultRedemptionToken.redeemOffsetOf(user2), 0, "post-mint redeemOffsetOf.user2"); // Nothing redeemed
        assertEq(vaultRedemptionToken.accClaimPerShare(), 0, "post-mint accClaimPerShare"); // No claimable amount

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0, "post-mint maxRedeemableBy.user1"); // 100% of
            // claimable amount (0 ether)
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), 0, "post-mint maxRedeemableBy.user2"); // 100% of
            // claimable amount (0 ether)

        vaultRedemptionToken.increaseClaimableAmount(2 ether);

        assertEq(
            vaultRedemptionToken.totalClaimableShares(), 200 ether, "post-increaseClaimableAmount totalClaimableShares"
        ); // Matches claimable shares
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 0, "post-increaseClaimableAmount redeemOffsetOf.user1");
        // // Nothing redeemed
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user2), 0, "post-increaseClaimableAmount redeemOffsetOf.user2");
        // // Nothing redeemed
        assertEq(
            vaultRedemptionToken.accClaimPerShare(),
            2e18 * 1e18 / 200e18,
            "post-increaseClaimableAmount accClaimPerShare"
        ); // 2 ether / 200 ether = 0.01

        assertEq(
            vaultRedemptionToken.maxRedeemableBy(user1), 1 ether, "post-increaseClaimableAmount maxRedeemableBy.user1"
        ); // 50% of claimable amount (2 ether)
        assertEq(
            vaultRedemptionToken.maxRedeemableBy(user2), 1 ether, "post-increaseClaimableAmount maxRedeemableBy.user2"
        ); // 50% of claimable amount (2 ether)

        uint256 redeemed = 0;

        // Both users should be able to redeem 1 asset each
        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertEq(redeemed, 1 ether, "redeemed.user1");

        vm.prank(user2);
        redeemed = vaultRedemptionToken.redeem(user2, user2);
        assertEq(redeemed, 1 ether, "redeemed.user2");

        assertEq(vaultRedemptionToken.balanceOf(user1), 99 ether, "post-redeem balanceOf.user1");
        assertEq(vaultRedemptionToken.balanceOf(user2), 99 ether, "post-redeem balanceOf.user2");
        assertEq(asset.balanceOf(user1), 1 ether, "post-redeem asset.balanceOf.user1");
        assertEq(asset.balanceOf(user2), 1 ether, "post-redeem asset.balanceOf.user2");
        assertEq(asset.balanceOf(address(vaultRedemptionToken)), 0, "post-redeem asset.balanceOf(vaultRedemptionToken)");

        assertEq(vaultRedemptionToken.totalClaimableShares(), 198 ether, "post-redeem totalClaimableShares"); // 200
            // ether - 2 ether redeemed
        uint256 previousTotalClaimableShares = vaultRedemptionToken.totalClaimableShares();
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 1 ether, "post-redeem redeemOffsetOf.user1"); // 1 ether
        // redeemed
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user2), 1 ether, "post-redeem redeemOffsetOf.user2"); // 1 ether
        // redeemed
        assertEq(vaultRedemptionToken.accClaimPerShare(), 2e18 * 1e18 / 200e18, "post-redeem accClaimPerShare"); // 2
            // ether / 200 ether = 0.01

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0, "post-redeem maxRedeemableBy.user1"); // 50% of
            // claimable amount (0 ether)
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), 0, "post-redeem maxRedeemableBy.user2"); // 50% of
            // claimable amount (0 ether)

        // Remains proportional after increasing claimable amount
        // if only one user redeems
        vaultRedemptionToken.increaseClaimableAmount(2 ether);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertApproxEqAbs(redeemed, 1 ether, 1, "post-redeem2 redeemed");

        assertEq(
            vaultRedemptionToken.totalClaimableShares(),
            previousTotalClaimableShares - redeemed,
            "post-redeem2 totalClaimableShares"
        ); // 198e18 - 1e18 = 197e18
        previousTotalClaimableShares = vaultRedemptionToken.totalClaimableShares();
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 1 ether + redeemed, "post-redeem2
        // redeemOffsetOf.user1"); // 1 ether redeemed + redeemed
        // assertEq(vaultRedemptionToken.redeemOffsetOf(user2), 1 ether, "post-redeem2 redeemOffsetOf.user2"); // 1
        // ether redeemed
        assertEq(vaultRedemptionToken.accClaimPerShare(), 20101010101010101, "post-redeem2 accClaimPerShare"); // 2e18 *
            // 1e18 / 200e18 + 2e18 * 1e18 / 198e18 = 10000000000000000 + 10101010101010101 = 20101010101010101

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0 ether, "post-redeem2 maxRedeemableBy.user1"); // Already
            // claimed
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), redeemed, "post-redeem2 maxRedeemableBy.user2"); // 50% of
            // claimable amount (2 ether)

        vaultRedemptionToken.increaseClaimableAmount(2 ether);
        vm.prank(user1);
        redeemed = vaultRedemptionToken.redeem(user1, user1);
        assertApproxEqAbs(redeemed, 1 ether, 1, "post-redeem3 redeemed");

        assertEq(
            vaultRedemptionToken.totalClaimableShares(),
            previousTotalClaimableShares - redeemed,
            "post-redeem3 totalClaimableShares"
        ); // 197e18 - 1e18 = 196e18
        previousTotalClaimableShares = vaultRedemptionToken.totalClaimableShares();
        assertEq(vaultRedemptionToken.accClaimPerShare(), 30253294364969491, "post-redeem3 accClaimPerShare"); // 2e18 *
            // 1e18 / 200e18 + 2e18 * 1e18 / 198e18 + 2e18 * 1e18 / 197e18 = 10000000000000000 + 10101010101010101 +
            // 10152284263959390 = 30253294364969491

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0 ether, "post-redeem3 maxRedeemableBy.user1"); // Already
            // claimed
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), 2 ether, "post-redeem3 maxRedeemableBy.user2"); // 50% of
            // claimable amount (4 ether)

        vm.prank(user2);
        redeemed = vaultRedemptionToken.redeem(user2, user2);
        assertApproxEqAbs(redeemed, 2 ether, 1, "post-redeem4 redeemed");

        assertApproxEqRel(vaultRedemptionToken.balanceOf(user1), 97 ether, ONE_PERCENT);
        assertApproxEqRel(vaultRedemptionToken.balanceOf(user2), 97 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user1), 3 ether, ONE_PERCENT);
        assertApproxEqRel(asset.balanceOf(user2), 3 ether, ONE_PERCENT);

        assertEq(
            vaultRedemptionToken.totalClaimableShares(),
            previousTotalClaimableShares - redeemed,
            "post-redeem4 totalClaimableShares"
        ); // 196e18 - 2e18 = 194e18
        previousTotalClaimableShares = vaultRedemptionToken.totalClaimableShares();
        assertEq(vaultRedemptionToken.accClaimPerShare(), 30253294364969491, "post-redeem3 accClaimPerShare"); // 2e18 *
            // 1e18 / 200e18 + 2e18 * 1e18 / 198e18 + 2e18 * 1e18 / 197e18 = 10000000000000000 + 10101010101010101 +
            // 10152284263959390 = 30253294364969491

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0 ether, "post-redeem3 maxRedeemableBy.user1"); // Already
            // claimed
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), 0 ether, "post-redeem3 maxRedeemableBy.user2"); // Already
            // claimed
    }

    function testProportionalAfterPartialRedemptionAndNewJoiner() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // user1 redeems 50
        vm.prank(user1);
        vaultRedemptionToken.redeem(user1, user1);

        assertEq(vaultRedemptionToken.totalClaimableShares(), 50 ether, "post-redeem totalClaimableShares"); // 100
            // ether - 50 ether redeemed
        assertEq(vaultRedemptionToken.accClaimPerShare(), 50e18 * 1e18 / 100e18, "post-redeem accClaimPerShare"); // 50
            // ether / 100 ether = 0.01

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0 ether, "post-redeem maxRedeemableBy.user1"); // Already
            // claimed
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), 0 ether, "post-redeem maxRedeemableBy.user2"); // No
            // shares

        // user2 joins with 50 shares
        mintClaimableShares(user2, 50 ether);

        // Add an additional 50 units to redeem
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        assertEq(
            vaultRedemptionToken.totalClaimableShares(), 100 ether, "post-increaseClaimableAmount totalClaimableShares"
        ); // 100 ether - 50 ether redeemed + 50 ether minted
        assertEq(
            vaultRedemptionToken.accClaimPerShare(),
            50e18 * 1e18 / 100e18 + 50e18 * 1e18 / 100e18,
            "post-increaseClaimableAmount accClaimPerShare"
        );

        assertEq(
            vaultRedemptionToken.maxRedeemableBy(user1), 25 ether, "post-increaseClaimableAmount maxRedeemableBy.user1"
        ); // 50/100 * 50 = 25
        assertEq(
            vaultRedemptionToken.maxRedeemableBy(user2), 25 ether, "post-increaseClaimableAmount maxRedeemableBy.user2"
        ); // 50/100 * 50 = 25

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

        assertEq(vaultRedemptionToken.totalClaimableShares(), 50 ether, "post-redeem2 totalClaimableShares"); // 100
            // ether - 50 ether redeemed + 50 ether minted - 25 ether redeemed - 25 ether redeemed = 50 ether
        assertEq(
            vaultRedemptionToken.accClaimPerShare(),
            50e18 * 1e18 / 100e18 + 50e18 * 1e18 / 100e18,
            "post-redeem2 accClaimPerShare"
        );

        assertEq(vaultRedemptionToken.maxRedeemableBy(user1), 0 ether, "post-redeem2 maxRedeemableBy.user1"); // Already
            // claimed
        assertEq(vaultRedemptionToken.maxRedeemableBy(user2), 0 ether, "post-redeem2 maxRedeemableBy.user2"); // Already
            // claimed
    }

    function testClaimTransferredOnTransfer() public {
        // totalClaimableShares = 100
        // accClaimPerShare = 0
        // redeemOffsetOf(user1) = 0
        // redeemOffsetOf(user2) = 0
        mintClaimableShares(user1, 100 ether);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // totalClaimableShares = 100
        // accClaimPerShare = 50 / 100 = 0.5
        // redeemOffsetOf(user1) = 0
        // redeemOffsetOf(user2) = 0
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // user1 redeems 50
        // totalClaimableShares = 100 - 50 = 50
        // accClaimPerShare = 50 / 100 = 0.5
        // redeemOffsetOf(user1) = 50
        // redeemOffsetOf(user2) = 0
        vm.prank(user1);
        vaultRedemptionToken.redeem(user1, user1);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // Transfer 25 shares to user2
        // claim transfer = 50 * 25 / 50 = 25
        // totalClaimableShares = 50
        // accClaimPerShare = 50 / 100 = 0.5
        // redeemOffsetOf(user1) = 50 - 25 = 25
        // redeemOffsetOf(user2) = 25
        vm.prank(user1);
        vaultRedemptionToken.transfer(user2, 25 ether);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // Check user1
        assertEq(vaultRedemptionToken.balanceOf(user1), 25 ether, "post-transfer balanceOf.user1");

        // Check user2
        assertEq(vaultRedemptionToken.balanceOf(user2), 25 ether, "post-transfer balanceOf.user2");

        // user2 should inherit half of user1's claimed
        assertEq(vaultRedemptionToken.redeemOffsetOf(user2), 25e18, "post-transfer redeemOffsetOf.user2");
        assertEq(
            vaultRedemptionToken.redeemOffsetOf(user2),
            vaultRedemptionToken.redeemOffsetOf(user1),
            "Claimed transferred not proportional"
        );

        assertEq(vaultRedemptionToken.totalClaimableShares(), 50 ether, "post-transfer totalClaimableShares"); // 100
            // ether
        assertEq(vaultRedemptionToken.accClaimPerShare(), 50e18 * 1e18 / 100e18, "post-transfer accClaimPerShare"); // 50
            // ether / 100 ether = 0.5
    }

    function testClaimTransferredWithoutRedemption() public {
        // totalClaimableShares = 100
        // accClaimPerShare = 0
        // redeemOffsetOf(user1) = 0
        // redeemOffsetOf(user2) = 0
        mintClaimableShares(user1, 100 ether);

        // totalClaimableShares = 100
        // accClaimPerShare = 50 / 100 = 0.5
        // redeemOffsetOf(user1) = 0
        // redeemOffsetOf(user2) = 0
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // Transfer 25 shares to user2
        vm.prank(user1);
        vaultRedemptionToken.transfer(user2, 25 ether);

        // Check user1
        assertEq(vaultRedemptionToken.balanceOf(user1), 75 ether, "post-transfer balanceOf.user1");
        assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 0, "post-transfer redeemOffsetOf.user1");

        // Check user2
        assertEq(vaultRedemptionToken.balanceOf(user2), 25 ether, "post-transfer balanceOf.user2");
        assertEq(vaultRedemptionToken.redeemOffsetOf(user2), 0, "post-transfer redeemOffsetOf.user2");

        assertEq(vaultRedemptionToken.totalClaimableShares(), 100 ether, "post-transfer totalClaimableShares"); // 100
            // ether
        assertEq(vaultRedemptionToken.accClaimPerShare(), 50e18 * 1e18 / 100e18, "post-transfer accClaimPerShare"); // 50
            // ether / 100 ether = 0.5
    }

    function testBurnAfterRedemption() public {
        // totalClaimableShares = 100
        // accClaimPerShare = 0
        // redeemOffsetOf(user1) = 0
        // redeemOffsetOf(user2) = 0
        mintClaimableShares(user1, 100 ether);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // totalClaimableShares = 100
        // accClaimPerShare = 50 / 100 = 0.5
        // redeemOffsetOf(user1) = 0
        // redeemOffsetOf(user2) = 0
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // user1 redeems 50
        // totalClaimableShares = 100 - 50 = 50
        // accClaimPerShare = 50 / 100 = 0.5
        // redeemOffsetOf(user1) = 50
        // redeemOffsetOf(user2) = 0
        vm.prank(user1);
        vaultRedemptionToken.redeem(user1, user1);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        vm.prank(user1);
        vaultRedemptionToken.burn(25 ether);

        console2.log("redeemOffsetOf(user1)", vaultRedemptionToken.redeemOffsetOf(user1));

        // Check user1
        assertEq(vaultRedemptionToken.balanceOf(user1), 25 ether, "post-burn balanceOf.user1");
        assertEq(vaultRedemptionToken.redeemOffsetOf(user1), 25e18, "post-burn redeemOffsetOf.user1");

        // Check zero address
        assertEq(vaultRedemptionToken.balanceOf(address(0)), 25 ether, "post-burn balanceOf.zeroAddress");
        assertEq(vaultRedemptionToken.redeemOffsetOf(address(0)), 25e18, "post-burn redeemOffsetOf.zeroAddress");

        // TODO decide if burning the tokens should increase what can be claimed by other users
        assertEq(vaultRedemptionToken.totalClaimableShares(), 50 ether, "post-burn totalClaimableShares"); // 100 ether
        assertEq(vaultRedemptionToken.accClaimPerShare(), 50e18 * 1e18 / 100e18, "post-burn accClaimPerShare"); // 50
            // ether / 100 ether = 0.5
    }

    function testTransferWithInsufficientBalance() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // Try to transfer more than the balance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 100 ether, 101 ether)
        );

        vm.prank(user1);
        vaultRedemptionToken.transfer(user2, 101 ether);
    }

    function testTransferFromWithInsufficientBalance() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // Approve spending
        vm.prank(user1);
        vaultRedemptionToken.approve(user2, 101 ether);

        // Try to transfer more than the balance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 100 ether, 101 ether)
        );

        vm.prank(user2);
        vaultRedemptionToken.transferFrom(user1, user2, 101 ether);
    }

    function testTransferFromWithInsufficientAllowance() public {
        // TODO
    }

    function testMintAfterRedemption() public {
        // TODO
    }

    function testRevertsClaimableExceedsBalance() public {
        mintClaimableShares(user1, 100 ether);
        vaultRedemptionToken.increaseClaimableAmount(50 ether);

        // Try to increase claimable shares by 50
        vm.expectRevert(VaultRedemptionToken.ClaimableExceedsBalance.selector);
        vaultRedemptionToken.increaseClaimableSharesFor(user1, 50 ether);
    }

    // [ ] redeemOffsetOf when redeeming
    // [ ] redeemOffsetOf when burning
    // [ ] redeemOffsetOf when transferring
    // [ ] access controls for redeem
    // [ ] access controls for increaseClaimableSharesFor
    // [ ] access controls for increaseClaimableAmount
}
