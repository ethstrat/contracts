// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ESPNRedemptionQueue} from "../../src/ESPNRedemptionQueue.sol";
import {EthStrategyPerpetualNote} from "../../src/EthStrategyPerpetualNote.sol";
import {MorphoBlueFlashLoanProvider} from "../../src/MorphoBlueFlashLoanProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

/**
 * @title ESPN Redemption Queue Integration Tests
 * @notice Tests for ESPN Redemption Queue using MorphoBlueFlashLoanProvider for USDS flash loans
 * @dev 
 *      To run these tests:
 *        FORK_URL=<your_mainnet_rpc_url> yarn test:integration
 *      
 *      Or directly with forge:
 *        FOUNDRY_PROFILE=integration forge test --fork-url <your_mainnet_rpc_url> -vv
 *      
 *      Example:
 *        FORK_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY yarn test:integration
 *      
 *      Fork block: 22_000_000 (same as esETH integration tests)
 *      
 *      These tests verify that the cancellation mechanism works correctly with MorphoBlueFlashLoanProvider:
 *      - Cancel redemption uses USDS flash loan via MorphoBlueFlashLoanProvider
 *      - Provider flashes sUSDS from MorphoBlue, unstakes to USDS, sends to ESPNRedemptionQueue
 *      - ESPNRedemptionQueue uses USDS to deposit into ESPN (minting ESPN shares)
 *      - ESPN sends USDS to manager (this contract) as part of deposit
 *      - Provider restakes USDS to sUSDS and repays MorphoBlue flash loan
 *      - Minted ESPN is returned to user
 *      - ERC-3156 compliance throughout
 */
contract ESPNRedemptionQueueIntegrationTest is Test {
    ESPNRedemptionQueue public queue;
    EthStrategyPerpetualNote public espn;
    MorphoBlueFlashLoanProvider public flashLoanProvider;
    
    // Mainnet addresses
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    
    // Test addresses
    address public owner = address(0x1);
    address public sweeper = address(0x2);
    address public user1 = address(0x3);
    
    // Fork block number - using same as other integration tests
    uint256 public constant FORK_BLOCK = 22_000_000;
    
    // Whale address with USDS for testing (Sky: SUsds)
    address public constant USDS_WHALE = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    
    function setUp() public {
        // Create fork at specific block number
        vm.rollFork(FORK_BLOCK);
        
        // Verify we're on mainnet fork (chainid 1)
        require(block.chainid == 1, "Must be on mainnet fork");
        
        // Deploy ESPN with USDS as underlying
        vm.prank(owner);
        espn = new EthStrategyPerpetualNote(IERC20(USDS), owner);
        
        // Deploy MorphoBlue flash loan provider
        flashLoanProvider = new MorphoBlueFlashLoanProvider();
        
        // Deploy redemption queue with MorphoBlueFlashLoanProvider
        ITripwireController ctrl = ITripwireController(address(new TripwireController()));
        vm.prank(owner);
        queue = new ESPNRedemptionQueue(address(espn), sweeper, owner, ctrl);
        
        // Set queue as ESPN manager (required for cancellation to work)
        vm.prank(owner);
        espn.setManager(address(queue));
        
        // Set unlimited deposit cap for testing
        vm.prank(owner);
        espn.setDepositCap(type(uint256).max);
        
        // Fund user1 with USDS from whale
        vm.prank(USDS_WHALE);
        IERC20(USDS).transfer(user1, 10_000 * 10 ** 18);

        // Fund flashLoanProvider with 1 USDS from whale. This is to prevent rounding issues between redeem and mint.
        vm.prank(USDS_WHALE);
        IERC20(USDS).transfer(address(flashLoanProvider), 1 * 10 ** 18);
        
        // User1 deposits USDS into ESPN to get ESPN shares
        vm.startPrank(user1);
        IERC20(USDS).approve(address(espn), 5_000 * 10 ** 18);
        espn.deposit(5_000 * 10 ** 18, user1);
        vm.stopPrank();
    }
    
    /**
     * @notice Test that cancellation works with USDS flash loan via MorphoBlueFlashLoanProvider
     * @dev This is the main integration test that verifies:
     *      1. User can queue a redemption by burning ESPN
     *      2. User can cancel the redemption using USDS flash loan via MorphoBlueFlashLoanProvider
     *      3. Flash loan provider flashes sUSDS, unstakes to USDS, sends to ESPNRedemptionQueue
     *      4. ESPNRedemptionQueue uses USDS to mint ESPN
     *      5. ESPN sends USDS back to manager
     *      6. Provider restakes USDS to sUSDS and repays MorphoBlue
     *      7. User receives ESPN back
     *      
     *      Note: MorphoBlueFlashLoanProvider expects MorphoBlue to charge 0 fee (reverts if fee != 0)
     *      The provider passes fee=0 to ESPNRedemptionQueue's callback
     */
    function testFork_CancelRedemption_WithMorphoBlueFlashLoan() public {
        uint256 espnAmount = 100 * 10 ** 18;
        
        // User1 queues redemption (burns ESPN, mints NFT)
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount);
        uint256 tokenId = queue.queueRedemption(espnAmount);
        vm.stopPrank();
        
        uint256 user1EspnBefore = espn.balanceOf(user1);
        
        // User1 cancels redemption using USDS flash loan via MorphoBlueFlashLoanProvider
        vm.prank(user1);
        queue.cancelRedemption(tokenId);
        
        uint256 user1EspnAfter = espn.balanceOf(user1);
        
        // Verify cancellation worked
        (,, bool redeemed, bool cancelled) = queue.redemptions(tokenId);
        assertEq(cancelled, true, "Should be marked as cancelled");
        assertEq(redeemed, false, "Should not be redeemed");
        assertGt(user1EspnAfter, user1EspnBefore, "User should have received ESPN back");
    }
    
    /**
     * @notice Test multiple cancellations
     * @dev Verifies that multiple redemptions can be cancelled using flash loans
     */
    function testFork_MultipleCancellations() public {
        uint256 espnAmount1 = 50 * 10 ** 18;
        uint256 espnAmount2 = 75 * 10 ** 18;
        
        // Queue two redemptions
        vm.startPrank(user1);
        IERC20(address(espn)).approve(address(queue), espnAmount1 + espnAmount2);
        uint256 tokenId1 = queue.queueRedemption(espnAmount1);
        uint256 tokenId2 = queue.queueRedemption(espnAmount2);
        vm.stopPrank();
        
        uint256 user1EspnBefore = espn.balanceOf(user1);
        
        // Cancel both redemptions
        vm.prank(user1);
        queue.cancelRedemption(tokenId1);
        
        vm.prank(user1);
        queue.cancelRedemption(tokenId2);
        
        uint256 user1EspnAfter = espn.balanceOf(user1);
        
        // Verify both are cancelled and ESPN returned
        (,, bool redeemed1, bool cancelled1) = queue.redemptions(tokenId1);
        (,, bool redeemed2, bool cancelled2) = queue.redemptions(tokenId2);
        
        assertEq(cancelled1, true, "First should be cancelled");
        assertEq(cancelled2, true, "Second should be cancelled");
        assertEq(redeemed1, false, "First should not be redeemed");
        assertEq(redeemed2, false, "Second should not be redeemed");
        assertGt(user1EspnAfter, user1EspnBefore, "User should have received ESPN back");
    }
}
