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

// Mock conversion contract for tokens like rETH
contract MockConversionContract {
    // For testing, we'll use a simple multiplier
    uint256 public constant RETH_MULTIPLIER = 1.1e18; // 1 rETH = 1.1 ETH
    address public rETHAddress;

    constructor(address _rETHAddress) {
        rETHAddress = _rETHAddress;
    }

    function convertToETH(address token, uint256 amount) external view returns (uint256) {
        // For rETH, multiply by 1.1
        if (token == rETHAddress) {
            return amount * RETH_MULTIPLIER / 1e18;
        }
        return amount;
    }

    function convertFromETH(address token, uint256 ethValue) external view returns (uint256) {
        // For rETH, divide by 1.1
        if (token == rETHAddress) {
            return ethValue * 1e18 / RETH_MULTIPLIER;
        }
        return ethValue;
    }
}

// Wrapper for MockERC20 to add mint function
contract MintableMockERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract esETHTest is Test {
    esETH public esETHContract;
    MintableMockERC20 public weth;
    MintableMockERC20 public reth;
    MockERC4626Vault public stETH;
    MockERC4626Vault public cbETH;
    MockConversionContract public conversionContract;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant MINT_AMOUNT = 1000 * 1e18;

    function setUp() public {
        // Deploy mock tokens
        weth = new MintableMockERC20();
        weth.initialize("Wrapped Ether", "WETH", 18);
        weth.mint(address(this), INITIAL_BALANCE);
        weth.mint(user1, INITIAL_BALANCE);
        weth.mint(user2, INITIAL_BALANCE);

        reth = new MintableMockERC20();
        reth.initialize("Rocket Pool ETH", "rETH", 18);
        reth.mint(address(this), INITIAL_BALANCE);
        reth.mint(user1, INITIAL_BALANCE);
        reth.mint(user2, INITIAL_BALANCE);

        // Deploy ERC4626 vaults
        MintableMockERC20 underlyingStETH = new MintableMockERC20();
        underlyingStETH.initialize("stETH", "stETH", 18);
        underlyingStETH.mint(address(this), INITIAL_BALANCE);
        underlyingStETH.mint(user1, INITIAL_BALANCE);
        underlyingStETH.mint(user2, INITIAL_BALANCE);

        stETH = new MockERC4626Vault(address(underlyingStETH));
        underlyingStETH.approve(address(stETH), type(uint256).max);
        stETH.deposit(INITIAL_BALANCE, address(this));
        underlyingStETH.transfer(user1, INITIAL_BALANCE);
        underlyingStETH.transfer(user2, INITIAL_BALANCE);
        vm.prank(user1);
        underlyingStETH.approve(address(stETH), type(uint256).max);
        vm.prank(user2);
        underlyingStETH.approve(address(stETH), type(uint256).max);

        MintableMockERC20 underlyingCbETH = new MintableMockERC20();
        underlyingCbETH.initialize("cbETH", "cbETH", 18);
        underlyingCbETH.mint(address(this), INITIAL_BALANCE);
        underlyingCbETH.mint(user1, INITIAL_BALANCE);
        underlyingCbETH.mint(user2, INITIAL_BALANCE);

        cbETH = new MockERC4626Vault(address(underlyingCbETH));
        underlyingCbETH.approve(address(cbETH), type(uint256).max);
        cbETH.deposit(INITIAL_BALANCE, address(this));
        underlyingCbETH.transfer(user1, INITIAL_BALANCE);
        underlyingCbETH.transfer(user2, INITIAL_BALANCE);
        vm.prank(user1);
        underlyingCbETH.approve(address(cbETH), type(uint256).max);
        vm.prank(user2);
        underlyingCbETH.approve(address(cbETH), type(uint256).max);

        // Deploy conversion contract
        conversionContract = new MockConversionContract(address(reth));

        // Deploy esETH contract
        vm.prank(owner);
        esETHContract = new esETH(owner);

        // Configure tokens
        vm.startPrank(owner);
        // WETH: non-ERC4626, 1:1 with ETH, mintable and redeemable
        esETHContract.setTokenConfig(address(weth), false, address(0), true, true);
        // rETH: non-ERC4626, uses conversion contract, mintable and redeemable
        esETHContract.setTokenConfig(address(reth), false, address(conversionContract), true, true);
        // stETH: ERC4626, mintable and redeemable
        esETHContract.setTokenConfig(address(stETH), true, address(0), true, true);
        // cbETH: ERC4626, mintable and redeemable
        esETHContract.setTokenConfig(address(cbETH), true, address(0), true, true);
        vm.stopPrank();

        // Approve esETH contract to spend tokens
        weth.approve(address(esETHContract), type(uint256).max);
        reth.approve(address(esETHContract), type(uint256).max);
        stETH.approve(address(esETHContract), type(uint256).max);
        cbETH.approve(address(esETHContract), type(uint256).max);
    }

    // ============ Constructor Tests ============

    function test_Constructor() external view {
        assertEq(esETHContract.owner(), owner);
        assertEq(esETHContract.name(), "ETH Strategy ETH");
        assertEq(esETHContract.symbol(), "esETH");
        assertEq(esETHContract.decimals(), 18);
        assertEq(esETHContract.totalSupply(), 0);
    }

    // ============ Token Configuration Tests ============

    function test_SetTokenConfig() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.prank(owner);
        esETHContract.setTokenConfig(address(newToken), false, address(0), true, true);

        (bool isERC4626, address convContract, bool isMintable, bool isRedeemable) =
            esETHContract.tokenConfigs(address(newToken));
        assertEq(isERC4626, false);
        assertEq(convContract, address(0));
        assertEq(isMintable, true);
        assertEq(isRedeemable, true);
    }

    function test_SetTokenConfig_OnlyOwner() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);

        vm.prank(user1);
        vm.expectRevert();
        esETHContract.setTokenConfig(address(newToken), false, address(0), true, true);
    }

    function test_TokenListLength() external view {
        assertEq(esETHContract.tokenListLength(), 4);
    }

    // ============ Mint Tests ============

    function test_Mint_WithWETH() external {
        uint256 amount = MINT_AMOUNT;
        uint256 balanceBefore = esETHContract.balanceOf(user1);
        uint256 wethBalanceBefore = weth.balanceOf(address(esETHContract));

        vm.prank(user1);
        weth.approve(address(esETHContract), amount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), amount);

        assertEq(esETHAmount, amount); // 1:1 for WETH
        assertEq(esETHContract.balanceOf(user1), balanceBefore + esETHAmount);
        assertEq(weth.balanceOf(address(esETHContract)), wethBalanceBefore + amount);
        assertEq(esETHContract.totalSupply(), esETHAmount);
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
    }

    function test_Mint_WithConversionContract() external {
        uint256 amount = MINT_AMOUNT;
        uint256 balanceBefore = esETHContract.balanceOf(user1);

        vm.prank(user1);
        reth.approve(address(esETHContract), amount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(reth), amount);

        // rETH should use conversion contract: amount * 1.1
        uint256 expectedETH = amount * 110 / 100; // 1.1 multiplier
        assertEq(esETHAmount, expectedETH);
        assertEq(esETHContract.balanceOf(user1), balanceBefore + esETHAmount);
    }

    function test_Mint_NotWhitelisted() external {
        MintableMockERC20 newToken = new MintableMockERC20();
        newToken.initialize("New Token", "NEW", 18);
        newToken.mint(user1, MINT_AMOUNT);

        vm.prank(user1);
        newToken.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        vm.expectRevert(esETH.TokenNotWhitelistedForMint.selector);
        esETHContract.mint(address(newToken), MINT_AMOUNT);
    }

    function test_Mint_ZeroAmount() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.mint(address(weth), 0);
    }

    // ============ Redeem Tests ============

    function test_Redeem_ForWETH() external {
        // First mint some esETH
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        weth.approve(address(esETHContract), mintAmount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), mintAmount);

        // Now redeem
        uint256 wethBalanceBefore = weth.balanceOf(user1);
        vm.prank(user1);
        uint256 tokenAmount = esETHContract.redeem(address(weth), esETHAmount);

        assertEq(tokenAmount, esETHAmount); // 1:1 for WETH
        assertEq(weth.balanceOf(user1), wethBalanceBefore + tokenAmount);
        assertEq(esETHContract.balanceOf(user1), 0);
        assertEq(esETHContract.totalSupply(), 0);
    }

    function test_Redeem_ForERC4626() external {
        // First mint some esETH with stETH
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        stETH.approve(address(esETHContract), mintAmount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(stETH), mintAmount);

        // Now redeem for stETH
        uint256 stETHBalanceBefore = stETH.balanceOf(user1);
        vm.prank(user1);
        uint256 tokenAmount = esETHContract.redeem(address(stETH), esETHAmount);

        // Should get back shares equivalent to the ETH value
        uint256 expectedShares = stETH.convertToShares(esETHAmount);
        assertEq(tokenAmount, expectedShares);
        assertEq(stETH.balanceOf(user1), stETHBalanceBefore + tokenAmount);
    }

    function test_Redeem_ForConversionContract() external {
        // First mint some esETH with rETH
        uint256 mintAmount = MINT_AMOUNT;
        vm.prank(user1);
        reth.approve(address(esETHContract), mintAmount);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(reth), mintAmount);

        // Now redeem for rETH
        uint256 rethBalanceBefore = reth.balanceOf(user1);
        vm.prank(user1);
        uint256 tokenAmount = esETHContract.redeem(address(reth), esETHAmount);

        // Should get back rETH using conversion: ethValue / 1.1
        uint256 expectedRETH = esETHAmount * 100 / 110;
        assertApproxEqRel(tokenAmount, expectedRETH, 0.01e18); // Allow small rounding
        assertEq(reth.balanceOf(user1), rethBalanceBefore + tokenAmount);
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
        vm.expectRevert(esETH.TokenNotWhitelistedForRedeem.selector);
        esETHContract.redeem(address(newToken), esETHAmount);
    }

    function test_Redeem_InsufficientBalance() external {
        // Mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        uint256 esETHAmount = esETHContract.mint(address(weth), MINT_AMOUNT);

        // Try to redeem more than contract has
        vm.prank(user1);
        vm.expectRevert(esETH.InsufficientBalance.selector);
        esETHContract.redeem(address(weth), esETHAmount + 1);
    }

    function test_Redeem_ZeroAmount() external {
        vm.prank(user1);
        vm.expectRevert(esETH.ZeroAmount.selector);
        esETHContract.redeem(address(weth), 0);
    }

    // ============ Total Backing Tests ============

    function test_TotalBacking_Empty() external view {
        uint256 backing = esETHContract.totalBacking();
        assertEq(backing, 0);
    }

    function test_TotalBacking_WithTokens() external {
        // Mint esETH with different tokens
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        vm.prank(user2);
        stETH.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user2);
        esETHContract.mint(address(stETH), MINT_AMOUNT);

        uint256 backing = esETHContract.totalBacking();
        uint256 expectedWETH = MINT_AMOUNT;
        uint256 expectedStETH = stETH.convertToAssets(MINT_AMOUNT);
        assertEq(backing, expectedWETH + expectedStETH);
    }

    // ============ Mint Deficit Tests ============

    function test_MintDeficit() external {
        // Mint some esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Manually add more tokens to contract (simulating yield or donations)
        weth.transfer(address(esETHContract), MINT_AMOUNT);

        uint256 backingBefore = esETHContract.totalBacking();
        uint256 supplyBefore = esETHContract.totalSupply();
        uint256 deficit = backingBefore - supplyBefore;

        vm.prank(owner);
        esETHContract.mintDeficit();

        uint256 supplyAfter = esETHContract.totalSupply();

        assertEq(supplyAfter, supplyBefore + deficit);
        assertEq(esETHContract.balanceOf(owner), deficit);
    }

    function test_MintDeficit_NoDeficit() external {
        // Mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        vm.prank(owner);
        vm.expectRevert(esETH.InsufficientBacking.selector);
        esETHContract.mintDeficit();
    }

    function test_MintDeficit_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert();
        esETHContract.mintDeficit();
    }

    // ============ Convert LST Tests ============

    function test_ConvertLST_NoLoss() external {
        // Setup: mint esETH and have tokens in contract
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Transfer some esETH to contract for potential loss coverage
        vm.prank(user1);
        esETHContract.transfer(address(esETHContract), MINT_AMOUNT / 10);

        uint256 fromAmount = MINT_AMOUNT / 2;
        
        // Get balance before (should have weth from mint)
        uint256 wethBalanceBefore = weth.balanceOf(address(esETHContract));
        assertGe(wethBalanceBefore, fromAmount);

        uint256 toBalanceBefore = cbETH.balanceOf(address(esETHContract));
        
        // Simulate swap: owner swaps weth for cbETH externally and sends cbETH to contract
        // In real scenario, owner would do this via DEX, but for test we simulate
        cbETH.transfer(address(esETHContract), fromAmount); // 1:1 swap, no loss
        uint256 toBalanceAfter = cbETH.balanceOf(address(esETHContract));
        uint256 toAmount = toBalanceAfter - toBalanceBefore;

        vm.prank(owner);
        (uint256 receivedAmount, uint256 loss) = esETHContract.convertLST(
            address(weth), address(cbETH), fromAmount, toAmount
        );

        assertEq(receivedAmount, toAmount);
        assertEq(loss, 0);
    }

    function test_ConvertLST_WithLoss() external {
        // Setup: mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Transfer esETH to contract for loss coverage
        vm.prank(user1);
        esETHContract.transfer(address(esETHContract), MINT_AMOUNT);

        uint256 fromAmount = MINT_AMOUNT;
        
        // Get balance before
        uint256 toBalanceBefore = cbETH.balanceOf(address(esETHContract));
        
        // Simulate swap with loss: receive 90% of value
        uint256 toAmount = MINT_AMOUNT * 9 / 10;
        cbETH.transfer(address(esETHContract), toAmount);
        uint256 toBalanceAfter = cbETH.balanceOf(address(esETHContract));

        uint256 esETHBalanceBefore = esETHContract.balanceOf(address(esETHContract));

        vm.prank(owner);
        (uint256 receivedAmount, uint256 loss) = esETHContract.convertLST(
            address(weth), address(cbETH), fromAmount, toAmount
        );

        uint256 esETHBalanceAfter = esETHContract.balanceOf(address(esETHContract));

        assertEq(receivedAmount, toBalanceAfter - toBalanceBefore);
        assertGt(loss, 0);
        assertEq(esETHBalanceBefore - esETHBalanceAfter, loss);
    }

    function test_ConvertLST_InsufficientESETHForLoss() external {
        // Setup: mint esETH
        vm.prank(user1);
        weth.approve(address(esETHContract), MINT_AMOUNT);
        vm.prank(user1);
        esETHContract.mint(address(weth), MINT_AMOUNT);

        // Don't transfer esETH to contract (contract has 0 esETH balance)
        uint256 fromAmount = MINT_AMOUNT;
        uint256 toAmount = MINT_AMOUNT * 9 / 10; // 10% loss

        // Simulate swap: send toToken to contract
        cbETH.transfer(address(esETHContract), toAmount);

        vm.prank(owner);
        vm.expectRevert();
        esETHContract.convertLST(address(weth), address(cbETH), fromAmount, toAmount);
    }

    function test_ConvertLST_OnlyOwner() external {
        vm.prank(user1);
        vm.expectRevert();
        esETHContract.convertLST(address(weth), address(cbETH), 100, 100);
    }

    // ============ Get ETH Value Tests ============

    function test_GetETHValue_WETH() external view {
        uint256 value = esETHContract.getETHValue(address(weth), MINT_AMOUNT);
        assertEq(value, MINT_AMOUNT);
    }

    function test_GetETHValue_ERC4626() external view {
        uint256 value = esETHContract.getETHValue(address(stETH), MINT_AMOUNT);
        uint256 expected = stETH.convertToAssets(MINT_AMOUNT);
        assertEq(value, expected);
    }

    function test_GetETHValue_ConversionContract() external view {
        uint256 value = esETHContract.getETHValue(address(reth), MINT_AMOUNT);
        uint256 expected = MINT_AMOUNT * 110 / 100; // 1.1 multiplier
        assertEq(value, expected);
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

        // User1 redeems for cbETH
        vm.prank(user1);
        esETHContract.redeem(address(cbETH), esETH1);

        // User2 redeems for WETH
        vm.prank(user2);
        esETHContract.redeem(address(weth), esETH2);

        // Check balances
        assertEq(esETHContract.balanceOf(user1), 0);
        assertEq(esETHContract.balanceOf(user2), 0);
        assertGt(cbETH.balanceOf(user1), 0);
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
}
