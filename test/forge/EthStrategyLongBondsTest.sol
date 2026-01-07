// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/EthStrategyLongBonds.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";
import "../mocks/MockTreasury.sol";
import "../mocks/MockGavToken.sol";
import {EthUsdPriceOracleProvider} from "../lib/EthUsdPriceOracleProvider.sol";
import {PermitGenerator} from "../lib/Permit.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract EthStrategyLongBondsTest is Test, EthUsdPriceOracleProvider, PermitGenerator {
    EthStrategyLongBonds public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    MockGavToken public gavToken;

    // Mocks
    MockTreasury public treasury;
    MockTreasury public treasuryVault;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal permitOwner;
    uint256 internal permitPk;

    /// @dev ETH price: $3000
    uint256 internal _ETH_USD_INITIAL_PRICE = 3000e18;

    function setUp() public {
        (permitOwner, permitPk) = makeAddrAndKey("PERMIT_OWNER");

        // mocks
        _setUpEthUsdOracle(_ETH_USD_INITIAL_PRICE);
        treasury = new MockTreasury();
        treasury.setWithdrawAllowed(true);
        treasuryVault = new MockTreasury();

        // Deploy the real contracts
        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);
        gavToken = new MockGavToken(owner);

        // Deploy the EthStrategyLongBonds contract
        bonds = new EthStrategyLongBonds(
            address(cdtToken),
            address(stratToken),
            address(gavToken), // GAV token
            address(treasuryVault), // treasury vault
            address(treasury), // treasury for withdrawals
            address(ethUsdOracle),
            1e18, // PCF
            1e18, // GCF
            owner
        );

        stratToken.manageMinter(owner, true);
        stratToken.manageMinter(address(bonds), true); // Allow bonds contract to mint STRAT
        gavToken.manageMinter(owner, true);

        // Mint tokens to initialize the supply (So it's non-zero)
        stratToken.mint(address(this), 10_000 ether);
        gavToken.mint(address(this), 1 ether); // 1 ETH worth of GAV token
        vm.deal(address(treasury), 1 ether);

        // Give bonding contract ability to mint CDT
        cdtToken.manageMinter(address(bonds), true);
        vm.stopPrank();
    }

    // ============ Bonding Tests ============

    function testOnlyOwnerCanSetPCF() public {
        // A non-owner attempting to change PCF should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(user)));
        bonds.setPCF(5); // Should revert because user is not the owner

        // An owner attempting to change PCF should succeed
        vm.prank(owner);
        bonds.setPCF(5);
        assertEq(bonds.pcf(), 5, "PCF should be updated to 5");
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
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.NoEthSent.selector));
        bonds.bond(user, 1 ether, block.timestamp + 1 hours);
    }

    function testBondRevertIfBonderAddressIsZero() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.ZeroAddress.selector));
        bonds.bond{value: 1 ether}(address(0), 1 ether, block.timestamp + 1 hours);
    }

    function testStrikePrice() public view {
        uint256 notionalUSDAmount = 3000e18;

        // Expected strike with no CDT, 1 ETH in GAV (3000 USD) and 10k STRAT (without scaling) is
        //   (3000 * 1 + 1 * 1500) / 10_000
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
        //  =  (gav * GCF / stratSupply) + (PCF * debt / stratSupply)
        //  =  (gav * GCF + PCF * debt) / stratSupply
        // substituting the values for gav (1 ETH = 3000 USD) and strat supply (10k) and no starting debt, we get
        //  =  (3000 * GCF + PCF * 1500) / 10_000
        uint256 expectedStrikePrice = (3000e18 * gcf + pcf * (notionalUSDAmount / 2)) / 10_000e18;
        uint256 calculatedStrikePrice = bonds.strikePrice(notionalUSDAmount);

        assertEq(calculatedStrikePrice, expectedStrikePrice, "Strike price calculation is incorrect");
    }

    function testBond() public {
        vm.deal(user, 1 ether); // Give ETH to user
        vm.prank(user);
        // Run bond function
        bonds.bond{value: 1 ether}(user, 0.5 ether, block.timestamp + 1 hours);

        // Check treasury vault receives money
        assertEq(address(treasuryVault).balance, 1 ether, "Treasury vault did not receive the correct ETH amount");

        // Verify the CDT balance of the user
        uint256 expectedCdUSDAmount = (1 ether * _ETH_USD_INITIAL_PRICE) / 1e18; // ETH -> USD conversion
        assertEq(cdtToken.balanceOf(user), expectedCdUSDAmount, "User CDT balance incorrect");

        // Verify the minted NFT attributes
        uint256 tokenId = 1; // First minted NFT
        uint256 expectedStrikeAmount = expectedCdUSDAmount;

        // NFT properties
        assertEq(bonds.ownerOf(tokenId), user, "Incorrect owner");
        assertEq(bonds.strikeAmount(tokenId), expectedStrikeAmount, "Incorrect strike amount");
        assertApproxEqAbs(
            bonds.notionalUnderlyingAmount(tokenId),
            6666.6666666 ether,
            1e12, // acceptable delta in wei (0.000001 ether)
            "Incorrect notional underlying amount"
        );

        assertEq(bonds.notionalUSDAmount(tokenId), expectedCdUSDAmount, "Incorrect notional USD amount");
        assertEq(bonds.expiry(tokenId), block.timestamp + (4.2 * 365 days), "Incorrect expiry");
        assertEq(bonds.timelock(tokenId), block.timestamp + 6.9 days, "Incorrect timelock");

        // Confirm bond is accretive w.r.t the treasury
        assertLt(
            bonds.notionalUnderlyingAmount(tokenId),
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

            uint256 tokenId = i; // tokenId starts at 1, but we're comparing i and i+1
            assertGt(
                bonds.notionalUnderlyingAmount(tokenId),
                bonds.notionalUnderlyingAmount(tokenId + 1),
                "Each subsequent bond should have less notional than the previous"
            );
            assertEq(
                bonds.strikeAmount(tokenId),
                bonds.strikeAmount(tokenId + 1),
                "Strike should be the same, as we are bonding the same amount of ETH each time (and the oracle isn't changing)"
            );
            assertEq(
                bonds.notionalUSDAmount(tokenId),
                bonds.strikeAmount(tokenId + 1),
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
            bonds.strikeAmount(1),
            bonds.strikeAmount(2),
            "ETH price increase should increase total strike amount"
        );

        // Bond 1 more ETH, after ETH/USD price goes down to $3000
        ethUsdOracle.setBasePerQuote(3000e18);
        vm.deal(user, 1 ether);
        vm.prank(user);
        bonds.bond{value: 1 ether}(user, 0, block.timestamp + 1 hours);
        assertGt(
            bonds.strikeAmount(2),
            bonds.strikeAmount(3),
            "ETH price decrease should decrease total strike amount"
        );
    }

    // ============ Exercise Tests ============

    uint256 private _lastTokenId;

    function _bondOption(address to, uint256 ethAmount) internal returns (uint256 tokenId) {
        uint256 balanceBefore = bonds.balanceOf(to);
        vm.deal(to, ethAmount);
        vm.prank(to);
        bonds.bond{value: ethAmount}(to, 0, block.timestamp + 1 hours);
        // Find the tokenId by checking which token the user now owns
        uint256 balanceAfter = bonds.balanceOf(to);
        require(balanceAfter == balanceBefore + 1, "NFT not minted");
        // Find the tokenId by checking ownerOf for recent tokenIds
        // Start from last known tokenId + 1
        uint256 startId = _lastTokenId > 0 ? _lastTokenId + 1 : 1;
        for (uint256 i = startId; i <= startId + 100; i++) {
            try bonds.ownerOf(i) returns (address tokenOwner) {
                if (tokenOwner == to) {
                    _lastTokenId = i;
                    return i;
                }
            } catch {
                continue;
            }
        }
        revert("TokenId not found");
    }

    function testExerciseSuccess() public {
        // Bond an option
        uint256 tokenId = _bondOption(user, 1 ether);
        
        // Capture values before exercise
        uint256 expectedStrat = bonds.notionalUnderlyingAmount(tokenId);
        uint256 strike = bonds.strikeAmount(tokenId);
        
        // Give user CDT
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // After timelock, before expiry
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(user);

        // Approve CDT burn
        cdtToken.approve(address(bonds), strike);
        bonds.approve(address(bonds), tokenId);

        // Exercise
        bonds.exercise(tokenId);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStrat, "User should get STRAT");
        assertEq(bonds.balanceOf(user), 0, "Option NFT should be burned");
        assertEq(cdtToken.balanceOf(user), 1000 ether - strike, "CDT should be burned");
        vm.stopPrank();
    }

    function testExerciseWithSufficientPremintedStrat() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        // mint more STRAT into the bonds contract than needed
        uint256 stratNeeded = bonds.notionalUnderlyingAmount(tokenId);
        vm.prank(owner);
        stratToken.mint(address(bonds), stratNeeded + 1000 ether);

        // Give user CDT
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // After timelock, before expiry
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(user);

        // Approve CDT burn
        cdtToken.approve(address(bonds), bonds.strikeAmount(tokenId));
        bonds.approve(address(bonds), tokenId);

        // Capture expected STRAT before exercise
        uint256 expectedStrat = bonds.notionalUnderlyingAmount(tokenId);
        
        // Exercise
        bonds.exercise(tokenId);

        // Check balances
        assertEq(stratToken.balanceOf(user), expectedStrat, "User should get STRAT");
        assertEq(bonds.balanceOf(user), 0, "Option NFT should be burned");
        assertEq(stratToken.balanceOf(address(bonds)), 1000 ether, "Bonds contract should have 1000 STRAT left");
        vm.stopPrank();
    }

    function testRevertIfTimelockActive() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.TimelockActive.selector, user, tokenId));
        bonds.exercise(tokenId);
        vm.stopPrank();
    }

    function testRevertIfOptionExpired() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // Warp past expiry
        vm.warp(block.timestamp + (4.2 * 365 days) + 1);
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.OptionExpired.selector, user, tokenId));
        bonds.exercise(tokenId);
        vm.stopPrank();
    }

    function testRevertIfNotOptionOwner() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        address randoUser = address(0x999);
        vm.prank(owner);
        cdtToken.mint(randoUser, 1000 ether);

        // Advance time beyond timelock, before expiry
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(randoUser);
        cdtToken.approve(address(bonds), bonds.strikeAmount(tokenId));

        vm.expectRevert();
        bonds.exercise(tokenId);

        vm.stopPrank();
    }

    function test_exerciseWithPermit_deadlineIsZero_reverts() public {
        uint256 tokenId = _bondOption(permitOwner, 1 ether);
        
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        bonds.approve(address(bonds), tokenId);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Expect allowance revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(bonds), 0, bonds.strikeAmount(tokenId)
            )
        );

        vm.prank(permitOwner);
        bonds.exerciseWithPermit(tokenId, permitApproval);
    }

    function test_exerciseWithPermit_deadlineIsZero_spendingApprovalProvided() public {
        uint256 tokenId = _bondOption(permitOwner, 1 ether);
        
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval =
            Permit.IPermitApproval({deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Approve spending of CDT
        vm.prank(permitOwner);
        cdtToken.approve(address(bonds), bonds.strikeAmount(tokenId));

        // Approve NFT transfer
        vm.prank(permitOwner);
        bonds.approve(address(bonds), tokenId);

        // Exercise
        vm.prank(permitOwner);
        bonds.exerciseWithPermit(tokenId, permitApproval);

        // Capture values before checking (NFT is burned)
        uint256 expectedStrat = bonds.notionalUnderlyingAmount(tokenId);
        uint256 strike = bonds.strikeAmount(tokenId);
        
        // Check balances
        assertEq(stratToken.balanceOf(permitOwner), expectedStrat, "Permit owner should get STRAT");
        assertEq(bonds.balanceOf(permitOwner), 0, "Option NFT should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 1000 ether - strike, "CDT should be burned");
    }

    function test_exerciseWithPermit() public {
        uint256 tokenId = _bondOption(permitOwner, 1 ether);
        uint256 cdtAmount = bonds.strikeAmount(tokenId);
        
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Approve NFT transfer
        vm.prank(permitOwner);
        bonds.approve(address(bonds), tokenId);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(bonds),
            block.timestamp + 1 days,
            cdtAmount,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Capture expected STRAT amount before exercise
        uint256 expectedStrat = bonds.notionalUnderlyingAmount(tokenId);
        
        // Exercise
        vm.prank(permitOwner);
        bonds.exerciseWithPermit(tokenId, permitApproval);

        // Check balances
        assertEq(stratToken.balanceOf(permitOwner), expectedStrat, "Permit owner should get STRAT");
        assertEq(bonds.balanceOf(permitOwner), 0, "Option NFT should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 1000 ether - cdtAmount, "CDT should be burned");
    }

    // ============ Redemption Tests ============

    function testRedeemSuccessTreasuryGtDebt() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        uint256 notionalUSD = bonds.notionalUSDAmount(tokenId);
        
        // Give treasury enough ETH (value > total CDT)
        vm.deal(address(treasury), 100 ether);
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + (4.2 * 365 days) + 1);

        vm.startPrank(user);
        cdtToken.approve(address(bonds), notionalUSD);
        bonds.approve(address(bonds), tokenId);

        bonds.redeemCdtForUsdNotional(tokenId);

        assertEq(bonds.balanceOf(user), 0, "Option NFT should be burned");
        assertEq(cdtToken.balanceOf(user), 1000 ether - notionalUSD, "CDT should be partially burned");
        // In this case: if treasury.total() * price >= totalDebt, so withdraw should be full notional USD of ETH
        uint256 expectedEth = notionalUSD * 1e18 / _ETH_USD_INITIAL_PRICE;
        assertEq(address(user).balance, expectedEth, "should withdraw full notional USD of ETH");
        vm.stopPrank();
    }

    function testRedeemSuccessTreasuryLtDebt() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        uint256 notionalUSD = bonds.notionalUSDAmount(tokenId);
        
        // Set price to 7.5. This will make treasury value < total debt
        ethUsdOracle.setBasePerQuote(7.5e18);
        
        // Give treasury some ETH
        vm.deal(address(treasury), 100 ether);
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // Move time beyond timelock and expiry
        vm.warp(block.timestamp + (4.2 * 365 days) + 1);

        vm.startPrank(user);
        cdtToken.approve(address(bonds), notionalUSD);
        bonds.approve(address(bonds), tokenId);

        bonds.redeemCdtForUsdNotional(tokenId);

        assertEq(bonds.balanceOf(user), 0, "Option NFT should be burned");
        assertEq(cdtToken.balanceOf(user), 1000 ether - notionalUSD, "CDT should be partially burned");
        // In this case: if treasury.total() * price < totalDebt, so withdraw should be proportional share
        uint256 totalDebt = cdtToken.totalSupply();
        uint256 expectedEth = notionalUSD * 100 ether / totalDebt;
        assertApproxEqAbs(address(user).balance, expectedEth, 1e15, "should withdraw proportional share of ETH");
        vm.stopPrank();
    }

    function testRevertIfTimelockActive_Redemption() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // Before timelock
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.TimelockActive.selector, user, tokenId));
        bonds.redeemCdtForUsdNotional(tokenId);
        vm.stopPrank();
    }

    function testRevertIfOptionUnexpired() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);

        // before expiry, after timelock
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.OptionUnexpired.selector, user, tokenId));
        bonds.redeemCdtForUsdNotional(tokenId);
        vm.stopPrank();
    }

    function test_redeemCdtForUsdNotionalWithPermit() public {
        uint256 tokenId = _bondOption(permitOwner, 1 ether);
        uint256 notionalUSD = bonds.notionalUSDAmount(tokenId);
        
        vm.deal(address(treasury), 100 ether);
        vm.warp(block.timestamp + (4.2 * 365 days) + 1);
        vm.prank(owner);
        cdtToken.mint(permitOwner, 1000 ether);

        // Approve NFT transfer
        vm.prank(permitOwner);
        bonds.approve(address(bonds), tokenId);

        // Generate permit approval
        Permit.IPermitApproval memory permitApproval = _getPermitOwnerSignature(
            permitOwner,
            permitPk,
            address(bonds),
            block.timestamp + 1 days,
            notionalUSD,
            cdtToken.DOMAIN_SEPARATOR()
        );

        // Redeem
        vm.prank(permitOwner);
        bonds.redeemCdtForUsdNotionalWithPermit(tokenId, permitApproval);

        // Check balances
        assertEq(bonds.balanceOf(permitOwner), 0, "Option NFT should be burned");
        assertEq(cdtToken.balanceOf(permitOwner), 1000 ether - notionalUSD, "CDT should be partially burned");
        uint256 expectedEth = notionalUSD * 1e18 / _ETH_USD_INITIAL_PRICE;
        assertEq(address(permitOwner).balance, expectedEth, "should withdraw full notional USD of ETH");
    }

    // ============ NFT Transfer Tests ============

    function testNFTTransfer() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        address recipient = address(0x456);
        
        vm.prank(user);
        bonds.transferFrom(user, recipient, tokenId);
        
        assertEq(bonds.ownerOf(tokenId), recipient, "NFT should be transferred");
        assertEq(bonds.balanceOf(user), 0, "User should have no NFTs");
        assertEq(bonds.balanceOf(recipient), 1, "Recipient should have 1 NFT");
    }

    function testNFTApproval() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        address operator = address(0x456);
        
        vm.prank(user);
        bonds.approve(operator, tokenId);
        
        assertEq(bonds.getApproved(tokenId), operator, "Operator should be approved");
    }

    function testNFTApprovalForAll() public {
        _bondOption(user, 1 ether);
        address operator = address(0x456);
        
        vm.prank(user);
        bonds.setApprovalForAll(operator, true);
        
        assertTrue(bonds.isApprovedForAll(user, operator), "Operator should be approved for all");
    }

    function testExerciseByApprovedOperator() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        address operator = address(0x456);
        
        vm.prank(owner);
        cdtToken.mint(operator, 1000 ether);
        
        vm.prank(user);
        bonds.setApprovalForAll(operator, true);
        
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(operator);
        cdtToken.approve(address(bonds), bonds.strikeAmount(tokenId));
        
        // Capture expected STRAT before exercise
        uint256 expectedStrat = bonds.notionalUnderlyingAmount(tokenId);
        
        bonds.exercise(tokenId);
        
        assertEq(stratToken.balanceOf(user), expectedStrat, "User should get STRAT");
        assertEq(bonds.balanceOf(user), 0, "NFT should be burned");
        vm.stopPrank();
    }

    // ============ Edge Cases ============

    function testTokenURI() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        // Should return empty string if no renderer set
        string memory uri = bonds.tokenURI(tokenId);
        assertEq(bytes(uri).length, 0, "TokenURI should be empty when no renderer");
        
        // Set renderer (mock address for testing)
        address renderer = address(0x999);
        vm.prank(owner);
        bonds.managerRenderer(renderer);
        
        // Should call renderer (will revert if renderer doesn't implement interface, but that's expected)
        vm.expectRevert();
        bonds.tokenURI(tokenId);
    }

    function testCannotExerciseAfterExpiry() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);
        
        // Warp past expiry
        vm.warp(block.timestamp + (4.2 * 365 days) + 1);
        
        vm.startPrank(user);
        cdtToken.approve(address(bonds), bonds.strikeAmount(tokenId));
        bonds.approve(address(bonds), tokenId);
        
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.OptionExpired.selector, user, tokenId));
        bonds.exercise(tokenId);
        vm.stopPrank();
    }

    function testCannotRedeemBeforeExpiry() public {
        uint256 tokenId = _bondOption(user, 1 ether);
        
        vm.prank(owner);
        cdtToken.mint(user, 1000 ether);
        
        // After timelock but before expiry
        vm.warp(block.timestamp + 7 days);
        
        vm.startPrank(user);
        cdtToken.approve(address(bonds), bonds.notionalUSDAmount(tokenId));
        bonds.approve(address(bonds), tokenId);
        
        vm.expectRevert(abi.encodeWithSelector(EthStrategyLongBonds.OptionUnexpired.selector, user, tokenId));
        bonds.redeemCdtForUsdNotional(tokenId);
        vm.stopPrank();
    }
}

