// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {esETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Minimal ERC4626 vault. `totalAssets()` is derived from underlying token balance,
///      so tests can simulate yield/loss by donating/removing underlying assets.
contract SimpleERC4626Vault is ERC4626 {
    constructor(address underlying, string memory name_, string memory symbol_)
        ERC4626(IERC20(underlying))
        ERC20(name_, symbol_)
    {}
}

// Wrapper for MockERC20 to add mint function
contract MintableMockERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract esETHTest is Test {
    esETH public esETHContract;
    MockWETH public weth;
    SimpleERC4626Vault public yieldBearingLST;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public yieldReceiver = address(0x4);
    address public randomUser = address(0x5);
    address public treasuryManager = address(0x6);

    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant MINT_AMOUNT = 1000 * 1e18;

    function setUp() public {
        // Deploy mock tokens
        weth = new MockWETH();
        // Fund and wrap ETH into WETH for test actors (WETH is underlying for ERC4626 vaults too).
        vm.deal(address(this), INITIAL_BALANCE * 3);
        weth.deposit{value: INITIAL_BALANCE * 3}();

        vm.deal(user1, INITIAL_BALANCE * 3);
        vm.prank(user1);
        weth.deposit{value: INITIAL_BALANCE * 3}();

        vm.deal(user2, INITIAL_BALANCE * 3);
        vm.prank(user2);
        weth.deposit{value: INITIAL_BALANCE * 3}();

        // Deploy ERC4626 vaults
        yieldBearingLST = new SimpleERC4626Vault(address(weth), "Mock Yield Bearing LST Vault", "myLST");
        weth.approve(address(yieldBearingLST), type(uint256).max);
        yieldBearingLST.deposit(INITIAL_BALANCE, address(this));

        // Deploy esETH contract
        vm.prank(owner);
        esETHContract = new esETH(owner, address(weth));

        // Configure tokens
        vm.startPrank(owner);
        // WETH: ERC20 type, 1:1 with ETH, mintable and redeemable
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);
        // yieldBearingLST: ERC4626, mintable and redeemable
        esETHContract.setTokenConfig(address(yieldBearingLST), esETH.TokenType.ERC4626, true, true);
        vm.stopPrank();

        // user1 and user2 initial token state setup
        vm.startPrank(user1);
        weth.approve(address(yieldBearingLST), type(uint256).max);
        yieldBearingLST.deposit(INITIAL_BALANCE, user1);
        weth.approve(address(esETHContract), type(uint256).max);
        yieldBearingLST.approve(address(esETHContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        weth.approve(address(yieldBearingLST), type(uint256).max);
        yieldBearingLST.deposit(INITIAL_BALANCE, user2);
        weth.approve(address(esETHContract), type(uint256).max);
        yieldBearingLST.approve(address(esETHContract), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor() external view {
        assertEq(esETHContract.owner(), owner);
        assertEq(esETHContract.name(), "ETH Strategy ETH");
        assertEq(esETHContract.symbol(), "esETH");
        assertEq(esETHContract.decimals(), 18);
        assertEq(esETHContract.totalSupply(), 0);
        // yieldReceiver should be initialized to owner
        assertEq(esETHContract.yieldReceiver(), owner);
        // treasuryManager should be initialized to owner
        assertEq(esETHContract.treasuryManager(), owner);
    }

    // ============ Token Configuration Tests ============

    function test_SetTokenConfig() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.prank(owner);
        esETHContract.setTokenConfig(address(newToken), esETH.TokenType.ERC20, true, true);

        (esETH.TokenType tokenType, bool isMintable, bool isRedeemable, uint256 totalMinted) =
            esETHContract.tokenConfigs(address(newToken));
        assertEq(uint256(tokenType), uint256(esETH.TokenType.ERC20));
        assertEq(isMintable, true);
        assertEq(isRedeemable, true);
        assertEq(totalMinted, 0);
    }

    function test_SetTokenConfig_OnlyOwner() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user1)
        );
        esETHContract.setTokenConfig(address(newToken), esETH.TokenType.ERC20, true, true);
    }

    function test_SetTokenConfig_ZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(esETH.ZeroAddress.selector);
        esETHContract.setTokenConfig(address(0), esETH.TokenType.ERC20, true, true);
    }

    function test_SetTokenConfig_PreservesTotalMinted() external {
        // First mint some esETH
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Check totalMinted
        (,,, uint256 totalMintedBefore) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMintedBefore, MINT_AMOUNT);

        // Update config
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, false);

        // totalMinted should be preserved
        (,,, uint256 totalMintedAfter) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMintedAfter, totalMintedBefore);
    }

    // ============ Treasury Manager Tests ============

    function test_SetTreasuryManager() external {
        vm.prank(owner);
        esETHContract.setTreasuryManager(treasuryManager);
        assertEq(esETHContract.treasuryManager(), treasuryManager);
    }

    function test_SetTreasuryManager_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user1)
        );
        esETHContract.setTreasuryManager(treasuryManager);
    }

    function test_SetTreasuryManager_ZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(esETH.ZeroAddress.selector);
        esETHContract.setTreasuryManager(address(0));
    }

    function test_TreasuryManager_CanMint_WhenNotMintable() external {
        // Set token as not mintable for regular users
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);

        // Set treasury manager
        vm.prank(owner);
        esETHContract.setTreasuryManager(treasuryManager);

        // Fund + approve
        vm.deal(treasuryManager, MINT_AMOUNT);
        vm.prank(treasuryManager);
        weth.deposit{value: MINT_AMOUNT}();
        vm.startPrank(treasuryManager);
        weth.approve(address(esETHContract), type(uint256).max);

        // Should succeed for treasury manager even though isMintable=false
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, treasuryManager);
        assertEq(esETHAmount, MINT_AMOUNT);
        assertEq(esETHContract.balanceOf(treasuryManager), MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_TreasuryManager_CanRedeem_WhenNotRedeemable() external {
        // Set token as not mintable AND not redeemable for regular users
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, false);

        // Set treasury manager
        vm.prank(owner);
        esETHContract.setTreasuryManager(treasuryManager);

        // Fund + approve
        vm.deal(treasuryManager, MINT_AMOUNT);
        vm.prank(treasuryManager);
        weth.deposit{value: MINT_AMOUNT}();
        vm.startPrank(treasuryManager);
        weth.approve(address(esETHContract), type(uint256).max);

        // Mint then redeem should both succeed for treasury manager
        esETHContract.mint(address(weth), MINT_AMOUNT, treasuryManager);
        uint256 esETHBurned = esETHContract.redeem(address(weth), MINT_AMOUNT, treasuryManager);
        assertEq(esETHBurned, MINT_AMOUNT);
        assertEq(esETHContract.balanceOf(treasuryManager), 0);
        assertEq(weth.balanceOf(treasuryManager), MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_TreasuryManager_RevertsOnUnsupportedToken() external {
        // Set treasury manager
        vm.prank(owner);
        esETHContract.setTreasuryManager(treasuryManager);

        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);
        newToken.mint(treasuryManager, MINT_AMOUNT);

        vm.startPrank(treasuryManager);
        newToken.approve(address(esETHContract), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(newToken)));
        esETHContract.mint(address(newToken), MINT_AMOUNT, treasuryManager);

        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(newToken)));
        esETHContract.redeem(address(newToken), MINT_AMOUNT, treasuryManager);
        vm.stopPrank();
    }

    // ============ Mint Tests ============

    function test_Mint_UnsupportedTokenTypeConfigured_Reverts() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);
        newToken.mint(user1, MINT_AMOUNT);

        // Configure as UNSUPPORTED but mintable=true to ensure the revert is due to unsupported type
        vm.prank(owner);
        esETHContract.setTokenConfig(address(newToken), esETH.TokenType.UNSUPPORTED, true, false);

        vm.startPrank(user1);
        newToken.approve(address(esETHContract), MINT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(newToken)));
        esETHContract.mint(address(newToken), MINT_AMOUNT, user1);
        vm.stopPrank();
    }

    function test_Mint_WithERC20() external {
        uint256 amount = MINT_AMOUNT;

        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), amount, user1);

        assertEq(esETHAmount, amount); // 1:1 for ERC20
        assertEq(esETHContract.balanceOf(user1), esETHAmount);
        assertEq(weth.balanceOf(address(esETHContract)), amount);
        assertEq(esETHContract.totalSupply(), esETHAmount);

        // Check totalMinted is updated
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMinted, esETHAmount);
    }

    function test_Mint_ToReceiver() external {
        uint256 amount = MINT_AMOUNT;

        uint256 user1WethBefore = weth.balanceOf(user1);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), amount, user2);

        assertEq(esETHContract.balanceOf(user1), 0);
        assertEq(esETHContract.balanceOf(user2), esETHAmount);
        assertEq(weth.balanceOf(user1), user1WethBefore - amount);
        assertEq(weth.balanceOf(address(esETHContract)), amount);
    }

    function test_WrapAndMint_MintsToReceiver() external {
        uint256 amount = 5 ether;
        vm.deal(user1, amount);

        uint256 esETHBefore = esETHContract.balanceOf(user2);
        uint256 wethBackingBefore = weth.balanceOf(address(esETHContract));

        vm.prank(user1);
        uint256 esETHAmount = esETHContract.wrapAndMint{value: amount}(user2);

        assertEq(esETHAmount, amount);
        assertEq(esETHContract.balanceOf(user2), esETHBefore + amount);
        assertEq(weth.balanceOf(address(esETHContract)), wethBackingBefore + amount);
    }

    function test_WrapAndMint_ZeroValueReverts() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.wrapAndMint{value: 0}(user1);
    }

    function test_MintAndWrap_Alias_Works() external {
        uint256 amount = 3 ether;
        vm.deal(user1, amount);

        uint256 esETHBefore = esETHContract.balanceOf(user2);
        uint256 wethBackingBefore = weth.balanceOf(address(esETHContract));

        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mintAndWrap{value: amount}(user2);

        assertEq(esETHAmount, amount);
        assertEq(esETHContract.balanceOf(user2), esETHBefore + amount);
        assertEq(weth.balanceOf(address(esETHContract)), wethBackingBefore + amount);
    }

    function test_Mint_WithERC4626() external {
        uint256 amount = MINT_AMOUNT;

        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(yieldBearingLST), amount, user1);

        // For ERC4626, convertToAssets should return the underlying asset value
        uint256 expectedETH = yieldBearingLST.convertToAssets(amount);
        assertEq(esETHAmount, expectedETH);
        assertEq(esETHContract.balanceOf(user1), esETHAmount);
        assertEq(yieldBearingLST.balanceOf(address(esETHContract)), amount);

        // Check totalMinted is updated
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(yieldBearingLST));
        assertEq(totalMinted, esETHAmount);
    }

    function test_Mint_NotWhitelisted() external {
        // Set token as not mintable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.TokenNotWhitelistedForMint.selector, address(weth))
        );
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);
    }

    function test_Mint_ZeroAmount() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.mint(address(weth), 0, user1);
    }

    // ============ Redeem Tests ============

    function test_Redeem_UnsupportedTokenTypeConfigured_Reverts() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        // Configure as UNSUPPORTED but redeemable=true to ensure the revert is due to unsupported type
        vm.prank(owner);
        esETHContract.setTokenConfig(address(newToken), esETH.TokenType.UNSUPPORTED, false, true);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(newToken)));
        esETHContract.redeem(address(newToken), MINT_AMOUNT, user1);
        vm.stopPrank();
    }

    function test_Redeem_ForERC20() external {
        // First mint some esETH
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), mintAmount, user1);

        // Now redeem
        uint256 wethBalanceBefore = weth.balanceOf(user1);
        uint256 esETHBalanceBefore = esETHContract.balanceOf(user1);
        vm.prank(user1);
        uint256 tokenAmount = esETHContract.redeem(address(weth), esETHAmount, user1);

        assertEq(tokenAmount, esETHAmount); // 1:1 for ERC20
        assertEq(weth.balanceOf(user1), wethBalanceBefore + tokenAmount);
        assertEq(esETHContract.balanceOf(user1), esETHBalanceBefore - esETHAmount);
        assertEq(esETHContract.totalSupply(), 0);

        // Check totalMinted is updated
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMinted, 0);
    }

    function test_Redeem_ToReceiver() external {
        // Mint esETH for user1
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        uint256 user2WethBefore = weth.balanceOf(user2);
        uint256 user1EsEthBefore = esETHContract.balanceOf(user1);

        // Redeem to user2
        vm.prank(user1);
        uint256 tokenOut = esETHContract.redeem(address(weth), esETHAmount, user2);

        assertEq(tokenOut, esETHAmount);
        assertEq(weth.balanceOf(user2), user2WethBefore + tokenOut);
        assertEq(esETHContract.balanceOf(user1), user1EsEthBefore - esETHAmount);
    }

    function test_Redeem_ForERC4626() external {
        // First mint some esETH with yieldBearingLST
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(yieldBearingLST), mintAmount, user1);

        // Now redeem for yieldBearingLST - redeem the exact shares that were deposited
        uint256 balanceBefore = yieldBearingLST.balanceOf(user1);
        // Contract has mintAmount shares from our deposit, redeem those exact shares
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(yieldBearingLST), mintAmount, user1);

        // Should get back the shares we requested (mintAmount shares)
        assertEq(yieldBearingLST.balanceOf(user1), balanceBefore + mintAmount);
        // esETHBurned should equal esETHAmount (the ETH value of mintAmount shares)
        assertEq(esETHBurned, esETHAmount);
    }

    function test_Redeem_NotWhitelisted() external {
        // Mint esETH
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Set token as not redeemable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, false);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, address(weth))
        );
        esETHContract.redeem(address(weth), esETHAmount, user1);
    }

    function test_Redeem_InsufficientContractTokenBalance() external {
        // Mint esETH
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Try to redeem more than contract has
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.InsufficientBalance.selector, address(weth))
        );
        esETHContract.redeem(address(weth), esETHAmount + 1, user1);
    }

    function test_Redeem_InsufficientEsETHBalanceToBurn() external {
        // Mint some esETH for user1
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Increase totalMinted + contract WETH balance so the failure comes from burning esETH
        // (not token balance checks, and not totalMinted underflow).
        vm.prank(user2);
        esETHContract.mint(address(weth), MINT_AMOUNT, user2);

        // User tries to redeem more WETH than their esETH balance supports burning.
        uint256 redeemAmount = esETHAmount + 1;
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                user1,
                esETHAmount,
                redeemAmount
            )
        );
        esETHContract.redeem(address(weth), redeemAmount, user1);
    }

    function test_Redeem_ZeroAmount() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.redeem(address(weth), 0, user1);
    }

    function test_Redeem_CrossToken() external {
        // User1 mints with WETH
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // User2 mints with yieldBearingLST to ensure contract has yieldBearingLST for cross-token redemption
        vm.prank(user2);
        esETHContract.mint(address(yieldBearingLST), MINT_AMOUNT, user2);

        // User1 redeems for yieldBearingLST (different token) - contract has MINT_AMOUNT shares
        uint256 balanceBefore = yieldBearingLST.balanceOf(user1);
        // Calculate shares needed based on esETHAmount, but limit to what's available
        uint256 shares = yieldBearingLST.convertToShares(esETHAmount);
        // Contract has MINT_AMOUNT shares, so we can redeem up to that
        uint256 sharesToRedeem = shares > MINT_AMOUNT ? MINT_AMOUNT : shares;
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(yieldBearingLST), sharesToRedeem, user1);

        assertGt(esETHBurned, 0);
        assertEq(yieldBearingLST.balanceOf(user1), balanceBefore + sharesToRedeem);
    }

    // ============ Harvest Yield Tests ============

    function test_HarvestYield_AnyoneCanCall() external {
        // Mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Manually add more tokens to contract (simulating yield or donations)
        weth.transfer(address(esETHContract), MINT_AMOUNT);

        uint256 supplyBefore = esETHContract.totalSupply();
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Random user can call harvestYield
        vm.prank(randomUser);
        esETHContract.harvestYield(tokens);

        uint256 supplyAfter = esETHContract.totalSupply();
        uint256 yield = supplyAfter - supplyBefore;

        assertGt(yield, 0);
        // Should mint to yieldReceiver (owner by default)
        assertEq(esETHContract.balanceOf(owner), yield);
    }

    function test_HarvestYield_MintsToYieldReceiver() external {
        // Set custom yield receiver
        vm.prank(owner);
        esETHContract.setYieldReceiver(yieldReceiver);

        // Mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Add more tokens
        weth.transfer(address(esETHContract), MINT_AMOUNT);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(user1);
        esETHContract.harvestYield(tokens);

        // Should mint to yieldReceiver
        assertGt(esETHContract.balanceOf(yieldReceiver), 0);
    }

    function test_HarvestYield_NoYield() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.harvestYield(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should not mint if no yield
        assertEq(supplyAfter, supplyBefore);
    }

    function test_HarvestYield_MultipleTokens() external {
        // Mint esETH with WETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Mint esETH with yieldBearingLST
        vm.prank(user2);
        yieldBearingLST.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        esETHContract.mint(address(yieldBearingLST), MINT_AMOUNT, user2);

        // Add extra tokens to both
        weth.transfer(address(esETHContract), MINT_AMOUNT / 2);
        yieldBearingLST.transfer(address(esETHContract), MINT_AMOUNT / 2);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(yieldBearingLST);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.harvestYield(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        assertGt(supplyAfter, supplyBefore);
    }

    function test_HarvestYield_WithERC4626Yield() external {
        // Mint esETH with yieldBearingLST
        vm.prank(user1);
        yieldBearingLST.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(yieldBearingLST), MINT_AMOUNT, user1);

        // Simulate yield by donating underlying assets to the vault (increases totalAssets,
        // and thus increases convertToAssets() for a fixed share amount).
        address donor = address(0xBEEF);
        vm.deal(donor, MINT_AMOUNT / 10);
        vm.prank(donor);
        weth.deposit{value: MINT_AMOUNT / 10}();
        vm.prank(donor);
        weth.transfer(address(yieldBearingLST), MINT_AMOUNT / 10);

        address[] memory tokens = new address[](1);
        tokens[0] = address(yieldBearingLST);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.harvestYield(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should mint yield based on increased backing
        assertGt(supplyAfter, supplyBefore);
    }

    // ============ Burn Excess Tests ============

    function test_BurnExcess_AnyoneCanCall() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Remove some tokens (simulating loss) - transfer tokens out as contract
        vm.prank(address(esETHContract));
        weth.transfer(owner, MINT_AMOUNT / 2);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Anyone can call (per US-006: no strong reason to make this permissioned)
        // user1 already has enough esETH to burn the excess
        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.burnExcess(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should burn excess
        assertLt(supplyAfter, supplyBefore);
    }

    function test_BurnExcess_NoExcess() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(owner);
        esETHContract.burnExcess(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should not burn if no excess
        assertEq(supplyAfter, supplyBefore);
    }

    function test_BurnExcess_BurnsFromCallerBalance() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Remove some tokens (simulating loss) - transfer tokens out as contract
        vm.prank(address(esETHContract));
        weth.transfer(owner, MINT_AMOUNT / 2);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Owner needs to have esETH to burn
        // Transfer esETH to owner first
        vm.prank(user1);
        esETHContract.transfer(owner, MINT_AMOUNT / 2);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(owner);
        esETHContract.burnExcess(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should burn excess from owner's balance
        assertLt(supplyAfter, supplyBefore);
    }

    function test_BurnExcess_RevertsIfCallerInsufficientEsETH() external {
        // Mint esETH (this also moves WETH backing into the contract)
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Create an excess by reducing backing (simulate loss)
        vm.prank(address(esETHContract));
        weth.transfer(owner, MINT_AMOUNT / 2);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Excess is totalMinted (MINT_AMOUNT) - backing (MINT_AMOUNT/2) = MINT_AMOUNT/2.
        // Owner has 0 esETH, so burning should revert with OZ ERC20 insufficient balance.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                owner,
                0,
                MINT_AMOUNT / 2
            )
        );
        esETHContract.burnExcess(tokens);
    }

    // ============ Set Yield Receiver Tests ============

    function test_SetYieldReceiver() external {
        vm.prank(owner);
        esETHContract.setYieldReceiver(yieldReceiver);

        assertEq(esETHContract.yieldReceiver(), yieldReceiver);
    }

    function test_SetYieldReceiver_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert();
        esETHContract.setYieldReceiver(yieldReceiver);
    }

    function test_SetYieldReceiver_ZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(esETH.ZeroAddress.selector);
        esETHContract.setYieldReceiver(address(0));
    }

    // ============ Get ETH Value Tests ============

    function test_GetETHValue_ERC20() external view {
        uint256 value = esETHContract.getETHValue(address(weth), MINT_AMOUNT);
        assertEq(value, MINT_AMOUNT);
    }

    function test_GetETHValue_ERC4626() external view {
        uint256 value = esETHContract.getETHValue(address(yieldBearingLST), MINT_AMOUNT);
        uint256 expected = yieldBearingLST.convertToAssets(MINT_AMOUNT);
        assertEq(value, expected);
    }

    function test_GetETHValue_UnsupportedToken() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.expectRevert(
            abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(newToken))
        );
        esETHContract.getETHValue(address(newToken), MINT_AMOUNT);
    }

    // ============ Integration Tests ============

    function test_Integration_MintAndRedeem() external {
        // User1 mints with WETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETH1 = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // User2 mints with yieldBearingLST
        vm.prank(user2);
        yieldBearingLST.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        uint256 esETH2 = esETHContract.mint(address(yieldBearingLST), MINT_AMOUNT, user2);

        // User1 redeems for yieldBearingLST - calculate shares and limit to available
        uint256 shares = yieldBearingLST.convertToShares(esETH1);
        uint256 sharesToRedeem = shares > MINT_AMOUNT ? MINT_AMOUNT : shares;
        vm.prank(user1);
        esETHContract.redeem(address(yieldBearingLST), sharesToRedeem, user1);

        // User2 redeems for WETH - need to check contract has enough WETH
        // Contract has MINT_AMOUNT WETH from user1, so we can redeem up to that
        uint256 wethBalance = weth.balanceOf(address(esETHContract));
        uint256 wethToRedeem = esETH2 > wethBalance ? wethBalance : esETH2;
        vm.prank(user2);
        esETHContract.redeem(address(weth), wethToRedeem, user2);

        // Check balances - user1 should have redeemed (may have tiny remainder due to rounding)
        assertLe(esETHContract.balanceOf(user1), 1); // Allow 1 wei rounding error
        assertGt(yieldBearingLST.balanceOf(user1), 0);
        // user2 may have remaining esETH if contract didn't have enough WETH, so just check they got some WETH
        assertGt(weth.balanceOf(user2), 0);
    }

    function test_Integration_MultipleUsers() external {
        uint256 amount = 100 * 1e18;

        // Multiple users mint
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(1000 + i));
            vm.deal(user, amount);
            vm.prank(user);
            weth.deposit{value: amount}();
            vm.prank(user);
            weth.approve(address(esETHContract), amount);
            vm.prank(user);
            esETHContract.mint(address(weth), amount, user);
        }

        assertEq(esETHContract.totalSupply(), amount * 5);
        assertEq(weth.balanceOf(address(esETHContract)), amount * 5);
    }

    function test_Integration_FullCycle() external {
        // 1. Multiple users mint with different tokens
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETH1 = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        vm.prank(user2);
        yieldBearingLST.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        uint256 esETH2 = esETHContract.mint(address(yieldBearingLST), MINT_AMOUNT, user2);

        // 2. Yield accrues (simulated by adding tokens)
        weth.transfer(address(esETHContract), MINT_AMOUNT / 10);
        // ERC4626 yield accrues by increasing underlying assets in the vault.
        address donor = address(0xCAFE);
        vm.deal(donor, MINT_AMOUNT / 10);
        vm.prank(donor);
        weth.deposit{value: MINT_AMOUNT / 10}();
        vm.prank(donor);
        weth.transfer(address(yieldBearingLST), MINT_AMOUNT / 10);

        // 3. Anyone can harvest
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(yieldBearingLST);
        vm.prank(randomUser);
        esETHContract.harvestYield(tokens);

        // 4. Users redeem
        vm.prank(user1);
        esETHContract.redeem(address(weth), esETH1, user1);
        // Calculate shares needed for yieldBearingLST redemption based on esETH2
        uint256 shares = yieldBearingLST.convertToShares(esETH2);
        vm.prank(user2);
        esETHContract.redeem(address(yieldBearingLST), shares, user2);

        // 5. Owner can burn excess if needed
        // (In this case there shouldn't be excess, but test the flow)
        vm.prank(owner);
        esETHContract.burnExcess(tokens);
    }
}
