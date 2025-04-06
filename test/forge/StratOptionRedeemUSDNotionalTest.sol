// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratOptionRedeemUSDNotional.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/interfaces/ITreasury.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

contract MockTreasury is ITreasury {
    function withdraw(uint256 amount, address to) external {
        payable(to).transfer(amount);
    }

    function total() external view returns (uint256) {
        return address(this).balance;
    }
}

contract StratOptionRedeemUSDNotionalTest is Test {
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;
    StratOptionRedeemUSDNotional public optionRedeem;

    MockTreasury public mockTreasury;
    MockOracle public mockOracle;

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
        mockOracle = new MockOracle(2000e8, 18, 8); // e.g., 1 ETH = 2000 USD

        // Deploy target contract
        optionRedeem = new StratOptionRedeemUSDNotional(
            address(cdtToken), address(stratToken), address(mockTreasury), address(mockOracle), address(stratOption)
        );

        // Enable minting
        cdtToken.manageMinter(owner, true);
        stratToken.manageMinter(owner, true);
        stratOption.manageMinter(owner, true);

        // Give the treasury some initial balance
        vm.deal(address(mockTreasury), 100 ether);

        // Mint user some CDT, and mint an option with a notionalUSD of 500
        cdtToken.mint(user, 1000 ether);
        stratOption.mint(user, 0, 0, 500 ether, block.timestamp + 3600, block.timestamp + 1800);

        vm.stopPrank();
    }

    modifier givenExpiryPassed() {
        vm.warp(block.timestamp + 3601);
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
    // given the option is from the presale
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

    function test_timelockActive_reverts() public {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.TimelockActive.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function test_optionUnexpired_reverts() public {
        // before expiry, after timelock
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.OptionUnexpired.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function test_notOptionOwner_optionNotApproved_reverts()
        public
        givenExpiryPassed
        givenAccountHasCDT(rando, 1000 ether)
        givenAccountHasApprovedCDTSpending(rando, 500 ether)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionRedeem), 1));

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_notOptionOwner_cdtSpendingNotApproved_reverts()
        public
        givenExpiryPassed
        givenAccountHasCDT(rando, 1000 ether)
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
        givenExpiryPassed
        givenAccountHasCDT(rando, 499 ether)
        givenAccountHasApprovedCDTSpending(rando, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // rando has insufficient CDT balance, so this reverts
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, rando, 499 ether, 500 ether)
        );

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_notOptionOwner()
        public
        givenExpiryPassed
        givenAccountHasCDT(rando, 500 ether)
        givenAccountHasApprovedCDTSpending(rando, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, 1, 500 ether, 0.25 ether);

        // Call function as randoUser
        vm.prank(rando);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");

        // rando's CDT should be burned
        assertEq(cdtToken.balanceOf(rando), 0, "rando: CDT should be burned");
        // user's CDT should be untouched
        assertEq(cdtToken.balanceOf(user), 1000 ether, "user: CDT should be untouched");

        // In this case: if treasury.total() * price >= totalDebt, so withdraw should be $500 of ETH at 2k / ETH
        assertEq(address(user).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");
    }

    function test_cdtSpendingNotApproved_reverts() public givenExpiryPassed givenOptionSpendingApproved(1) {
        // optionRedeem does not have approval to spend the CDT, so this reverts
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_cdtInsufficientBalance_reverts()
        public
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Change the balance of the CDT token
        vm.prank(user);
        cdtToken.transfer(rando, 501 ether);

        // Expect revert
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 499 ether, 500 ether)
        );

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_optionNotApproved_reverts()
        public
        givenExpiryPassed
        givenAccountHasCDT(user, 500 ether)
        givenAccountHasApprovedCDTSpending(user, 500 ether)
    {
        // optionRedeem does not have approval to spend the option, so this reverts
        vm.expectRevert(abi.encodeWithSelector(StratOption.NotOwnerOrApproved.selector, address(optionRedeem), 1));

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);
    }

    function test_treasuryGtDebt()
        public
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, 1, 500 ether, 0.25 ether);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        // CDT should be partially burned
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price >= totalDebt, so withdraw should be $500 of ETH at 2k / ETH
        assertEq(address(user).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");
    }

    function test_treasuryGtDebt_oracleDecimals18()
        public
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Set the oracle scale to 18
        mockOracle.setQuoteTokenDecimals(18);
        mockOracle.setPrice(2000e18);

        // Expect event
        vm.expectEmit();
        emit OptionRedeemed(user, 1, 500 ether, 0.25 ether);

        // Call function as the option owner
        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        // CDT should be partially burned
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price >= totalDebt, so withdraw should be $500 of ETH at 2k / ETH
        assertEq(address(user).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");
    }

    function test_treasuryLtDebt_ethPrice1()
        public
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Set the oracle price to $1
        mockOracle.setPrice(1e8); // 1 ETH = 1 USD

        // Treasury has:
        // - 100 ETH (100e18)
        // - 1000 CDT debt (1000e18)
        //
        // At 1 ETH (1e18) = 1 USD (1e8), the treasury is valued at 100 USD (100e18)
        // Treasury USD value (100e18) is less than the USD debt (1000e18)

        // Option owner has 1000 CDT (1000e18) and a notional USD value of 500 (500e18)
        // Option owner receives 500e18 * 100e18 / 1000e18 = 50e18 (50 ETH)

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        // CDT should be partially burned
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price < totalDebt, so withdraw should be half of treasury
        // (500 CDT out of a total of 1k CDT)
        assertEq(address(user).balance, 50 ether, "should withdraw half of all ETH in treasury");
    }

    function test_treasuryLtDebt_ethPrice9()
        public
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Set the oracle price to $9
        mockOracle.setPrice(9e8); // 1 ETH = 9 USD

        // Treasury has:
        // - 100 ETH (100e18)
        // - 1000 CDT debt (1000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e8), the treasury is valued at 900 USD (900e18)
        // Treasury USD value (900e18) is less than the USD debt (1000e18)

        // Option owner has 1000 CDT (1000e18) and a notional USD value of 500 (500e18)
        // Option owner entitled to USD value of: 500e18 * 900e18 / 1000e18 = 450e18 USD (450)
        // Option owner receives: 450e18 * 1e8 / 9e8 = 50e18 ETH (50)

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        // CDT should be partially burned
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price < totalDebt, so withdraw should be half of treasury
        // (500 CDT out of a total of 1k CDT)
        assertEq(address(user).balance, 50 ether, "should withdraw half of all ETH in treasury");
    }

    function test_treasuryLtDebt_ethPrice9_oracleDecimals18()
        public
        givenExpiryPassed
        givenAccountHasApprovedCDTSpending(user, 500 ether)
        givenOptionSpendingApproved(1)
    {
        // Set the oracle price to $9 and scale to 18
        mockOracle.setQuoteTokenDecimals(18);
        mockOracle.setPrice(9e18); // 1 ETH = 9 USD

        // Treasury has:
        // - 100 ETH (100e18)
        // - 1000 CDT debt (1000e18)
        //
        // At 1 ETH (1e18) = 9 USD (9e18), the treasury is valued at 900 USD (900e18)
        // Treasury USD value (900e18) is less than the USD debt (1000e18)

        // Option owner has 1000 CDT (1000e18) and a notional USD value of 500 (500e18)
        // Option owner entitled to USD value of: 500e18 * 900e18 / 1000e18 = 450e18 USD (450)
        // Option owner receives: 450e18 * 1e8 / 9e8 = 50e18 ETH (50)

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(1);

        // Option should be burned
        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        // CDT should be partially burned
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price < totalDebt, so withdraw should be half of treasury
        // (500 CDT out of a total of 1k CDT)
        assertEq(address(user).balance, 50 ether, "should withdraw half of all ETH in treasury");
    }

    function test_presaleOption_reverts() public {
        // Create a presale option with no underlying USD amount
        vm.prank(owner);
        stratOption.mint(user, 1000 ether, 1000 ether, 0, block.timestamp + 3600, block.timestamp + 1800);

        // Warp to after expiry
        vm.warp(block.timestamp + 3601);

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.Unsupported.selector, user, 2));

        vm.prank(user);
        optionRedeem.redeemCdtForUsdNotional(2);
    }
}
