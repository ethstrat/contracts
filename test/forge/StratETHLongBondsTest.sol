// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratETHLongBonds.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/StratOption.sol";
import "../../src/interfaces/ITreasury.sol";
import "../mocks/MockTreasury.sol";
import {EthUsdPriceOracleProvider} from "../lib/EthUsdPriceOracleProvider.sol";

contract StratETHLongBondsTest is Test, EthUsdPriceOracleProvider {
    StratETHLongBonds public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;

    // Mocks
    MockTreasury public treasury;

    address internal owner = address(0x123);
    address internal user = address(0x789);

    /// @dev ETH price: $3000
    uint256 internal _ETH_USD_INITIAL_PRICE = 3000e18;

    function setUp() public {
        // mocks
        _setUpEthUsdOracle(_ETH_USD_INITIAL_PRICE);
        treasury = new MockTreasury();

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
            address(treasury),
            address(treasury),
            address(ethUsdOracle),
            1e18, // PCF
            1e18, // GCF
            owner
        );

        stratToken.manageMinter(owner, true);

        // Mint tokens to initialize the supply (So it's non-zero)
        stratToken.mint(address(this), 10_000 ether);
        vm.deal(address(treasury), 1 ether);

        // Give bonding contract ability to mint CDT and StratOption
        cdtToken.manageMinter(address(bonds), true);
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();
    }

    function testOnlyOwnerCanSetPCF() public {
        // A non-owner attempting to change BCV should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user)));
        bonds.setPCF(5); // Should revert because user is not the owner

        // A owner attempting to change BCV should suceed
        vm.prank(owner);
        bonds.setPCF(5);
        assertEq(bonds.pcf(), 5, "PCF should be updated to 5000");
    }

    function testOnlyOwnerCanSetGCF() public {
        // A non-owner attempting to change GCF should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user)));
        bonds.setGCF(5); // Should revert because user is not the owner

        // An owner attempting to change GCF should succeed
        vm.prank(owner);
        bonds.setGCF(5);
        assertEq(bonds.gcf(), 5, "GCF should be updated to 5");
    }

    function testBondRevertIfNoETHSent() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(StratETHLongBonds.NoEthSent.selector));
        bonds.bond(user, 1 ether, block.timestamp + 1 hours);
    }

    function testBondRevertIfBonderAddressIsZero() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(StratETHLongBonds.ZeroAddress.selector));
        bonds.bond{value: 1 ether}(address(0), 1 ether, block.timestamp + 1 hours);
    }

    function testStrikePrice() public view {
        uint256 notionalUSDAmount = 3000e18;

        // Expected strike with no CDT, 1 ETH in treasury and 10k STRAT (without scaling) is
        //   (3000 + (3000 / 2)) / 10_000
        // = 0.45
        uint256 expectedStrikePrice = 0.45 ether;
        uint256 calculatedStrikePrice = bonds.strikePrice(notionalUSDAmount);
        assertEq(calculatedStrikePrice, expectedStrikePrice, "Strike price calculation is incorrect");
    }

    function testFuzz_strikePriceWithPCFandGCFupdates(uint256 pcf, uint256 gcf) public {
        pcf = bound(pcf, 1.5e18, 2e18);
        gcf = bound(gcf, 0.5e18, 1e18);

        // Update PCF and GCF using the owner account
        vm.startPrank(owner);
        bonds.setPCF(pcf);
        bonds.setGCF(gcf);
        vm.stopPrank();

        uint256 notionalUSDAmount = 3000e18;
        // Expected strike price calculation:
        //  =  (gav * GCF / stratSupply) + (PCF * (debt/gav) * (gav/stratSupply))
        //  =  (gav * GCF / stratSupply) + (PCF * debt / stratSupply) # cancel gav
        //  =  (gav * GCF + PCF * debt) / stratSupply
        // substituting the values for gav (1) eth price (3k) and strat supply (10k) and no starting debt, we get
        //  =  (3000 * 1 * GCF + PCF * 1500) / 10_000
        uint256 expectedStrikePrice = (3000e18 * gcf + pcf * (notionalUSDAmount / 2)) / 10_000e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(notionalUSDAmount);

        assertEq(calculatedStrikePrice, expectedStrikePrice, "Strike price calculation is incorrect");
    }

    function testBond() public {
        vm.deal(user, 1 ether); // Give ETH to user
        vm.prank(user);
        // Run bond function
        bonds.bond{value: 1 ether}(user, 0.5 ether, block.timestamp + 1 hours);

        // Check treasury receives money
        assertEq(treasury.total(), 2 ether, "Treasury did not receive the correct ETH amount");

        // Verify the CDT balance of the user
        uint256 expectedCdUSDAmount = (1 ether * _ETH_USD_INITIAL_PRICE) / 1e18; // ETH -> USD conversion
        assertEq(cdtToken.balanceOf(user), expectedCdUSDAmount, "User CDT balance incorrect");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option
        uint256 expectedStrikeAmount = expectedCdUSDAmount;

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), expectedStrikeAmount, "Incorrect strike amount");
        assertApproxEqAbs(
            stratOption.notionalUnderlyingAmount(tokenId),
            6666.6666666 ether,
            1e12, // acceptable delta in wei (0.000001 ether)
            "Incorrect notional underlying amount"
        );

        assertEq(stratOption.notionalUSDAmount(tokenId), expectedCdUSDAmount, "Incorrect notional USD amount");
        assertEq(stratOption.expiry(tokenId), block.timestamp + (4.2 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");

        // Confirm bond is accreative w.r.t the treasury
        assertLt(
            stratOption.notionalUnderlyingAmount(tokenId),
            10_000 ether,
            "given the unit bias of 1 ETH is 10k STRAT, bond should always be less than 10k STRAT for a 1 ETH notional"
        );
    }

    function testBondDataInvariants() public {
        for (uint256 i = 0; i < 10; i++) {
            // Bond 1 ETH
            vm.deal(user, 1 ether);
            vm.prank(user);
            bonds.bond{value: 1 ether}(user, 0, block.timestamp + 1 hours);

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
        bonds.bond{value: 1 ether}(user, 0, block.timestamp + 1 hours);

        // Bond 1 more ETH, after eth price goes up to $4000
        ethUsdOracle.setBasePerQuote(4000e18);
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user, 0, block.timestamp + 1 hours);

        // strike price should be different between the two (goes up)
        assertLt(
            stratOption.strikeAmount(1),
            stratOption.strikeAmount(2),
            "ETH price increase should increase total strike amount"
        );

        // Bond 1 more ETH, after ETH/USD price goes down to $3000
        ethUsdOracle.setBasePerQuote(3000e18);
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user, 0, block.timestamp + 1 hours);
        assertGt(
            stratOption.strikeAmount(2),
            stratOption.strikeAmount(3),
            "ETH price decrease should decrease total strike amount"
        );
    }
}
