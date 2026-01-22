// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../../src/EthStrategyConvertibleNote.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";

import "../mocks/MockWETH.sol";
import {EthUsdPriceOracleProvider} from "../lib/EthUsdPriceOracleProvider.sol";
import {PermitGenerator} from "../lib/Permit.sol";

/// @dev Unit tests aligned to docs/EthStrategyConvertibleNote_User_Stories.md and current
/// src/EthStrategyConvertibleNote.sol.
contract EthStrategyConvertibleNoteTest is Test, EthUsdPriceOracleProvider, PermitGenerator {
    EthStrategyConvertibleNote public bonds;
    CdtToken public cdtToken;
    StratToken public stratToken;
    esETH public esETHToken;
    MockWETH public weth;

    address internal owner = address(0x123);
    address internal user = address(0x789);
    address internal other = address(0x456);

    address internal permitOwner;
    uint256 internal permitPk;

    // Holdings addresses (must approve the note contract for esETH.transferFrom-based flows)
    address internal unencumberedHoldings = address(0xA11CE);
    address internal encumberedHoldings = address(0xB0B);

    /// @dev ETH price: $3000
    uint256 internal constant ETH_USD_PRICE = 3000e18;

    function setUp() public {
        (permitOwner, permitPk) = makeAddrAndKey("PERMIT_OWNER");

        _setUpEthUsdOracle(ETH_USD_PRICE);

        vm.startPrank(owner);
        cdtToken = new CdtToken(owner);
        stratToken = new StratToken(owner);

        // Deploy esETH with a local WETH implementation. Mark WETH as mintable so bond() can call wrapAndMint.
        weth = new MockWETH();
        esETHToken = new esETH(owner, address(weth));
        esETHToken.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);

        // Deploy the note contract (per current spec)
        bonds = new EthStrategyConvertibleNote(
            address(cdtToken),
            address(stratToken),
            address(esETHToken),
            unencumberedHoldings,
            encumberedHoldings,
            address(ethUsdOracle),
            owner
        );

        // Allow note contract to mint/burn required tokens
        cdtToken.manageMinter(address(bonds), true);
        stratToken.manageMinter(address(bonds), true);

        // Ensure non-zero STRAT supply for conversionEntitlements()
        stratToken.manageMinter(owner, true);
        stratToken.mint(address(this), 10_000 ether);
        vm.stopPrank();

        // Seed esETH balances so conversionEntitlements() doesn't return (0,0) at bond time
        vm.deal(owner, 10_000 ether);
        vm.prank(owner);
        esETHToken.wrapAndMint{value: 100 ether}(unencumberedHoldings);
        vm.prank(owner);
        esETHToken.wrapAndMint{value: 100 ether}(encumberedHoldings);

        // Holdings must approve the note contract for transferFrom-based flows
        vm.prank(unencumberedHoldings);
        esETHToken.approve(address(bonds), type(uint256).max);
        vm.prank(encumberedHoldings);
        esETHToken.approve(address(bonds), type(uint256).max);

        vm.deal(user, 100 ether);
        vm.deal(other, 100 ether);
        vm.deal(permitOwner, 100 ether);
    }

    function _bond(address bonder, uint256 ethAmount, uint256 minStrat, uint256 minEth, uint256 deadline)
        internal
        returns (uint256 tokenId, uint256 settlementUsd, uint256 entitlementStrat, uint256 entitlementEth)
    {
        settlementUsd = (ethAmount * ETH_USD_PRICE) / 1e18;
        (entitlementStrat, entitlementEth) = bonds.conversionEntitlements(settlementUsd);

        uint256 beforeId = bonds._tokenIdCounter();
        vm.prank(bonder);
        bonds.bond{value: ethAmount}(bonder, minStrat, minEth, deadline);
        tokenId = beforeId;
    }

    function _warpPastTimelock(uint256 tokenId) internal {
        vm.warp(bonds.timelock(tokenId) + 1);
    }

    function _warpPastExpiry(uint256 tokenId) internal {
        vm.warp(bonds.expiry(tokenId) + 1);
    }

    // ========= Admin =========

    function testOnlyOwnerCanSetPCF() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bonds.setPCF(5);

        vm.prank(owner);
        bonds.setPCF(5);
        assertEq(bonds.pcf(), 5);
    }

    function testOnlyOwnerCanManageRenderer() public {
        address renderer = address(0xDEAD);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bonds.managerRenderer(renderer);

        vm.prank(owner);
        bonds.managerRenderer(renderer);
        assertEq(bonds.tokenURIRenderer(), renderer);
    }

    // ========= Bonding =========

    function testBondRevertsOnNoEth() public {
        vm.prank(user);
        vm.expectRevert(EthStrategyConvertibleNote.NoEthSent.selector);
        bonds.bond(user, 0, 0, block.timestamp);
    }

    function testBondRevertsOnZeroBonder() public {
        vm.prank(user);
        vm.expectRevert(EthStrategyConvertibleNote.ZeroAddress.selector);
        bonds.bond{value: 1 ether}(address(0), 0, 0, block.timestamp);
    }

    function testBondRevertsOnStaleDeadline() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(EthStrategyConvertibleNote.TransactionStale.selector, block.timestamp - 1)
        );
        bonds.bond{value: 1 ether}(user, 0, 0, block.timestamp - 1);
    }

    function testBondRevertsOnInsufficientOutput() public {
        uint256 ethAmount = 1 ether;
        uint256 settlementUsd = (ethAmount * ETH_USD_PRICE) / 1e18;
        (uint256 expectedStrat, uint256 expectedEth) = bonds.conversionEntitlements(settlementUsd);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                EthStrategyConvertibleNote.InsufficientOutput.selector, expectedStrat + 1, expectedStrat
            )
        );
        bonds.bond{value: ethAmount}(user, expectedStrat + 1, 0, block.timestamp);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(EthStrategyConvertibleNote.InsufficientOutput.selector, expectedEth + 1, expectedEth)
        );
        bonds.bond{value: ethAmount}(user, 0, expectedEth + 1, block.timestamp);
    }

    function testBondMintsCdtAndNftAndSplitsEthToHoldings() public {
        uint256 ethAmount = 1 ether;

        uint256 encBefore = esETHToken.balanceOf(encumberedHoldings);
        uint256 unencBefore = esETHToken.balanceOf(unencumberedHoldings);

        (uint256 tokenId, uint256 settlementUsd, uint256 entitlementStrat, uint256 entitlementEth) =
            _bond(user, ethAmount, 0, 0, block.timestamp);

        assertEq(bonds.ownerOf(tokenId), user);
        assertEq(bonds.amountOwedCdt(tokenId), settlementUsd);
        assertEq(bonds.settlementEntitlementUsd(tokenId), settlementUsd);
        assertEq(bonds.conversionEntitlementStrat(tokenId), entitlementStrat);
        assertEq(bonds.conversionEntitlementEth(tokenId), entitlementEth);
        assertEq(cdtToken.balanceOf(user), settlementUsd);

        // esETH minted to holdings during bond: encumbered gets entitlementEth, unencumbered gets remainder
        assertEq(esETHToken.balanceOf(encumberedHoldings) - encBefore, entitlementEth);
        assertEq(esETHToken.balanceOf(unencumberedHoldings) - unencBefore, ethAmount - entitlementEth);
    }

    // ========= Conversion =========

    function testConvertRevertsDuringTimelock() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.TimelockActive.selector, user, tokenId));
        bonds.convertPartial(tokenId, false, 1);
    }

    function testConvertRevertsAfterExpiry() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.OptionExpired.selector, user, tokenId));
        bonds.convertPartial(tokenId, false, 1);
    }

    function testOnlyOwnerOfNftCanConvertEvenIfApproved() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        bonds.approve(other, tokenId);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.NotOwnerOrApproved.selector, other, tokenId));
        bonds.convertPartial(tokenId, false, 1);
    }

    function testPartialConvertToStratDecrementsBalancesAndMintsStrat() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        uint256 strike = bonds.amountOwedCdt(tokenId);
        uint256 cdtToBurn = strike / 2;
        uint256 stratEnt = bonds.conversionEntitlementStrat(tokenId);
        uint256 ethEnt = bonds.conversionEntitlementEth(tokenId);

        uint256 expectedStratOut = (stratEnt * cdtToBurn) / strike;
        uint256 expectedEthOut = (ethEnt * cdtToBurn) / strike;

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 stratBefore = stratToken.balanceOf(user);
        uint256 encBefore = esETHToken.balanceOf(encumberedHoldings);
        uint256 unencBefore = esETHToken.balanceOf(unencumberedHoldings);

        vm.prank(user);
        bonds.convertPartial(tokenId, false, cdtToBurn);

        assertEq(stratToken.balanceOf(user) - stratBefore, expectedStratOut);
        assertEq(esETHToken.balanceOf(encumberedHoldings), encBefore - expectedEthOut);
        assertEq(esETHToken.balanceOf(unencumberedHoldings), unencBefore + expectedEthOut);

        assertEq(bonds.amountOwedCdt(tokenId), strike - cdtToBurn);
        assertEq(bonds.conversionEntitlementStrat(tokenId), stratEnt - expectedStratOut);
        assertEq(bonds.conversionEntitlementEth(tokenId), ethEnt - expectedEthOut);
        assertEq(bonds.settlementEntitlementUsd(tokenId), strike - cdtToBurn);
    }

    function testPartialConvertToEthTransfersEsEthToOwner() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        uint256 strike = bonds.amountOwedCdt(tokenId);
        uint256 cdtToBurn = strike / 3;
        uint256 ethEnt = bonds.conversionEntitlementEth(tokenId);
        uint256 expectedEthOut = (ethEnt * cdtToBurn) / strike;

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.convertPartial(tokenId, true, cdtToBurn);
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEthOut);
    }

    function testFullConvertBurnsNftAndClearsTimestamps() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        bonds.convert(tokenId, false);

        assertEq(bonds.expiry(tokenId), 0);
        assertEq(bonds.timelock(tokenId), 0);
        vm.expectRevert();
        bonds.ownerOf(tokenId);
    }

    function testConvertWithPermitWorksWithoutPriorApprove() public {
        (uint256 tokenId,,,) = _bond(permitOwner, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        uint256 strike = bonds.amountOwedCdt(tokenId);
        uint256 deadline = block.timestamp + 1 hours;
        Permit.IPermitApproval memory approval = _getPermitOwnerSignature(
            permitOwner, permitPk, address(bonds), deadline, strike, cdtToken.DOMAIN_SEPARATOR()
        );

        vm.prank(permitOwner);
        bonds.convertWithPermit(tokenId, approval);

        vm.expectRevert();
        bonds.ownerOf(tokenId);
    }

    // ========= Redemption =========

    function testRedeemRevertsBeforeExpiry() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.OptionUnexpired.selector, user, tokenId));
        bonds.redeemCdtForUsdNotional(tokenId);
    }

    function testRedeemRevertsIfNotOwner() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.NotOwnerOrApproved.selector, other, tokenId));
        bonds.redeemCdtForUsdNotional(tokenId);
    }

    function testRedeemSolventPaysFullUsdNotionalInEth() public {
        (uint256 tokenId, uint256 settlementUsd,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        // Ensure "solvent" by making unencumbered holdings very large in USD terms
        vm.deal(owner, 20_000 ether);
        vm.prank(owner);
        esETHToken.wrapAndMint{value: 10_000 ether}(unencumberedHoldings);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId);

        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
    }

    function testRedeemInsolventPaysProRataShare() public {
        (uint256 tokenId, uint256 settlementUsd,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        // Drain unencumbered holdings down to a tiny amount (keep allowances intact).
        uint256 unencBal = esETHToken.balanceOf(unencumberedHoldings);
        if (unencBal > 1 ether) {
            vm.prank(unencumberedHoldings);
            esETHToken.transfer(address(0xCAFE), unencBal - 1 ether);
        }

        uint256 totalDebt = cdtToken.totalSupply();
        uint256 treasuryInETH = esETHToken.balanceOf(unencumberedHoldings);
        uint256 treasuryInUSD = (treasuryInETH * ETH_USD_PRICE) / 1e18;
        assertLe(treasuryInUSD, totalDebt);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId);

        uint256 expectedEth = (settlementUsd * treasuryInETH) / totalDebt;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
    }
}
