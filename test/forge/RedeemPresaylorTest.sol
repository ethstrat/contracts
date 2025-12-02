// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {RedeemPresaylor} from "../../src/RedeemPresaylor.sol";
import {IStratOption} from "../../src/interfaces/IStratOption.sol";
import {StratOption} from "../../src/StratOption.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/**
 * @title MockWETH
 * @notice A mock WETH token for testing, based on MintableBurnableToken
 */
contract MockWETH is MintableBurnableToken {
    constructor(address owner) MintableBurnableToken("Wrapped Ether", "WETH", owner) {}
}

contract RedeemPresaylorTest is Test {
    RedeemPresaylor public redeemPresaylor;
    StratOption public stratOption;
    MockWETH public weth;
    address public wethSource;

    address public owner = address(0x1);
    address public emergencyPauser = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public nonOwner = address(0x5);

    uint256 public constant MAX_TOKEN_ID = 466;

    uint256 public constant STRAT_AMOUNT_1 = 1000 * 1e18; // 1000 STRAT
    uint256 public constant ETH_AMOUNT_EXPECTED_1 = 800 * 1e18 / 10_000;
    uint256 public constant STRAT_AMOUNT_2 = 500 * 1e18; // 500 STRAT
    uint256 public constant ETH_AMOUNT_EXPECTED_2 = 400 * 1e18 / 10_000;

    function setUp() public {
        // Deploy StratOption (oStrat NFT)
        vm.prank(owner);
        stratOption = new StratOption(owner);

        // Deploy mock WETH token
        weth = new MockWETH(owner);

        // Set up WETH source
        wethSource = address(0x100);

        // Deploy RedeemPresaylor
        redeemPresaylor = new RedeemPresaylor(
            address(stratOption), address(weth), wethSource, emergencyPauser
        );

        // Set up minter for StratOption
        vm.prank(owner);
        stratOption.manageMinter(owner, true);

        // Set up minter for WETH
        vm.prank(owner);
        weth.manageMinter(owner, true);

        // Mint WETH to source (enough for all tests)
        vm.prank(owner);
        weth.mint(wethSource, 10000000 * 1e18); // 10M WETH

        // Approve RedeemPresaylor to pull from source
        vm.prank(wethSource);
        weth.approve(address(redeemPresaylor), type(uint256).max);
    }

    function test_Constructor() public view {
        assertEq(address(redeemPresaylor.stratOption()), address(stratOption));
        assertEq(address(redeemPresaylor.weth()), address(weth));
        assertEq(redeemPresaylor.wethSource(), wethSource);
        assertEq(redeemPresaylor.emergencyPauser(), emergencyPauser);
        assertEq(redeemPresaylor.MAX_CLAIMABLE_TOKEN_ID(), MAX_TOKEN_ID);
        assertFalse(redeemPresaylor.paused());
    }

    function test_BurnAndRedeemForETH_Success() public {
        // Mint oStrat NFT to user1 with tokenId 1
        uint256 tokenId = 1;
        vm.prank(owner);
        stratOption.mint(
            user1,
            0, // strikeAmount
            STRAT_AMOUNT_1, // notionalUnderlyingAmount
            0, // notionalUSDAmount
            block.timestamp + 365 days, // expiry
            block.timestamp + 1 days // timelock
        );

        // Verify user1 owns the NFT
        assertEq(stratOption.ownerOf(tokenId), user1);

        // Approve RedeemPresaylor to transfer the NFT
        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        // Get initial balances
        uint256 wethSourceBalanceBefore = weth.balanceOf(wethSource);
        uint256 user1WethBalanceBefore = weth.balanceOf(user1);

        // Burn and redeem as user1
        vm.prank(user1);
        uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);

        // Verify WETH amount
        assertEq(wethAmount, ETH_AMOUNT_EXPECTED_1);

        // Verify NFT was burned (ownerOf should revert for burned token)
        vm.expectRevert();
        stratOption.ownerOf(tokenId);

        // Verify hasBurnedAndRedeemed is set
        assertTrue(redeemPresaylor.hasBurnedAndRedeemed(tokenId));

        // Verify WETH was transferred from source to RedeemPresaylor and then to user1
        assertEq(weth.balanceOf(wethSource), wethSourceBalanceBefore - ETH_AMOUNT_EXPECTED_1);
        assertEq(weth.balanceOf(address(redeemPresaylor)), 0); // Should be 0 after transfer
        assertEq(weth.balanceOf(user1), user1WethBalanceBefore + ETH_AMOUNT_EXPECTED_1);
    }

    function test_BurnAndRedeemForETH_RevertIfTokenIdTooHigh() public {
        // First mint tokens 1-466 to reach tokenId 467
        for (uint256 i = 1; i <= MAX_TOKEN_ID; i++) {
            vm.prank(owner);
            stratOption.mint(address(0x999), 0, 1, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        }

        uint256 tokenId = MAX_TOKEN_ID + 1; // 467
        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(RedeemPresaylor.NotPresaylor.selector, tokenId));
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }

    function test_BurnAndRedeemForETH_RevertIfNotOwner() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(RedeemPresaylor.NotPresaylor.selector, tokenId));
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }

    function test_BurnAndRedeemForETH_RevertITokenIdIsApproved() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)", address(redeemPresaylor), tokenId));
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }

    function test_BurnAndRedeemForETH_RevertIfNotOwnerTokenIdIsApproved() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // user2 tries to redeem user1's NFT (with appropriate approvals)
        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(RedeemPresaylor.NotPresaylor.selector, tokenId));
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }

    function test_BurnAndRedeemForETH_RevertIfOwnerWithoutApproval() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // Verify user1 owns the NFT
        assertEq(stratOption.ownerOf(tokenId), user1);

        // user1 (the owner) tries to redeem without approving the NFT transfer
        vm.prank(user1);
        vm.expectRevert(); // Will revert on transferFrom due to lack of approval
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }

    function test_BurnAndRedeemForETH_RevertIfPaused() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // Approve RedeemPresaylor
        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        // Pause claiming
        vm.prank(emergencyPauser);
        redeemPresaylor.pause();

        // Try to redeem
        vm.prank(user1);
        vm.expectRevert(RedeemPresaylor.BurnAndRedeemPaused.selector);
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }

    function test_BurnAndRedeemForETH_MultipleUsers() public {
        // User1 redeems tokenId 1
        uint256 tokenId1 = 1;
        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId1);

        uint256 user1WethBalanceBefore = weth.balanceOf(user1);

        vm.prank(user1);
        uint256 wethAmount1 = redeemPresaylor.burnAndRedeemForETH(tokenId1);
        assertEq(wethAmount1, ETH_AMOUNT_EXPECTED_1);
        assertTrue(redeemPresaylor.hasBurnedAndRedeemed(tokenId1));
        assertEq(weth.balanceOf(user1), user1WethBalanceBefore + ETH_AMOUNT_EXPECTED_1);

        // Verify NFT was burned
        vm.expectRevert();
        stratOption.ownerOf(tokenId1);

        // User2 redeems tokenId 2
        uint256 tokenId2 = 2;
        vm.prank(owner);
        stratOption.mint(user2, 0, STRAT_AMOUNT_2, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user2);
        stratOption.approve(address(redeemPresaylor), tokenId2);

        uint256 user2WethBalanceBefore = weth.balanceOf(user2);

        vm.prank(user2);
        uint256 wethAmount2 = redeemPresaylor.burnAndRedeemForETH(tokenId2);
        assertEq(wethAmount2, ETH_AMOUNT_EXPECTED_2);
        assertTrue(redeemPresaylor.hasBurnedAndRedeemed(tokenId2));
        assertEq(weth.balanceOf(user2), user2WethBalanceBefore + ETH_AMOUNT_EXPECTED_2);

        // Verify NFT was burned
        vm.expectRevert();
        stratOption.ownerOf(tokenId2);
    }

    function test_BurnAndRedeemForETH_MaxTokenId() public {
        // Test that MAX_TOKEN_ID (466) can be redeemed
        uint256 tokenId = MAX_TOKEN_ID;

        // Need to mint enough tokens to reach tokenId 466
        for (uint256 i = 1; i < MAX_TOKEN_ID; i++) {
            vm.prank(owner);
            stratOption.mint(address(0x999), 0, 1, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        }

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        uint256 user1WethBalanceBefore = weth.balanceOf(user1);

        vm.prank(user1);
        uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);
        assertEq(wethAmount, ETH_AMOUNT_EXPECTED_1);
        assertTrue(redeemPresaylor.hasBurnedAndRedeemed(tokenId));
        assertEq(weth.balanceOf(user1), user1WethBalanceBefore + ETH_AMOUNT_EXPECTED_1);

        // Verify NFT was burned
        vm.expectRevert();
        stratOption.ownerOf(tokenId);
    }

    function test_Pause_OnlyEmergencyPauser() public {
        // Non-emergency pauser cannot pause
        vm.prank(nonOwner);
        vm.expectRevert(RedeemPresaylor.OnlyEmergencyPauser.selector);
        redeemPresaylor.pause();

        // Emergency pauser can pause
        vm.prank(emergencyPauser);
        redeemPresaylor.pause();
        assertTrue(redeemPresaylor.paused());
    }

    function test_Unpause_OnlyEmergencyPauser() public {
        // Pause first
        vm.prank(emergencyPauser);
        redeemPresaylor.pause();

        // Non-emergency pauser cannot unpause
        vm.prank(nonOwner);
        vm.expectRevert(RedeemPresaylor.OnlyEmergencyPauser.selector);
        redeemPresaylor.unpause();

        // Emergency pauser can unpause
        vm.prank(emergencyPauser);
        redeemPresaylor.unpause();
        assertFalse(redeemPresaylor.paused());
    }

    function test_Pause_Unpause_Flow() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // Pause
        vm.prank(emergencyPauser);
        redeemPresaylor.pause();
        assertTrue(redeemPresaylor.paused());

        // Cannot redeem while paused
        vm.prank(user1);
        vm.expectRevert(RedeemPresaylor.BurnAndRedeemPaused.selector);
        redeemPresaylor.burnAndRedeemForETH(tokenId);

        // Unpause
        vm.prank(emergencyPauser);
        redeemPresaylor.unpause();
        assertFalse(redeemPresaylor.paused());

        // Approve before redeeming
        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        // Can redeem after unpause
        uint256 user1WethBalanceBefore = weth.balanceOf(user1);

        vm.prank(user1);
        uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);
        assertEq(wethAmount, ETH_AMOUNT_EXPECTED_1);
        assertTrue(redeemPresaylor.hasBurnedAndRedeemed(tokenId));
        assertEq(weth.balanceOf(user1), user1WethBalanceBefore + ETH_AMOUNT_EXPECTED_1);

        // Verify NFT was burned
        vm.expectRevert();
        stratOption.ownerOf(tokenId);
    }

    function test_BurnAndRedeemForETH_DifferentAmounts() public {
        // Test with different STRAT amounts
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 100 * 1e18;
        amounts[1] = 1000 * 1e18;
        amounts[2] = 10000 * 1e18;
        amounts[3] = 100000 * 1e18;

        uint256[] memory expectedWethAmounts = new uint256[](4);
        expectedWethAmounts[0] = 80 * 1e18 / 10_000;
        expectedWethAmounts[1] = 800 * 1e18 / 10_000;
        expectedWethAmounts[2] = 8000 * 1e18 / 10_000;
        expectedWethAmounts[3] = 80000 * 1e18 / 10_000;

        for (uint256 i = 0; i < amounts.length; i++) {
            // Each mint gets a new sequential tokenId
            vm.prank(owner);
            stratOption.mint(user1, 0, amounts[i], 0, block.timestamp + 365 days, block.timestamp + 1 days);

            // Get the tokenId that was just minted
            uint256 tokenId = stratOption._tokenIdCounter() - 1;

            // Approve before redeeming
            vm.prank(user1);
            stratOption.approve(address(redeemPresaylor), tokenId);

            // Calculate expected WETH amount
            uint256 user1WethBalanceBefore = weth.balanceOf(user1);

            vm.prank(user1);
            uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);

            // Verify WETH amount calculation
            assertEq(wethAmount, expectedWethAmounts[i]);
            assertEq(weth.balanceOf(user1), user1WethBalanceBefore + expectedWethAmounts[i]);

            // Verify NFT was burned
            vm.expectRevert();
            stratOption.ownerOf(tokenId);
        }
    }

    function test_BurnAndRedeemForETH_EventEmitted() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        vm.prank(user1);
        // Expect the BurntAndRedeemed event to be emitted
        vm.expectEmit(true, true, true, true); // Check all indexed params and data
        emit RedeemPresaylor.BurntAndRedeemed(user1, user1, tokenId, ETH_AMOUNT_EXPECTED_1);
        uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);

        // Verify the event was emitted with correct values
        assertEq(wethAmount, ETH_AMOUNT_EXPECTED_1);

        // Verify NFT was burned
        vm.expectRevert();
        stratOption.ownerOf(tokenId);
    }

    function test_BurnAndRedeemForETH_WethAmountCalculation() public {
        // Test the WETH amount calculation: notionalUnderlyingAmount * 8e17 / 1e22
        // This should give 80% of notionalUnderlyingAmount / 10_000

        // Test with 10,000 STRAT (should give 0.8 WETH)
        uint256 amount = 10000 * 1e18;
        uint256 expectedWeth = amount * 8e17 / 1e22; // Should be 0.8e18

        vm.prank(owner);
        stratOption.mint(user1, 0, amount, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        uint256 tokenId = stratOption._tokenIdCounter() - 1;

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        vm.prank(user1);
        uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);

        // Verify calculation: 10000e18 * 8e17 / 1e22 = 8e21 / 1e22 = 0.8e18
        assertEq(wethAmount, expectedWeth);
        assertEq(wethAmount, 0.8e18);
    }

    function test_BurnAndRedeemForETH_WethAmountCalculation_EdgeCase() public {
        // Test with 1 STRAT (should give 0.00008 WETH)
        uint256 amount = 1e18;
        uint256 expectedWeth = amount * 8e17 / 1e22; // Should be 0.00008e18 = 8e13

        vm.prank(owner);
        stratOption.mint(user1, 0, amount, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        uint256 tokenId = stratOption._tokenIdCounter() - 1;

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        vm.prank(user1);
        uint256 wethAmount = redeemPresaylor.burnAndRedeemForETH(tokenId);

        // Verify calculation: 1e18 * 8e17 / 1e22 = 8e35 / 1e22 = 8e13
        assertEq(wethAmount, expectedWeth);
        assertEq(wethAmount, 8e13);
    }

    function test_BurnAndRedeemForETH_SendsToPresaylor() public {
        // Test that WETH is sent to the presaylor (NFT owner)
        // Note: Since the contract checks msg.sender == ownerOf(tokenId), 
        // the presaylor will always be the caller, but we verify the logic
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        uint256 user1WethBalanceBefore = weth.balanceOf(user1);

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        // user1 calls (presaylor is user1)
        vm.prank(user1);
        redeemPresaylor.burnAndRedeemForETH(tokenId);

        // WETH should go to user1 (the presaylor)
        assertEq(weth.balanceOf(user1), user1WethBalanceBefore + ETH_AMOUNT_EXPECTED_1);
    }

    function test_BurnAndRedeemForETH_RevertIfZeroNotionalUnderlyingAmount() public {
        uint256 tokenId = 1;

        // Mint NFT with zero notionalUnderlyingAmount
        vm.prank(owner);
        stratOption.mint(user1, 0, 0, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        stratOption.approve(address(redeemPresaylor), tokenId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(RedeemPresaylor.NotPresaylor.selector, tokenId));
        redeemPresaylor.burnAndRedeemForETH(tokenId);
    }
}

