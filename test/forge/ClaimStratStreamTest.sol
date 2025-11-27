// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ClaimStratStream} from "../../src/ClaimStratStream.sol";
import {IStratOption} from "../../src/interfaces/IStratOption.sol";
import {ITokenLockupPlans} from "../../src/interfaces/ITokenLockupPlans.sol";
import {StratOption} from "../../src/StratOption.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
// Using deployed TokenLockupPlans contract on mainnet via fork

contract ClaimStratStreamTest is Test {
    ClaimStratStream public claimStream;
    StratOption public stratOption;
    MintableBurnableToken public stratToken;
    ITokenLockupPlans public constant tokenLockupPlans = ITokenLockupPlans(0x1961A23409CA59EEDCA6a99c97E4087DaD752486);
    address public stratSource;

    address public owner = address(0x1);
    address public emergencyPauser = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public nonOwner = address(0x5);

    uint256 public constant MAX_TOKEN_ID = 466;
    uint256 public constant VESTING_START = 1764417600; // November 29, 2025 00:00:00 UTC
    uint256 public constant VESTING_DURATION_SECONDS = 5270400; // 2 months = 61 days
    uint256 public constant VESTING_RATE_PERIOD = 1;

    uint256 public constant STRAT_AMOUNT_1 = 1000 * 1e18; // 1000 STRAT
    uint256 public constant STRAT_AMOUNT_2 = 500 * 1e18; // 500 STRAT

    function setUp() public {
        // Fork mainnet at block 23881435 to use deployed TokenLockupPlans contract
        // Usage: forge test --fork-url <RPC_URL> Or set MAINNET_RPC_URL environment variable
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl, 23881435);
        } else {
            // If --fork-url is used, Foundry creates the fork automatically
            // We just need to select it and roll to the correct block
            try vm.activeFork() returns (uint256 forkId) {
                vm.selectFork(forkId);
                vm.rollFork(23881435);
            } catch {
                // No fork active, tests will fail when trying to interact with deployed contract
                // This is expected - fork tests require --fork-url or MAINNET_RPC_URL
            }
        }

        // Deploy StratOption (oStrat NFT)
        vm.prank(owner);
        stratOption = new StratOption(owner);

        // Deploy STRAT token
        stratToken = new MintableBurnableToken("STRAT", "STRAT", owner);

        // Set up strat source
        stratSource = address(0x100);

        // Deploy ClaimStratStream
        claimStream = new ClaimStratStream(
            address(stratOption),
            address(stratToken),
            address(tokenLockupPlans),
            stratSource,
            emergencyPauser
        );

        // Set up minter for StratOption
        vm.prank(owner);
        stratOption.manageMinter(owner, true);

        // Set up minter for STRAT token
        vm.prank(owner);
        stratToken.manageMinter(owner, true);

        // Mint STRAT to source (enough for all tests)
        vm.prank(owner);
        stratToken.mint(stratSource, 10000000 * 1e18); // 10M STRAT

        // Approve ClaimStratStream to pull from source
        vm.prank(stratSource);
        stratToken.approve(address(claimStream), type(uint256).max);
    }

    function test_Constructor() public view {
        assertEq(address(claimStream.stratOption()), address(stratOption));
        assertEq(address(claimStream.stratToken()), address(stratToken));
        assertEq(address(claimStream.tokenLockupPlans()), address(tokenLockupPlans));
        assertEq(claimStream.stratSource(), stratSource);
        assertEq(claimStream.emergencyPauser(), emergencyPauser);
        assertEq(claimStream.MAX_CLAIMABLE_TOKEN_ID(), MAX_TOKEN_ID);
        assertEq(claimStream.VESTING_START(), VESTING_START);
        assertEq(claimStream.VESTING_DURATION_SECONDS(), VESTING_DURATION_SECONDS);
        assertEq(claimStream.VESTING_RATE_PERIOD(), VESTING_RATE_PERIOD);
        assertFalse(claimStream.paused());

        // Check that unlimited allowance was set
        assertEq(
            stratToken.allowance(address(claimStream), address(tokenLockupPlans)),
            type(uint256).max
        );
    }

    function test_Claim_Success() public {
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

        // Calculate expected rate
        uint256 expectedRate = STRAT_AMOUNT_1 / VESTING_DURATION_SECONDS;

        // Claim as user1
        vm.prank(user1);
        uint256 planId = claimStream.claim(tokenId);

        // Verify hasClaimed is set
        assertTrue(claimStream.hasClaimed(tokenId));
        assertEq(claimStream.planId(tokenId), planId);

        // Verify STRAT was transferred from source to claimStream
        assertEq(stratToken.balanceOf(stratSource), 10000000 * 1e18 - STRAT_AMOUNT_1);
        assertEq(stratToken.balanceOf(address(claimStream)), 0); // Should be 0 after creating plan

        // Verify lockup plan was created
        ITokenLockupPlans.Plan memory plan = tokenLockupPlans.plans(planId);
        assertEq(plan.token, address(stratToken));
        assertEq(plan.amount, STRAT_AMOUNT_1);
        assertEq(plan.start, VESTING_START);
        assertEq(plan.cliff, VESTING_START);
        assertEq(plan.rate, expectedRate);
        assertEq(plan.period, VESTING_RATE_PERIOD);

        // Verify NFT owner is user1
        assertEq(tokenLockupPlans.ownerOf(planId), user1);
    }

    function test_Claim_RevertIfTokenIdTooHigh() public {
        uint256 tokenId = MAX_TOKEN_ID + 1; // 467

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ClaimStratStream.NotPresaylor.selector, tokenId));
        claimStream.claim(tokenId);
    }

    function test_Claim_RevertIfAlreadyClaimed() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // First claim succeeds
        vm.prank(user1);
        claimStream.claim(tokenId);

        // Second claim should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ClaimStratStream.AlreadyClaimed.selector, tokenId));
        claimStream.claim(tokenId);
    }

    function test_Claim_RevertIfNotOwner() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // user2 tries to claim user1's NFT
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ClaimStratStream.NotPresaylor.selector, tokenId));
        claimStream.claim(tokenId);
    }

    function test_Claim_RevertIfPaused() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // Pause claiming
        vm.prank(emergencyPauser);
        claimStream.pause();

        // Try to claim
        vm.prank(user1);
        vm.expectRevert(ClaimStratStream.ClaimingPaused.selector);
        claimStream.claim(tokenId);
    }

    function test_Claim_MultipleUsers() public {
        // User1 claims tokenId 1
        uint256 tokenId1 = 1;
        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        uint256 planId1 = claimStream.claim(tokenId1);
        assertTrue(claimStream.hasClaimed(tokenId1));
        assertEq(claimStream.planId(tokenId1), planId1);

        // User2 claims tokenId 2
        uint256 tokenId2 = 2;
        vm.prank(owner);
        stratOption.mint(user2, 0, STRAT_AMOUNT_2, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user2);
        uint256 planId2 = claimStream.claim(tokenId2);
        assertTrue(claimStream.hasClaimed(tokenId2));
        assertEq(claimStream.planId(tokenId2), planId2);

        // Verify both plans were created
        assertEq(tokenLockupPlans.ownerOf(planId1), user1);
        assertEq(tokenLockupPlans.ownerOf(planId2), user2);
    }

    function test_Claim_MaxTokenId() public {
        // Test that MAX_TOKEN_ID (466) can be claimed
        uint256 tokenId = MAX_TOKEN_ID;

        // Need to mint enough tokens to reach tokenId 466
        // First mint tokens 1-465 to other addresses (or skip them)
        // For simplicity, we'll just mint token 466 directly by setting the counter
        // Actually, we need to mint sequentially, so let's mint a bunch quickly
        for (uint256 i = 1; i < MAX_TOKEN_ID; i++) {
            vm.prank(owner);
            stratOption.mint(address(0x999), 0, 1, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        }

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        uint256 planId = claimStream.claim(tokenId);
        assertTrue(claimStream.hasClaimed(tokenId));
        assertEq(claimStream.planId(tokenId), planId);
    }

    function test_Pause_OnlyEmergencyPauser() public {
        // Non-emergency pauser cannot pause
        vm.prank(nonOwner);
        vm.expectRevert(ClaimStratStream.OnlyEmergencyPauser.selector);
        claimStream.pause();

        // Emergency pauser can pause
        vm.prank(emergencyPauser);
        claimStream.pause();
        assertTrue(claimStream.paused());
    }

    function test_Unpause_OnlyEmergencyPauser() public {
        // Pause first
        vm.prank(emergencyPauser);
        claimStream.pause();

        // Non-emergency pauser cannot unpause
        vm.prank(nonOwner);
        vm.expectRevert(ClaimStratStream.OnlyEmergencyPauser.selector);
        claimStream.unpause();

        // Emergency pauser can unpause
        vm.prank(emergencyPauser);
        claimStream.unpause();
        assertFalse(claimStream.paused());
    }

    function test_Pause_Unpause_Flow() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        // Pause
        vm.prank(emergencyPauser);
        claimStream.pause();
        assertTrue(claimStream.paused());

        // Cannot claim while paused
        vm.prank(user1);
        vm.expectRevert(ClaimStratStream.ClaimingPaused.selector);
        claimStream.claim(tokenId);

        // Unpause
        vm.prank(emergencyPauser);
        claimStream.unpause();
        assertFalse(claimStream.paused());

        // Can claim after unpause
        vm.prank(user1);
        uint256 planId = claimStream.claim(tokenId);
        assertTrue(claimStream.hasClaimed(tokenId));
        assertEq(claimStream.planId(tokenId), planId);
    }

    function test_Claim_DifferentAmounts() public {
        // Test with different STRAT amounts
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 100 * 1e18;
        amounts[1] = 1000 * 1e18;
        amounts[2] = 10000 * 1e18;
        amounts[3] = 100000 * 1e18;


        for (uint256 i = 0; i < amounts.length; i++) {
            // Each mint gets a new sequential tokenId
            vm.prank(owner);
            stratOption.mint(user1, 0, amounts[i], 0, block.timestamp + 365 days, block.timestamp + 1 days);
            
            // Get the tokenId that was just minted (it's the current counter value)
            uint256 tokenId = stratOption._tokenIdCounter() - 1;

            // Calculate expected rate
            uint256 expectedRate = amounts[i] / VESTING_DURATION_SECONDS;

            vm.prank(user1);
            uint256 planId = claimStream.claim(tokenId);

            // Verify plan details            
            ITokenLockupPlans.Plan memory plan = tokenLockupPlans.plans(planId);
            assertEq(plan.rate, expectedRate);
            assertEq(plan.amount, amounts[i]);
            assertEq(plan.start, VESTING_START);
            assertEq(plan.cliff, VESTING_START);
            assertEq(plan.period, VESTING_RATE_PERIOD);
            // planEnd adds an extra period when amount % rate != 0, so it's VESTING_START + VESTING_DURATION_SECONDS + 1
            assertEq(tokenLockupPlans.planEnd(planId), VESTING_START + VESTING_DURATION_SECONDS + 1);
        }
    }

    function test_Claim_EventEmitted() public {
        uint256 tokenId = 1;

        vm.prank(owner);
        stratOption.mint(user1, 0, STRAT_AMOUNT_1, 0, block.timestamp + 365 days, block.timestamp + 1 days);

        vm.prank(user1);
        // Expect the Claimed event to be emitted
        // Note: planId will be whatever the next plan ID is on the deployed contract
        vm.expectEmit(true, true, false, false); // Check first 2 indexed params, skip planId and amount
        emit ClaimStratStream.Claimed(user1, tokenId, 0, 0);
        uint256 planId = claimStream.claim(tokenId);
        
        // Verify the event was emitted with a valid planId
        assertTrue(planId > 0);
        assertEq(claimStream.planId(tokenId), planId);
    }

    function test_Claim_RateCalculation() public {
        // Amount that gives exactly 1e18 per second rate over 61 days (5270400 seconds)
        uint256 amount = 5270400 * 1e18; // Exactly 61 days worth at rate 1e18 per second

        vm.prank(owner);
        stratOption.mint(user1, 0, amount, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        uint256 tokenId = stratOption._tokenIdCounter() - 1;

        vm.prank(user1);
        uint256 planId = claimStream.claim(tokenId);

        // Rate should be exactly 1e18 per second
        ITokenLockupPlans.Plan memory plan = tokenLockupPlans.plans(planId);
        assertEq(plan.rate, 1e18);
    }

    function test_Claim_RateCalculation_MatchesExample() public {
        // Test with the exact example values from the user
        uint256 amount = 2000000000000000000; // 2e18

        vm.prank(owner);
        stratOption.mint(user1, 0, amount, 0, block.timestamp + 365 days, block.timestamp + 1 days);
        uint256 tokenId = stratOption._tokenIdCounter() - 1;

        vm.prank(user1);
        uint256 planId = claimStream.claim(tokenId);

        // Verify rate calculation
        ITokenLockupPlans.Plan memory plan = tokenLockupPlans.plans(planId);
        uint256 calculatedRate = amount / VESTING_DURATION_SECONDS;
        assertEq(plan.rate, calculatedRate);
        // The calculated rate should be 379,477,838,494 for 2 months (61 days = 5270400 seconds)
        // 2e18 / 5270400 = 379477838494
        assertEq(plan.rate, 379477838494);
    }
}

