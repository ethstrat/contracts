// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {esETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IAaveV3AToken {
    function scaledTotalSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

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
    // swETH (0xf951E335afb289353dc249e82926178EaC7DEd78) was deprecated by Swell Network;
    // its convertToAssets() reverts at current block numbers. Use sfrxETH instead.
    address public constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;

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
        esETHContract.setTokenConfig(SFRXETH, esETH.TokenType.ERC4626, false, false);
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

        // aWETH is a rebasing token: 1 aWETH = 1 WETH. Balance is already ETH-denominated.
        assertEq(ethValue, TEST_AMOUNT, "aWETH ETH value must be 1:1 - no additional scaling");
    }

    /**
     * @notice Regression guard: aWETH MUST NOT double-scale.
     * @dev aWETH (Aave V3) is a rebasing token whose balance already represents the current
     *      ETH value (1 aWETH == 1 WETH at any point in time). A previous bug applied the
     *      Aave liquidity-index ratio (`totalSupply / scaledTotalSupply`, currently ~1.04)
     *      on top of the already-rebased balance, inflating the reported ETH value by ~4%.
     *
     *      This test proves the conversion is strictly 1:1 by cross-checking with the raw
     *      on-chain ratio: if that ratio were mistakenly applied, ethValue would exceed
     *      TEST_AMOUNT, so we assert equality.
     */
    function testFork_GetETHValue_AWETH_NoDoubleScaling() public view {
        // scaledTotalSupply < totalSupply whenever any interest has accrued.
        // The ratio (totalSupply / scaledTotalSupply) is the Aave liquidity index (>1).
        uint256 scaledSupply = IAaveV3AToken(AWETH).scaledTotalSupply();
        uint256 totalSupply  = IAaveV3AToken(AWETH).totalSupply();
        assertGt(totalSupply, scaledSupply, "Setup: interest must have accrued for this test to be meaningful");

        uint256 ethValue = esETHContract.getETHValue(AWETH, TEST_AMOUNT);

        // aWETH is 1:1 with WETH — the rebasing balance IS the ETH value.
        assertEq(ethValue, TEST_AMOUNT, "aWETH ETH value must equal input amount (no double scaling)");

        // Cross-check: the old (buggy) formula would have returned more than TEST_AMOUNT.
        uint256 buggyValue = TEST_AMOUNT * totalSupply / scaledSupply;
        assertGt(buggyValue, TEST_AMOUNT, "Cross-check: old formula would have inflated the value");
        console2.log("aWETH correct ETH value:   ", ethValue);
        console2.log("aWETH buggy ETH value would have been:", buggyValue);
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
     * @notice Test getETHValue for sfrxETH (ERC4626)
     * @dev sfrxETH is a live ERC4626 vault (Frax Ether) that uses convertToAssets().
     *      swETH was previously used here but was deprecated by Swell Network and its
     *      convertToAssets() reverts at current block numbers.
     */
    function testFork_GetETHValue_SfrxETH() public view {
        uint256 ethValue = esETHContract.getETHValue(SFRXETH, TEST_AMOUNT);

        // sfrxETH should be worth >= 1 ETH (it accumulates staking rewards)
        assertGe(ethValue, TEST_AMOUNT, "sfrxETH should be worth at least 1 ETH");

        // Sanity check: sfrxETH rate should be reasonable (between 1.0 and 2.0 ETH per token)
        assertLe(ethValue, TEST_AMOUNT * 2, "sfrxETH rate seems unreasonably high");

        console2.log("sfrxETH ETH value:", ethValue);
        console2.log("sfrxETH rate (ETH per token):", ethValue * 1e18 / TEST_AMOUNT);
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
