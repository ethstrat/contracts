// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {esETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

/// @dev Minimal weETH-like token with configurable conversion rate to ETH-equivalent units.
contract MockWeETH is ERC20 {
    uint256 public rate; // ETH-equivalent per 1 weETH, scaled by 1e18

    constructor(uint256 initialRate) ERC20("Mock Wrapped eETH", "mweETH") {
        rate = initialRate;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256) {
        return weETHAmount * rate / 1e18;
    }
}

// Wrapper for MockERC20 to add mint function
contract MintableMockERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract esETHTest is Test {
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    esETH public esETHContract;
    MockWETH public weth;
    MockWeETH public weETH;

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
        // Fund and wrap ETH into WETH for test actors.
        vm.deal(address(this), INITIAL_BALANCE * 3);
        weth.deposit{value: INITIAL_BALANCE * 3}();

        vm.deal(user1, INITIAL_BALANCE * 3);
        vm.prank(user1);
        weth.deposit{value: INITIAL_BALANCE * 3}();

        vm.deal(user2, INITIAL_BALANCE * 3);
        vm.prank(user2);
        weth.deposit{value: INITIAL_BALANCE * 3}();

        weETH = new MockWeETH(1.05e18);
        weETH.mint(address(this), INITIAL_BALANCE);
        weETH.mint(user1, INITIAL_BALANCE);
        weETH.mint(user2, INITIAL_BALANCE);

        // Deploy esETH contract
        ITripwireController ctrl = ITripwireController(address(new TripwireController()));
        vm.prank(owner);
        esETHContract = new esETH(owner, address(weth), ctrl, owner);

        // Configure tokens
        vm.startPrank(owner);
        // WETH: ERC20 type, 1:1 with ETH, mintable and redeemable
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);
        // weETH: custom non-ERC4626 wrapped ETH rate token
        esETHContract.setTokenConfig(address(weETH), esETH.TokenType.WEETH, true, true);
        esETHContract.addMinter(user1);
        esETHContract.addMinter(user2);
        esETHContract.addMinter(treasuryManager);
        vm.stopPrank();

        // user1 and user2 initial token state setup
        vm.startPrank(user1);
        weth.approve(address(esETHContract), type(uint256).max);
        weETH.approve(address(esETHContract), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        weth.approve(address(esETHContract), type(uint256).max);
        weETH.approve(address(esETHContract), type(uint256).max);
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
        assertEq(esETHContract.isMinter(owner), false);
        assertEq(esETHContract.isMinter(user1), true);
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
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user1));
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
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user1));
        esETHContract.setTreasuryManager(treasuryManager);
    }

    function test_SetTreasuryManager_ZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(esETH.ZeroAddress.selector);
        esETHContract.setTreasuryManager(address(0));
    }

    // ============ Minter Tests ============

    function test_AddMinter() external {
        assertEq(esETHContract.isMinter(randomUser), false);
        vm.prank(owner);
        esETHContract.addMinter(randomUser);
        assertEq(esETHContract.isMinter(randomUser), true);
    }

    function test_AddMinter_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user1));
        esETHContract.addMinter(randomUser);
    }

    function test_AddMinter_ZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(esETH.ZeroAddress.selector);
        esETHContract.addMinter(address(0));
    }

    function test_RemoveMinter() external {
        vm.startPrank(owner);
        esETHContract.addMinter(randomUser);
        esETHContract.removeMinter(randomUser);
        vm.stopPrank();
        assertEq(esETHContract.isMinter(randomUser), false);
    }

    function test_RemoveMinter_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), user1));
        esETHContract.removeMinter(user2);
    }

    function test_Mint_NotMinter_Reverts() external {
        vm.deal(randomUser, MINT_AMOUNT);
        vm.prank(randomUser);
        weth.deposit{value: MINT_AMOUNT}();
        vm.prank(randomUser);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(randomUser);
        vm.expectRevert(esETH.NotMinter.selector);
        esETHContract.mint(address(weth), MINT_AMOUNT, randomUser);
    }

    function test_WrapAndMint_NotMinter_Reverts() external {
        vm.deal(randomUser, 1 ether);
        vm.prank(randomUser);
        vm.expectRevert(esETH.NotMinter.selector);
        esETHContract.wrapAndMint{value: 1 ether}(randomUser);
    }

    function test_FreshDeploy_NoAddressIsMinterByDefault() external {
        ITripwireController ctrl2 = ITripwireController(address(new TripwireController()));
        vm.prank(owner);
        esETH fresh = new esETH(owner, address(weth), ctrl2, owner);
        assertEq(fresh.isMinter(owner), false);
        assertEq(fresh.isMinter(address(0xBEEF)), false);
    }

    function test_AddMinter_EmitsMinterAdded() external {
        vm.expectEmit(true, true, true, true);
        emit MinterAdded(randomUser);
        vm.prank(owner);
        esETHContract.addMinter(randomUser);
    }

    function test_RemoveMinter_EmitsMinterRemoved() external {
        vm.prank(owner);
        esETHContract.addMinter(randomUser);
        vm.expectEmit(true, true, true, true);
        emit MinterRemoved(randomUser);
        vm.prank(owner);
        esETHContract.removeMinter(randomUser);
    }

    /// @dev NotMinter is checked before `safeTransferFrom`; no approval needed to observe it.
    function test_Mint_NotMinter_RevertsBeforeTokenPull() external {
        vm.prank(randomUser);
        vm.expectRevert(esETH.NotMinter.selector);
        esETHContract.mint(address(weth), MINT_AMOUNT, randomUser);
    }

    /// @dev Treasury bypass for `isMintable` does not substitute for `isMinter`.
    function test_TreasuryManager_MustBeMinter_ToMint() external {
        address tm = address(0xABC0);
        vm.startPrank(owner);
        esETHContract.setTreasuryManager(tm);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);
        vm.stopPrank();

        vm.deal(tm, MINT_AMOUNT);
        vm.prank(tm);
        weth.deposit{value: MINT_AMOUNT}();
        vm.prank(tm);
        weth.approve(address(esETHContract), type(uint256).max);
        vm.prank(tm);
        vm.expectRevert(esETH.NotMinter.selector);
        esETHContract.mint(address(weth), MINT_AMOUNT, tm);
    }

    function test_RemoveMinter_ThenReAdd_AllowsMint() external {
        vm.prank(owner);
        esETHContract.removeMinter(user2);
        vm.prank(user2);
        vm.expectRevert(esETH.NotMinter.selector);
        esETHContract.mint(address(weth), 1, user2);

        vm.prank(owner);
        esETHContract.addMinter(user2);
        vm.prank(user2);
        uint256 minted = esETHContract.mint(address(weth), MINT_AMOUNT, user2);
        assertEq(minted, MINT_AMOUNT);
    }

    /// @dev Only `mint` / `wrapAndMint` are minter-gated; `redeem` remains permissionless for holders.
    function test_Redeem_DoesNotRequireMinterRole() external {
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);
        vm.prank(owner);
        esETHContract.removeMinter(user1);
        vm.prank(user1);
        uint256 burned = esETHContract.redeem(address(weth), MINT_AMOUNT - 1, user1);
        assertEq(burned, MINT_AMOUNT);
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
        // Redeem 1 wei less to account for rounding protection
        uint256 esETHBurned = esETHContract.redeem(address(weth), MINT_AMOUNT - 1, treasuryManager);
        assertEq(esETHBurned, MINT_AMOUNT); // Burns all esETH (including +1 wei)
        assertEq(esETHContract.balanceOf(treasuryManager), 0);
        assertEq(weth.balanceOf(treasuryManager), MINT_AMOUNT - 1); // Gets 1 wei less WETH
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

    function test_Mint_WithWEETH() external {
        uint256 amount = MINT_AMOUNT;

        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weETH), amount, user1);

        uint256 expectedETH = weETH.getEETHByWeETH(amount);
        assertEq(esETHAmount, expectedETH);
        assertEq(esETHContract.balanceOf(user1), expectedETH);
        assertEq(weETH.balanceOf(address(esETHContract)), amount);

        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(weETH));
        assertEq(totalMinted, expectedETH);
    }

    function test_Mint_NotWhitelisted() external {
        // Set token as not mintable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForMint.selector, address(weth)));
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

        // Now redeem - redeem 1 wei less to account for rounding protection
        uint256 wethBalanceBefore = weth.balanceOf(user1);
        uint256 esETHBalanceBefore = esETHContract.balanceOf(user1);
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(weth), esETHAmount - 1, user1);

        assertEq(esETHBurned, esETHAmount); // Burns esETH amount (base + 1 wei)
        assertEq(weth.balanceOf(user1), wethBalanceBefore + esETHAmount - 1); // Gets 1 wei less WETH
        assertEq(esETHContract.balanceOf(user1), 0); // All esETH burned
        assertEq(esETHContract.totalSupply(), 0);

        // Check totalMinted is updated (1 wei remains due to rounding protection)
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMinted, 1);
    }

    function test_Redeem_ToReceiver() external {
        // Mint esETH for user1
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        uint256 user2WethBefore = weth.balanceOf(user2);
        uint256 user1EsEthBefore = esETHContract.balanceOf(user1);

        // Redeem to user2 - redeem 1 wei less to account for rounding protection
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(weth), esETHAmount - 1, user2);

        assertEq(esETHBurned, esETHAmount); // Burns all esETH (including +1 wei)
        assertEq(weth.balanceOf(user2), user2WethBefore + esETHAmount - 1); // Gets 1 wei less WETH
        assertEq(esETHContract.balanceOf(user1), 0); // All esETH burned
    }

    function test_Redeem_ForWEETH() external {
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        uint256 esETHMinted = esETHContract.mint(address(weETH), mintAmount, user1);

        uint256 redeemAmount = mintAmount / 2;
        uint256 userWeETHBefore = weETH.balanceOf(user1);
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(weETH), redeemAmount, user1);

        uint256 expectedBurn = weETH.getEETHByWeETH(redeemAmount) + 1;
        assertEq(esETHBurned, expectedBurn);
        assertEq(weETH.balanceOf(user1), userWeETHBefore + redeemAmount);
        assertEq(esETHContract.balanceOf(user1), esETHMinted - expectedBurn);

        (,,, uint256 totalMintedAfter) = esETHContract.tokenConfigs(address(weETH));
        assertEq(totalMintedAfter, esETHMinted - (expectedBurn - 1));
    }

    function test_Redeem_NotWhitelisted() external {
        // Mint esETH
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Set token as not redeemable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, false);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, address(weth)));
        esETHContract.redeem(address(weth), esETHAmount, user1);
    }

    function test_Redeem_InsufficientContractTokenBalance() external {
        // Mint esETH
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Try to redeem more than contract has
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(esETH.InsufficientBalance.selector, address(weth)));
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
        // With +1 wei rounding protection, redeeming esETHAmount WETH requires esETHAmount + 1 wei
        uint256 redeemAmount = esETHAmount + 1;
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), user1, esETHAmount, esETHAmount + 2
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
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // User2 mints with weETH to ensure contract has weETH for cross-token redemption
        vm.prank(user2);
        esETHContract.mint(address(weETH), MINT_AMOUNT, user2);

        // User1 redeems for weETH (different token) using a fixed, round token amount.
        // esETH burned = getEETHByWeETH(redeemAmt) + 1 = redeemAmt * rate / 1e18 + 1
        uint256 weEthToRedeem = MINT_AMOUNT / 2;
        uint256 expectedBurned = weETH.getEETHByWeETH(weEthToRedeem) + 1;
        uint256 balanceBefore = weETH.balanceOf(user1);

        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(weETH), weEthToRedeem, user1);

        assertEq(esETHBurned, expectedBurned);
        assertEq(weETH.balanceOf(user1), balanceBefore + weEthToRedeem);
        assertGt(esETHContract.balanceOf(user1), 0); // User still has remaining esETH
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
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Mint esETH with weETH
        vm.prank(user2);
        esETHContract.mint(address(weETH), MINT_AMOUNT, user2);

        // Add extra tokens to both (simulates yield / donations)
        weth.transfer(address(esETHContract), MINT_AMOUNT / 2);
        weETH.mint(address(esETHContract), MINT_AMOUNT / 2);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(weETH);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.harvestYield(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        assertGt(supplyAfter, supplyBefore);
    }

    function test_HarvestYield_WithWEETHRateIncrease() external {
        vm.prank(user1);
        esETHContract.mint(address(weETH), MINT_AMOUNT, user1);

        // Simulate weETH yield accrual by increasing conversion rate.
        weETH.setRate(1.10e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.harvestYield(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        assertGt(supplyAfter, supplyBefore);

        (,,, uint256 totalMintedAfter) = esETHContract.tokenConfigs(address(weETH));
        uint256 backingAfter = esETHContract.getETHValue(address(weETH), weETH.balanceOf(address(esETHContract)));
        assertEq(totalMintedAfter, backingAfter);
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
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), owner, 0, MINT_AMOUNT / 2
            )
        );
        esETHContract.burnExcess(tokens);
    }

    function test_BurnExcess_WithWEETHRateDecrease() external {
        vm.prank(user1);
        esETHContract.mint(address(weETH), MINT_AMOUNT, user1);

        // Simulate weETH loss by reducing conversion rate.
        weETH.setRate(0.95e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weETH);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.burnExcess(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        assertLt(supplyAfter, supplyBefore);

        (,,, uint256 totalMintedAfter) = esETHContract.tokenConfigs(address(weETH));
        uint256 backingAfter = esETHContract.getETHValue(address(weETH), weETH.balanceOf(address(esETHContract)));
        assertEq(totalMintedAfter, backingAfter);
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

    function test_GetETHValue_WEETH() external view {
        uint256 value = esETHContract.getETHValue(address(weETH), MINT_AMOUNT);
        uint256 expected = weETH.getEETHByWeETH(MINT_AMOUNT);
        assertEq(value, expected);
    }

    function test_GetETHValue_UnsupportedToken() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(newToken)));
        esETHContract.getETHValue(address(newToken), MINT_AMOUNT);
    }

    // ============ Integration Tests ============

    function test_Integration_MintAndRedeem() external {
        // User1 mints with WETH
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // User2 mints with weETH
        vm.prank(user2);
        uint256 esETH2 = esETHContract.mint(address(weETH), MINT_AMOUNT, user2);

        // User1 redeems for weETH using a fixed, round token amount
        uint256 weEthToRedeem = MINT_AMOUNT / 2;
        vm.prank(user1);
        esETHContract.redeem(address(weETH), weEthToRedeem, user1);

        // User2 redeems for WETH - redeem 1 wei less to account for rounding
        uint256 wethBalance = weth.balanceOf(address(esETHContract));
        uint256 wethToRedeem = (esETH2 - 1) > wethBalance ? wethBalance : (esETH2 - 1);
        vm.prank(user2);
        esETHContract.redeem(address(weth), wethToRedeem, user2);

        // Check balances - both users received their requested tokens
        assertGt(weETH.balanceOf(user1), 0);
        assertGt(weth.balanceOf(user2), 0);
    }

    function test_Integration_MultipleUsers() external {
        uint256 amount = 100 * 1e18;

        // Multiple users mint
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(1000 + i));
            vm.prank(owner);
            esETHContract.addMinter(user);
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
        uint256 esETH1 = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        vm.prank(user2);
        uint256 esETH2 = esETHContract.mint(address(weETH), MINT_AMOUNT, user2);

        // 2. Yield accrues (simulated by adding tokens)
        weth.transfer(address(esETHContract), MINT_AMOUNT / 10);
        weETH.mint(address(esETHContract), MINT_AMOUNT / 10);

        // 3. Anyone can harvest
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(weETH);
        vm.prank(randomUser);
        esETHContract.harvestYield(tokens);

        // 4. Users redeem - redeem 1 wei less to account for rounding protection
        vm.prank(user1);
        esETHContract.redeem(address(weth), esETH1 - 1, user1);
        // weETH tokens for esETH2 - 1 esETH: (esETH2 - 1) * 1e18 / rate
        uint256 weEthShares = (esETH2 - 1) * 1e18 / weETH.rate();
        vm.prank(user2);
        esETHContract.redeem(address(weETH), weEthShares, user2);

        // 5. Owner can burn excess if needed
        // (In this case there shouldn't be excess, but test the flow)
        vm.prank(owner);
        esETHContract.burnExcess(tokens);
    }

    // ============ Invariant Tests ============

    /**
     * @notice INV-ESETH-001: Per-token Backing Invariant
     * @dev Verifies that totalMinted <= actual backing for each token
     *      After harvestYield(), totalMinted MUST equal actual backing
     */
    function test_Invariant_ESETH001_PerTokenBacking() external {
        // Mint with WETH
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Check invariant: totalMinted <= backing
        (,,, uint256 totalMintedBefore) = esETHContract.tokenConfigs(address(weth));
        uint256 backingBefore = esETHContract.getETHValue(address(weth), weth.balanceOf(address(esETHContract)));
        assertLe(totalMintedBefore, backingBefore, "INV-ESETH-001: totalMinted must be <= backing");

        // Add yield
        weth.transfer(address(esETHContract), MINT_AMOUNT / 10);

        // Before harvest: totalMinted < backing (yield exists)
        uint256 backingWithYield = esETHContract.getETHValue(address(weth), weth.balanceOf(address(esETHContract)));
        assertLt(totalMintedBefore, backingWithYield, "Before harvest: totalMinted should be < backing");

        // Harvest yield
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        esETHContract.harvestYield(tokens);

        // After harvest: totalMinted MUST equal backing
        (,,, uint256 totalMintedAfter) = esETHContract.tokenConfigs(address(weth));
        uint256 backingAfter = esETHContract.getETHValue(address(weth), weth.balanceOf(address(esETHContract)));
        assertEq(totalMintedAfter, backingAfter, "INV-ESETH-001: After harvestYield, totalMinted MUST equal backing");
    }

    /**
     * @notice INV-ESETH-001: Backing Invariant with burnExcess
     * @dev Verifies that burnExcess ensures totalMinted never exceeds backing
     */
    function test_Invariant_ESETH001_BurnExcess() external {
        // Mint with WETH
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Simulate loss by removing backing
        vm.prank(address(esETHContract));
        weth.transfer(owner, MINT_AMOUNT / 4);

        // Before burnExcess: totalMinted > backing (excess exists)
        (,,, uint256 totalMintedBefore) = esETHContract.tokenConfigs(address(weth));
        uint256 backingBefore = esETHContract.getETHValue(address(weth), weth.balanceOf(address(esETHContract)));
        assertGt(totalMintedBefore, backingBefore, "totalMinted should exceed backing after loss");

        // Burn excess
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        vm.prank(user1);
        esETHContract.burnExcess(tokens);

        // After burnExcess: totalMinted MUST equal backing
        (,,, uint256 totalMintedAfter) = esETHContract.tokenConfigs(address(weth));
        uint256 backingAfter = esETHContract.getETHValue(address(weth), weth.balanceOf(address(esETHContract)));
        assertEq(totalMintedAfter, backingAfter, "INV-ESETH-001: After burnExcess, totalMinted MUST equal backing");
    }

    /**
     * @notice INV-ESETH-002: Total Supply vs Total Backing
     * @dev Verifies that totalSupply == sum(tokenConfigs[t].totalMinted)
     */
    function test_Invariant_ESETH002_TotalSupplyEqualsSumOfTotalMinted() external {
        // Mint with multiple tokens
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        vm.prank(user2);
        esETHContract.mint(address(weETH), MINT_AMOUNT / 2, user2);

        // Check invariant
        (,,, uint256 totalMintedWeth) = esETHContract.tokenConfigs(address(weth));
        (,,, uint256 totalMintedWeETH) = esETHContract.tokenConfigs(address(weETH));
        uint256 sumTotalMinted = totalMintedWeth + totalMintedWeETH;
        uint256 totalSupply = esETHContract.totalSupply();

        assertEq(
            totalSupply, sumTotalMinted, "INV-ESETH-002: totalSupply must equal sum of all tokenConfigs[t].totalMinted"
        );
    }

    /**
     * @notice INV-ESETH-002: Total Supply maintained across operations
     * @dev Verifies invariant holds through mint, redeem, harvest, and burn operations
     */
    function test_Invariant_ESETH002_TotalSupplyMaintained() external {
        // Initial mint with WETH
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Check invariant after mint
        _checkTotalSupplyInvariant();

        // Mint with weETH
        vm.prank(user2);
        esETHContract.mint(address(weETH), MINT_AMOUNT / 2, user2);

        // Check invariant after second mint
        _checkTotalSupplyInvariant();

        // Add yield and harvest
        weth.transfer(address(esETHContract), MINT_AMOUNT / 10);
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(weETH);
        esETHContract.harvestYield(tokens);

        // Check invariant after harvest
        _checkTotalSupplyInvariant();

        // Redeem
        vm.prank(user1);
        esETHContract.redeem(address(weth), MINT_AMOUNT / 2, user1);

        // Check invariant after redeem
        _checkTotalSupplyInvariant();
    }

    /**
     * @notice INV-ESETH-003: Monotonic TotalMinted Updates
     * @dev Verifies that totalMinted increases by exactly esETHAmount on mint
     *      and decreases by exactly esETHAmount on redeem
     */
    function test_Invariant_ESETH003_MonotonicTotalMintedUpdates() external {
        // Check initial state
        (,,, uint256 totalMintedInitial) = esETHContract.tokenConfigs(address(weth));
        uint256 totalSupplyInitial = esETHContract.totalSupply();

        // Mint
        vm.prank(user1);
        uint256 esETHMinted = esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Verify totalMinted increased by exactly esETHAmount
        (,,, uint256 totalMintedAfterMint) = esETHContract.tokenConfigs(address(weth));
        assertEq(
            totalMintedAfterMint - totalMintedInitial,
            esETHMinted,
            "INV-ESETH-003: totalMinted must increase by exactly esETHAmount on mint"
        );
        assertEq(
            esETHContract.totalSupply() - totalSupplyInitial, esETHMinted, "Total supply must increase by esETHAmount"
        );

        // Redeem
        uint256 redeemAmount = MINT_AMOUNT / 2;
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(weth), redeemAmount, user1);

        // Verify totalMinted decreased by esETHBurned - 1 (the +1 wei is rounding protection)
        (,,, uint256 totalMintedAfterRedeem) = esETHContract.tokenConfigs(address(weth));
        assertEq(
            totalMintedAfterMint - totalMintedAfterRedeem,
            esETHBurned - 1,
            "INV-ESETH-003: totalMinted must decrease by esETHAmount - 1 on redeem (1 wei is rounding protection)"
        );
    }

    /**
     * @notice INV-ESETH-004: Unsupported Tokens Never Work
     * @dev Verifies all operations revert for unsupported tokens
     */
    function test_Invariant_ESETH004_UnsupportedTokensNeverWork() external {
        MintableMockERC20 unsupportedToken = new MintableMockERC20();
        unsupportedToken.initialize("Unsupported", "UNSUP", 18);
        unsupportedToken.mint(user1, MINT_AMOUNT);

        vm.startPrank(user1);
        unsupportedToken.approve(address(esETHContract), MINT_AMOUNT);

        // mint() should revert
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(unsupportedToken)));
        esETHContract.mint(address(unsupportedToken), MINT_AMOUNT, user1);

        // redeem() should revert (even though user has no balance)
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(unsupportedToken)));
        esETHContract.redeem(address(unsupportedToken), MINT_AMOUNT, user1);

        // getETHValue() should revert
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(unsupportedToken)));
        esETHContract.getETHValue(address(unsupportedToken), MINT_AMOUNT);

        vm.stopPrank();
    }

    /**
     * @notice INV-ESETH-004: Operations fail for unsupported tokens regardless of caller
     * @dev Verifies that even treasuryManager cannot use unsupported tokens
     */
    function test_Invariant_ESETH004_UnsupportedTokensFailForTreasuryManager() external {
        MintableMockERC20 unsupportedToken = new MintableMockERC20();
        unsupportedToken.initialize("Unsupported", "UNSUP", 18);
        unsupportedToken.mint(treasuryManager, MINT_AMOUNT);

        // Set treasury manager
        vm.prank(owner);
        esETHContract.setTreasuryManager(treasuryManager);

        vm.startPrank(treasuryManager);
        unsupportedToken.approve(address(esETHContract), MINT_AMOUNT);

        // Even treasuryManager cannot mint unsupported tokens
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(unsupportedToken)));
        esETHContract.mint(address(unsupportedToken), MINT_AMOUNT, treasuryManager);

        // Even treasuryManager cannot redeem unsupported tokens
        vm.expectRevert(abi.encodeWithSelector(esETH.UnsupportedToken.selector, address(unsupportedToken)));
        esETHContract.redeem(address(unsupportedToken), MINT_AMOUNT, treasuryManager);

        vm.stopPrank();
    }

    /**
     * @notice INV-ESETH-005: Treasury Manager Bypass
     * @dev Verifies treasuryManager can bypass isMintable/isRedeemable flags
     */
    function test_Invariant_ESETH005_TreasuryManagerBypass() external {
        // Set token as not mintable and not redeemable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, false);

        // Set treasury manager
        vm.prank(owner);
        esETHContract.setTreasuryManager(treasuryManager);

        // Fund treasury manager
        vm.deal(treasuryManager, MINT_AMOUNT);
        vm.prank(treasuryManager);
        weth.deposit{value: MINT_AMOUNT}();

        vm.startPrank(treasuryManager);
        weth.approve(address(esETHContract), type(uint256).max);

        // Regular user should fail
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(esETH.TokenNotWhitelistedForMint.selector, address(weth)));
        esETHContract.mint(address(weth), 1, user1);

        // Treasury manager should succeed even with isMintable=false
        vm.startPrank(treasuryManager);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT, treasuryManager);
        assertGt(esETHAmount, 0, "INV-ESETH-005: treasuryManager should bypass isMintable flag");

        // Treasury manager should succeed with redeem even with isRedeemable=false
        esETHContract.redeem(address(weth), MINT_AMOUNT / 2, treasuryManager);
        assertLt(
            esETHContract.balanceOf(treasuryManager),
            esETHAmount,
            "INV-ESETH-005: treasuryManager should bypass isRedeemable flag"
        );

        vm.stopPrank();
    }

    /**
     * @notice INV-ESETH-006: Token Config Preservation
     * @dev Verifies that setTokenConfig preserves totalMinted
     */
    function test_Invariant_ESETH006_TokenConfigPreservation() external {
        // Mint to establish totalMinted
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT, user1);

        // Get initial totalMinted
        (,,, uint256 totalMintedBefore) = esETHContract.tokenConfigs(address(weth));
        assertGt(totalMintedBefore, 0, "Should have minted some esETH");

        // Update config (change flags)
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, false);

        // Verify totalMinted preserved
        (esETH.TokenType tokenType, bool isMintable, bool isRedeemable, uint256 totalMintedAfter) =
            esETHContract.tokenConfigs(address(weth));
        assertEq(totalMintedAfter, totalMintedBefore, "INV-ESETH-006: setTokenConfig must preserve totalMinted");
        assertEq(uint256(tokenType), uint256(esETH.TokenType.ERC20), "Token type should be updated");
        assertEq(isMintable, false, "isMintable should be updated");
        assertEq(isRedeemable, false, "isRedeemable should be updated");

        // Update config again (change token type)
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);

        // Verify totalMinted still preserved
        (,,, uint256 totalMintedFinal) = esETHContract.tokenConfigs(address(weth));
        assertEq(
            totalMintedFinal,
            totalMintedBefore,
            "INV-ESETH-006: totalMinted must remain unchanged after multiple config updates"
        );
    }

    function test_MintAndRedeem_ERC4626_WETHUnderlying() external {
        ERC4626Mock vault = new ERC4626Mock(address(weth));
        vm.prank(owner);
        esETHContract.setTokenConfig(address(vault), esETH.TokenType.ERC4626, true, true);

        vm.startPrank(user1);
        uint256 dep = 500e18;
        weth.approve(address(vault), dep);
        IERC4626(address(vault)).deposit(dep, user1);
        uint256 shares = IERC20(address(vault)).balanceOf(user1);
        uint256 expected = IERC4626(address(vault)).convertToAssets(shares);
        IERC20(address(vault)).approve(address(esETHContract), shares);
        uint256 minted = esETHContract.mint(address(vault), shares, user1);
        assertEq(minted, expected);

        uint256 redeemShares = shares / 2;
        uint256 burnExpected = IERC4626(address(vault)).convertToAssets(redeemShares) + 1;
        uint256 burned = esETHContract.redeem(address(vault), redeemShares, user1);
        assertEq(burned, burnExpected);
        vm.stopPrank();
    }

    /**
     * @notice Helper function to check total supply invariant
     */
    function _checkTotalSupplyInvariant() internal view {
        (,,, uint256 totalMintedWeth) = esETHContract.tokenConfigs(address(weth));
        (,,, uint256 totalMintedWeETH) = esETHContract.tokenConfigs(address(weETH));
        uint256 sumTotalMinted = totalMintedWeth + totalMintedWeETH;
        uint256 totalSupply = esETHContract.totalSupply();

        // With +1 wei rounding protection on redeem, totalSupply can be slightly less than sumTotalMinted
        // Allow up to N wei difference where N is a reasonable number of redemptions
        assertLe(
            sumTotalMinted > totalSupply ? sumTotalMinted - totalSupply : 0,
            1000, // Allow up to 1000 wei difference (1000 redemptions)
            "INV-ESETH-002: totalSupply must be close to sum of all tokenConfigs[t].totalMinted"
        );
    }
}
