// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UltraPresaleToken} from "../../src/UltraPresaleToken.sol";
import {UltraPresale} from "../../src/UltraPresale.sol";
import {IERC20MintableBurnable} from "../../src/interfaces/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {ITripwireGuard} from "../../src/interfaces/ITripwireGuard.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Safe that re-enters the collector when it receives ETH.
contract ReentrantSafe {
    UltraPresale public presale;
    uint256 public reentries;

    function set(UltraPresale p) external {
        presale = p;
    }

    receive() external payable {
        if (reentries < 3 && address(this).balance < 50 ether) {
            reentries++;
            presale.deposit{value: msg.value}(address(this));
        }
    }
}

contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

contract PresaleHandler is Test {
    UltraPresale internal presale;
    MockWETH internal weth;
    address[] internal actors;

    constructor(UltraPresale p, MockWETH w) {
        presale = p;
        weth = w;
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(0xA000 + i)));
        }
    }

    function depositEth(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 30 ether);
        vm.deal(a, amount);
        vm.prank(a);
        try presale.deposit{value: amount}(a) {} catch {}
    }

    function depositWeth(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 30 ether);
        vm.deal(a, amount);
        vm.startPrank(a);
        weth.deposit{value: amount}();
        weth.approve(address(presale), amount);
        try presale.depositWeth(a, amount) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }

    function forceEth(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        new ForceSend{value: amount}(payable(address(presale)));
    }
}

contract UltraPresaleAdversarialTest is Test {
    TripwireController internal ctrl;
    MockWETH internal weth;
    UltraPresaleToken internal receipt;
    UltraPresale internal presale;
    PresaleHandler internal handler;

    address internal safe = address(0x5AFE);
    uint256 internal constant CAP = 100 ether;
    uint256 internal forced;

    function setUp() external {
        vm.warp(1_000_000);
        ctrl = new TripwireController();
        weth = new MockWETH();
        receipt = new UltraPresaleToken(safe, ITripwireController(address(ctrl)), safe);
        presale = new UltraPresale(
            IERC20MintableBurnable(address(receipt)),
            IERC20(address(weth)),
            safe,
            block.timestamp,
            block.timestamp + 7 days,
            CAP,
            ITripwireController(address(ctrl)),
            safe
        );
        vm.prank(safe);
        receipt.manageMinter(address(presale), true);

        handler = new PresaleHandler(presale, weth);
        targetContract(address(handler));
    }

    /// Invariants 2, 3 and 5 (from the audit scope): supply == totalDeposited == value at the Safe, <= cap.
    function invariant_accounting() external view {
        assertEq(receipt.totalSupply(), presale.totalDeposited());
        assertEq(safe.balance + weth.balanceOf(safe), presale.totalDeposited());
        assertLe(presale.totalDeposited(), CAP);
    }

    /// Invariant 1: the collector never holds WETH, and holds ETH only if force-sent (never accounted).
    function invariant_noCustody() external view {
        assertEq(weth.balanceOf(address(presale)), 0);
        assertEq(receipt.balanceOf(address(presale)), 0);
    }

    function testReentrantSafeCannotBypassCap() external {
        ReentrantSafe rs = new ReentrantSafe();
        UltraPresaleToken r = new UltraPresaleToken(address(this), ITripwireController(address(ctrl)), address(this));
        UltraPresale p = new UltraPresale(
            IERC20MintableBurnable(address(r)),
            IERC20(address(weth)),
            address(rs),
            block.timestamp,
            block.timestamp + 1 days,
            10 ether,
            ITripwireController(address(ctrl)),
            address(this)
        );
        r.manageMinter(address(p), true);
        rs.set(p);

        vm.deal(address(this), 20 ether);
        // 3 re-entries of 4 ETH would reach 16 ETH > cap: the whole call reverts, nothing recorded
        vm.expectRevert(UltraPresale.EthTransferFailed.selector);
        p.deposit{value: 4 ether}(address(this));
        assertEq(p.totalDeposited(), 0);
        assertEq(r.totalSupply(), 0);

        // 2 ETH + 3 re-entries = 8 ETH <= cap: every nested deposit is accounted and backed
        p.deposit{value: 2 ether}(address(this));
        assertEq(p.totalDeposited(), 8 ether);
        assertEq(r.totalSupply(), 8 ether);
        assertEq(address(rs).balance, 2 ether, "Safe holds the ETH once; nested deposits re-used it");
    }

    function testForcedEthDoesNotAffectAccounting() external {
        vm.deal(address(this), 1 ether);
        new ForceSend{value: 1 ether}(payable(address(presale)));
        assertEq(address(presale).balance, 1 ether);
        assertEq(presale.totalDeposited(), 0);
        assertEq(presale.remaining(), CAP);
    }

    function testTrippingReceiptBlocksDepositsWithoutLoss() external {
        vm.prank(safe);
        ctrl.tripGlobal(address(receipt));
        address u = address(0xBEEF);
        vm.deal(u, 1 ether);
        vm.prank(u);
        vm.expectRevert(abi.encodeWithSelector(ITripwireGuard.Tripped.selector, IERC20MintableBurnable.mint.selector));
        presale.deposit{value: 1 ether}(u);
        assertEq(u.balance, 1 ether);
    }

    function testTrippingDoesNotFreezeReceiptTransfers() external {
        address u = address(0xBEEF);
        vm.deal(u, 1 ether);
        vm.prank(u);
        presale.deposit{value: 1 ether}(u);
        vm.prank(safe);
        ctrl.tripGlobal(address(receipt));
        vm.prank(u);
        receipt.transfer(address(0xCAFE), 1 ether);
        assertEq(receipt.balanceOf(address(0xCAFE)), 1 ether);
    }

    function testDirectEthSendReverts() external {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(presale).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
