// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratETHLongBonds.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import "../../../src/StratOption.sol";

contract MockOracle {
    uint256 private _price;
    uint8 public baseTokenDecimals;
    uint8 public quoteTokenDecimals;

    constructor(uint256 initialPrice, uint8 _baseTokenDecimals, uint8 _quoteTokenDecimals) {
        _price = initialPrice;
        baseTokenDecimals = _baseTokenDecimals;
        quoteTokenDecimals = _quoteTokenDecimals;
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
        // Deploy mock oracles
        ethUsdOracle = new MockOracle(3000e8, 18, 8); // ETH price: $3000
        stratEthOracle = new MockOracle(1e18, 18, 18); // Strat price: 1 ETH

        // Deploy the real contracts
        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);

        // Deploy the StratETHLongBonds contract
        bonds = new StratETHLongBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            treasuryManager,
            address(ethUsdOracle),
            address(stratEthOracle),
            1e18, // BCV
            owner
        );

        stratToken.manageMinter(owner, true);

        // Mint tokens to initialize the supply (So it's non-zero)
        stratToken.mint(address(this), 1000e18);

        // Give bonding contract ability to mint CDT and StratOption
        cdtToken.manageMinter(address(bonds), true);
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();
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

        uint256 stratPrice = (stratEthOracle.price() * ethUsdOracle.price()) / 1e8; // 18 DP

        // Expected strike with no CDT and 1000 STRAT (without scaling) is
        //   STRAT_PRICE + ((3000 / 2 / (1000 * STRAT_PRICE)) * bcv * STRAT_PRICE)
        // = STRAT_PRICE + ((1500 / (1000 * STRAT_PRICE)) * bcv * STRAT_PRICE)
        // = STRAT_PRICE + ((1500 / 1000) * bcv)
        // = STRAT_PRICE + 1.5 * bcv
        // given BCV is 1, the strike price should be STRAT_PRICE + 1.5
        uint256 expectedStrikePrice = stratPrice + 1.5e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(notionalUSDAmount);
        assertEq(calculatedStrikePrice, expectedStrikePrice, "Strike price calculation is incorrect");
    }

    function testBond() public {
        uint256 ethAmount = 1 ether;

        vm.deal(user, ethAmount); // Give ETH to user
        vm.prank(user);
        // Run bond function
        bonds.bond{value: ethAmount}(user);

        // Check treasury receives money
        assertEq(treasuryManager.balance, ethAmount, "Treasury did not receive the correct ETH amount");

        // Verify the CDT balance of the user
        uint256 expectedCdUSDAmount = (ethAmount * ethUsdOracle.price()) / 1e8; // ETH -> USD conversion
        assertEq(cdtToken.balanceOf(user), expectedCdUSDAmount, "User CDT balance incorrect");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option
        uint256 expectedStrikeAmount = expectedCdUSDAmount;

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), expectedStrikeAmount, "Incorrect strike amount");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId), 999500249875062468, "Incorrect notional underlying amount"
        );
        assertLt(
            stratOption.notionalUnderlyingAmount(tokenId),
            stratEthOracle.price(),
            "Should be less than current spot price for strat"
        );
        assertEq(stratOption.notionalUSDAmount(tokenId), expectedCdUSDAmount, "Incorrect notional USD amount");
        assertEq(stratOption.expiry(tokenId), block.timestamp + (4.2 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 69 minutes, "Incorrect timelock");
    }

    function testBondDataInvariants() public {
        for (uint256 i = 0; i < 10; i++) {
            // Bond 1 ETH
            vm.deal(user, 1 ether);
            vm.prank(user);
            bonds.bond{value: 1 ether}(user);

            if (i == 0) {
                continue;
            }

            assertGt(
                stratOption.notionalUnderlyingAmount(i),
                stratOption.notionalUnderlyingAmount(i + 1),
                "Each subsequent bond should have less notional than the previous"
            );
            assertEq(
                stratOption.strikeAmount(i),
                stratOption.strikeAmount(i + 1),
                "Strike should be the same, as we are bonding the same amount of ETH each time (and the oracle isn't changing)"
            );
            assertEq(
                stratOption.notionalUSDAmount(i),
                stratOption.strikeAmount(i + 1),
                "Debt should be the same, as we are bonding the same amount of ETH each time (and the oracle isn't changing)"
            );
        }
    }

    function testStrikeChangesWhenOracleChanges() public {
        // Bond 1 ETH
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user);

        // Bond 1 more ETH, after eth price goes up to $4000
        ethUsdOracle.setPrice(4000e8);
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user);

        // strike price should be different between the two (goes up)
        assertLt(
            stratOption.strikeAmount(1),
            stratOption.strikeAmount(2),
            "ETH price increase should increase total strike amount"
        );

        // Changes in STRAT/ETH price don't change the notional USD (but the calculated strike price should move about)
        uint256 strikeBeforePriceChange = bonds.strikePrice(0);
        stratEthOracle.setPrice(1.5e18);
        uint256 strikeAfterPriceChange = bonds.strikePrice(0);
        assertLt(
            strikeBeforePriceChange,
            strikeAfterPriceChange,
            "STRAT price increase should increase the bond strike per strat"
        );

        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user);
        assertEq(
            stratOption.notionalUSDAmount(2),
            stratOption.notionalUSDAmount(3),
            "STRAT price increase shouldn't effect notional USD"
        );

        strikeBeforePriceChange = bonds.strikePrice(0);
        stratEthOracle.setPrice(0.5e18);
        strikeAfterPriceChange = bonds.strikePrice(0);
        assertGt(
            strikeBeforePriceChange,
            strikeAfterPriceChange,
            "STRAT price decrease should decrease the bond strike per strat"
        );

        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user);
        assertEq(
            stratOption.notionalUSDAmount(3),
            stratOption.notionalUSDAmount(4),
            "STRAT price decrease shouldn't effect notional USD"
        );

        // Bond 1 more ETH, after ETH/USD price goes down to $3000
        ethUsdOracle.setPrice(3000e8);
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user);
        assertGt(
            stratOption.strikeAmount(4),
            stratOption.strikeAmount(5),
            "ETH price decrease should decrease total strike amount"
        );
    }
}
