// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/StratETHLongBonds.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../../src/StratOption.sol";
import "../../src/interfaces/ITreasury.sol";

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

contract MockTreasury is ITreasury {
    function withdraw(uint256 amount, address to) external {
        revert("MockTreasury: StratETHLongBonds should never withdraw from treasury");
    }

    function total() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}

contract StratETHLongBondsTest is Test {
    StratETHLongBonds public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    StratOption public stratOption;

    // Mocks
    MockOracle public ethUsdOracle;
    MockTreasury public treasury;

    address internal owner = address(0x123);
    address internal user = address(0x789);

    function setUp() public {
        // mocks
        ethUsdOracle = new MockOracle(3000e8, 18, 8); // ETH price: $3000
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
            1e18, // BCV
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

    function testOnlyOwnerCanSetBCV() public {
        // A non-owner attempting to change BCV should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user)));
        bonds.setBCV(5); // Should revert because user is not the owner

        // A owner attempting to change BCV should suceed
        vm.prank(owner);
        bonds.setBCV(5);
        assertEq(bonds.bcv(), 5, "BCV should be updated to 5000");
    }

    function testBondRevertIfNoETHSent() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(StratETHLongBonds.NoEthSent.selector));
        bonds.bond(user); // Should revert because no ETH is sent
    }

    function testBondRevertIfBonderAddressIsZero() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(StratETHLongBonds.ZeroAddress.selector));
        bonds.bond{value: 1 ether}(address(0));
    }

    function testStrikePrice() public {
        uint256 notionalUSDAmount = 3000e18;

        // Expected strike with no CDT, 1 ETH in treasury and 10k STRAT (without scaling) is
        //   (3000 + (3000 / 2)) / 10_000
        // = 0.45
        uint256 expectedStrikePrice = 0.45 ether;
        uint256 calculatedStrikePrice = bonds.strikePrice(notionalUSDAmount);
        assertEq(calculatedStrikePrice, expectedStrikePrice, "Strike price calculation is incorrect");
    }

    function testBond() public {
        vm.deal(user, 1 ether); // Give ETH to user
        vm.prank(user);
        // Run bond function
        bonds.bond{value: 1 ether}(user);

        // Check treasury receives money
        assertEq(treasury.total(), 2 ether, "Treasury did not receive the correct ETH amount");

        // Verify the CDT balance of the user
        uint256 expectedCdUSDAmount = (1 ether * ethUsdOracle.price()) / 1e8; // ETH -> USD conversion
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

        // Bond 1 more ETH, after ETH/USD price goes down to $3000
        ethUsdOracle.setPrice(3000e8);
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user);
        assertGt(
            stratOption.strikeAmount(2),
            stratOption.strikeAmount(3),
            "ETH price decrease should decrease total strike amount"
        );
    }
}
