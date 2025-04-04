// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../src/StratETHShortBonds.sol";
import "../../../src/CdtToken.sol";
import "../../../src/StratToken.sol";
import "../../../src/StratOption.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";

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
        vm.expectRevert(abi.encodeWithSelector(StratETHShortBonds.InvalidParams.selector, "amount"));
        bonds.bond(user, 0); // Should revert because no CDT amount is specified
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

        // Get the strike price
        uint48 expectedExpiry = uint48(block.timestamp + (420 * 365 days));
        uint48 expectedTimelock = uint48(block.timestamp + 6.9 days);
        uint256 expectedStrikePrice = bonds.strikePrice(cdtAmount);
        uint256 expectedTokenId =
            stratOption.getTokenId(expectedStrikePrice, 0, expectedExpiry, expectedTimelock, false);

        cdtToken.approve(address(bonds), cdtAmount);
        uint256 tokenId = bonds.bond(user, cdtAmount);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Check the token ID is correct
        assertEq(tokenId, expectedTokenId, "Incorrect token ID");

        // Balance = cdtAmount
        assertEq(stratOption.balanceOf(user, tokenId), cdtAmount, "Incorrect balance");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        // Strike price
        assertEq(option.strikePrice, expectedStrikePrice, "Incorrect strike price");

        // Redemption price
        // Not redeemable, so 0
        assertEq(option.redemptionPrice, 0, "Incorrect redemption price");

        // Check STRAT output when exercised
        assertEq(cdtAmount * 1e18 / option.strikePrice, 222166666666666666, "Incorrect STRAT output");

        // Expiry
        assertEq(option.expiry, expectedExpiry, "Incorrect expiry");

        // Timelock
        assertEq(option.timelock, expectedTimelock, "Incorrect timelock");

        // requiresInputBurn
        assertEq(option.requiresInputBurn, false, "requiresInputBurn");
    }

    function test_bond() public {
        uint256 startingCdtSupply = cdtToken.totalSupply();
        uint256 cdtAmount = 1000 ether;

        // Get the strike price
        uint48 expectedExpiry = uint48(block.timestamp + (420 * 365 days));
        uint48 expectedTimelock = uint48(block.timestamp + 6.9 days);
        uint256 expectedStrikePrice = bonds.strikePrice(cdtAmount);
        uint256 expectedTokenId =
            stratOption.getTokenId(expectedStrikePrice, 0, expectedExpiry, expectedTimelock, false);

        cdtToken.approve(address(bonds), cdtAmount);
        uint256 tokenId = bonds.bond(user, cdtAmount);

        assertEq(cdtToken.totalSupply() + cdtAmount, startingCdtSupply, "CDT not burned");

        // Check the token ID is correct
        assertEq(tokenId, expectedTokenId, "Incorrect token ID");

        // Balance = cdtAmount
        assertEq(stratOption.balanceOf(user, tokenId), cdtAmount, "Incorrect balance");

        IStratOptionMinter.Option memory option = stratOption.getOption(tokenId);

        // Strike price
        assertEq(option.strikePrice, expectedStrikePrice, "Incorrect strike price");

        // Redemption price
        // Not redeemable, so 0
        assertEq(option.redemptionPrice, 0, "Incorrect redemption price");

        // Check STRAT output when exercised
        assertEq(cdtAmount * 1e18 / option.strikePrice, 222166666666666666, "Incorrect STRAT output");

        // Expiry
        assertEq(option.expiry, expectedExpiry, "Incorrect expiry");

        // Timelock
        assertEq(option.timelock, expectedTimelock, "Incorrect timelock");

        // requiresInputBurn
        assertEq(option.requiresInputBurn, false, "requiresInputBurn");
    }

    function testBondDataInvariants() public {
        cdtToken.approve(address(bonds), 100000 ether);

        uint256 previousTokenId;
        for (uint256 i = 0; i < 10; i++) {
            // Bond 1000 cdt
            uint256 tokenId = bonds.bond(user, 1000 ether);

            if (i == 0) {
                previousTokenId = tokenId;
                continue;
            }

            IStratOptionMinter.Option memory currentOption = stratOption.getOption(tokenId);
            IStratOptionMinter.Option memory previousOption = stratOption.getOption(previousTokenId);

            // Strike price increases
            assertGt(currentOption.strikePrice, previousOption.strikePrice, "Strike price should increase");

            // Balance should be the same as the USD input is the same
            uint256 currentBalance = stratOption.balanceOf(user, tokenId);
            uint256 previousBalance = stratOption.balanceOf(user, previousTokenId);
            assertEq(currentBalance, previousBalance, "Balance should be the same as the USD input is the same");

            // STRAT output should decrease as the strike price increases
            assertGt(
                previousBalance * 1e18 / previousOption.strikePrice,
                currentBalance * 1e18 / currentOption.strikePrice,
                "STRAT output should decrease as the strike price increases"
            );

            previousTokenId = tokenId;
        }
    }
}
