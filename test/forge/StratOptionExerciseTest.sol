// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PermitGenerator} from "../lib/Permit.sol";

import "../../src/StratOptionExercise.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";

contract StratOptionExerciseTest is Test, PermitGenerator {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionExercise public optionExercise;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal permitOwner;
    uint256 internal permitPk;

    function setUp() public {
        (permitOwner, permitPk) = makeAddrAndKey("PERMIT_OWNER");

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

    function _mintOption(address to_) internal {
        vm.prank(owner);
        stratOption.mint(to_, 100 ether, 900 ether, 0, block.timestamp + 3600, block.timestamp + 1800);
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

    // exerciseWithPermit
    // given the deadline is 0
    //  given the caller has not approved spending of CDT
    //   [X] it reverts
    //  [X] it uses the existing spending allowance
    // given the deadline has passed
    //  [X] it reverts
    // given the signature is for another user
    //  [X] it reverts
    // given the caller is not the recipient
    //  given the signature is for the recipient
    //   [X] it reverts
    //  [X] it does not require approval to spend the CDT
    //  [X] it burns the CDT
    // given the signature is for a different spender
    //  [X] it reverts
    // given the signature is invalid
    //  [X] it reverts
    // [X] it does not require approval to spend the CDT
    // [X] it burns the CDT

    function test_exerciseWithPermit_deadlineIsZero_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do not approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Expect allowance revert
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);
    }

    function test_exerciseWithPermit_deadlineIsZero_spendingApprovalProvided() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Approve spending of CDT
        vm.prank(permitOwner);
        cdtToken.approve(address(optionExercise), 100 ether);

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Exercise
        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);

        // Check balances
        assertEq(stratToken.balanceOf(permitOwner), 900 ether, "Permit owner should get STRAT");
        assertEq(stratOption.balanceOf(permitOwner), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 900 ether, "cdtToken should be burned");
    }

    function test_exerciseWithPermit_deadlineHasPassed_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(optionExercise), block.timestamp - 1, 100 ether, cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, block.timestamp - 1));

        // Exercise
        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);
    }

    function test_exerciseWithPermit_differentOwner_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate permit approval
        (address newOwner, uint256 newOwnerPk) = makeAddrAndKey("NEW_OWNER");
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            newOwner,
            newOwnerPk,
            address(optionExercise),
            block.timestamp + 1 days,
            100 ether,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0xFba41A79DD636Bfc748890D1Deb80829fEdDD28f, permitOwner
            )
        );

        // Exercise
        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);
    }

    function test_exerciseWithPermit_differentSpender_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(stratOption),
            block.timestamp + 1 days,
            100 ether,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0xf392f9c119F8bbD01c1A4d7Ac3A7c45F5D643F3B, permitOwner
            )
        );

        // Exercise
        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);
    }

    function test_exerciseWithPermit_invalidSignature_reverts() public {
        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate invalid signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(permitPk, keccak256("INVALID"));

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: block.timestamp + 1 days, v: v, r: r, s: s});

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0x5c1344a134077f4F410944f7F722E48E978CD240, permitOwner
            )
        );

        // Exercise
        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);
    }

    function test_exerciseWithPermit_callerNotRecipient() public {
        uint256 cdtAmount = 100 ether;

        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Create a new user
        (address newUser, uint256 newUserPk) = makeAddrAndKey("NEW_USER");

        // Give new user CDT
        vm.prank(owner);
        cdtToken.mint(newUser, cdtAmount);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            newUser,
            newUserPk,
            address(optionExercise),
            block.timestamp + 1 days,
            cdtAmount,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Exercise as new user
        vm.prank(newUser);
        optionExercise.exerciseWithPermit(2, permitApproval);

        // Check balances
        assertEq(stratToken.balanceOf(permitOwner), 900 ether, "Permit owner should get STRAT");
        assertEq(stratOption.balanceOf(permitOwner), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(newUser), 0, "newUser: cdtToken should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 0, "permitOwner: CDT balance");
    }

    function test_exerciseWithPermit_callerNotRecipient_permitFromRecipient_reverts() public {
        uint256 cdtAmount = 100 ether;

        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Create a new user
        (address newUser, uint256 newUserPk) = makeAddrAndKey("NEW_USER");

        // Give new user CDT
        vm.prank(owner);
        cdtToken.mint(newUser, cdtAmount);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate permit approval as the permit owner
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(optionExercise),
            block.timestamp + 1 days,
            cdtAmount,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612InvalidSigner.selector, 0x3f58E86ceFbCE43eb57605fB1cBE4fff44021709, newUser
            )
        );

        // Exercise as new user
        vm.prank(newUser);
        optionExercise.exerciseWithPermit(2, permitApproval);
    }

    function test_exerciseWithPermit() public {
        uint256 cdtAmount = 100 ether;

        // Mint an option to the permit owner
        _mintOption(permitOwner);

        // After timelock, before expiry
        vm.warp(block.timestamp + 1801);

        // Give permit owner CDT
        vm.prank(owner);
        cdtToken.mint(permitOwner, cdtAmount);

        // Do NOT approve CDT burn

        // Approve option transfer
        vm.prank(permitOwner);
        stratOption.approve(address(optionExercise), 2);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(optionExercise),
            block.timestamp + 1 days,
            cdtAmount,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Exercise
        vm.prank(permitOwner);
        optionExercise.exerciseWithPermit(2, permitApproval);

        // Check balances
        assertEq(stratToken.balanceOf(permitOwner), 900 ether, "Permit owner should get STRAT");
        assertEq(stratOption.balanceOf(permitOwner), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 0, "permitOwner: CDT balance");
    }
}
