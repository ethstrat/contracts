// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratETHShortBonds.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/StratOption.sol";

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

contract StratETHShortBondsTest is Test {
    StratETHShortBonds public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;

    // Mock oracles are defined directly here
    MockOracle public ethUsdOracle;
    MockOracle public stratEthOracle;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal bondConverter = address(0x989);

    function setUp() public {
        // Deploy mock oracles
        ethUsdOracle = new MockOracle(3000e8, 18, 8); // ETH price: $3000
        stratEthOracle = new MockOracle(1e18, 18, 18); // Strat price: 1 ETH

        // Deploy the real contracts
        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        stratOption = new StratOption(owner);

        // Deploy the StratETHShortBonds contract
        bonds = new StratETHShortBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(ethUsdOracle),
            address(stratEthOracle),
            bondConverter,
            1e18, // BCV
            owner
        );

        stratToken.manageMinter(owner, true);
        stratToken.manageMinter(address(bonds), true);
        cdtToken.manageMinter(owner, true);

        // Mint tokens to initialize the supply (So it's non-zero)
        stratToken.mint(address(this), 1000e18);
        cdtToken.mint(address(this), 2000000e18);

        // Give bonding contract ability to mint StratOption
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

    function testBondRevertIfNoCDTSent() public {
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        bonds.bond(user, 0); // Should revert because no CDT is sent
    }

    function testStrikePrice() public view {
        uint256 amount = 3000e18;

        uint256 stratPrice = (stratEthOracle.price() * ethUsdOracle.price()) / 1e8; // 18 DP

        // Expected strike with 2000000 CDT and 1000 STRAT (without scaling and BCV of 1) is
        //   STRAT_PRICE * 1000 * STRAT_PRICE / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / 1998500
        uint256 expectedStrikePrice = stratPrice * stratPrice / 1998500e18 * 1000e18 / 1e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(amount);
        assertApproxEqAbs(calculatedStrikePrice, expectedStrikePrice, 100000, "Strike price calculation is incorrect");
    }

    function testBond() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        cdtToken.approve(address(bonds), cdtAmount);
        bonds.bond(user, cdtAmount);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Verify the minted StratOption attributes
        uint256 tokenId = 1; // Assuming this is the first minted option

        // NFT Option properties
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(stratOption.strikeAmount(tokenId), 0, "Strike should be 0");
        assertEq(stratOption.notionalUSDAmount(tokenId), 0, "notional USD amount should be 0");
        assertEq(
            stratOption.notionalUnderlyingAmount(tokenId), 222166666666666666, "Incorrect notional underlying amount"
        );
        assertEq(stratOption.notionalUnderlyingAmount(tokenId), stratToken.balanceOf(bondConverter));

        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
    }

    function testBondDataInvariants() public {
        cdtToken.approve(address(bonds), 100000 ether);

        for (uint256 i = 0; i < 10; i++) {
            // Bond 1000 cdt
            bonds.bond(user, 1000 ether);

            if (i == 0) {
                continue;
            }

            assertGt(
                stratOption.notionalUnderlyingAmount(i),
                stratOption.notionalUnderlyingAmount(i + 1),
                "Each subsequent bond should have less notional than the previous"
            );
        }
    }
}
