// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratOptionExercise.sol";
import "../../../src/StratOption.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";

contract StratOptionExerciseTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionExercise public optionExercise;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal rando = address(0x999);

    event OptionExercised(address indexed optionOwner, uint256 tokenId, uint256 strike, uint256 strat);

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
        stratToken.mint(owner, 1000 ether);

        // Mint an option to user
        stratOption.mint(user, 100 ether, 900 ether, 0, block.timestamp + 3600, block.timestamp + 1800);

        vm.stopPrank();
    }

    modifier givenTimelockPassed() {
        vm.warp(block.timestamp + 1801);
        _;
    }

    modifier givenAccountHasCDT(address account_, uint256 amount_) {
        vm.prank(owner);
        cdtToken.mint(account_, amount_);
        _;
    }

    modifier givenAccountHasApprovedCDTSpending(address account_, uint256 amount_) {
        vm.prank(account_);
        cdtToken.approve(address(optionExercise), amount_);
        _;
    }

    modifier givenOptionSpendingApproved(uint256 tokenId_) {
        vm.prank(user);
        stratOption.approve(address(optionExercise), tokenId_);
        _;
    }

    // given the token id is invalid
    //  [X] it reverts
    // given the timelock has not passed
    //  [X] it reverts
    // given the option expiry has passed
    //  [X] it reverts
    // given the option owner has not approved the contract to spend the option
    //  [X] it reverts
    // given the caller is not the option owner
    //  given the caller has not approved spending of CD tokens
    //   [X] it reverts
    //  [X] it burns the CDT tokens from the caller
    //  [X] it mints the STRAT tokens to the option owner
    //  [X] it burns the option
    //  [X] it emits an OptionExercised event
    // given the caller has not approved spending of CD tokens
    //  [X] it reverts
    // given the option is from the presale
    //  [X] it burns the CDT tokens from the option owner
    //  [X] it mints the STRAT tokens to the option owner
    //  [X] it burns the option
    //  [X] it emits an OptionExercised event
    // [X] it burns the CDT tokens from the option owner
    // [X] it mints the STRAT tokens to the option owner
    // [X] it burns the option
    // [X] it emits an OptionExercised event

    function test_invalidTokenId_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.InvalidTokenId.selector, user, 2));

        vm.prank(user);
        optionExercise.exercise(2);
    }

    function test_timelockActive_reverts() public {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.TimelockActive.selector, user, 1));
        optionExercise.exercise(1);
        vm.stopPrank();
    }

    function test_optionExpired_reverts() public {
        // Warp past expiry
        vm.warp(block.timestamp + 3601);
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.OptionExpired.selector, user, 1));
        optionExercise.exercise(1);
        vm.stopPrank();
    }

    function test_optionNotApproved_reverts()
        public
        givenTimelockPassed
        givenAccountHasCDT(rando, 100 ether)
        givenAccountHasApprovedCDTSpending(rando, 100 ether)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionExercise), 1));

        // Call function as randoUser
        vm.prank(rando);
        optionExercise.exercise(1);
    }

    function test_notOptionOwner_cdtSpendingNotApproved_reverts()
        public
        givenTimelockPassed
        givenOptionSpendingApproved(1)
    {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as rando
        vm.prank(rando);
        optionExercise.exercise(1);
    }

    function test_notOptionOwner()
        public
        givenTimelockPassed
        givenAccountHasCDT(rando, 100 ether)
        givenAccountHasApprovedCDTSpending(rando, 100 ether)
        givenOptionSpendingApproved(1)
    {
        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, 1, 100 ether, 900 ether);

        // Call function as rando
        vm.prank(rando);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
        assertEq(stratToken.balanceOf(rando), 0, "rando: no STRAT received");

        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");

        assertEq(cdtToken.balanceOf(user), 1000 ether, "user: cdtToken should not be burned");
        assertEq(cdtToken.balanceOf(rando), 0, "rando: cdtToken should be burned");
    }

    function test_cdtSpendingNotApproved_reverts() public givenTimelockPassed givenOptionSpendingApproved(1) {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(1);
    }

    function testExerciseSuccess()
        public
        givenTimelockPassed
        givenAccountHasApprovedCDTSpending(user, 100 ether)
        givenOptionSpendingApproved(1)
    {
        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, 1, 100 ether, 900 ether);

        // Exercise
        vm.prank(user);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 900 ether, "cdtToken should be burned");
    }

    function test_presaleOption() public givenAccountHasApprovedCDTSpending(user, 100 ether) {
        // Mint a presale option with no underlying USD amount
        vm.prank(owner);
        stratOption.mint(user, 100 ether, 900 ether, 0, block.timestamp + 3600, block.timestamp + 1800);

        // Warp to after timelock
        vm.warp(block.timestamp + 1801);

        // Approve spending of option
        vm.prank(user);
        stratOption.approve(address(optionExercise), 2);

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(2);

        // Check balances
        assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 1, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 900 ether, "cdtToken should be burned");
    }
}
