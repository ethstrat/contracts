// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratOptionExercise.sol";
import "../../../src/StratOption.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {StratETHLongBonds} from "../../../src/StratETHLongBonds.sol";
import {StratETHShortBonds} from "../../../src/StratETHShortBonds.sol";
import {StratPresale} from "../../../src/StratPresale.sol";
import {IStratOptionMinter} from "../../../src/interfaces/IStratOptionMinter.sol";
import {IERC1155Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

contract StratOptionExerciseTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionExercise public optionExercise;
    MockOracle public ethUsdOracle;
    MockOracle public stratEthOracle;
    StratETHLongBonds public longBonds;
    StratETHShortBonds public shortBonds;
    StratPresale public presale;

    uint256 public tokenId;

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
        ethUsdOracle = new MockOracle(3000e8, 18, 8);
        stratEthOracle = new MockOracle(1e18, 18, 18);

        longBonds = new StratETHLongBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            owner,
            address(ethUsdOracle),
            address(stratEthOracle),
            1e18,
            owner
        );
        shortBonds = new StratETHShortBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(ethUsdOracle),
            address(stratEthOracle),
            1e18,
            owner
        );
        presale = new StratPresale(1000 ether, address(stratOption), owner, uint48(block.timestamp));

        // Enable minting
        cdtToken.manageMinter(address(longBonds), true);
        cdtToken.manageMinter(address(shortBonds), false);
        cdtToken.manageMinter(address(presale), false);
        stratOption.manageMinter(address(longBonds), true);
        stratOption.manageMinter(address(shortBonds), true);
        stratOption.manageMinter(address(presale), true);

        cdtToken.manageMinter(owner, true);
        stratToken.manageMinter(owner, true);
        stratToken.manageMinter(address(optionExercise), true);
        vm.stopPrank();

        // Mint STRAT tokens, required for long and short bonds
        vm.prank(owner);
        stratToken.mint(owner, 1000e18);
    }

    modifier givenTimelockNotPassed() {
        if (tokenId == 0) revert("No token id");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        vm.warp(option.timelock - 1);
        _;
    }

    modifier givenTimelockPassed() {
        if (tokenId == 0) revert("No token id");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        vm.warp(option.timelock + 1);
        _;
    }

    modifier givenExpiryPassed() {
        if (tokenId == 0) revert("No token id");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        vm.warp(option.expiry + 1);
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

    modifier givenOptionSpendingApproved() {
        vm.prank(user);
        stratOption.setApprovalForAll(address(optionExercise), true);
        _;
    }

    modifier givenPresaleOptionMinted(uint256 ethAmount_) {
        deal(user, ethAmount_);

        vm.prank(user);
        tokenId = presale.mint{value: ethAmount_}();
        _;
    }

    modifier givenLongBondMinted(uint256 ethAmount_) {
        deal(user, ethAmount_);

        vm.prank(user);
        tokenId = longBonds.bond{value: ethAmount_}(user);
        _;
    }

    modifier givenShortBondMinted(uint256 cdtAmount_) {
        vm.prank(owner);
        cdtToken.mint(user, cdtAmount_);

        vm.startPrank(user);
        cdtToken.approve(address(shortBonds), cdtAmount_);
        tokenId = shortBonds.bond(user, cdtAmount_);
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

    function test_timelockNotPassed_reverts() public givenPresaleOptionMinted(1e18) givenTimelockNotPassed {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.TimelockActive.selector, user, tokenId));
        optionExercise.exercise(tokenId);
        vm.stopPrank();
    }

    function test_optionExpired_reverts() public givenPresaleOptionMinted(1e18) givenExpiryPassed {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionExercise.OptionExpired.selector, user, tokenId));
        optionExercise.exercise(tokenId);
        vm.stopPrank();
    }

    function test_optionNotApproved_reverts()
        public
        givenPresaleOptionMinted(1e18)
        givenTimelockPassed
        givenAccountHasCDT(user, 1e18)
        givenAccountHasApprovedCDTSpending(user, 1e18)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(optionExercise), user)
        );

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(tokenId);
    }

    // TODO strat exerciseFor

    // function test_notOptionOwner_cdtSpendingNotApproved_reverts()
    //     public
    //     givenPresaleOptionMinted(1e18)
    //     givenTimelockPassed
    //     givenOptionSpendingApproved()
    // {
    //     // optionRedeem does not have approval to spend the CDT, so this reverts
    //     vm.expectRevert("ERC20: burn amount exceeds allowance");

    //     // Call function as rando
    //     vm.prank(rando);
    //     optionExercise.exercise(tokenId);
    // }

    // function test_notOptionOwner()
    //     public
    //     givenTimelockPassed
    //     givenAccountHasCDT(rando, 100 ether)
    //     givenAccountHasApprovedCDTSpending(rando, 100 ether)
    //     givenOptionSpendingApproved(1)
    // {
    //     // Expect event
    //     vm.expectEmit();
    //     emit OptionExercised(user, 1, 100 ether, 900 ether);

    //     // Call function as rando
    //     vm.prank(rando);
    //     optionExercise.exercise(1);

    //     // Check balances
    //     assertEq(stratToken.balanceOf(user), 900 ether, "User should get STRAT");
    //     assertEq(stratToken.balanceOf(rando), 0, "rando: no STRAT received");

    //     assertEq(stratOption.balanceOf(user), 0, "Option should be burned");

    //     assertEq(cdtToken.balanceOf(user), 1000 ether, "user: cdtToken should not be burned");
    //     assertEq(cdtToken.balanceOf(rando), 0, "rando: cdtToken should be burned");
    // }

    function test_cdtSpendingNotApproved_reverts()
        public
        givenPresaleOptionMinted(1e18)
        givenTimelockPassed
        givenOptionSpendingApproved
    {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(tokenId);
    }

    function test_presaleOption()
        public
        givenPresaleOptionMinted(2e18)
        givenTimelockPassed
        givenAccountHasCDT(user, 2e18)
        givenAccountHasApprovedCDTSpending(user, 2e18)
        givenOptionSpendingApproved
    {
        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, tokenId, 2e18, 2e18);

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(tokenId);

        // Check balances
        assertEq(stratToken.balanceOf(user), 2e18, "User should get STRAT");
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdtToken should be burned");
    }

    function test_longBond()
        public
        givenLongBondMinted(2e18)
        givenTimelockPassed
        givenAccountHasApprovedCDTSpending(user, 6000e18)
        givenOptionSpendingApproved
    {
        // User has 2 * 3000e18 options (USD value), 6000e18 CDT (from the long bond minting)
        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);
        uint256 expectedStratQuantity = 6000e18 * 1e18 / option.strikePrice;

        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, tokenId, 6000e18, expectedStratQuantity);

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(tokenId);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdtToken should be burned");
    }

    function test_shortBond()
        public
        givenAccountHasApprovedCDTSpending(user, 6000e18)
        givenShortBondMinted(6000e18)
        givenTimelockPassed
        givenOptionSpendingApproved
    {
        // User has 6000e18 options (USD value), no CDT
        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);
        uint256 expectedStratQuantity = 6000e18 * 1e18 / option.strikePrice;

        // Expect event
        vm.expectEmit();
        emit OptionExercised(user, tokenId, 6000e18, expectedStratQuantity);

        // Call function as user
        vm.prank(user);
        optionExercise.exercise(tokenId);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStratQuantity, "User should get STRAT");
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 0, "cdtToken should be burned");
    }
}
