// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratETHLongBonds.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import "../../../src/StratOption.sol";
import {IStratOptionMinter} from "../../../src/interfaces/IStratOptionMinter.sol";

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

    function setQuoteTokenDecimals(uint8 newQuoteTokenDecimals) public {
        quoteTokenDecimals = newQuoteTokenDecimals;
    }

    function setBaseTokenDecimals(uint8 newBaseTokenDecimals) public {
        baseTokenDecimals = newBaseTokenDecimals;
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

    // constructor
    // given the STRAT-ETH oracle decimals are not 18
    //  [X] it reverts

    function test_constructor_stratEthOracleDecimalsNot18() public {
        // Adjust the decimal scale of the STRAT-ETH oracle to 8
        stratEthOracle.setQuoteTokenDecimals(8);
        stratEthOracle.setPrice(1e8); // 1 STRAT = 1 ETH

        vm.expectRevert(abi.encodeWithSelector(StratETHLongBonds.InvalidParams.selector, "stratEthOracle"));
        new StratETHLongBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            treasuryManager,
            address(ethUsdOracle),
            address(stratEthOracle),
            1e18,
            owner
        );
    }

    // setBCV
    // given the caller is not the owner
    //  [X] it reverts
    // [X] it updates the BCV

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

    // strikePrice
    // given the STRAT-ETH price is not 1
    //  [X] the strike price is calculated correctly
    // [X] the strike price is calculated correctly

    function test_strikePrice_notEqual() public {
        // Adjust the STRAT-ETH price
        stratEthOracle.setPrice(1.1e18); // 1.1 ETH/STRAT

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

    function test_strikePrice() public view {
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

    // bond
    // when no ETH is sent
    //  [X] it reverts
    // given the ETH-USD oracle decimals are 18
    //  [X] the strike amount is calculated correctly
    //  [X] the notional underlying amount is calculated correctly
    //  [X] the CDT balance of the user is the notional USD amount
    //  [X] the expiry is 4.2 years from now
    //  [X] the timelock is 69 minutes from now
    //  [X] the owner of the option is the bonder
    //  [X] the treasury receives the ETH
    // [X] the strike amount is calculated correctly
    // [X] the notional underlying amount is calculated correctly
    // [X] the CDT balance of the user is the notional USD amount
    // [X] the expiry is 4.2 years from now
    // [X] the timelock is 69 minutes from now
    // [X] the owner of the option is the bonder
    // [X] the treasury receives the ETH

    function test_bond_noETH() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(StratETHLongBonds.InvalidParams.selector, "msg.value"));
        bonds.bond(user);
    }

    function test_bond() public {
        uint256 ethAmount = 1 ether;

        // Get the strike price
        uint256 ethUsdValue = ethAmount * ethUsdOracle.price() / 1e8; // ETH -> USD conversion
        uint256 expectedStrikePrice = bonds.strikePrice(ethUsdValue);

        vm.deal(user, ethAmount); // Give ETH to user
        vm.prank(user);
        // Run bond function
        uint256 tokenId = bonds.bond{value: ethAmount}(user);

        // Check treasury receives money
        assertEq(treasuryManager.balance, ethAmount, "Treasury did not receive the correct ETH amount");

        // Verify the CDT balance of the user
        assertEq(cdtToken.balanceOf(user), ethUsdValue, "User CDT balance incorrect");

        // Balance = STRAT output when exercised
        assertEq(stratOption.balanceOf(user, tokenId), 999500249875062468, "Incorrect balance");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        // Strike price
        assertEq(option.strikePrice, expectedStrikePrice, "Incorrect strike price");

        // Redemption price
        assertEq(option.redemptionPrice, expectedStrikePrice, "Incorrect redemption price");

        // Expiry
        assertEq(option.expiry, block.timestamp + (4.2 * 365 days), "Incorrect expiry");

        // Timelock
        assertEq(option.timelock, block.timestamp + 69 minutes, "Incorrect timelock");
    }

    function test_bond_ethUsdOracleDecimals18() public {
        // Adjust the decimal scale of the ETH-USD oracle to 18
        ethUsdOracle.setQuoteTokenDecimals(18);
        ethUsdOracle.setPrice(3000e18); // 1 ETH = 1 USD

        // Create a new contract
        vm.startPrank(owner);
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
        cdtToken.manageMinter(address(bonds), true);
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();

        uint256 ethAmount = 1 ether;

        // Get the strike price
        uint256 ethUsdValue = ethAmount * 3000e18 / 1e18; // ETH -> USD conversion
        uint256 expectedStrikePrice = bonds.strikePrice(ethUsdValue);

        vm.deal(user, ethAmount); // Give ETH to user
        vm.prank(user);
        // Run bond function
        uint256 tokenId = bonds.bond{value: ethAmount}(user);

        // Check treasury receives money
        assertEq(treasuryManager.balance, ethAmount, "Treasury did not receive the correct ETH amount");

        // Verify the CDT balance of the user
        assertEq(cdtToken.balanceOf(user), ethUsdValue, "User CDT balance incorrect");

        // Balance = STRAT output when exercised
        uint256 balance = stratOption.balanceOf(user, tokenId);
        assertEq(balance, 999500249875062468, "Incorrect balance");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        // Strike price
        assertEq(option.strikePrice, expectedStrikePrice, "Incorrect strike price");

        // Balance * strike price = USD value
        assertEq(balance * option.strikePrice / 1e18, ethUsdValue, "Incorrect strike amount");

        // Redemption price
        assertEq(option.redemptionPrice, expectedStrikePrice, "Incorrect redemption price");

        // Balance * redemption price = USD value
        assertEq(balance * option.redemptionPrice / 1e18, ethUsdValue, "Incorrect redemption amount");

        // Expiry
        assertEq(option.expiry, block.timestamp + (4.2 * 365 days), "Incorrect expiry");

        // Timelock
        assertEq(option.timelock, block.timestamp + 69 minutes, "Incorrect timelock");
    }

    function testBondDataInvariants() public {
        uint256 previousTokenId;

        for (uint256 i = 0; i < 10; i++) {
            // Bond 1 ETH
            vm.deal(user, 1 ether);
            vm.prank(user);
            uint256 tokenId = bonds.bond{value: 1 ether}(user);

            if (i == 0) {
                previousTokenId = tokenId;
                continue;
            }

            IStratOptionMinter.Option memory currentOption = stratOption.getOption(tokenId);
            IStratOptionMinter.Option memory previousOption = stratOption.getOption(previousTokenId);

            // Strike price increases
            assertGt(currentOption.strikePrice, previousOption.strikePrice, "Strike price should increase");

            // STRAT output should decrease as the strike price increases
            uint256 currentBalance = stratOption.balanceOf(user, tokenId);
            uint256 previousBalance = stratOption.balanceOf(user, previousTokenId);
            assertLt(
                currentBalance, previousBalance, "Each subsequent bond should have less STRAT output than the previous"
            );

            // Strike amount is the same
            assertEq(
                currentOption.strikePrice * currentBalance / 1e18,
                previousOption.strikePrice * previousBalance / 1e18,
                "Strike amount should be the same"
            );

            // Redemption amount is the same
            assertEq(
                currentOption.redemptionPrice * currentBalance / 1e18,
                previousOption.redemptionPrice * previousBalance / 1e18,
                "Redemption amount should be the same"
            );

            previousTokenId = tokenId;
        }
    }

    function testStrikeChangesWhenOracleChanges() public {
        // Bond 1 ETH
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 tokenIdOne = bonds.bond{value: 1 ether}(user);

        // Bond 1 more ETH, after eth price goes up to $4000
        ethUsdOracle.setPrice(4000e8);
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 tokenIdTwo = bonds.bond{value: 1 ether}(user);

        IStratOptionMinter.Option memory optionOne = stratOption.getOption(tokenIdOne);
        IStratOptionMinter.Option memory optionTwo = stratOption.getOption(tokenIdTwo);

        // strike price should increase with the increase in ETH price
        assertLt(optionOne.strikePrice, optionTwo.strikePrice, "ETH price increase should increase strike price");

        // Changes in STRAT/ETH price don't change the notional USD (but the calculated strike price should move about)
        uint256 strikeBeforePriceChange = bonds.strikePrice(0);
        stratEthOracle.setPrice(1.5e18);
        uint256 strikeAfterPriceChange = bonds.strikePrice(0);
        assertLt(
            strikeBeforePriceChange,
            strikeAfterPriceChange,
            "STRAT price increase should increase the bond strike per strat"
        );

        // Bond 1 more ETH, after STRAT/ETH price goes up to 1.5 ETH/STRAT
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 tokenIdThree = bonds.bond{value: 1 ether}(user);
        IStratOptionMinter.Option memory optionThree = stratOption.getOption(tokenIdThree);
        uint256 balanceTwo = stratOption.balanceOf(user, tokenIdTwo);
        uint256 balanceThree = stratOption.balanceOf(user, tokenIdThree);

        // Redemption amount should be the same
        assertEq(
            optionTwo.redemptionPrice * balanceTwo / 1e18,
            optionThree.redemptionPrice * balanceThree / 1e18,
            "STRAT price increase shouldn't effect redemption amount"
        );

        strikeBeforePriceChange = bonds.strikePrice(0);
        stratEthOracle.setPrice(0.5e18);
        strikeAfterPriceChange = bonds.strikePrice(0);
        assertLt(
            strikeAfterPriceChange,
            strikeBeforePriceChange,
            "STRAT price decrease should decrease the bond strike per strat"
        );

        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 tokenIdFour = bonds.bond{value: 1 ether}(user);
        IStratOptionMinter.Option memory optionFour = stratOption.getOption(tokenIdFour);
        uint256 balanceFour = stratOption.balanceOf(user, tokenIdFour);

        // Redemption amount should be the same
        assertEq(
            optionThree.redemptionPrice * balanceThree / 1e18,
            optionFour.redemptionPrice * balanceFour / 1e18,
            "STRAT price decrease shouldn't effect redemption amount"
        );

        // Bond 1 more ETH, after ETH/USD price goes down to $3000
        ethUsdOracle.setPrice(3000e8);
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 tokenIdFive = bonds.bond{value: 1 ether}(user);
        IStratOptionMinter.Option memory optionFive = stratOption.getOption(tokenIdFive);
        uint256 balanceFive = stratOption.balanceOf(user, tokenIdFive);

        assertGt(balanceFour, balanceFive, "ETH price decrease should decrease total STRAT output");
    }
}
