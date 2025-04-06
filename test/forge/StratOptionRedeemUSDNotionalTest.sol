// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratOptionRedeemUSDNotional.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/interfaces/ITreasury.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {StratETHLongBonds} from "../../src/StratETHLongBonds.sol";
import {StratETHShortBonds} from "../../src/StratETHShortBonds.sol";
import {StratPresale} from "../../src/StratPresale.sol";

import {MockOracle} from "../mocks/MockOracle.sol";
import {MockTreasury} from "../mocks/MockTreasury.sol";

contract StratOptionRedeemUSDNotionalTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionRedeemUSDNotional public optionRedeem;
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

    event OptionRedeemed(address indexed optionOwner, uint256 tokenId, uint256 notionalUSDAmount, uint256 ethAmount);

    function setUp() public {
        vm.startPrank(owner);
        // Deploy tokens and mocks
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);
        ethUsdOracle = new MockOracle(2000e8, 18, 8); // e.g., 1 ETH = 2000 USD
        stratEthOracle = new MockOracle(1e18, 18, 18);
        treasury = new MockTreasury();
        treasury.setWithdrawAllowed(true); // Allow withdrawals for testing
        vm.stopPrank();

        _createContracts();

        _authoriseMinting();

        vm.startPrank(owner);

        // Mint STRAT tokens, required for long and short bonds
        stratToken.mint(owner, 1000e18);

        // Give the treasury some initial balance
        vm.deal(address(treasury), 100 ether);

        vm.stopPrank();
    }

    function _createContracts() internal {
        optionRedeem = new StratOptionRedeemUSDNotional(
            address(cdtToken), address(stratToken), address(treasury), address(ethUsdOracle), address(stratOption)
        );
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
    }

    function _authoriseMinting() internal {
        vm.startPrank(owner);
        cdtToken.manageMinter(address(longBonds), true);
        cdtToken.manageMinter(address(shortBonds), false);
        cdtToken.manageMinter(address(presale), false);
        cdtToken.manageMinter(owner, true);

        stratOption.manageMinter(address(longBonds), true);
        stratOption.manageMinter(address(shortBonds), true);
        stratOption.manageMinter(address(presale), true);

        stratToken.manageMinter(owner, true);
        stratToken.manageMinter(address(shortBonds), true);
        stratToken.manageMinter(address(optionRedeem), true);
        vm.stopPrank();
    }

    // TODO restore simple tests, shift integration tests to a new file

    modifier givenEthUsdOracleScale(uint8 scale_, uint256 price_) {
        ethUsdOracle.setQuoteTokenDecimals(scale_);
        ethUsdOracle.setPrice(price_);

        // Re-create the contracts
        _createContracts();
        _authoriseMinting();
        _;
    }

    modifier givenTimelockPassed() {
        if (stratOption.timelock(1) == 0) {
            revert("No token id");
        }

        vm.warp(stratOption.timelock(1) + 1);
        _;
    }

    function _warpPastExpiry() internal {
        if (stratOption.expiry(1) == 0) {
            revert("No token id");
        }

        vm.warp(stratOption.expiry(1) + 1);
    }

    modifier givenExpiryPassed() {
        _warpPastExpiry();
        _;
    }

    modifier givenAccountHasCDT(address account_, uint256 amount_) {
        vm.prank(owner);
        cdtToken.mint(account_, amount_);
        _;
    }

    modifier givenAccountHasApprovedCDTSpending(address account_, uint256 amount_) {
        vm.prank(account_);
        cdtToken.approve(address(optionRedeem), amount_);
        _;
    }

    modifier givenOptionSpendingApproved(uint256 tokenId_) {
        vm.prank(user);
        stratOption.approve(address(optionRedeem), tokenId_);
        _;
    }

    modifier givenPresaleOptionMinted(uint256 ethAmount_) {
        deal(user, ethAmount_);

        vm.prank(user);
        presale.mint{value: ethAmount_}();
        _;
    }

    function _mintLongBond(uint256 ethAmount_) internal returns (uint256) {
        deal(user, ethAmount_);

        vm.prank(user);
        longBonds.bond{value: ethAmount_}(user);
    }

    modifier givenLongBondMinted(uint256 ethAmount_) {
        _mintLongBond(ethAmount_);
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

    // redeemCdtForUsdNotional
    // when the token id is invalid
    //  [X] it reverts
    // given the timelock has not passed
    //  [X] it reverts
    // given the option expiry has not passed
    //  [X] it reverts
    // given the caller has not approved spending of the notionalUSDAmount of CDT tokens
    //  [X] it reverts
    // when the caller does not have notionalUSDAmount of CDT tokens
    //  [X] it reverts
    // given the option owner has not approved the contract to spend the option
    //  [X] it reverts
    // given the treasury value is greater than the CDT token supply
    //  given the oracle scale is 18
    //   [X] it correctly calculates the amount of ETH to send to the option owner
    //  [X] it sends the notionalUSDAmount converted to ETH at the current ETH price from the treasury to the option
    // owner
    // when the caller is not the option owner
    //  given the option owner has not approved the contract to spend the option
    //   [X] it reverts
    //  given the caller has not approved spending of the notionalUSDAmount of CDT tokens
    //   [X] it reverts
    //  given the caller has insufficient CDT balance
    //   [X] it reverts
    //  [X] it burns the notionalUSDAmount of CDT tokens from the caller
    //  [X] it burns the option
    //  [X] it sends the proportional amount of ETH from the treasury to the option owner
    //  [X] it emits a OptionRedeemed event
    // given the oracle scale is 18
    //  [X] it correctly calculates the amount of ETH to send to the option owner
    // given it is a presale option
    //  [X] it reverts
    // given it is a short bond
    //  [X] it reverts
    // [X] it burns the notionalUSDAmount of CDT tokens from the caller
    // [X] it burns the option
    // [X] it sends the proportional amount of ETH from the treasury to the option owner
    // [X] it emits a OptionRedeemed event

    function test_invalidTokenId_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.InvalidTokenId.selector, user, 2));

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(2);
    }

    function test_timelockActive_reverts() public givenLongBondMinted(1e18) {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.TimelockActive.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function test_optionUnexpired_reverts() public givenLongBondMinted(1e18) givenTimelockPassed {
        // before expiry, after timelock
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.OptionUnexpired.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function test_notOptionOwner_optionNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasCDT(rando, 2000e18)
        givenAccountHasApprovedCDTSpending(rando, 2000e18)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionRedeem), 1));

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_notOptionOwner_cdtSpendingNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasCDT(rando, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_notOptionOwner_cdtInsufficientBalance_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(rando, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // rando has insufficient CDT balance, so this reverts
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, rando, 0, 2000e18));

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_notOptionOwner()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasCDT(rando, 2000e18)
        givenAccountHasApprovedCDTSpending(rando, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Treasury has 100e18 + 1e18 ETH
        // Value @ $2000/ETH is 202_000e18 USD
        // Total debt is 2000e18 CDT
        // Option owner has 2000e18 CDT
        // Option has redemption value of 2000e18 * 1e18 / 2000e18 = 1e18
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 1e18 / 2000e18;

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, 1, expectedRedemptionValue, expectedEthAmount);

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");

        // rando's CDT should be burned
        assertEq(cdtToken.balanceOf(rando), 0, "rando: CDT should be burned");
        // user's CDT should be untouched
        assertEq(cdtToken.balanceOf(user), 2000e18, "user: CDT should be untouched");

        assertEq(address(user).balance, expectedEthAmount, "should withdraw 1e18 ETH");
    }

    function test_cdtSpendingNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenOptionSpendingApproved(1)
    {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_cdtInsufficientBalance_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Change the balance of the CDT token
        vm.prank(user);
        cdtToken.transfer(rando, 2000e18);

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 0, 2000e18));

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_optionNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasCDT(user, 2000e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionRedeem), 1));

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_treasuryGtDebt()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Mint another long bond
        _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry();

        // Treasury has 100e18 + 1e18 + 2e18 ETH
        // Value @ $2000/ETH is 206_000e18 USD
        // Total debt is 6000e18 CDT
        // Option owner has 6000e18 CDT
        // option has redemption value of 2000e18 * 1e18 / 2000e18 = 1e18
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 1e18 / 2000e18;

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, 1, expectedRedemptionValue, expectedEthAmount);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 1, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be partially burned");
        assertEq(address(user).balance, expectedEthAmount, "should withdraw 1e18 ETH");
    }

    function test_treasuryGtDebt_oracleDecimals18()
        public
        givenEthUsdOracleScale(18, 2000e18)
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Mint another long bond
        _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry();

        // Treasury has 100e18 + 1e18 + 2e18 ETH
        // Value @ $2000/ETH is 206_000e18 USD
        // Total debt is 6000e18 CDT
        // Option owner has 6000e18 CDT
        // option has redemption value of 2000e18 * 1e18 / 2000e18 = 1e18
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 1e18 / 2000e18;

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, 1, expectedRedemptionValue, expectedEthAmount);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 1, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "should withdraw 1e18 ETH");
    }

    function test_treasuryLtDebt_ethPrice1()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Mint another long bond
        _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry();

        // Set the oracle price to $1
        ethUsdOracle.setPrice(1e8); // 1 ETH = 1 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 1 USD (1e8), the treasury is valued at 103 USD (103e18)
        // Treasury USD value (103e18) is less than the USD debt (6000e18)

        // Option owner has 2000 CDT (2000e18) and a redemption value of 2000 (2000e18)
        // Option has entitlement to 2000e18 * 103e18 / 6000e18 = 34.333333333e18 (34.333333333 USD of ETH)
        // Option owner receives 34.333333333e18 * 1e8 / 1e8 = 34.333333333e18 (34.333333333 ETH)
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 103e18 / 6000e18;

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 1, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be partially burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_treasuryLtDebt_ethPrice9()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Mint another long bond
        _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry();

        // Set the oracle price to $9
        ethUsdOracle.setPrice(9e8); // 1 ETH = 9 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e8), the treasury is valued at 927e18 USD (927e18)
        // Treasury USD value (927e18) is less than the USD debt (6000e18)

        // Option owner has 2000 CDT (2000e18) and a notional USD value of 2000e18 (2000e18)
        // Option owner entitled to USD value of: 2000e18 * 927e18 / 6000e18 = 309e18 USD (309)
        // Option owner receives: 309e18 * 1e8 / 9e8 = 34.333333333e18 ETH (34.333333333)
        uint256 expectedRedemptionValue = 2000e18;
        uint256 usdEntitlement = expectedRedemptionValue * 927e18 / 6000e18;
        uint256 expectedEthAmount = usdEntitlement * 1e8 / 9e8;

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 1, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_treasuryLtDebt_ethPrice9_oracleDecimals18()
        public
        givenEthUsdOracleScale(18, 2000e18)
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved(1)
    {
        // Mint another long bond
        _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry();

        // Adjust price to $9
        ethUsdOracle.setPrice(9e18); // 1 ETH = 9 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e8), the treasury is valued at 927e18 USD (927e18)
        // Treasury USD value (927e18) is less than the USD debt (6000e18)

        // Option owner has 2000 CDT (2000e18) and a notional USD value of 2000e18 (2000e18)
        // Option owner entitled to USD value of: 2000e18 * 927e18 / 6000e18 = 309e18 USD (309)
        // Option owner receives: 309e18 * 1e18 / 9e18 = 34.333333333e18 ETH (34.333333333)
        uint256 expectedRedemptionValue = 2000e18;
        uint256 usdEntitlement = expectedRedemptionValue * 927e18 / 6000e18;
        uint256 expectedEthAmount = usdEntitlement * 1e18 / 9e18;

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 1, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_presaleOption_reverts() public givenPresaleOptionMinted(1e18) givenExpiryPassed {
        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.Unsupported.selector, user, 1));

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_shortBond_reverts() public givenShortBondMinted(1e18) givenExpiryPassed {
        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.Unsupported.selector, user, 1));

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }
}
