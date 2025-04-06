// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratOptionRedeemUSDNotional.sol";
import "../../src/StratOption.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/interfaces/ITreasury.sol";

contract MockTreasury is ITreasury {
    function withdraw(uint256 amount, address to) external {
        payable(to).transfer(amount);
    }

    function total() external view returns (uint256) {
        return address(this).balance;
    }
}

contract MockOracle is IOracle {
    uint256 public price;
    uint8 public baseTokenDecimals = 18;
    uint8 public quoteTokenDecimals = 8;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
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

    function setUp() public {
        vm.startPrank(owner);
        // Deploy tokens and mocks
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);
        mockTreasury = new MockTreasury();
        mockOracle = new MockOracle(2000e8); // e.g., 1 ETH = 2000 USD

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

    function testRedeemSuccessTreasuryGtDebt() public {
        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        vm.startPrank(user);

        cdtToken.approve(address(optionRedeem), 500 ether);
        stratOption.approve(address(optionRedeem), 1);

        optionRedeem.redeemCdtForUsdNotional(1);

        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price >= totalDebt, so withdraw should be $500 of ETH at 2k / ETH
        assertEq(address(user).balance, 0.25 ether, "should withdraw $500 of ETH (0.25 ETH)");

        vm.stopPrank();
    }

    function testRedeemSuccessTreasuryLtDebt() public {
        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);

        vm.prank(owner);
        mockOracle.setPrice(0.5e8);

        vm.startPrank(user);

        cdtToken.approve(address(optionRedeem), 500 ether);
        stratOption.approve(address(optionRedeem), 1);

        optionRedeem.redeemCdtForUsdNotional(1);

        assertEq(stratOption.balanceOf(user), 0, "Option should be burned");
        assertEq(cdtToken.balanceOf(user), 500 ether, "CDT should be partially burned");
        // In this case: if treasury.total() * price < totalDebt, so withdraw should be half of treasury
        // (500 CDT out of a total of 1k CDT)
        assertEq(address(user).balance, 50 ether, "should withdraw half of all ETH in treasury");

        vm.stopPrank();
    }

    function testRevertIfTimelockActive() public {
        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.TimelockActive.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function testRevertIfOptionUnexpired() public {
        // before expiry, after timelock
        vm.warp(block.timestamp + 1801);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(StratOptionRedeemUSDNotional.OptionUnexpired.selector, user, 1));
        optionRedeem.redeemCdtForUsdNotional(1);
        vm.stopPrank();
    }

    function testRevertIfNotOptionOwner() public {
        // Advance time beyond timelock and expiry
        vm.warp(block.timestamp + 3601);
        address randoUser = address(0x999);

        vm.prank(owner);
        cdtToken.mint(randoUser, 1000 ether);

        // Prank some random user
        vm.startPrank(randoUser);
        cdtToken.approve(address(optionRedeem), 500 ether);

        vm.expectRevert();
        optionRedeem.redeemCdtForUsdNotional(1);

        vm.stopPrank();
    }
}
