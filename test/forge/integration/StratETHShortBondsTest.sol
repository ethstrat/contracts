// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../src/StratETHShortBonds.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import "../../../src/StratOption.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

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
            1e18, // BCV
            owner
        );

        stratToken.manageMinter(owner, true);
        cdtToken.manageMinter(owner, true);

        // Mint tokens to initialize the supply (So it's non-zero)
        stratToken.mint(address(this), 1000e18);
        cdtToken.mint(address(this), 2000000e18);

        // Give bonding contract ability to mint StratOption
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();
    }

    // setBCV
    // given the caller is not the owner
    //  [X] it reverts
    // [X] it sets the BCV

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
    // given the ETH-USD oracle has 18 decimals
    //  [X] the strike price is calculated correctly
    // [X] the strike price is calculated correctly

    function testStrikePrice_ethUsdOracleDecimals18() public {
        // Adjust the ethUsdOracle price to 18 decimals
        ethUsdOracle.setPrice(3000e18);
        ethUsdOracle.setQuoteTokenDecimals(18);

        // Create a new contract
        vm.startPrank(owner);
        bonds = new StratETHShortBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(ethUsdOracle),
            address(stratEthOracle),
            1e18, // BCV
            owner
        );
        cdtToken.manageMinter(address(bonds), true);
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();

        uint256 amount = 3000e18;

        uint256 stratPrice = (stratEthOracle.price() * ethUsdOracle.price()) / 1e18; // 18 DP

        // Expected strike with 2000000 CDT and 1000 STRAT (without scaling and BCV of 1) is
        //   STRAT_PRICE * 1000 * STRAT_PRICE / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / (2000000 - (3000 / 2))
        // = STRAT_PRICE^2 * 1000 / 1998500
        uint256 expectedStrikePrice = stratPrice * stratPrice / 1998500e18 * 1000e18 / 1e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(amount);
        assertApproxEqAbs(calculatedStrikePrice, expectedStrikePrice, 100000, "Strike price calculation is incorrect");
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

    // bond
    // when no amount is sent
    //  [X] it reverts
    // when the caller has not approved spending of CDT
    //  [X] it reverts
    // when the caller does not have enough CDT
    //  [X] it reverts
    // given the ETH-USD oracle has 18 decimals
    //  [X] the strike amount is 0
    //  [X] the notional USD amount is 0
    //  [X] the notional underlying amount is calculated correctly
    //  [X] the expiry is 4.2 years from now
    //  [X] the timelock is 69 minutes from now
    //  [X] the CDT is burned
    //  [X] the owner of the option is the bonder
    // [X] the strike amount is 0
    // [X] the notional USD amount is 0
    // [X] the notional underlying amount is calculated correctly
    // [X] the expiry is 4.2 years from now
    // [X] the timelock is 69 minutes from now
    // [X] the CDT is burned
    // [X] the owner of the option is the bonder

    function test_bond_noAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        bonds.bond(user, 0); // Should revert because no CDT is sent
    }

    function test_bond_cdtSpendingNotApproved_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Mint CDT to the user
        vm.prank(owner);
        cdtToken.mint(user, cdtAmount);

        // Expect revert
        vm.expectRevert("ERC20: burn amount exceeds allowance");

        vm.prank(user);
        bonds.bond(user, cdtAmount);
    }

    function test_bond_cdtBalanceInsufficient_reverts() public {
        uint256 cdtAmount = 1000 ether;

        // Approve spending of CDT
        vm.prank(user);
        cdtToken.approve(address(bonds), cdtAmount);

        // Expect revert
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 0, cdtAmount));

        vm.prank(user);
        bonds.bond(user, cdtAmount);
    }

    function test_bond_ethUsdOracleDecimals18() public {
        // Adjust the ethUsdOracle price to 18 decimals
        ethUsdOracle.setPrice(3000e18);
        ethUsdOracle.setQuoteTokenDecimals(18);

        // Create a new contract
        vm.startPrank(owner);
        bonds = new StratETHShortBonds(
            address(cdtToken),
            address(stratToken),
            address(stratOption),
            address(ethUsdOracle),
            address(stratEthOracle),
            1e18, // BCV
            owner
        );
        cdtToken.manageMinter(address(bonds), true);
        stratOption.manageMinter(address(bonds), true);
        vm.stopPrank();

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
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
    }

    function test_bond() public {
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
        assertEq(stratOption.expiry(tokenId), block.timestamp + (420 * 365 days), "Incorrect expiry");
        assertEq(stratOption.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");
        assertEq(stratOption.ownerOf(tokenId), user, "Incorrect owner");
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
