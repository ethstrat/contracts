// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratOptionExercise.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";

contract StratOptionExerciseTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionExercise public optionExercise;

    address internal owner = address(0x123);
    address internal user = address(0x789);

    function setUp() public {
        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);
        optionExercise = new StratOptionExercise(address(cdtToken), address(stratToken), address(stratOption));

        // Enable minting
        cdtToken.manageMinter(owner, true);
        stratToken.manageMinter(owner, true);
        stratOption.manageMinter(owner, true);
        stratToken.manageMinter(address(optionExercise), true);

        // Mint some CDT and STRAT
        cdtToken.mint(user, 1000 ether);

        // Mint an option to user
        stratOption.mint(user, 100 ether, 900 ether, 0, block.timestamp + 3600, block.timestamp + 1800);

        vm.stopPrank();
    }

    function testExerciseSuccess() public {
        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);

        // Approve option transfer and CDT burn
        cdtToken.approve(address(optionExercise), 100 ether);
        stratOption.approve(address(optionExercise), 1);

        // Exercise
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 900 ether, "cdtToken should be burned");
        vm.stopPrank();
    }

    function testExerciseWithSufficientPremintedStrat() public {
        // mint more STRAT into the optionExercise contract than needed
        vm.prank(owner);
        stratToken.mint(address(optionExercise), 1000 ether);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);

        // Approve option transfer and CDT burn
        cdtToken.approve(address(optionExercise), 100 ether);
        stratOption.approve(address(optionExercise), 1);

        // Exercise
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 900 ether, "cdtToken should be burned");
        assertEq(stratToken.balanceOf(address(optionExercise)), 100 ether, "OptionExercise should have 100 STRAT left");
        assertEq(stratToken.totalSupply(), 1000 ether, "Total supply should be 10,000,000 STRAT");
        vm.stopPrank();
    }

    function testExerciseWithPartialPremintedStrat() public {
        // mint more STRAT into the optionExercise contract than needed
        vm.prank(owner);
        stratToken.mint(address(optionExercise), 100 ether);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);

        // Approve option transfer and CDT burn
        cdtToken.approve(address(optionExercise), 100 ether);
        stratOption.approve(address(optionExercise), 1);

        // Exercise
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 900 ether, "cdtToken should be burned");
        assertEq(stratToken.balanceOf(address(optionExercise)), 0);
        assertEq(stratToken.totalSupply(), 900 ether, "Total supply should be 9,000,000 STRAT");
        vm.stopPrank();
    }

    function testRevertIfTimelockActive() public {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.TimelockActive.selector, user, 1));
        optionExercise.exercise(1);
        vm.stopPrank();
    }

    function testRevertIfOptionExpired() public {
        // Warp past expiry
        vm.warp(block.timestamp + 3601);
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.OptionExpired.selector, user, 1));
        optionExercise.exercise(1);
        vm.stopPrank();
    }

    function testRevertIfNotOptionOwner() public {
        // Advance time beyond timelock, before expiry
        vm.warp(block.timestamp + 1801);
        address randoUser = address(0x999);

        vm.prank(owner);
        cdtToken.mint(randoUser, 1000 ether);

        // Prank some random user
        vm.startPrank(randoUser);
        cdtToken.approve(address(optionExercise), 100 ether);

        vm.expectRevert();
        optionExercise.exercise(1);

        vm.stopPrank();
    }
}
