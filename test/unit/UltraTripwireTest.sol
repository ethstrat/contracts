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
import {MockWETH} from "../mocks/MockWETH.sol";
import {Pause} from "../../script/deployments/robinhood/009-ultra-tripwire/Pause.s.sol";
import {Unpause} from "../../script/deployments/robinhood/009-ultra-tripwire/Unpause.s.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";

contract UltraTripwireTest is Test {
    TripwireController internal ctrl;
    UltraToken internal ultra;
    UltraPresaleToken internal receipt;
    UltraPresale internal presale;
    Pause internal pauseScript;
    Unpause internal unpauseScript;

    address internal safe = address(0x5AFE);

    function setUp() external {
        vm.warp(1_000_000);
        vm.etch(safe, hex"00");
        ctrl = new TripwireController();
        ultra = new UltraToken(safe, ITripwireController(address(ctrl)), safe);
        receipt = new UltraPresaleToken(safe, ITripwireController(address(ctrl)), safe);
        presale = new UltraPresale(
            IERC20MintableBurnable(address(receipt)),
            IERC20(address(new MockWETH())),
            safe,
            block.timestamp,
            block.timestamp + 7 days,
            100 ether,
            ITripwireController(address(ctrl)),
            safe
        );
        pauseScript = new Pause();
        unpauseScript = new Unpause();
    }

    function _targets() internal view returns (address[3] memory) {
        return [address(ultra), address(receipt), address(presale)];
    }

    function testPauseTripsAllThree() external {
        address[3] memory targets = _targets();
        SafeBatchLib.Tx[] memory txs = pauseScript.build(safe, ctrl, targets);
        pauseScript.simulate(safe, ctrl, targets, txs);
        assertTrue(ctrl.isGloballyTripped(address(ultra)));
        assertTrue(ctrl.isGloballyTripped(address(receipt)));
        assertTrue(ctrl.isGloballyTripped(address(presale)));
    }

    function testUnpauseResetsAllThree() external {
        address[3] memory targets = _targets();
        SafeBatchLib.Tx[] memory pauseTxs = pauseScript.build(safe, ctrl, targets);
        pauseScript.simulate(safe, ctrl, targets, pauseTxs);

        SafeBatchLib.Tx[] memory unpauseTxs = unpauseScript.build(safe, ctrl, targets);
        unpauseScript.simulate(safe, ctrl, targets, unpauseTxs);
        assertFalse(ctrl.isGloballyTripped(address(ultra)));
        assertFalse(ctrl.isGloballyTripped(address(receipt)));
        assertFalse(ctrl.isGloballyTripped(address(presale)));
    }

    function testPauseRejectsMismatchedGuardian() external {
        UltraToken wrongGuardian = new UltraToken(address(this), ITripwireController(address(ctrl)), address(this));
        address[3] memory targets = [address(wrongGuardian), address(receipt), address(presale)];
        vm.expectRevert("Pause: guardian mismatch");
        pauseScript.build(safe, ctrl, targets);
    }

    function testUnpauseRejectsMismatchedGuardian() external {
        UltraToken wrongGuardian = new UltraToken(address(this), ITripwireController(address(ctrl)), address(this));
        address[3] memory targets = [address(wrongGuardian), address(receipt), address(presale)];
        vm.expectRevert("Unpause: guardian mismatch");
        unpauseScript.build(safe, ctrl, targets);
    }

    function testPauseRejectsDuplicateTarget() external {
        address[3] memory targets = [address(ultra), address(ultra), address(presale)];
        vm.expectRevert("Pause: duplicate target");
        pauseScript.build(safe, ctrl, targets);
    }

    function testUnpauseRejectsDuplicateTarget() external {
        address[3] memory targets = [address(ultra), address(receipt), address(receipt)];
        vm.expectRevert("Unpause: duplicate target");
        unpauseScript.build(safe, ctrl, targets);
    }
}
