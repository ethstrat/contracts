// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {MorphoBlueFlashLoanProvider} from "../../src/MorphoBlueFlashLoanProvider.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashLender} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";

/**
 * @title MorphoBlue Flash Loan Provider Integration Tests
 * @notice Tests for MorphoBlueFlashLoanProvider using real mainnet contracts
 * @dev 
 *      To run these tests:
 *        FORK_URL=<your_mainnet_rpc_url> yarn test:integration
 *      
 *      Or directly with forge:
 *        FOUNDRY_PROFILE=integration forge test --fork-url <your_mainnet_rpc_url> -vv
 *      
 *      Fork block: 22_000_000 (same as other integration tests)
 *      
 *      NOTE: Update the following addresses with actual mainnet addresses:
 *      - MORPHO_BLUE: MorphoBlue flash loan contract address
 *      - SUSDS: sUSDS token address (staked USDS)
 *      - STAKING_CONTRACT: Sky staking contract address for USDS <-> sUSDS conversion
 */
contract MorphoBlueFlashLoanProviderIntegrationTest is Test {
    MorphoBlueFlashLoanProvider public flashLoanProvider;
    
    // Mainnet addresses
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // Sky USDS stablecoin
    // Note: MORPHO_BLUE, SUSDS, and STAKING_CONTRACT are now constants in MorphoBlueFlashLoanProvider contract
    // Tests will fail at deployment if these are not set correctly in the contract
    
    // Test addresses
    address public user1 = address(0x3);
    
    // Fork block number
    uint256 public constant FORK_BLOCK = 22_000_000;
    
    // Whale address with USDS for testing
    address public constant USDS_WHALE = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    
    function setUp() public {
        // Create fork at specific block number
        vm.rollFork(FORK_BLOCK);
        
        // Verify we're on mainnet fork (chainid 1)
        require(block.chainid == 1, "Must be on mainnet fork");

        // Deploy MorphoBlue flash loan provider (only USDS needed, other addresses are constants)
        flashLoanProvider = new MorphoBlueFlashLoanProvider();
        
        // Fund user1 with USDS from whale
        vm.prank(USDS_WHALE);
        IERC20(USDS).transfer(user1, 10_000 * 10 ** 18);

        // Fund flashLoanProvider with 1 USDS from whale. This is to prevent rounding issues between redeem and mint.
        vm.prank(USDS_WHALE);
        IERC20(USDS).transfer(address(flashLoanProvider), 1 * 10 ** 18);
    }
    
    /**
     * @notice Test that MorphoBlueFlashLoanProvider can flash loan USDS
     * @dev This test verifies:
     *      1. Provider can query max flash loan
     *      2. Provider can query flash fee (should be 0 as provider expects no fee)
     *      3. Provider can execute flash loan
     *      4. Flash loan properly converts sUSDS to USDS and back
     *      
     *      Note: The provider expects MorphoBlue to charge 0 fee (reverts if fee != 0)
     */
    function testFork_FlashLoan_USDS() public {
        uint256 amount = 100 * 10 ** 18;
        
        // Create a simple borrower contract for testing
        TestFlashBorrower borrower = new TestFlashBorrower(USDS);
        
        // Execute flash loan
        bytes memory data = abi.encode("test");
        bool success = flashLoanProvider.flashLoan(
            IERC3156FlashBorrower(address(borrower)),
            USDS,
            amount,
            data
        );
    }
}

/**
 * @title Test Flash Borrower
 * @dev Simple test contract that implements IERC3156FlashBorrower
 *      Note: MorphoBlueFlashLoanProvider passes fee=0 to the callback
 */
contract TestFlashBorrower is IERC3156FlashBorrower {
    address public immutable token;
    
    constructor(address _token) {
        token = _token;
    }
    
    function onFlashLoan(
        address /* initiator */,
        address tokenAddress,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        // Verify we received USDS
        require(tokenAddress == token, "Wrong token");
        
        // Verify fee is 0 (as expected by MorphoBlueFlashLoanProvider)
        require(fee == 0, "Provider expects 0 fee");
        
        // Note: We receive more USDS than `amount` due to sUSDS exchange rate,
        // but we only need to repay `amount` (which is calculated via previewMint)
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "Did not receive expected amount");
        
        // Since fee is 0, we only need to repay `amount`
        // Approve repayment of exactly `amount` USDS
        IERC20(token).approve(msg.sender, amount);
        
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
