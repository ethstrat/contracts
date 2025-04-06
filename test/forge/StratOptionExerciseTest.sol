// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratOptionExercise.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {StratETHLongBonds} from "../../src/StratETHLongBonds.sol";
import {StratETHShortBonds} from "../../src/StratETHShortBonds.sol";
import {StratPresale} from "../../src/StratPresale.sol";
import {MockTreasury} from "../mocks/MockTreasury.sol";

contract StratOptionExerciseTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionExercise public optionExercise;
    StratETHLongBonds public longBonds;
    StratETHShortBonds public shortBonds;
    StratPresale public presale;

    MockOracle public ethUsdOracle;
    MockOracle public stratEthOracle;
    MockTreasury public treasury;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal rando = address(0x999);
    address internal bondConverter = address(0x989);

    event OptionExercised(address indexed optionOwner, uint256 tokenId, uint256 strike, uint256 strat);

    function setUp() public {
        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);
        optionExercise = new StratOptionExercise(address(cdtToken), address(stratToken), address(stratOption));
        ethUsdOracle = new MockOracle(3000e8, 18, 8);
        stratEthOracle = new MockOracle(1e18, 18, 18);
        treasury = new MockTreasury();
        treasury.setWithdrawAllowed(true);

        longBonds = new StratETHLongBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(treasury),
            address(treasury),
            address(ethUsdOracle),
            1e18,
            owner
        );
        shortBonds = new StratETHShortBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(ethUsdOracle),
            address(stratEthOracle),
            bondConverter,
            1e18,
            owner
        );
        presale = new StratPresale(address(stratOption), owner);

        // Enable minting
        cdtToken.manageMinter(address(longBonds), true);
        cdtToken.manageMinter(address(shortBonds), false);
        cdtToken.manageMinter(address(presale), false);
        stratOption.manageMinter(address(longBonds), true);
        stratOption.manageMinter(address(shortBonds), true);
        stratOption.manageMinter(address(presale), true);

        cdtToken.manageMinter(owner, true);
        stratToken.manageMinter(owner, true);
        stratToken.manageMinter(address(shortBonds), true);
        stratToken.manageMinter(address(optionExercise), true);
        vm.stopPrank();

        // Mint STRAT tokens, required for long and short bonds
        vm.prank(owner);
        stratToken.mint(owner, 1000e18);
    }

    // TODO restore simple tests, shift integration tests to a new file

    modifier givenTimelockNotPassed() {
        if (stratOption.timelock(1) == 0) revert("no token id");

        vm.warp(stratOption.timelock(1) - 1);
        _;
    }

    modifier givenTimelockPassed() {
        if (stratOption.timelock(1) == 0) revert("no token id");

        vm.warp(stratOption.timelock(1) + 1);
        _;
    }

    modifier givenExpiryPassed() {
        if (stratOption.expiry(1) == 0) revert("no token id");

        vm.warp(stratOption.expiry(1) + 1);
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

    modifier givenPresaleOptionMinted(uint256 ethAmount_) {
        deal(user, ethAmount_);

        vm.prank(user);
        presale.mint{value: ethAmount_}();
        _;
    }

    modifier givenLongBondMinted(uint256 ethAmount_) {
        deal(user, ethAmount_);

        vm.prank(user);
        longBonds.bond{value: ethAmount_}(user);
        _;
    }

    modifier givenShortBondMinted(uint256 cdtAmount_) {
        vm.prank(owner);
        cdtToken.mint(user, cdtAmount_);

        vm.startPrank(user);
        cdtToken.approve(address(shortBonds), cdtAmount_);
        shortBonds.bond(user, cdtAmount_);
        vm.stopPrank();
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
    // given the option is a short bond
    //  [X] it does not burn CDT tokens from the option owner
    //  [X] it mints STRAT tokens to the option owner
    //  [X] it burns the option
    //  [X] it emits an OptionExercised event
    // given the option is a long bond
    //  [X] it burns the CDT tokens from the option owner
    //  [X] it mints the STRAT tokens to the option owner
    //  [X] it burns the option
    //  [X] it emits an OptionExercised event

    function test_invalidTokenId_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.InvalidTokenId.selector, user, 2));

        vm.prank(user);
        optionExercise.exercise(2);
    }

    function testExerciseWithSufficientPremintedStrat()
        public
        givenLongBondMinted(1e18)
        givenTimelockPassed
        givenAccountHasApprovedCDTSpending(user, 3000e18)
        givenOptionSpendingApproved(1)
    {
        uint256 expectedCdUSDAmount = (1 ether * ethUsdOracle.price()) / 1e8; // ETH -> USD conversion
        uint256 expectedStratQuantity = stratOption.notionalUnderlyingAmount(1);

        // mint more STRAT into the optionExercise contract than needed
        vm.prank(owner);
        stratToken.mint(address(optionExercise), 10000e18);

        // Exercise
        vm.prank(user);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdtToken should be burned");

        assertEq(
            stratToken.balanceOf(address(optionExercise)),
            10000e18 - expectedStratQuantity,
            "OptionExercise should have STRAT left"
        );
        assertEq(stratToken.totalSupply(), 10000e18 + 1000e18, "Total supply");
    }

    function testExerciseWithPartialPremintedStrat()
        public
        givenLongBondMinted(1e18)
        givenTimelockPassed
        givenAccountHasApprovedCDTSpending(user, 3000e18)
        givenOptionSpendingApproved(1)
    {
        uint256 expectedCdUSDAmount = (1 ether * ethUsdOracle.price()) / 1e8; // ETH -> USD conversion
        uint256 expectedStratQuantity = stratOption.notionalUnderlyingAmount(1);

        // mint less STRAT into the optionExercise contract than needed
        vm.prank(owner);
        stratToken.mint(address(optionExercise), 100e18);

        // Exercise
        vm.prank(user);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdtToken should be burned");

        assertEq(stratToken.balanceOf(address(optionExercise)), 0, "optionExercise STRAT balance");
        assertEq(stratToken.totalSupply(), expectedStratQuantity + 1000e18, "Total supply");
    }

    function test_timelockNotPassed_reverts() public givenPresaleOptionMinted(1e18) givenTimelockNotPassed {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.TimelockActive.selector, user, 1));
        optionExercise.exercise(1);
        vm.stopPrank();
    }

    function test_optionExpired_reverts() public givenPresaleOptionMinted(1e18) givenExpiryPassed {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.OptionExpired.selector, user, 1));
        optionExercise.exercise(1);
        vm.stopPrank();
    }

    function test_optionNotApproved_reverts() public givenPresaleOptionMinted(1e18) givenTimelockPassed {
        // optionExercise does not have approval to spend the option, so this reverts
        vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionExercise), 1));

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(1);
    }

    function test_notOptionOwner()
        public
        givenPresaleOptionMinted(1e18)
        givenTimelockPassed
        givenOptionSpendingApproved(1)
    {
        uint256 expectedStratQuantity = stratOption.notionalUnderlyingAmount(1);

        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, 1, 0, expectedStratQuantity);

        // Call function as rando
        vm.prank(rando);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "user: STRAT balance");
        assertEq(stratToken.balanceOf(rando), 0, "rando: STRAT balance");

        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");

        assertEq(cdtToken.balanceOf(user), 0, "user: cdt balance should be 0");
        assertEq(cdtToken.balanceOf(rando), 0, "rando: cdt balance should be 0");
    }

    function test_notOptionOwner_longBond_cdtSpendingNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenTimelockPassed
        givenOptionSpendingApproved(1)
    {
        // optionExercise does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as rando
        vm.prank(rando);
        optionExercise.exercise(1);
    }

    function test_presaleOption()
        public
        givenPresaleOptionMinted(1e18)
        givenTimelockPassed
        givenOptionSpendingApproved(1)
    {
        uint256 expectedStratQuantity = stratOption.notionalUnderlyingAmount(1);

        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, 1, 0, expectedStratQuantity);

        // Exercise
        vm.prank(user);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdt balance should be 0");
    }

    function test_longBond()
        public
        givenLongBondMinted(1e18)
        givenTimelockPassed
        givenAccountHasApprovedCDTSpending(user, 3000e18)
        givenOptionSpendingApproved(1)
    {
        uint256 expectedCdUSDAmount = (1 ether * ethUsdOracle.price()) / 1e8; // ETH -> USD conversion
        uint256 expectedStratQuantity = stratOption.notionalUnderlyingAmount(1);

        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, 1, expectedCdUSDAmount, expectedStratQuantity);

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdt balance should be 0");
    }

    function test_longBond_cdtSpendingNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenTimelockPassed
        givenOptionSpendingApproved(1)
    {
        // optionExercise does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(1);
    }

    function test_shortBond()
        public
        givenAccountHasApprovedCDTSpending(user, 6000e18)
        givenShortBondMinted(6000e18)
        givenTimelockPassed
        givenOptionSpendingApproved(1)
    {
        uint256 expectedStratQuantity = stratOption.notionalUnderlyingAmount(1);

        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, 1, 0, expectedStratQuantity);

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(1);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdt balance should be 0");
    }
}
