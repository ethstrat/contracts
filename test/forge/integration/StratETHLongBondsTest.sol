// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratETHLongBonds.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import "../../../src/StratOption.sol";

contract MockOracle {
    uint256 private _price;

    constructor(uint256 initialPrice) {
        _price = initialPrice;
    }

    function setPrice(uint256 newPrice) public {
        _price = newPrice;
    }

    function price() external view returns (uint256) {
        return _price;
    }
}

contract StratETHLongBondsTest is Test {
    StratETHLongBonds public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;

    // Mock oracles are defined directly here
    MockOracle public ethUsdOracle;
    MockOracle public stratEthOracle;

    address internal owner = address(0x123);
    address internal treasuryManager = address(0x456);
    address internal user = address(0x789);

    function setUp() public {
        // Deploy the real contracts
        vm.prank(owner);
        cdtToken = new CdtToken(owner);
        vm.prank(owner);
        stratToken = new StratToken(owner);
        vm.prank(owner);
        stratOption = new StratOption(owner);

        // Deploy mock oracles
        ethUsdOracle = new MockOracle(3000e8); // ETH price: $3000
        stratEthOracle = new MockOracle(1e18); // Strat price: 1 ETH
        vm.prank(owner);
        // Deploy the StratETHLongBonds contract
        bonds = new StratETHLongBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            treasuryManager,
            address(ethUsdOracle),
            address(stratEthOracle),
            1, // BCV
            owner
        );

        vm.prank(owner);
        cdtToken.manageMinter(address(this), true); // Allow this test contract to mint CDT
        vm.prank(owner);
        stratToken.manageMinter(address(this), true); // Allow this test contract to mint stratToken

        // Mint tokens to initialize the supply (So it's non-zero)
        cdtToken.mint(address(this), 1000);
        stratToken.mint(address(this), 1000);

        // Give bonding contract ability to mint CDT and StratOption
        vm.prank(owner);
        cdtToken.manageMinter(address(bonds), true);
        vm.prank(owner);
        stratOption.manageMinter(address(bonds), true);
    }

    function testOnlyOwnerCanSetBCV() public {
        // A non-owner attempting to change BCV should fail
        vm.prank(user);
        vm.expectRevert();
        bonds.setBCV(5); // Should revert because user is not the owner

        // A owner attempting to change BCV should suceed
        vm.prank(owner);
        bonds.setBCV(5);
        assertEq(bonds.bcv(), 5, "BCV should be updated to 5000");
    }

    function testBondRevertIfNoETHSent() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        bonds.bond(user); // Should revert because no ETH is sent
    }

    function testStrikePrice() public {
        uint256 notionalUSDAmount = 3000e18;

        // Calculate expected strike price
        uint256 stratPrice = (stratEthOracle.price() * ethUsdOracle.price()) / 1e18;
        uint256 ratio = ((cdtToken.totalSupply() + (notionalUSDAmount / 2)) * bonds.SCALE()) / stratToken.totalSupply();
        uint256 debtToMc = (ratio * stratPrice) / bonds.SCALE();
        uint256 expectedStrikePrice = stratPrice * bonds.bcv() * debtToMc;

        uint256 calculatedStrikePrice = bonds.strikePrice(notionalUSDAmount);

        assertEq(calculatedStrikePrice, expectedStrikePrice, "Strike price calculation is incorrect");
    }

    function testBond() public {
        uint256 ethAmount = 1 ether;
        uint256 treasuryBalanceBefore = treasuryManager.balance;

        vm.deal(user, ethAmount); // Give ETH to user
        vm.prank(user);
        // Run bond function
        bonds.bond{value: ethAmount}(user);

        // Check treasury receives money
        uint256 treasuryBalanceAfter = treasuryManager.balance;
        assertEq(
            treasuryBalanceAfter - treasuryBalanceBefore, ethAmount, "Treasury did not receive the correct ETH amount"
        );

        // Verify the CDT balance of the user
        uint256 expectedCdUSDAmount = (ethAmount * ethUsdOracle.price()) / 1e8; // ETH -> USD conversion
        assertEq(cdtToken.balanceOf(user), expectedCdUSDAmount, "User CDT balance incorrect");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option
        uint256 expectedStrikeAmount = expectedCdUSDAmount;
        uint256 expectedNotionalUnderlying =
            (expectedCdUSDAmount * bonds.SCALE()) / bonds.strikePrice(expectedCdUSDAmount);

        assertEq(stratOption.strikeAmount(tokenId), expectedStrikeAmount, "Incorrect strike amount");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId),
            expectedNotionalUnderlying,
            "Incorrect notional underlying amount"
        );
        assertEq(stratOption.notionalUSDAmount(tokenId), expectedCdUSDAmount, "Incorrect notional USD amount");

        // Verify expiry and timelock values
        uint256 expectedExpiry = block.timestamp + (420 * 365 days);
        uint256 expectedTimelock = block.timestamp + 69 minutes;
        assertEq(stratOption.expiry(tokenId), expectedExpiry, "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), expectedTimelock, "Incorrect timelock");
    }
}
