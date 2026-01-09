// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {esETH} from "../../src/esETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";

// Mock ERC4626 vault
contract MockERC4626Vault is ERC4626 {
    uint256 private _totalAssets;

    constructor(address underlying) ERC4626(IERC20(underlying)) ERC20("Mock Vault", "MV") {
        _totalAssets = 0;
    }

    function totalAssets() public view virtual override returns (uint256) {
        return _totalAssets;
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        _totalAssets += assets;
        return shares;
    }

    function setTotalAssets(uint256 assets) external {
        _totalAssets = assets;
    }

    // Override to update _totalAssets
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        super._deposit(caller, receiver, assets, shares);
        _totalAssets += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        super._withdraw(caller, receiver, owner, assets, shares);
        _totalAssets -= assets;
    }
}

// Wrapper for MockERC20 to add mint function
contract MintableMockERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock wstETH token (has stEthPerToken function)
contract MockWstETH is MintableMockERC20 {
    uint256 public stEthPerToken = 1e18; // 1:1 by default, can be changed to simulate rebasing

    constructor() {
        initialize("Wrapped stETH", "wstETH", 18);
    }

    function setStEthPerToken(uint256 rate) external {
        stEthPerToken = rate;
    }
}

// Mock rETH token (has getExchangeRate function)
contract MockRETH is MintableMockERC20 {
    uint256 public exchangeRate = 1e18; // 1:1 by default, can be changed

    constructor() {
        initialize("Rocket Pool ETH", "rETH", 18);
    }

    function getExchangeRate() external view returns (uint256) {
        return exchangeRate;
    }

    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }
}

contract esETHTest is Test {
    esETH public esETHContract;
    MintableMockERC20 public weth;
    MockERC4626Vault public stETH;
    MockERC4626Vault public cbETH;
    MockWstETH public wstETH;
    MockRETH public rETH;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public harvestReceiver = address(0x4);
    address public randomUser = address(0x5);

    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant MINT_AMOUNT = 1000 * 1e18;

    function setUp() public {
        // Deploy mock tokens
        weth = new MintableMockERC20();
        weth.initialize("Wrapped Ether", "WETH", 18);
        weth.mint(address(this), INITIAL_BALANCE);
        weth.mint(user1, INITIAL_BALANCE);
        weth.mint(user2, INITIAL_BALANCE);

        // Deploy ERC4626 vaults
        MintableMockERC20 underlyingStETH = new MintableMockERC20();
        underlyingStETH.initialize("stETH", "stETH", 18);
        underlyingStETH.mint(address(this), INITIAL_BALANCE);
        underlyingStETH.mint(user1, INITIAL_BALANCE);
        underlyingStETH.mint(user2, INITIAL_BALANCE);

        stETH = new MockERC4626Vault(address(underlyingStETH));
        underlyingStETH.approve(address(stETH), type(uint256).max);
        stETH.deposit(INITIAL_BALANCE, address(this));
        // user1 and user2 need to deposit their underlying tokens to get vault shares
        vm.prank(user1);
        underlyingStETH.approve(address(stETH), type(uint256).max);
        vm.prank(user1);
        stETH.deposit(INITIAL_BALANCE, user1);
        vm.prank(user2);
        underlyingStETH.approve(address(stETH), type(uint256).max);
        vm.prank(user2);
        stETH.deposit(INITIAL_BALANCE, user2);

        MintableMockERC20 underlyingCbETH = new MintableMockERC20();
        underlyingCbETH.initialize("cbETH", "cbETH", 18);
        underlyingCbETH.mint(address(this), INITIAL_BALANCE);
        underlyingCbETH.mint(user1, INITIAL_BALANCE);
        underlyingCbETH.mint(user2, INITIAL_BALANCE);

        cbETH = new MockERC4626Vault(address(underlyingCbETH));
        underlyingCbETH.approve(address(cbETH), type(uint256).max);
        cbETH.deposit(INITIAL_BALANCE, address(this));
        // user1 and user2 need to deposit their underlying tokens to get vault shares
        vm.prank(user1);
        underlyingCbETH.approve(address(cbETH), type(uint256).max);
        vm.prank(user1);
        cbETH.deposit(INITIAL_BALANCE, user1);
        vm.prank(user2);
        underlyingCbETH.approve(address(cbETH), type(uint256).max);
        vm.prank(user2);
        cbETH.deposit(INITIAL_BALANCE, user2);

        // Deploy wstETH and rETH
        wstETH = new MockWstETH();
        wstETH.mint(address(this), INITIAL_BALANCE);
        wstETH.mint(user1, INITIAL_BALANCE);
        wstETH.mint(user2, INITIAL_BALANCE);

        rETH = new MockRETH();
        rETH.mint(address(this), INITIAL_BALANCE);
        rETH.mint(user1, INITIAL_BALANCE);
        rETH.mint(user2, INITIAL_BALANCE);

        // Deploy esETH contract
        vm.prank(owner);
        esETHContract = new esETH(owner);

        // Configure tokens
        vm.startPrank(owner);
        // WETH: ERC20 type, 1:1 with ETH, mintable and redeemable
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);
        // stETH: ERC4626, mintable and redeemable
        esETHContract.setTokenConfig(address(stETH), esETH.TokenType.ERC4626, true, true);
        // cbETH: ERC4626, mintable and redeemable
        esETHContract.setTokenConfig(address(cbETH), esETH.TokenType.ERC4626, true, true);
        // wstETH: WSTETH type, mintable and redeemable
        esETHContract.setTokenConfig(address(wstETH), esETH.TokenType.WSTETH, true, true);
        // rETH: RETH type, mintable and redeemable
        esETHContract.setTokenConfig(address(rETH), esETH.TokenType.RETH, true, true);
        vm.stopPrank();

        // Approve esETH contract to spend tokens
        weth.approve(address(esETHContract), type(uint256).max);
        stETH.approve(address(esETHContract), type(uint256).max);
        cbETH.approve(address(esETHContract), type(uint256).max);
        wstETH.approve(address(esETHContract), type(uint256).max);
        rETH.approve(address(esETHContract), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_Constructor() external view {
        assertEq(esETHContract.owner(), owner);
        assertEq(esETHContract.name(), "ETH Strategy ETH");
        assertEq(esETHContract.symbol(), "esETH");
        assertEq(esETHContract.decimals(), 18);
        assertEq(esETHContract.totalSupply(), 0);
        // harvestReceiver should be initialized to owner
        assertEq(esETHContract.harvestReceiver(), owner);
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
        vm.expectRevert();
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
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

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

    // ============ Mint Tests ============

    function test_Mint_WithERC20() external {
        uint256 amount = MINT_AMOUNT;
        uint256 balanceBefore = esETHContract.balanceOf(user1);
        uint256 wethBalanceBefore = weth.balanceOf(address(esETHContract));

        vm.prank(user1);
        weth.approve(address(esETHContract), amount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), amount);

        assertEq(esETHAmount, amount); // 1:1 for ERC20
        assertEq(esETHContract.balanceOf(user1), balanceBefore + esETHAmount);
        assertEq(weth.balanceOf(address(esETHContract)), wethBalanceBefore + amount);
        assertEq(esETHContract.totalSupply(), esETHAmount);

        // Check totalMinted is updated
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMinted, esETHAmount);
    }

    function test_Mint_WithERC4626() external {
        uint256 amount = MINT_AMOUNT;
        uint256 balanceBefore = esETHContract.balanceOf(user1);

        vm.prank(user1);
        stETH.approve(address(esETHContract), amount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(stETH), amount);

        // For ERC4626, convertToAssets should return the underlying asset value
        uint256 expectedETH = stETH.convertToAssets(amount);
        assertEq(esETHAmount, expectedETH);
        assertEq(esETHContract.balanceOf(user1), balanceBefore + esETHAmount);

        // Check totalMinted is updated
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(stETH));
        assertEq(totalMinted, esETHAmount);
    }

    function test_Mint_WithWstETH() external {
        uint256 amount = MINT_AMOUNT;
        // Set exchange rate: 1 wstETH = 1.1 stETH
        wstETH.setStEthPerToken(1.1e18);

        vm.prank(user1);
        wstETH.approve(address(esETHContract), amount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(wstETH), amount);

        // Should convert using stEthPerToken
        uint256 expectedETH = amount * 1.1e18 / 1e18;
        assertEq(esETHAmount, expectedETH);
        assertEq(esETHContract.balanceOf(user1), esETHAmount);
    }

    function test_Mint_WithRETH() external {
        uint256 amount = MINT_AMOUNT;
        // Set exchange rate: 1 rETH = 1.05 ETH
        rETH.setExchangeRate(1.05e18);

        vm.prank(user1);
        rETH.approve(address(esETHContract), amount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(rETH), amount);

        // Should convert using getExchangeRate
        uint256 expectedETH = amount * 1.05e18 / 1e18;
        assertEq(esETHAmount, expectedETH);
        assertEq(esETHContract.balanceOf(user1), esETHAmount);
    }

    function test_Mint_AnyoneCanMint() external {
        // Verify that non-owner users can mint
        vm.prank(randomUser);
        weth.mint(randomUser, MINT_AMOUNT);
        vm.prank(randomUser);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(randomUser);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        assertEq(esETHAmount, MINT_AMOUNT);
        assertEq(esETHContract.balanceOf(randomUser), MINT_AMOUNT);
    }

    function test_Mint_NotWhitelisted() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);
        newToken.mint(user1, MINT_AMOUNT);

        vm.prank(user1);
        newToken.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.TokenNotWhitelistedForMint.selector, address(newToken))
        );
        esETHContract.mint(address(newToken), MINT_AMOUNT);
    }

    function test_Mint_NotMintable() external {
        // Set token as not mintable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, false, true);

        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.TokenNotWhitelistedForMint.selector, address(weth))
        );
        esETHContract.mint(address(weth), MINT_AMOUNT);
    }

    function test_Mint_ZeroAmount() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.mint(address(weth), 0);
    }

    // ============ Redeem Tests ============

    function test_Redeem_ForERC20() external {
        // First mint some esETH
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        weth.approve(address(esETHContract), mintAmount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), mintAmount);

        // Now redeem
        uint256 wethBalanceBefore = weth.balanceOf(user1);
        uint256 esETHBalanceBefore = esETHContract.balanceOf(user1);
        vm.prank(user1);
        uint256 tokenAmount = esETHContract.redeem(address(weth), esETHAmount);

        assertEq(tokenAmount, esETHAmount); // 1:1 for ERC20
        assertEq(weth.balanceOf(user1), wethBalanceBefore + tokenAmount);
        assertEq(esETHContract.balanceOf(user1), esETHBalanceBefore - esETHAmount);
        assertEq(esETHContract.totalSupply(), 0);

        // Check totalMinted is updated
        (,,, uint256 totalMinted) = esETHContract.tokenConfigs(address(weth));
        assertEq(totalMinted, 0);
    }

    function test_Redeem_ForERC4626() external {
        // First mint some esETH with stETH
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        stETH.approve(address(esETHContract), mintAmount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(stETH), mintAmount);

        // Now redeem for stETH - redeem the exact shares that were deposited
        uint256 stETHBalanceBefore = stETH.balanceOf(user1);
        // Contract has mintAmount shares from our deposit, redeem those exact shares
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(stETH), mintAmount);

        // Should get back the shares we requested (mintAmount shares)
        assertEq(stETH.balanceOf(user1), stETHBalanceBefore + mintAmount);
        // esETHBurned should equal esETHAmount (the ETH value of mintAmount shares)
        assertEq(esETHBurned, esETHAmount);
    }

    function test_Redeem_AnyoneCanRedeem() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        // Random user can redeem if they have esETH
        vm.prank(user1);
        esETHContract.transfer(randomUser, esETHAmount);

        vm.prank(randomUser);
        uint256 tokenAmount = esETHContract.redeem(address(weth), esETHAmount);

        assertEq(tokenAmount, esETHAmount);
        assertEq(weth.balanceOf(randomUser), tokenAmount);
    }

    function test_Redeem_NotWhitelisted() external {
        // First mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, address(newToken))
        );
        esETHContract.redeem(address(newToken), esETHAmount);
    }

    function test_Redeem_NotRedeemable() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        // Set token as not redeemable
        vm.prank(owner);
        esETHContract.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, false);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.TokenNotWhitelistedForRedeem.selector, address(weth))
        );
        esETHContract.redeem(address(weth), esETHAmount);
    }

    function test_Redeem_InsufficientBalance() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        // Try to redeem more than contract has
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(esETH.InsufficientBalance.selector, address(weth))
        );
        esETHContract.redeem(address(weth), esETHAmount + 1);
    }

    function test_Redeem_ZeroAmount() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.redeem(address(weth), 0);
    }

    function test_Redeem_CrossToken() external {
        // User1 mints with WETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        // User2 mints with cbETH to ensure contract has cbETH for cross-token redemption
        vm.prank(user2);
        cbETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        esETHContract.mint(address(cbETH), MINT_AMOUNT);

        // User1 redeems for cbETH (different token) - contract has MINT_AMOUNT shares
        uint256 cbETHBalanceBefore = cbETH.balanceOf(user1);
        // Calculate shares needed based on esETHAmount, but limit to what's available
        uint256 cbETHShares = cbETH.convertToShares(esETHAmount);
        // Contract has MINT_AMOUNT shares, so we can redeem up to that
        uint256 sharesToRedeem = cbETHShares > MINT_AMOUNT ? MINT_AMOUNT : cbETHShares;
        vm.prank(user1);
        uint256 esETHBurned = esETHContract.redeem(address(cbETH), sharesToRedeem);

        assertGt(esETHBurned, 0);
        assertEq(cbETH.balanceOf(user1), cbETHBalanceBefore + sharesToRedeem);
    }

    // ============ Mint Deficit / Harvest Tests ============

    function test_MintDeficit_AnyoneCanCall() external {
        // Mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Manually add more tokens to contract (simulating yield or donations)
        weth.transfer(address(esETHContract), MINT_AMOUNT);

        uint256 supplyBefore = esETHContract.totalSupply();
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Random user can call mintDeficit
        vm.prank(randomUser);
        esETHContract.mintDeficit(tokens);

        uint256 supplyAfter = esETHContract.totalSupply();
        uint256 deficit = supplyAfter - supplyBefore;

        assertGt(deficit, 0);
        // Should mint to harvestReceiver (owner by default)
        assertEq(esETHContract.balanceOf(owner), deficit);
    }

    function test_MintDeficit_MintsToHarvestReceiver() external {
        // Set custom harvest receiver
        vm.prank(owner);
        esETHContract.setHarvestReceiver(harvestReceiver);

        // Mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Add more tokens
        weth.transfer(address(esETHContract), MINT_AMOUNT);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(user1);
        esETHContract.mintDeficit(tokens);

        // Should mint to harvestReceiver
        assertGt(esETHContract.balanceOf(harvestReceiver), 0);
    }

    function test_MintDeficit_NoDeficit() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.mintDeficit(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should not mint if no deficit
        assertEq(supplyAfter, supplyBefore);
    }

    function test_MintDeficit_MultipleTokens() external {
        // Mint esETH with WETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Mint esETH with stETH
        vm.prank(user2);
        stETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        esETHContract.mint(address(stETH), MINT_AMOUNT);

        // Add extra tokens to both
        weth.transfer(address(esETHContract), MINT_AMOUNT / 2);
        stETH.transfer(address(esETHContract), MINT_AMOUNT / 2);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(stETH);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.mintDeficit(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        assertGt(supplyAfter, supplyBefore);
    }

    function test_MintDeficit_WithERC4626Yield() external {
        // Mint esETH with stETH
        vm.prank(user1);
        stETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(stETH), MINT_AMOUNT);

        // Simulate yield by increasing totalAssets (which affects convertToAssets)
        stETH.setTotalAssets(stETH.totalAssets() + MINT_AMOUNT / 10);

        address[] memory tokens = new address[](1);
        tokens[0] = address(stETH);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.mintDeficit(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should mint deficit based on increased backing
        assertGt(supplyAfter, supplyBefore);
    }

    // ============ Burn Surplus Tests ============

    function test_BurnSurplus_AnyoneCanCall() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Remove some tokens (simulating loss) - transfer tokens out as contract
        vm.prank(address(esETHContract));
        weth.transfer(owner, MINT_AMOUNT / 2);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Anyone can call (per US-006: no strong reason to make this permissioned)
        // user1 already has enough esETH to burn the surplus
        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(user1);
        esETHContract.burnSurplus(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should burn surplus
        assertLt(supplyAfter, supplyBefore);
    }

    function test_BurnSurplus_NoSurplus() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256 supplyBefore = esETHContract.totalSupply();
        vm.prank(owner);
        esETHContract.burnSurplus(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should not burn if no surplus
        assertEq(supplyAfter, supplyBefore);
    }

    function test_BurnSurplus_OwnerMustHaveBalance() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

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
        esETHContract.burnSurplus(tokens);
        uint256 supplyAfter = esETHContract.totalSupply();

        // Should burn surplus from owner's balance
        assertLt(supplyAfter, supplyBefore);
    }

    // ============ Set Harvest Receiver Tests ============

    function test_SetHarvestReceiver() external {
        vm.prank(owner);
        esETHContract.setHarvestReceiver(harvestReceiver);

        assertEq(esETHContract.harvestReceiver(), harvestReceiver);
    }

    function test_SetHarvestReceiver_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert();
        esETHContract.setHarvestReceiver(harvestReceiver);
    }

    function test_SetHarvestReceiver_ZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(esETH.ZeroAddress.selector);
        esETHContract.setHarvestReceiver(address(0));
    }

    // ============ Get ETH Value Tests ============

    function test_GetETHValue_ERC20() external view {
        uint256 value = esETHContract.getETHValue(address(weth), MINT_AMOUNT);
        assertEq(value, MINT_AMOUNT);
    }

    function test_GetETHValue_ERC4626() external view {
        uint256 value = esETHContract.getETHValue(address(stETH), MINT_AMOUNT);
        uint256 expected = stETH.convertToAssets(MINT_AMOUNT);
        assertEq(value, expected);
    }

    function test_GetETHValue_WstETH() external {
        wstETH.setStEthPerToken(1.1e18);
        uint256 value = esETHContract.getETHValue(address(wstETH), MINT_AMOUNT);
        uint256 expected = MINT_AMOUNT * 1.1e18 / 1e18;
        assertEq(value, expected);
    }

    function test_GetETHValue_RETH() external {
        rETH.setExchangeRate(1.05e18);
        uint256 value = esETHContract.getETHValue(address(rETH), MINT_AMOUNT);
        uint256 expected = MINT_AMOUNT * 1.05e18 / 1e18;
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
        uint256 esETH1 = esETHContract.mint(address(weth), MINT_AMOUNT);

        // User2 mints with stETH
        vm.prank(user2);
        stETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        uint256 esETH2 = esETHContract.mint(address(stETH), MINT_AMOUNT);

        // Add cbETH to contract for cross-token redemption (simulate another user minting with cbETH)
        vm.prank(user2);
        cbETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        esETHContract.mint(address(cbETH), MINT_AMOUNT);

        // User1 redeems for cbETH - calculate shares and limit to available
        uint256 cbETHShares = cbETH.convertToShares(esETH1);
        uint256 sharesToRedeem = cbETHShares > MINT_AMOUNT ? MINT_AMOUNT : cbETHShares;
        vm.prank(user1);
        esETHContract.redeem(address(cbETH), sharesToRedeem);

        // User2 redeems for WETH - need to check contract has enough WETH
        // Contract has MINT_AMOUNT WETH from user1, so we can redeem up to that
        uint256 wethBalance = weth.balanceOf(address(esETHContract));
        uint256 wethToRedeem = esETH2 > wethBalance ? wethBalance : esETH2;
        vm.prank(user2);
        esETHContract.redeem(address(weth), wethToRedeem);

        // Check balances - user1 should have redeemed (may have tiny remainder due to rounding)
        assertLe(esETHContract.balanceOf(user1), 1); // Allow 1 wei rounding error
        assertGt(cbETH.balanceOf(user1), 0);
        // user2 may have remaining esETH if contract didn't have enough WETH, so just check they got some WETH
        assertGt(weth.balanceOf(user2), 0);
    }

    function test_Integration_MultipleUsers() external {
        uint256 amount = 100 * 1e18;

        // Multiple users mint
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(1000 + i));
            weth.mint(user, amount);
            vm.prank(user);
            weth.approve(address(esETHContract), amount);
            vm.prank(user);
            esETHContract.mint(address(weth), amount);
        }

        assertEq(esETHContract.totalSupply(), amount * 5);
        assertEq(weth.balanceOf(address(esETHContract)), amount * 5);
    }

    function test_Integration_FullCycle() external {
        // 1. Multiple users mint with different tokens
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETH1 = esETHContract.mint(address(weth), MINT_AMOUNT);

        vm.prank(user2);
        stETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        uint256 esETH2 = esETHContract.mint(address(stETH), MINT_AMOUNT);

        // 2. Yield accrues (simulated by adding tokens)
        weth.transfer(address(esETHContract), MINT_AMOUNT / 10);
        stETH.setTotalAssets(stETH.totalAssets() + MINT_AMOUNT / 10);

        // 3. Anyone can harvest
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(stETH);
        vm.prank(randomUser);
        esETHContract.mintDeficit(tokens);

        // 4. Users redeem
        vm.prank(user1);
        esETHContract.redeem(address(weth), esETH1);
        // Calculate shares needed for stETH redemption based on esETH2
        uint256 stETHShares = stETH.convertToShares(esETH2);
        vm.prank(user2);
        esETHContract.redeem(address(stETH), stETHShares);

        // 5. Owner can burn surplus if needed
        // (In this case there shouldn't be surplus, but test the flow)
        vm.prank(owner);
        esETHContract.burnSurplus(tokens);
    }
}
