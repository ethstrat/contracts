// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratOptionRedeemUSDNotional.sol";
import "../../../src/StratOption.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {StratETHLongBonds} from "../../../src/StratETHLongBonds.sol";
import {StratETHShortBonds} from "../../../src/StratETHShortBonds.sol";
import {StratPresale} from "../../../src/StratPresale.sol";
import {IStratOptionMinter} from "../../../src/interfaces/IStratOptionMinter.sol";
import {IERC1155Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

contract MockTreasury is Treasury {
    function withdraw(uint256 amount, address to) external {
        payable(to).transfer(amount);
    }

    function total() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}

contract StratOptionRedeemUSDNotionalTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionRedeemUSDNotional public optionRedeem;
    StratETHLongBonds public longBonds;
    StratETHShortBonds public shortBonds;
    StratPresale public presale;

    MockTreasury public mockTreasury;
    MockOracle public ethUsdOracle;
    MockOracle public stratEthOracle;

    uint256 public tokenId;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal rando = address(0x999);

    event OptionRedeemed(address indexed optionOwner, uint256 tokenId, uint256 notionalUSDAmount, uint256 ethAmount);

    function setUp() public {
        vm.startPrank(owner);
        // Deploy tokens and mocks
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);
        mockTreasury = new MockTreasury();
        ethUsdOracle = new MockOracle(2000e8, 18, 8); // e.g., 1 ETH = 2000 USD
        stratEthOracle = new MockOracle(1e18, 18, 18); // e.g., 1 STRAT = 1 ETH

        // Deploy target contract
        optionRedeem = new StratOptionRedeemUSDNotional(
            address(cdtToken), address(stratToken), address(mockTreasury), address(ethUsdOracle), address(stratOption)
        );

        longBonds = new StratETHLongBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(mockTreasury),
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

        // Mint STRAT tokens, required for long and short bonds
        stratToken.mint(owner, 1000e18);

        // Give the treasury some initial balance
        vm.deal(address(mockTreasury), 100 ether);

        vm.stopPrank();
    }

    modifier givenTimelockPassed() {
        if (tokenId == 0) revert("No token id");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        vm.warp(option.timelock + 1);
        _;
    }

    function _warpPastExpiry(uint256 tokenId_) internal {
        if (tokenId_ == 0) revert("No token id");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId_);

        vm.warp(option.expiry + 1);
    }

    modifier givenExpiryPassed() {
        _warpPastExpiry(tokenId);
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

    modifier givenOptionSpendingApproved() {
        vm.prank(user);
        stratOption.setApprovalForAll(address(optionRedeem), true);
        _;
    }

    modifier givenPresaleOptionMinted(uint256 ethAmount_) {
        deal(user, ethAmount_);

        vm.prank(user);
        tokenId = presale.mint{value: ethAmount_}();
        _;
    }

    function _mintLongBond(uint256 ethAmount_) internal returns (uint256) {
        deal(user, ethAmount_);

        vm.prank(user);
        uint256 returnedTokenId = longBonds.bond{value: ethAmount_}(user);

        return returnedTokenId;
    }

    modifier givenLongBondMinted(uint256 ethAmount_) {
        tokenId = _mintLongBond(ethAmount_);
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

    // redeem
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
    // given the user does not have the required amount of options
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
        optionRedeem.redeem(2, 1e18);
    }

    function test_timelockActive_reverts() public givenLongBondMinted(1e18) {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.TimelockActive.selector, user, tokenId));
        optionRedeem.redeem(tokenId, 2000e18);
        vm.stopPrank();
    }

    function test_optionUnexpired_reverts() public givenLongBondMinted(1e18) givenTimelockPassed {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.OptionUnexpired.selector, user, tokenId));
        optionRedeem.redeem(tokenId, 2000e18);
        vm.stopPrank();
    }

    // TODO redeemFor

    // function test_notOptionOwner_optionNotApproved_reverts()
    //     public
    //     givenExpiryPassed
    //     givenAccountHasCDT(rando, 1000 ether)
    //     givenAccountHasApprovedCDTSpending(rando, 500 ether)
    // {
    //     // optionRedeem does not have approval to spend the option, so this reverts
    //     vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionRedeem), 1));

    //     // Call function as randoUser
    //     vm.prank(rando);
    //     optionRedeem.redeem(1);
    // }

    // function test_notOptionOwner_cdtSpendingNotApproved_reverts()
    //     public
    //     givenExpiryPassed
    //     givenAccountHasCDT(rando, 1000 ether)
    //     givenOptionSpendingApproved(1)
    // {
    //     // optionRedeem does not have approval to spend the CDT, so this reverts
    //     vm.expectRevert("ERC20: burn amount exceeds allowance");

    //     // Call function as randoUser
    //     vm.prank(rando);
    //     optionRedeem.redeem(1);
    // }

    // function test_notOptionOwner_cdtInsufficientBalance_reverts()
    //     public
    //     givenExpiryPassed
    //     givenAccountHasCDT(rando, 499 ether)
    //     givenAccountHasApprovedCDTSpending(rando, 500 ether)
    //     givenOptionSpendingApproved(1)
    // {
    //     // rando has insufficient CDT balance, so this reverts
    //     vm.expectRevert(
    //         abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, rando, 499 ether, 500 ether)
    //     );

    //     // Call function as randoUser
    //     vm.prank(rando);
    //     optionRedeem.redeem(1);
    // }

    // function test_notOptionOwner()
    //     public
    //     givenExpiryPassed
    //     givenAccountHasCDT(rando, 500 ether)
    //     givenAccountHasApprovedCDTSpending(rando, 500 ether)
    //     givenOptionSpendingApproved(1)
    // {
    //     // Expect event
    //     vm.expectEmit();
    //     emit OptionRedeemed(user, 1, 500 ether, 0.25 ether);

    //     // Call function as randoUser
    //     vm.prank(rando);
    //     optionRedeem.redeem(1);

    //     // Option should be burned
    //     assertEq(stratOption.balanceOf(user), 0, "Option should be burned");

    //     // rando's CDT should be burned
    //     assertEq(cdtToken.balanceOf(rando), 0, "rando: CDT should be burned");
    //     // user's CDT should be untouched
    //     assertEq(cdtToken.balanceOf(user), 1000 ether, "user: CDT should be untouched");

    //     // In this case: if treasury.total() * price >= totalDebt, so withdraw should be $500 of ETH at 2k / ETH
    //     assertEq(address(user).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");
    // }

    function test_cdtSpendingNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenOptionSpendingApproved
    {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);
    }

    function test_cdtInsufficientBalance_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        // Change the balance of the CDT token to be insufficient
        vm.prank(user);
        cdtToken.transfer(rando, 1);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 2000e18 - 1, 2000e18)
        );

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);
    }

    function test_optionNotApproved_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 2000e18)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(optionRedeem), user)
        );

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);
    }

    function test_insufficientOptionBalance_reverts()
        public
        givenLongBondMinted(1e18)
        givenExpiryPassed
        givenAccountHasCDT(user, 4000e18)
        givenAccountHasApprovedCDTSpending(user, 4000e18)
        givenOptionSpendingApproved
    {
        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, user, 2000e18, 4000e18, tokenId)
        );

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, 4000e18);
    }

    function test_treasuryGtDebt()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Treasury has 100e18 + 1e18 + 2e18 ETH
        // Value @ $2000/ETH is 206_000e18 USD
        // Total debt is 6000e18 CDT
        // Option owner has 6000e18 CDT
        // tokenId has redemption value of 2000e18 * 1e18 / 2000e18 = 1e18
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 1e18 / 2000e18;

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, tokenId, expectedRedemptionValue, expectedEthAmount);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be partially burned");
        assertEq(address(user).balance, expectedEthAmount, "should withdraw 1e18 ETH");
    }

    function test_treasuryGtDebt_fuzz(uint256 amount_)
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        uint256 amount = bound(amount_, 1e18, 2000e18);

        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Treasury has 100e18 + 1e18 + 2e18 ETH
        // Value @ $2000/ETH is 206_000e18 USD
        // Total debt is 6000e18 CDT
        // Option owner has 6000e18 CDT
        // tokenId has redemption value of 2000e18 * 1e18 / 2000e18 = 1e18
        uint256 expectedRedemptionValue = amount;
        uint256 expectedEthAmount = expectedRedemptionValue * 1e18 / 2000e18;

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, tokenId, expectedRedemptionValue, expectedEthAmount);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, amount);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 2000e18 - amount, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - amount, "CDT should be partially burned");
        assertEq(address(user).balance, expectedEthAmount, "should withdraw 1e18 ETH");
    }

    function test_treasuryGtDebt_oracleDecimals18()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Treasury has 100e18 + 1e18 + 2e18 ETH
        // Value @ $2000/ETH is 206_000e18 USD
        // Total debt is 6000e18 CDT
        // Option owner has 6000e18 CDT
        // tokenId has redemption value of 2000e18 * 1e18 / 2000e18 = 1e18
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 1e18 / 2000e18;

        // Set the oracle scale to 18
        ethUsdOracle.setQuoteTokenDecimals(18);
        ethUsdOracle.setPrice(2000e18);

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, tokenId, expectedRedemptionValue, expectedEthAmount);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "should withdraw 1e18 ETH");
    }

    function test_treasuryLtDebt_ethPrice1()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Set the oracle price to $1
        ethUsdOracle.setPrice(1e8); // 1 ETH = 1 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 1 USD (1e8), the treasury is valued at 103 USD (103e18)
        // Treasury USD value (103e18) is less than the USD debt (6000e18)

        // For tokenId:
        // Option owner has 2000 CDT (2000e18) and a redemption value of 2000 (2000e18)
        // Option has entitlement to 2000e18 * 103e18 / 6000e18 = 34.333333333e18 (34.333333333 USD of ETH)
        // Option owner receives 34.333333333e18 * 1e8 / 1e8 = 34.333333333e18 (34.333333333 ETH)
        uint256 expectedRedemptionValue = 2000e18;
        uint256 expectedEthAmount = expectedRedemptionValue * 103e18 / 6000e18;

        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be partially burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_treasuryLtDebt_ethPrice9()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Set the oracle price to $9
        ethUsdOracle.setPrice(9e8); // 1 ETH = 9 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e8), the treasury is valued at 927e18 USD (927e18)
        // Treasury USD value (927e18) is less than the USD debt (6000e18)

        // For tokenId:
        // Option owner has 2000 CDT (2000e18) and a notional USD value of 2000e18 (2000e18)
        // Option owner entitled to USD value of: 2000e18 * 927e18 / 6000e18 = 309e18 USD (309)
        // Option owner receives: 309e18 * 1e8 / 9e8 = 34.333333333e18 ETH (34.333333333)
        uint256 expectedRedemptionValue = 2000e18;
        uint256 usdEntitlement = expectedRedemptionValue * 927e18 / 6000e18;
        uint256 expectedEthAmount = usdEntitlement * 1e8 / 9e8;

        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_treasuryLtDebt_ethPrice9_fuzz(uint256 amount_)
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        uint256 amount = bound(amount_, 1e18, 2000e18);

        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Set the oracle price to $9
        ethUsdOracle.setPrice(9e8); // 1 ETH = 9 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e8), the treasury is valued at 927e18 USD (927e18)
        // Treasury USD value (927e18) is less than the USD debt (6000e18)

        // For tokenId:
        // Option owner has 2000 CDT (2000e18) and a notional USD value of 2000e18 (2000e18)
        // Option owner entitled to USD value of: 2000e18 * 927e18 / 6000e18 = 309e18 USD (309)
        // Option owner receives: 309e18 * 1e8 / 9e8 = 34.333333333e18 ETH (34.333333333)
        uint256 expectedRedemptionValue = amount;
        uint256 usdEntitlement = expectedRedemptionValue * 927e18 / 6000e18;
        uint256 expectedEthAmount = usdEntitlement * 1e8 / 9e8;

        vm.prank(user);
        optionRedeem.redeem(tokenId, amount);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 2000e18 - amount, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - amount, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_treasuryLtDebt_ethPrice9_oracleDecimals18()
        public
        givenLongBondMinted(1e18)
        givenAccountHasApprovedCDTSpending(user, 2000e18)
        givenOptionSpendingApproved
    {
        // Mint another long bond
        uint256 tokenId2 = _mintLongBond(2e18);

        // Warp past expiry
        _warpPastExpiry(tokenId2);

        // Set the oracle price to $9 and scale to 18
        ethUsdOracle.setQuoteTokenDecimals(18);
        ethUsdOracle.setPrice(9e18); // 1 ETH = 9 USD

        // Treasury has:
        // - 100e18 + 1e18 + 2e18 ETH (103e18)
        // - 6000 CDT debt (6000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e8), the treasury is valued at 927e18 USD (927e18)
        // Treasury USD value (927e18) is less than the USD debt (6000e18)

        // For tokenId:
        // Option owner has 2000 CDT (2000e18) and a notional USD value of 2000e18 (2000e18)
        // Option owner entitled to USD value of: 2000e18 * 927e18 / 6000e18 = 309e18 USD (309)
        // Option owner receives: 309e18 * 1e18 / 9e18 = 34.333333333e18 ETH (34.333333333)
        uint256 expectedRedemptionValue = 2000e18;
        uint256 usdEntitlement = expectedRedemptionValue * 927e18 / 6000e18;
        uint256 expectedEthAmount = usdEntitlement * 1e18 / 9e18;

        vm.prank(user);
        optionRedeem.redeem(tokenId, 2000e18);

        // Option should be burned
        assertEq(stratOption.balanceOf(user, tokenId), 0, "Option should be burned");
        // CDT should be burned
        assertEq(cdtToken.balanceOf(user), 6000e18 - expectedRedemptionValue, "CDT should be burned");
        assertEq(address(user).balance, expectedEthAmount, "incorrect ETH amount received");
    }

    function test_presaleOption_reverts() public givenPresaleOptionMinted(1e18) givenExpiryPassed {
        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.Unsupported.selector, user, tokenId));

        vm.prank(user);
        optionRedeem.redeem(tokenId, 1e18);
    }

    function test_shortBond_reverts() public givenShortBondMinted(1e18) givenExpiryPassed {
        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.Unsupported.selector, user, tokenId));

        vm.prank(user);
        optionRedeem.redeem(tokenId, 1e18);
    }
}
