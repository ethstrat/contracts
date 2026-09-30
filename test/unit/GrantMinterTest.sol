// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UltraPresaleToken} from "../../src/UltraPresaleToken.sol";
import {UltraPresale} from "../../src/UltraPresale.sol";
import {IERC20MintableBurnable} from "../../src/interfaces/IERC20.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {GrantMinter} from "../../script/deployments/robinhood/008-ultra-presale/GrantMinter.s.sol";
import {SafeBatchLib} from "../../script/deployments/1/lib/SafeBatchLib.sol";

contract GrantMinterTest is Test {
    UltraPresaleToken internal receipt;
    UltraPresale internal presale;
    TripwireController internal ctrl;
    MockWETH internal weth;
    GrantMinter internal script_;

    address internal safe = address(0x5AFE);

    uint256 internal constant START = 1_000_000;
    uint256 internal constant END = START + 7 days;
    uint256 internal constant CAP = 100 ether;

    function setUp() external {
        vm.warp(START - 1 days);
        vm.etch(safe, hex"00");
        ctrl = new TripwireController();
        weth = new MockWETH();
        receipt = new UltraPresaleToken(safe, ITripwireController(address(ctrl)), safe);
        presale = new UltraPresale(
            IERC20MintableBurnable(address(receipt)),
            IERC20(address(weth)),
            safe,
            START,
            END,
            CAP,
            ITripwireController(address(ctrl)),
            safe
        );
        script_ = new GrantMinter();
    }

    function _params() internal view returns (GrantMinter.Params memory) {
        return GrantMinter.Params({safe: safe, receipt: receipt, presale: presale});
    }

    function testGrantsMinter() external {
        assertFalse(receipt.minters(address(presale)));
        SafeBatchLib.Tx[] memory txs = script_.build(_params());
        script_.simulate(_params(), txs);
        assertTrue(receipt.minters(address(presale)));
    }

    function testRejectsIfAlreadyGranted() external {
        SafeBatchLib.Tx[] memory txs = script_.build(_params());
        script_.simulate(_params(), txs);
        vm.expectRevert("GrantMinter: collector already a minter");
        script_.build(_params());
    }

    function testRejectsAfterPresaleStart() external {
        vm.warp(START);
        vm.expectRevert("GrantMinter: presale already started");
        script_.build(_params());
    }

    function testRejectsMismatchedPair() external {
        UltraPresaleToken otherReceipt = new UltraPresaleToken(safe, ITripwireController(address(ctrl)), safe);
        vm.expectRevert("GrantMinter: presale/receipt mismatch");
        script_.build(GrantMinter.Params({safe: safe, receipt: otherReceipt, presale: presale}));
    }

    function testRejectsIfPresaleSafeIsNotOwner() external {
        address otherSafe = address(0xBAD5AFE);
        vm.etch(otherSafe, hex"00");
        UltraPresale otherPresale = new UltraPresale(
            IERC20MintableBurnable(address(receipt)),
            IERC20(address(weth)),
            otherSafe,
            START,
            END,
            CAP,
            ITripwireController(address(ctrl)),
            safe
        );
        vm.expectRevert("GrantMinter: presale.safe != OWNER");
        script_.build(GrantMinter.Params({safe: safe, receipt: receipt, presale: otherPresale}));
    }

    function testRejectsIfOwnerHasNoCode() external {
        vm.expectRevert("GrantMinter: OWNER has no code");
        script_.build(GrantMinter.Params({safe: address(0xD00D), receipt: receipt, presale: presale}));
    }

    function testRejectsIfSafeDoesNotOwnReceipt() external {
        address otherOwner = address(0xC0DE);
        vm.etch(otherOwner, hex"00");
        UltraPresaleToken otherReceipt = new UltraPresaleToken(otherOwner, ITripwireController(address(ctrl)), safe);
        vm.expectRevert("GrantMinter: Safe does not own receipt");
        script_.build(GrantMinter.Params({safe: safe, receipt: otherReceipt, presale: presale}));
    }
}
