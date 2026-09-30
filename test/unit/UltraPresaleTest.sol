// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UltraPresaleToken} from "../../src/UltraPresaleToken.sol";
import {UltraPresale} from "../../src/UltraPresale.sol";
import {MintableBurnableToken} from "../../src/MintableBurnableToken.sol";
import {IERC20MintableBurnable} from "../../src/interfaces/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {ITripwireGuard} from "../../src/interfaces/ITripwireGuard.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {Deploy} from "../../script/deployments/robinhood/008-ultra-presale/Deploy.s.sol";

contract RejectEth {}

contract UltraPresaleTest is Test {
    UltraPresaleToken internal receipt;
    UltraPresale internal presale;
    TripwireController internal ctrl;
    MockWETH internal weth;

    address internal multisig = address(0x123);
    address internal user = address(0x789);
    address internal other = address(0xabc);

    uint256 internal constant START = 1_000_000;
    uint256 internal constant END = START + 7 days;
    uint256 internal constant CAP = 100 ether;

    function setUp() external {
        vm.warp(START - 1 days);
        ctrl = new TripwireController();
        weth = new MockWETH();
        receipt = new UltraPresaleToken(multisig, ITripwireController(address(ctrl)), multisig);
        presale = _newPresale(address(receipt), multisig, START, END, CAP);
        vm.prank(multisig);
        receipt.manageMinter(address(presale), true);
        vm.deal(user, 1000 ether);
    }

    function _newPresale(address receipt_, address safe_, uint256 start_, uint256 end_, uint256 cap_)
        internal
        returns (UltraPresale)
    {
        return new UltraPresale(
            IERC20MintableBurnable(receipt_),
            IERC20(address(weth)),
            safe_,
            start_,
            end_,
            cap_,
            ITripwireController(address(ctrl)),
            multisig
        );
    }

    function testInitialState() external view {
        assertEq(receipt.name(), "UltraETH Presale");
        assertEq(receipt.symbol(), "pULTRA");
        assertEq(receipt.owner(), multisig);
        assertEq(ctrl.guardian(address(receipt)), multisig);
        assertEq(ctrl.guardian(address(presale)), multisig);
        assertEq(address(presale.receipt()), address(receipt));
        assertEq(presale.safe(), multisig);
        assertEq(presale.remaining(), CAP);
    }

    function testConstructorRejects() external {
        vm.expectRevert(UltraPresale.ZeroAddress.selector);
        _newPresale(address(0), multisig, START, END, CAP);
        vm.expectRevert(UltraPresale.ZeroAddress.selector);
        _newPresale(address(receipt), address(0), START, END, CAP);
        vm.expectRevert(UltraPresale.InvalidWindow.selector);
        _newPresale(address(receipt), multisig, END, START, CAP);
        vm.expectRevert(UltraPresale.InvalidWindow.selector);
        _newPresale(address(receipt), multisig, 0, block.timestamp, CAP);
        vm.expectRevert(UltraPresale.InvalidCap.selector);
        _newPresale(address(receipt), multisig, START, END, 0);
    }

    function testDepositEth() external {
        vm.warp(START);
        vm.prank(user);
        presale.deposit{value: 3 ether}(other);

        assertEq(receipt.balanceOf(other), 3 ether);
        assertEq(multisig.balance, 3 ether);
        assertEq(address(presale).balance, 0);
        assertEq(presale.totalDeposited(), 3 ether);
    }

    function testDepositWeth() external {
        vm.warp(START);
        vm.startPrank(user);
        weth.deposit{value: 5 ether}();
        weth.approve(address(presale), 5 ether);
        presale.depositWeth(user, 5 ether);
        vm.stopPrank();

        assertEq(receipt.balanceOf(user), 5 ether);
        assertEq(weth.balanceOf(multisig), 5 ether);
        assertEq(weth.balanceOf(address(presale)), 0);
        assertEq(presale.totalDeposited(), 5 ether);
    }

    function testDepositWethEmitsTransferBeforeDeposit() external {
        vm.warp(START);
        vm.startPrank(user);
        weth.deposit{value: 5 ether}();
        weth.approve(address(presale), 5 ether);

        vm.recordLogs();
        presale.depositWeth(user, 5 ether);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 transferIndex = -1;
        int256 depositIndex = -1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(weth) && logs[i].topics[0] == IERC20.Transfer.selector) {
                transferIndex = int256(i);
            }
            if (logs[i].emitter == address(presale) && logs[i].topics[0] == UltraPresale.Deposit.selector) {
                depositIndex = int256(i);
            }
        }
        assertGe(transferIndex, 0, "WETH Transfer log not found");
        assertGe(depositIndex, 0, "Deposit log not found");
        assertLt(transferIndex, depositIndex, "Transfer must be recorded before Deposit");
    }

    function testEthAndWethShareCap() external {
        vm.warp(START);
        vm.startPrank(user);
        presale.deposit{value: 60 ether}(user);
        weth.deposit{value: 50 ether}();
        weth.approve(address(presale), 50 ether);
        vm.expectRevert(abi.encodeWithSelector(UltraPresale.CapExceeded.selector, 40 ether));
        presale.depositWeth(user, 50 ether);
        presale.depositWeth(user, 40 ether);
        vm.stopPrank();

        assertEq(presale.remaining(), 0);
        assertEq(receipt.totalSupply(), CAP);
    }

    function testWindow() external {
        vm.prank(user);
        vm.expectRevert(UltraPresale.NotOpen.selector);
        presale.deposit{value: 1 ether}(user);

        vm.warp(END);
        vm.prank(user);
        vm.expectRevert(UltraPresale.NotOpen.selector);
        presale.deposit{value: 1 ether}(user);

        vm.warp(END - 1);
        vm.prank(user);
        presale.deposit{value: 1 ether}(user);
        assertEq(receipt.balanceOf(user), 1 ether);
    }

    function testRejectsZero() external {
        vm.warp(START);
        vm.startPrank(user);
        vm.expectRevert(UltraPresale.ZeroAmount.selector);
        presale.deposit{value: 0}(user);
        vm.expectRevert(UltraPresale.ZeroAmount.selector);
        presale.depositWeth(user, 0);
        vm.expectRevert(UltraPresale.ZeroAddress.selector);
        presale.deposit{value: 1 ether}(address(0));
        vm.stopPrank();
    }

    function testRequiresMinterGrant() external {
        UltraPresale ungranted = _newPresale(address(receipt), multisig, START, END, CAP);
        vm.warp(START);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MintableBurnableToken.MinterUnauthorizedAccount.selector, address(ungranted))
        );
        ungranted.deposit{value: 1 ether}(user);
    }

    function testRevertsIfSafeRejectsEth() external {
        address rejecter = address(new RejectEth());
        UltraPresale p = _newPresale(address(receipt), rejecter, START, END, CAP);
        vm.prank(multisig);
        receipt.manageMinter(address(p), true);
        vm.warp(START);
        vm.prank(user);
        vm.expectRevert(UltraPresale.EthTransferFailed.selector);
        p.deposit{value: 1 ether}(user);
    }

    function testTripwirePauses() external {
        vm.warp(START);
        vm.prank(multisig);
        ctrl.tripGlobal(address(presale));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ITripwireGuard.Tripped.selector, UltraPresale.deposit.selector));
        presale.deposit{value: 1 ether}(user);
    }

    function testFuzzDeposit(uint256 amount) external {
        amount = bound(amount, 1, CAP);
        vm.warp(START);
        vm.prank(user);
        presale.deposit{value: amount}(user);
        assertEq(receipt.balanceOf(user), amount);
        assertEq(multisig.balance, amount);
    }

    function testDeployScript() external {
        vm.etch(multisig, hex"00");
        (UltraPresaleToken r, UltraPresale p) = new Deploy()
            .deploy(
                Deploy.Params({
                    owner: multisig, controller: address(ctrl), weth: address(weth), start: START, end: END, cap: CAP
                }),
                block.chainid
            );
        assertEq(address(p.receipt()), address(r));
        assertEq(p.cap(), CAP);
    }
}
