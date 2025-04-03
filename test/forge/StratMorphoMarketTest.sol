// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import "../../src/MorphoMarket/StratMorphoMarket.sol";
import "../../src/StratToken.sol";

import {IMorpho, MarketParams, Id, Position, Market} from "morpho-blue/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "morpho-blue/src/libraries/SharesMathLib.sol";

import {IOracle} from "morpho-blue/src/interfaces/IOracle.sol";
import {IIrm} from "morpho-blue/src/interfaces/IIrm.sol";

// Fixed price oracle (for testing purposes)
contract FixedPriceOracle is IOracle {
    uint256 private _price;

    constructor(uint256 initialPrice) {
        _price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function price() external view override returns (uint256) {
        return _price;
    }
}

contract StratMorphoMarketTest is Test {
    IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint256 constant LLTV = 0.98 ether; // 98% loan-to-value ratio

    address owner;
    address user;
    address borrower;

    StratMorphoMarket market;
    StratToken stratToken;
    FixedPriceOracle oracle;
    MarketParams marketParams;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"), 22187898);
        vm.selectFork(forkId);

        // Initialize addresses
        owner = makeAddr("owner");
        user = makeAddr("user");
        borrower = makeAddr("borrower");

        stratToken = new StratToken(owner);
        vm.prank(owner);
        stratToken.manageMinter(address(this), true);

        // Deploy the Strat proxy
        market = new StratMorphoMarket(address(morpho), address(stratToken), address(this), owner);

        // Deploy FixedPriceOracle
        oracle = new FixedPriceOracle(1e36); // Set initial price to 1

        // Create a Morpho market for strat/eth
        marketParams = MarketParams(address(weth), address(market), address(oracle), address(0x0), LLTV);

        morpho.createMarket(MarketParams(address(weth), address(market), address(oracle), address(0x0), LLTV));

        // Initialize market parameters in our StratMorphoMarket wrapper
        vm.prank(owner);
        market.initializeMarketParams(address(weth), address(oracle), address(0x0), LLTV);
    }

    function testOnlyOwnerCanInitializeMarketParams() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        market.initializeMarketParams(address(weth), address(oracle), address(0x0), LLTV);

        vm.prank(owner);
        market.initializeMarketParams(address(0x1), address(oracle), address(0x0), LLTV);
        (address loanToken, address collateralToken, address oracleAddress, address irmAddress, uint256 lltv) =
            market.marketParams();
        assertEq(collateralToken, address(market), "Loan token address mismatch");
        assertEq(loanToken, address(0x1), "Loan token address mismatch");
        assertEq(oracleAddress, address(oracle), "Oracle address mismatch");
        assertEq(irmAddress, address(0x0), "IRM address mismatch");
        assertEq(lltv, LLTV, "LLTV mismatch");
    }

    // Test supplying collateral
    function testSupplyCollateral() public {
        uint256 amount = 100e18;

        // Mint tokens to user and approve
        stratToken.mint(user, amount);

        vm.startPrank(user);
        stratToken.approve(address(market), amount);
        market.supplyCollateral(amount, user, "");
        vm.stopPrank();

        // Verify token transfer, and the user's collateral balance in the market
        assertEq(stratToken.balanceOf(user), 0);
        assertEq(stratToken.balanceOf(address(market)), amount);
        assertEq(market.balanceOf(address(morpho)), amount);
        Position memory userPosition = morpho.position(market.marketId(), user);
        assertEq(userPosition.collateral, amount, "User collateral mismatch");
    }

    function testWithdrawFailsIfNotAuthorized() public {
        uint256 amount = 100e18;

        vm.startPrank(user);
        vm.expectRevert("unauthorized");
        market.withdrawCollateral(amount, user);
        vm.stopPrank();
    }

    function testWithdrawCollateral() public {
        uint256 amount = 100e18;

        // Setup: First supply collateral
        stratToken.mint(user, amount);

        vm.startPrank(user);
        stratToken.approve(address(market), amount);
        market.supplyCollateral(amount, user, "");
        assertEq(stratToken.balanceOf(user), 0);

        // Then withdraw it
        morpho.setAuthorization(address(market), true);
        market.withdrawCollateral(amount, user);
        vm.stopPrank();

        // Verify the user received tokens
        assertEq(stratToken.balanceOf(user), amount);
        assertEq(market.balanceOf(address(morpho)), 0);
    }

    function testOnlyUserCanWithdrawCollateral() public {
        uint256 amount = 100e18;

        // Setup: First supply collateral
        stratToken.mint(user, amount);

        vm.startPrank(user);
        stratToken.approve(address(market), amount);
        market.supplyCollateral(amount, user, "");
        assertEq(stratToken.balanceOf(user), 0);

        // Then withdraw it
        morpho.setAuthorization(address(market), true);
        vm.stopPrank();

        vm.expectRevert("unauthorized");
        market.withdrawCollateral(amount, user);
    }

    function testRevertsWhenUnauthorizedFlashLoanCaller() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedMorphoFlashLoanCaller(address)", unauthorized));
        market.onMorphoFlashLoan(100e18, "");
    }

    function testOwnerSupply() public {
        uint256 amount = 100e18;

        // Setup tokens
        vm.prank(address(morpho));
        weth.transfer(address(this), amount);
        weth.approve(address(market), amount);

        // Supply as owner
        vm.prank(owner);
        market.supply(amount);
        Market memory m = morpho.market(market.marketId());
        assertEq(m.totalSupplyAssets, amount);
    }

    function testRevertsWhenOwnerSuppliesZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ZeroAssets()"));
        market.supply(0);
    }

    function testRevertsWhenNonOwnerSupplies() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        market.supply(100e18);
    }

    function testOwnerWithdraw() public {
        uint256 amount = 100e18;
        uint256 startingBalance = weth.balanceOf(address(this));

        // Setup tokens
        vm.prank(address(morpho));
        weth.transfer(address(this), amount);
        weth.approve(address(market), amount);

        // Supply as owner
        vm.prank(owner);
        market.supply(amount);
        Market memory m = morpho.market(market.marketId());
        assertEq(m.totalSupplyAssets, amount);
        assertEq(weth.balanceOf(address(this)), startingBalance);

        // Withdraw as owner
        vm.prank(owner);
        market.withdraw(amount, 0);
        m = morpho.market(market.marketId());
        assertEq(m.totalSupplyAssets, 0);
        assertEq(weth.balanceOf(address(this)), startingBalance + amount);
    }

    function testRevertsWhenOwnerWithdrawsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ZeroAssets()"));
        market.withdraw(0, 0);
    }

    function testRevertsWhenNonOwnerWithdraws() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        market.withdraw(100e18, 0);
    }

    // Test liquidation process
    function testLiquidate() public {
        uint256 collateralAmount = 100e18;
        uint256 borrowAmount = 90e18;

        // Confirm we have no strat, as the liquidator
        uint256 initialStratBalance = stratToken.balanceOf(address(this));

        // Step 0: Setup - Supply weth
        vm.prank(address(morpho));
        weth.transfer(address(this), borrowAmount * 2);
        weth.approve(address(market), borrowAmount * 2);
        vm.prank(owner);
        market.supply(borrowAmount * 2);

        // Step 1: Setup - Supply collateral
        stratToken.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        stratToken.approve(address(market), collateralAmount);
        market.supplyCollateral(collateralAmount, borrower, "");
        vm.stopPrank();

        // Step 2: Borrow assets directly on Morpho
        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Step 3: Update oracle price to trigger liquidation
        oracle.setPrice(0.91e36); // Drop price

        // Step 4: Perform liquidation
        market.liquidate(borrower);

        // Step 5: Verify liquidation results
        Position memory borrowerPosition = morpho.position(market.marketId(), borrower);
        assertEq(borrowerPosition.borrowShares, 0, "Borrower's borrow shares should be zero after liquidation");

        assertGt(
            stratToken.balanceOf(address(this)), initialStratBalance, "Liquidator should receive liquidation incentive"
        );

        uint256 marketBalance = stratToken.balanceOf(address(market));
        assertLt(marketBalance, collateralAmount, "Market should have less total collateral");
    }
}
