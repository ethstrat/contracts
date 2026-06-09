// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";
import {SeaportOrderLib} from "./lib/SeaportOrderLib.sol";

contract SeaportRageQuitTest is Test {
    using SeaportOrderLib for ISeaportMinimal;

    uint256 internal constant MAINNET_FORK_BLOCK = 25_282_546;

    address internal constant STRAT = 0x14cF922aa1512Adfc34409b63e18D391e4a86A2f;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;

    ISeaportMinimal internal constant seaport = ISeaportMinimal(SEAPORT);

    address internal treasury;
    uint256 internal treasuryPk;
    address internal rageQuitter = makeAddr("rageQuitter");

    uint256 internal constant TOTAL_WETH_OFFER = 3_000 ether;

    // Example rage-quit terms. Replace with the real STRAT/USDC ask.
    uint256 internal constant TOTAL_STRAT_ASK = 10_000_000 ether;
    uint256 internal constant TOTAL_USDC_ASK = 600_000e6;

    bytes32 internal constant NO_CONDUIT = bytes32(0);

    struct UiOrderMetrics {
        bytes32 orderHash;
        bool isValidated;
        bool isCancelled;
        uint256 totalFilled;
        uint256 totalSize;
        uint256 filledWeth;
        uint256 remainingWeth;
        uint256 remainingStrat;
        uint256 remainingUsdc;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);

        (treasury, treasuryPk) = makeAddrAndKey("treasury");

        deal(WETH, treasury, TOTAL_WETH_OFFER);

        _treasuryApproveWethOffer();
    }

    function testRageQuitPartialFillOnePercent() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        uint256 expectedWethOut = _scaleAmount(TOTAL_WETH_OFFER, fillNumerator, fillDenominator);
        uint256 expectedStratIn = _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator);
        uint256 expectedUsdcIn = _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator);

        _fundAndApproveRageQuitter(expectedStratIn, expectedUsdcIn);
        _assertSeaportVersion();

        // Treasury defines the fixed offer terms and signs them.
        ISeaportMinimal.OrderParameters memory params = _treasuryCreateOrderParameters();
        bytes memory signature = _treasurySignOrder(params);

        // The rage quitter chooses how much of the treasury order to fill.
        // Treasury does not choose this numerator/denominator.
        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _rageQuitterCreateAdvancedOrder(params, signature, fillNumerator, fillDenominator);

        uint256 treasuryWethBefore = IERC20(WETH).balanceOf(treasury);
        uint256 treasuryStratBefore = IERC20(STRAT).balanceOf(treasury);
        uint256 treasuryUsdcBefore = IERC20(USDC).balanceOf(treasury);

        uint256 userWethBefore = IERC20(WETH).balanceOf(rageQuitter);
        uint256 userStratBefore = IERC20(STRAT).balanceOf(rageQuitter);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(rageQuitter);

        bool fulfilled = _rageQuitterFulfill(advancedOrder);

        assertTrue(fulfilled, "order not fulfilled");

        assertEq(IERC20(WETH).balanceOf(treasury), treasuryWethBefore - expectedWethOut, "treasury WETH");
        assertEq(IERC20(STRAT).balanceOf(treasury), treasuryStratBefore + expectedStratIn, "treasury STRAT");
        assertEq(IERC20(USDC).balanceOf(treasury), treasuryUsdcBefore + expectedUsdcIn, "treasury USDC");

        assertEq(IERC20(WETH).balanceOf(rageQuitter), userWethBefore + expectedWethOut, "user WETH");
        assertEq(IERC20(STRAT).balanceOf(rageQuitter), userStratBefore - expectedStratIn, "user STRAT");
        assertEq(IERC20(USDC).balanceOf(rageQuitter), userUsdcBefore - expectedUsdcIn, "user USDC");
    }

    function testUiMetricsBeforeAndAfterPartialFill() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        uint256 expectedWethOut = _scaleAmount(TOTAL_WETH_OFFER, fillNumerator, fillDenominator);
        uint256 expectedStratIn = _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator);
        uint256 expectedUsdcIn = _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator);

        _fundAndApproveRageQuitter(expectedStratIn, expectedUsdcIn);

        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _buildRageQuitterAdvancedOrder(fillNumerator, fillDenominator);

        UiOrderMetrics memory beforeFill = _getUiOrderMetrics(advancedOrder.parameters);

        // Before the first fill, Seaport reports an untouched order as 0/0.
        // For UI purposes, treat that as 0 filled and the full order remaining.
        assertEq(beforeFill.totalFilled, 0, "before totalFilled");
        assertEq(beforeFill.totalSize, 0, "before totalSize");
        assertEq(beforeFill.filledWeth, 0, "before filled WETH");
        assertEq(beforeFill.remainingWeth, TOTAL_WETH_OFFER, "before remaining WETH");
        assertEq(beforeFill.remainingStrat, TOTAL_STRAT_ASK, "before remaining STRAT");
        assertEq(beforeFill.remainingUsdc, TOTAL_USDC_ASK, "before remaining USDC");
        assertFalse(beforeFill.isCancelled, "before cancelled");

        bool fulfilled = _rageQuitterFulfill(advancedOrder);
        assertTrue(fulfilled, "order not fulfilled");

        UiOrderMetrics memory afterFill = _getUiOrderMetrics(advancedOrder.parameters);

        assertEq(afterFill.totalFilled, fillNumerator, "after totalFilled");
        assertEq(afterFill.totalSize, fillDenominator, "after totalSize");

        assertEq(afterFill.filledWeth, expectedWethOut, "after filled WETH");
        assertEq(afterFill.remainingWeth, TOTAL_WETH_OFFER - expectedWethOut, "after remaining WETH");
        assertEq(afterFill.remainingStrat, TOTAL_STRAT_ASK - expectedStratIn, "after remaining STRAT");
        assertEq(afterFill.remainingUsdc, TOTAL_USDC_ASK - expectedUsdcIn, "after remaining USDC");

        assertFalse(afterFill.isCancelled, "after cancelled");
    }

    function testCannotFillAfterSeaportCancel() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        _fundAndApproveRageQuitter(
            _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator),
            _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator)
        );

        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _buildRageQuitterAdvancedOrder(fillNumerator, fillDenominator);

        ISeaportMinimal.OrderComponents[] memory orders = new ISeaportMinimal.OrderComponents[](1);
        orders[0] = seaport.toOrderComponents(advancedOrder.parameters);

        bytes32 orderHash = seaport.getOrderHash(orders[0]);

        vm.prank(treasury);
        bool cancelled = seaport.cancel(orders);

        assertTrue(cancelled, "cancel failed");

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) = seaport.getOrderStatus(orderHash);

        assertFalse(isValidated, "order should not be validated");
        assertTrue(isCancelled, "order should be cancelled");
        assertEq(totalFilled, 0, "totalFilled");
        assertEq(totalSize, 0, "totalSize");

        vm.expectRevert(abi.encodeWithSelector(ISeaportMinimal.OrderIsCancelled.selector, orderHash));

        _rageQuitterFulfill(advancedOrder);
    }

    function testCannotFillAfterCounterIncrement() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        _fundAndApproveRageQuitter(
            _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator),
            _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator)
        );

        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _buildRageQuitterAdvancedOrder(fillNumerator, fillDenominator);

        uint256 counterBefore = seaport.getCounter(treasury);

        vm.prank(treasury);
        uint256 counterAfter = seaport.incrementCounter();

        assertNotEq(counterAfter, counterBefore, "counter did not change");
        assertEq(seaport.getCounter(treasury), counterAfter, "stored counter");

        vm.expectRevert();
        _rageQuitterFulfill(advancedOrder);
    }

    function testCannotFillAfterTreasuryRevokesWethAllowance() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        _fundAndApproveRageQuitter(
            _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator),
            _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator)
        );

        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _buildRageQuitterAdvancedOrder(fillNumerator, fillDenominator);

        vm.prank(treasury);
        IERC20(WETH).approve(SEAPORT, 0);

        assertEq(IERC20(WETH).allowance(treasury, SEAPORT), 0, "treasury WETH allowance");

        vm.expectRevert();
        _rageQuitterFulfill(advancedOrder);
    }

    function testCannotFillAfterTreasuryMovesWethAway() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        _fundAndApproveRageQuitter(
            _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator),
            _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator)
        );

        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _buildRageQuitterAdvancedOrder(fillNumerator, fillDenominator);

        address coldWallet = makeAddr("coldWallet");

        vm.prank(treasury);
        IERC20(WETH).transfer(coldWallet, TOTAL_WETH_OFFER);

        assertEq(IERC20(WETH).balanceOf(treasury), 0, "treasury WETH balance");

        vm.expectRevert();
        _rageQuitterFulfill(advancedOrder);
    }

    function testCannotFillAfterExpiry() public {
        uint120 fillNumerator = 1;
        uint120 fillDenominator = 100;

        _fundAndApproveRageQuitter(
            _scaleAmount(TOTAL_STRAT_ASK, fillNumerator, fillDenominator),
            _scaleAmount(TOTAL_USDC_ASK, fillNumerator, fillDenominator)
        );

        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _buildRageQuitterAdvancedOrder(fillNumerator, fillDenominator);

        vm.warp(advancedOrder.parameters.endTime + 1);

        vm.expectRevert();
        _rageQuitterFulfill(advancedOrder);
    }

    // -------------------------------------------------------------------------
    // Treasury actions
    // -------------------------------------------------------------------------

    function _treasuryApproveWethOffer() internal {
        vm.prank(treasury);
        IERC20(WETH).approve(SEAPORT, TOTAL_WETH_OFFER);
    }

    function _treasuryCreateOrderParameters() internal view returns (ISeaportMinimal.OrderParameters memory) {
        ISeaportMinimal.OfferItem[] memory offer = new ISeaportMinimal.OfferItem[](1);

        offer[0] = ISeaportMinimal.OfferItem({
            itemType: ISeaportMinimal.ItemType.ERC20,
            token: WETH,
            identifierOrCriteria: 0,
            startAmount: TOTAL_WETH_OFFER,
            endAmount: TOTAL_WETH_OFFER
        });

        ISeaportMinimal.ConsiderationItem[] memory consideration = new ISeaportMinimal.ConsiderationItem[](2);

        consideration[0] = ISeaportMinimal.ConsiderationItem({
            itemType: ISeaportMinimal.ItemType.ERC20,
            token: STRAT,
            identifierOrCriteria: 0,
            startAmount: TOTAL_STRAT_ASK,
            endAmount: TOTAL_STRAT_ASK,
            recipient: payable(treasury)
        });

        consideration[1] = ISeaportMinimal.ConsiderationItem({
            itemType: ISeaportMinimal.ItemType.ERC20,
            token: USDC,
            identifierOrCriteria: 0,
            startAmount: TOTAL_USDC_ASK,
            endAmount: TOTAL_USDC_ASK,
            recipient: payable(treasury)
        });

        return ISeaportMinimal.OrderParameters({
            offerer: treasury,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: ISeaportMinimal.OrderType.PARTIAL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 7 days,
            zoneHash: bytes32(0),
            salt: uint256(keccak256("STRAT_RAGE_QUIT_EXAMPLE_ORDER")),
            conduitKey: NO_CONDUIT,
            totalOriginalConsiderationItems: consideration.length
        });
    }

    function _treasurySignOrder(ISeaportMinimal.OrderParameters memory params) internal view returns (bytes memory) {
        assertEq(params.offerer, treasury, "treasury must be offerer");

        bytes32 digest = seaport.getOrderDigest(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(treasuryPk, digest);

        return abi.encodePacked(r, s, v);
    }

    // -------------------------------------------------------------------------
    // Rage quitter actions
    // -------------------------------------------------------------------------

    function _fundAndApproveRageQuitter(uint256 stratAmount, uint256 usdcAmount) internal {
        deal(STRAT, rageQuitter, stratAmount);
        deal(USDC, rageQuitter, usdcAmount);

        vm.startPrank(rageQuitter);
        IERC20(STRAT).approve(SEAPORT, stratAmount);
        IERC20(USDC).approve(SEAPORT, usdcAmount);
        vm.stopPrank();
    }

    function _rageQuitterCreateAdvancedOrder(
        ISeaportMinimal.OrderParameters memory params,
        bytes memory signature,
        uint120 numerator,
        uint120 denominator
    ) internal pure returns (ISeaportMinimal.AdvancedOrder memory) {
        return ISeaportMinimal.AdvancedOrder({
            parameters: params, numerator: numerator, denominator: denominator, signature: signature, extraData: ""
        });
    }

    function _rageQuitterFulfill(ISeaportMinimal.AdvancedOrder memory advancedOrder) internal returns (bool) {
        ISeaportMinimal.CriteriaResolver[] memory criteriaResolvers = new ISeaportMinimal.CriteriaResolver[](0);

        vm.prank(rageQuitter);
        return seaport.fulfillAdvancedOrder(advancedOrder, criteriaResolvers, NO_CONDUIT, address(0));
    }

    // -------------------------------------------------------------------------
    // Shared helpers
    // -------------------------------------------------------------------------

    function _buildRageQuitterAdvancedOrder(uint120 numerator, uint120 denominator)
        internal
        view
        returns (ISeaportMinimal.AdvancedOrder memory)
    {
        ISeaportMinimal.OrderParameters memory params = _treasuryCreateOrderParameters();

        bytes memory signature = _treasurySignOrder(params);

        return _rageQuitterCreateAdvancedOrder(params, signature, numerator, denominator);
    }

    function _getUiOrderMetrics(ISeaportMinimal.OrderParameters memory params)
        internal
        view
        returns (UiOrderMetrics memory metrics)
    {
        ISeaportMinimal.OrderComponents memory components = seaport.toOrderComponents(params);

        bytes32 orderHash = seaport.getOrderHash(components);

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) = seaport.getOrderStatus(orderHash);

        uint256 filledWeth = _scaleByFillFraction(TOTAL_WETH_OFFER, totalFilled, totalSize);
        uint256 filledStrat = _scaleByFillFraction(TOTAL_STRAT_ASK, totalFilled, totalSize);
        uint256 filledUsdc = _scaleByFillFraction(TOTAL_USDC_ASK, totalFilled, totalSize);

        metrics = UiOrderMetrics({
            orderHash: orderHash,
            isValidated: isValidated,
            isCancelled: isCancelled,
            totalFilled: totalFilled,
            totalSize: totalSize,
            filledWeth: filledWeth,
            remainingWeth: TOTAL_WETH_OFFER - filledWeth,
            remainingStrat: TOTAL_STRAT_ASK - filledStrat,
            remainingUsdc: TOTAL_USDC_ASK - filledUsdc
        });
    }

    function _scaleAmount(uint256 amount, uint120 numerator, uint120 denominator) internal pure returns (uint256) {
        return amount * numerator / denominator;
    }

    function _scaleByFillFraction(uint256 amount, uint256 totalFilled, uint256 totalSize)
        internal
        pure
        returns (uint256)
    {
        // Seaport reports an untouched order as 0/0.
        if (totalSize == 0) {
            return 0;
        }

        return amount * totalFilled / totalSize;
    }

    function _assertSeaportVersion() internal view {
        (string memory version,,) = seaport.information();
        assertEq(version, "1.6", "unexpected Seaport version");
    }
}
