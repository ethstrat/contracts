// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {UltraToken} from "../../src/UltraToken.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {Deploy} from "../../script/deployments/robinhood/006-ultra-token/Deploy.s.sol";

contract UltraTokenTest is Test {
    UltraToken internal token;
    TripwireController internal ctrl;

    address internal multisig = address(0x123);
    address internal minter = address(0x456);
    address internal user = address(0x789);

    function setUp() external {
        ctrl = new TripwireController();
        token = new UltraToken(multisig, ITripwireController(address(ctrl)), multisig);
    }

    function testInitialState() external view {
        assertEq(token.name(), "UltraETH");
        assertEq(token.symbol(), "ULTRA");
        assertEq(token.decimals(), 18);
        assertEq(token.owner(), multisig);
        assertEq(token.totalSupply(), 0);
        assertEq(ctrl.guardian(address(token)), multisig);
    }

    function testOnlyOwnerManagesMinters() external {
        vm.prank(user);
        vm.expectRevert();
        token.manageMinter(minter, true);

        vm.prank(multisig);
        token.manageMinter(minter, true);
        assertTrue(token.minters(minter));
    }

    function testMintAndBurn() external {
        vm.prank(multisig);
        token.manageMinter(minter, true);

        vm.prank(user);
        vm.expectRevert();
        token.mint(user, 1);

        vm.prank(minter);
        token.mint(user, 100);
        vm.prank(user);
        token.burn(40);
        assertEq(token.balanceOf(user), 60);
    }

    function testDeployScriptFreshController() external {
        vm.etch(multisig, hex"00");
        new Deploy().deploy(multisig, address(0), block.chainid);
    }

    function testDeployScriptExistingController() external {
        vm.etch(multisig, hex"00");
        new Deploy().deploy(multisig, address(ctrl), block.chainid);
    }
}
