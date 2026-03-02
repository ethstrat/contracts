// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {esETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title esETH Integration Tests
 * @notice Tests for getETHValue using real mainnet token addresses
 * @dev 
 *      To run these tests:
 *        FOUNDRY_MATCH_CONTRACT=IntegrationTest forge test
 *        OR
 *        FOUNDRY_PROFILE=integration forge test --fork-url='...'
 *      
 *      Note: Fork block number is hardcoded in the test.
 *      
 *      These tests verify that getETHValue works correctly with real mainnet LST tokens:
 *      - wstETH: Uses stEthPerToken()
 *      - rETH: Uses getExchangeRate()
 *      - aWETH: Uses scaledTotalSupply() (Aave V3)
 *      - weETH: Uses getEETHByWeETH()
 *      - cbETH: Uses exchangeRate()
 */
contract esETHIntegrationTest is Test {
    esETH public esETHContract;

    // Mainnet token addresses
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address public constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address public constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant CBETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
    address public constant SWETH = 0xf951E335afb289353dc249e82926178EaC7DEd78;

    address public owner = address(0x1);
    uint256 public constant TEST_AMOUNT = 1e18; // 1 token for testing

    // Fork block number - using a recent block for consistency
    // Update this to a recent block number when running tests
    uint256 public constant FORK_BLOCK = 22_000_000;

    function setUp() public {
        // Create fork at specific block number
        vm.rollFork(FORK_BLOCK);
        
        // Verify we're on mainnet fork (chainid 1)
        require(block.chainid == 1, "Must be on mainnet fork");

        // Deploy esETH contract
        vm.prank(owner);
        esETHContract = new esETH(owner, WETH);

        // Configure all token types
        vm.startPrank(owner);
        esETHContract.setTokenConfig(WSTETH, esETH.TokenType.WSTETH, false, false);
        esETHContract.setTokenConfig(RETH, esETH.TokenType.RETH, false, false);
        esETHContract.setTokenConfig(AWETH, esETH.TokenType.AWETH, false, false);
        esETHContract.setTokenConfig(WEETH, esETH.TokenType.WEETH, false, false);
        esETHContract.setTokenConfig(CBETH, esETH.TokenType.CBETH, false, false);
        esETHContract.setTokenConfig(SWETH, esETH.TokenType.ERC4626, false, false);
        vm.stopPrank();
    }

    /**
     * @notice Test getETHValue for wstETH
     * @dev wstETH uses stEthPerToken() which returns the stETH per wstETH rate
     */
    function testFork_GetETHValue_WstETH() public view {
        uint256 ethValue = esETHContract.getETHValue(WSTETH, TEST_AMOUNT);

        // wstETH should be worth >= 1 ETH (it accumulates staking rewards)
        assertGe(ethValue, TEST_AMOUNT, "wstETH should be worth at least 1 ETH");

        // Sanity check: wstETH rate should be reasonable (between 1.0 and 2.0 ETH per token)
        assertLe(ethValue, TEST_AMOUNT * 2, "wstETH rate seems unreasonably high");

        console2.log("wstETH ETH value:", ethValue);
        console2.log("wstETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
    }

    /**
     * @notice Test getETHValue for rETH
     * @dev rETH uses getExchangeRate() which returns the ETH per rETH rate scaled by 1e18
     */
    function testFork_GetETHValue_RETH() public view {
        uint256 ethValue = esETHContract.getETHValue(RETH, TEST_AMOUNT);

        // rETH should be worth >= 1 ETH (it accumulates staking rewards)
        assertGe(ethValue, TEST_AMOUNT, "rETH should be worth at least 1 ETH");

        // Sanity check: rETH rate should be reasonable
        assertLe(ethValue, TEST_AMOUNT * 2, "rETH rate seems unreasonably high");

        console2.log("rETH ETH value:", ethValue);
        console2.log("rETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
    }

    /**
     * @notice Test getETHValue for aWETH (Aave V3)
     * @dev Regression guard: aWETH uses scaledTotalSupply(), not getScaledTotalSupply().
     */
    function testFork_GetETHValue_AWETH_UsesV3Selector() public view {
        // Old Aave V2 selector should fail against Aave V3 aWETH.
        bytes4 oldSelector = bytes4(keccak256("getScaledTotalSupply()"));
        (bool oldCallSuccess,) = AWETH.staticcall(abi.encodeWithSelector(oldSelector));
        assertEq(oldCallSuccess, false, "Old getScaledTotalSupply selector should fail for aWETH");

        // Current selector should succeed.
        (bool v3CallSuccess,) = AWETH.staticcall(abi.encodeWithSelector(bytes4(keccak256("scaledTotalSupply()"))));
        assertEq(v3CallSuccess, true, "scaledTotalSupply selector should succeed for aWETH");

        uint256 ethValue = esETHContract.getETHValue(AWETH, TEST_AMOUNT);

        // aWETH should be worth >= 1 ETH (it accrues yield)
        assertGe(ethValue, TEST_AMOUNT, "aWETH should be worth at least 1 ETH");

        // Sanity check: aWETH rate should be reasonable.
        assertLe(ethValue, TEST_AMOUNT * 2, "aWETH rate seems unreasonably high");

        console2.log("aWETH ETH value:", ethValue);
        console2.log("aWETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
    }

    /**
     * @notice Test getETHValue for weETH (ether.fi)
     * @dev Regression guard: weETH uses getEETHByWeETH(uint256), not ERC4626 convertToAssets(uint256).
     */
    function testFork_GetETHValue_WEETH_UsesEtherFiSelector() public view {
        // ERC4626 selector should fail because weETH is not ERC4626.
        bytes4 erc4626Selector = bytes4(keccak256("convertToAssets(uint256)"));
        (bool erc4626CallSuccess,) = WEETH.staticcall(abi.encodeWithSelector(erc4626Selector, TEST_AMOUNT));
        assertEq(erc4626CallSuccess, false, "convertToAssets selector should fail for weETH");

        // weETH selector should succeed.
        bytes4 weEthSelector = bytes4(keccak256("getEETHByWeETH(uint256)"));
        (bool selectorSuccess, bytes memory selectorData) = WEETH.staticcall(abi.encodeWithSelector(weEthSelector, TEST_AMOUNT));
        assertEq(selectorSuccess, true, "getEETHByWeETH selector should succeed for weETH");

        uint256 directRateValue = abi.decode(selectorData, (uint256));
        uint256 ethValue = esETHContract.getETHValue(WEETH, TEST_AMOUNT);

        // esETH conversion should match direct contract call
        assertEq(ethValue, directRateValue, "weETH ETH value should match getEETHByWeETH result");
        assertGe(ethValue, TEST_AMOUNT, "weETH should be worth at least 1 ETH");
        assertLe(ethValue, TEST_AMOUNT * 2, "weETH rate seems unreasonably high");

        console2.log("weETH ETH value:", ethValue);
        console2.log("weETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
    }

    /**
     * @notice Test getETHValue for cbETH
     * @dev cbETH uses exchangeRate() which returns the ETH per cbETH rate scaled by 1e18
     */
    function testFork_GetETHValue_CbETH() public view {
        uint256 ethValue = esETHContract.getETHValue(CBETH, TEST_AMOUNT);

        // cbETH should be worth >= 1 ETH (it accumulates staking rewards)
        assertGe(ethValue, TEST_AMOUNT, "cbETH should be worth at least 1 ETH");

        // Sanity check: cbETH rate should be reasonable
        assertLe(ethValue, TEST_AMOUNT * 2, "cbETH rate seems unreasonably high");

        console2.log("cbETH ETH value:", ethValue);
        console2.log("cbETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
    }

    /**
     * @notice Test getETHValue for swETH
     * @dev swETH is an ERC4626 vault that uses convertToAssets()
     */
    function testFork_GetETHValue_SwETH() public view {
        uint256 ethValue = esETHContract.getETHValue(SWETH, TEST_AMOUNT);

        // swETH should be worth >= 1 ETH (it accumulates staking rewards)
        assertGe(ethValue, TEST_AMOUNT, "swETH should be worth at least 1 ETH");

        // Sanity check: swETH rate should be reasonable (between 1.0 and 2.0 ETH per token)
        assertLe(ethValue, TEST_AMOUNT * 2, "swETH rate seems unreasonably high");

        console2.log("swETH ETH value:", ethValue);
        console2.log("swETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
    }

    /**
     * @notice Test that getETHValue reverts for unsupported tokens
     */
    function testFork_GetETHValue_UnsupportedToken() public {
        address unsupportedToken = address(0x1234);

        vm.expectRevert(
            abi.encodeWithSelector(esETH.UnsupportedToken.selector, unsupportedToken)
        );
        esETHContract.getETHValue(unsupportedToken, TEST_AMOUNT);
    }
}
