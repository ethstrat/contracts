// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UltraToken} from "../../src/UltraToken.sol";
import {UltraPresaleToken} from "../../src/UltraPresaleToken.sol";
import {UltraPresale} from "../../src/UltraPresale.sol";
import {IERC20MintableBurnable} from "../../src/interfaces/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {ISeaportMinimal} from "../../script/deployments/1/003-espn-redemption/interfaces/ISeaportMinimal.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";
import {PresaleOrderBase} from "../../script/deployments/robinhood/008-ultra-presale/PresaleOrderBase.sol";
import {Close} from "../../script/deployments/robinhood/008-ultra-presale/Close.s.sol";
import {Finish} from "../../script/deployments/robinhood/008-ultra-presale/Finish.s.sol";

/// @notice Robinhood Chain fork: presale deposits -> Close batch -> real Seaport 1.6 fills -> Finish batch.
/// FOUNDRY_PROFILE=integration forge test --match-contract UltraPresaleCloseTest (ROBINHOOD_RPC optional).
contract UltraPresaleCloseTest is Test {
    ISeaportMinimal internal constant SEAPORT = ISeaportMinimal(0x0000000000000068F116a894984e2DB1123eB395);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    uint256 internal constant ULTRA_PER_RECEIPT = 16_237; // whole ULTRA per 1 ETH contributed

    error OrderIsCancelled(bytes32 orderHash);

    address internal safe = makeAddr("safe");
    address internal u1 = makeAddr("u1");
    address internal u2 = makeAddr("u2");
    address internal u3 = makeAddr("u3");

    TripwireController internal ctrl;
    UltraToken internal ultra;
    UltraPresaleToken internal receipt;
    UltraPresale internal presale;
    Close internal close;
    Finish internal finish;
    uint256 internal start;
    uint256 internal end;

    function setUp() external {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC", string("https://rpc.mainnet.chain.robinhood.com")));
        require(block.chainid == 4663, "not Robinhood Chain");
        vm.etch(safe, hex"00");

        ctrl = new TripwireController();
        ultra = new UltraToken(safe, ITripwireController(address(ctrl)), safe);
        receipt = new UltraPresaleToken(safe, ITripwireController(address(ctrl)), safe);
        start = block.timestamp + 1 hours;
        end = start + 3 days;
        presale = new UltraPresale(
            IERC20MintableBurnable(address(receipt)),
            IERC20(WETH),
            safe,
            start,
            end,
            1000 ether,
            ITripwireController(address(ctrl)),
            safe
        );
        vm.prank(safe);
        receipt.manageMinter(address(presale), true);
        close = new Close();
        finish = new Finish();

        vm.warp(start);
        vm.deal(u1, 10 ether);
        vm.deal(u2, 10 ether);
        deal(WETH, u3, 5 ether);
        vm.prank(u1);
        presale.deposit{value: 1.234567891234567891 ether}(u1);
        vm.prank(u2);
        presale.deposit{value: 0.3 ether}(u2);
        vm.startPrank(u3);
        IERC20(WETH).approve(address(presale), 2 ether);
        presale.depositWeth(u3, 2 ether);
        vm.stopPrank();
    }

    function _params(bool isConvert) internal view returns (Close.Params memory) {
        return Close.Params({
            safe: safe,
            presale: presale,
            isConvert: isConvert,
            ultra: isConvert ? address(ultra) : address(0),
            ultraPerReceipt: isConvert ? ULTRA_PER_RECEIPT : 0,
            startTime: end,
            endTime: end + 365 days,
            salt: "ultra-presale-test"
        });
    }

    function _fill(address holder, PresaleOrderBase.OrderSpec memory spec) internal {
        uint256 bal = receipt.balanceOf(holder);
        ISeaportMinimal.AdvancedOrder memory order = ISeaportMinimal.AdvancedOrder({
            parameters: _params(spec),
            numerator: uint120(bal),
            denominator: uint120(spec.receiptAmount),
            signature: "",
            extraData: ""
        });
        vm.startPrank(holder);
        receipt.approve(address(SEAPORT), bal);
        SEAPORT.fulfillAdvancedOrder(order, new ISeaportMinimal.CriteriaResolver[](0), bytes32(0), holder);
        vm.stopPrank();
    }

    /// @dev Mirrors PresaleOrderBase._orderParams via the same library call the scripts use.
    function _params(PresaleOrderBase.OrderSpec memory spec)
        internal
        returns (ISeaportMinimal.OrderParameters memory)
    {
        return new OrderParamsHarness().params(spec);
    }

    function testCloseRevertsWhileOpen() external {
        vm.expectRevert("Close: presale still open");
        close.build(_params(true));
    }

    function testConvertFlow() external {
        vm.warp(end);
        (SafeBatchLib.Tx[] memory txs, PresaleOrderBase.OrderSpec memory spec) = close.build(_params(true));
        bytes32 orderHash = close.simulate(spec, txs);

        assertEq(spec.receiptAmount, 3.534567891234567891 ether);
        assertEq(spec.offerAmount, ULTRA_PER_RECEIPT * spec.receiptAmount);
        assertFalse(receipt.minters(address(presale)), "collector minter not revoked");
        assertFalse(ultra.minters(safe), "Safe still ULTRA minter");

        // odd balance fills exactly: no InexactFraction, no dust left in the wallet
        _fill(u1, spec);
        assertEq(ultra.balanceOf(u1), ULTRA_PER_RECEIPT * 1.234567891234567891 ether);
        assertEq(receipt.balanceOf(u1), 0);
        _fill(u2, spec);
        assertEq(ultra.balanceOf(u2), ULTRA_PER_RECEIPT * 0.3 ether);

        // finish before u3 converts: cancel, revoke, burn collected pULTRA
        SafeBatchLib.Tx[] memory finishTxs = finish.build(spec, orderHash);
        finish.simulate(spec, finishTxs);
        assertEq(receipt.totalSupply(), 2 ether, "only u3's pULTRA should remain");
        assertEq(ultra.balanceOf(safe), ULTRA_PER_RECEIPT * 2 ether, "u3's ULTRA stays on the Safe");

        vm.expectRevert(abi.encodeWithSelector(OrderIsCancelled.selector, orderHash));
        this.fillExternal(u3, spec);
    }

    function testRefundFlow() external {
        vm.warp(end);
        vm.expectRevert("Close: Safe WETH < outstanding pULTRA; wrap first");
        close.build(_params(false));

        deal(WETH, safe, IERC20(WETH).balanceOf(safe) + 1.534567891234567891 ether); // ETH leg, wrapped
        (SafeBatchLib.Tx[] memory txs, PresaleOrderBase.OrderSpec memory spec) = close.build(_params(false));
        close.simulate(spec, txs);
        assertEq(spec.offerToken, WETH);
        assertEq(spec.offerAmount, spec.receiptAmount);

        uint256 before = IERC20(WETH).balanceOf(u1);
        _fill(u1, spec);
        assertEq(IERC20(WETH).balanceOf(u1) - before, 1.234567891234567891 ether);
        before = IERC20(WETH).balanceOf(u3);
        _fill(u3, spec);
        assertEq(IERC20(WETH).balanceOf(u3) - before, 2 ether);
    }

    function testFinishRejectsWrongHash() external {
        vm.warp(end);
        (SafeBatchLib.Tx[] memory txs, PresaleOrderBase.OrderSpec memory spec) = close.build(_params(true));
        close.simulate(spec, txs);
        vm.expectRevert("Finish: rebuilt order hash does not match EXPECTED_ORDER_HASH");
        finish.build(spec, bytes32(uint256(1)));
    }

    function fillExternal(address holder, PresaleOrderBase.OrderSpec memory spec) external {
        _fill(holder, spec);
    }
}

contract OrderParamsHarness is PresaleOrderBase {
    function params(OrderSpec memory spec) external pure returns (ISeaportMinimal.OrderParameters memory) {
        return _orderParams(spec);
    }
}
