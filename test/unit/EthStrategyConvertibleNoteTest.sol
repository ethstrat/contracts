// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../../src/EthStrategyConvertibleNote.sol";
import "../../src/CdtToken.sol";
import "../../src/StratToken.sol";

import "../mocks/MockWETH.sol";
import {EthUsdPriceOracleProvider} from "../lib/EthUsdPriceOracleProvider.sol";
import {PermitGenerator} from "../lib/Permit.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

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

    ITripwireController internal ctrl;

    function setUp() public {
        (permitOwner, permitPk) = makeAddrAndKey("PERMIT_OWNER");

        _setUpEthUsdOracle(ETH_USD_PRICE);

        ctrl = ITripwireController(address(new TripwireController()));

        vm.startPrank(owner);
        cdtToken = new CdtToken(owner, ctrl, owner);
        stratToken = new StratToken(owner, ctrl, owner);

        // Deploy esETH with a local WETH implementation. Mark WETH as mintable so bond() can call wrapAndMint.
        weth = new MockWETH();
        esETHToken = new esETH(owner, address(weth), ctrl, owner);
        esETHToken.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);
        esETHToken.addMinter(owner);

        // Deploy the note contract (per current spec)
        bonds = new EthStrategyConvertibleNote(
            address(cdtToken),
            address(stratToken),
            address(esETHToken),
            unencumberedHoldings,
            encumberedHoldings,
            address(ethUsdOracle),
            owner,
            ctrl,
            owner
        );
        esETHToken.addMinter(address(bonds));

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

    /// @dev No boundary overlap: conversion requires `block.timestamp < expiry`; redemption allows
    ///      `expiry <= block.timestamp`. At `expiry == block.timestamp`, convert reverts and redeem works.
    function testNoBoundaryOverlap_ConvertAtExpiryReverts_RedeemSucceeds() public {
        (uint256 tokenId, uint256 settlementUsd,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        uint256 exp = bonds.expiry(tokenId);
        vm.warp(exp);
        assertEq(block.timestamp, exp, "sanity: warp to exact expiry");

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.OptionExpired.selector, user, tokenId));
        bonds.convertPartial(tokenId, false, 1);

        vm.deal(owner, 20_000 ether);
        vm.prank(owner);
        esETHToken.wrapAndMint{value: 10_000 ether}(unencumberedHoldings);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId, 0);
        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
    }

    function testConvertSucceedsOneSecondBeforeExpiry() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);

        uint256 exp = bonds.expiry(tokenId);
        vm.warp(exp - 1);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        vm.prank(user);
        bonds.convertPartial(tokenId, false, 1);
    }

    // ========= Admin =========

    function testOnlyOwnerCanSetBCF() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bonds.setBCF(5);

        vm.prank(owner);
        bonds.setBCF(5);
        assertEq(bonds.bcf(), 5);
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
        bonds.redeemCdtForUsdNotional(tokenId, 0);
    }

    function testRedeemRevertsIfNotOwner() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.NotOwnerOrApproved.selector, other, tokenId));
        bonds.redeemCdtForUsdNotional(tokenId, 0);
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
        bonds.redeemCdtForUsdNotional(tokenId, 0);

        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
    }

    function testRedeemSolventIncludesEncumberedEthInSolvencyCheck() public {
        (uint256 tokenId, uint256 settlementUsd,, uint256 entitlementEth) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        // Make unencumbered holdings insufficient on their own, but keep total treasury solvent.
        uint256 unencBal = esETHToken.balanceOf(unencumberedHoldings);
        uint256 targetUnenc = 0.1 ether;
        if (unencBal > targetUnenc) {
            vm.prank(unencumberedHoldings);
            esETHToken.transfer(address(0xCAFE), unencBal - targetUnenc);
        }

        uint256 encBal = esETHToken.balanceOf(encumberedHoldings);
        uint256 targetEnc = entitlementEth + 1 ether;
        if (encBal > targetEnc) {
            vm.prank(encumberedHoldings);
            esETHToken.transfer(address(0xBEEF), encBal - targetEnc);
        }

        uint256 totalDebt = cdtToken.totalSupply();
        uint256 unencTreasuryEth = esETHToken.balanceOf(unencumberedHoldings);
        uint256 totalTreasuryEth = unencTreasuryEth + esETHToken.balanceOf(encumberedHoldings);
        uint256 unencTreasuryUsd = (unencTreasuryEth * ETH_USD_PRICE) / 1e18;
        uint256 totalTreasuryUsd = (totalTreasuryEth * ETH_USD_PRICE) / 1e18;

        assertLe(unencTreasuryUsd, totalDebt, "Unencumbered-only view should appear insolvent");
        assertGt(totalTreasuryUsd, totalDebt, "Total treasury should be solvent");

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId, 0);

        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
    }

    /// @notice Recovery mode: oracle marks treasury underwater (USD value of all esETH <= CDT supply), so each CDT
    ///         dollar redeemed gets a pro-rata share of all treasury ETH (encumbered + unencumbered in the formula).
    ///         Payout is taken from unencumbered after moving this note's encumbrance entitlement only, so idle esETH
    ///         must live in unencumbered for a full-treasury pro-rata redemption to succeed.
    function testRedeemRecoveryModeProRataClaimsOnFullTreasuryEth() public {
        // Move fixture seed from encumbered → unencumbered: redemption no longer sweeps all encumbered balance for
        // payout, but burning 100% of CDT here pays essentially the whole treasury in esETH out of unencumbered.
        uint256 encSeed = esETHToken.balanceOf(encumberedHoldings);
        vm.prank(encumberedHoldings);
        esETHToken.transfer(unencumberedHoldings, encSeed);

        (uint256 tokenId, uint256 settlementUsd,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        // Push oracle price low so total treasury USD is below CDT supply (recovery / pro-rata path).
        uint256 lowEthPrice = 1e18;
        ethUsdOracle.setBasePerQuote(lowEthPrice);

        uint256 totalDebt = cdtToken.totalSupply();
        uint256 treasuryInETH = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 treasuryInUSD = (treasuryInETH * lowEthPrice) / 1e18;
        assertLe(treasuryInUSD, totalDebt);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId, 0);

        uint256 expectedEth = (settlementUsd * treasuryInETH) / totalDebt;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
    }

    function testRedeemRevertsOnInsufficientEthOut() public {
        (uint256 tokenId, uint256 settlementUsd,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        _warpPastExpiry(tokenId);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(EthStrategyConvertibleNote.InsufficientOutput.selector, expectedEth + 1, expectedEth)
        );
        bonds.redeemCdtForUsdNotional(tokenId, expectedEth + 1);
    }

    // ========= releaseEncumbrance =========

    function testReleaseEncumbranceRevertsIfNotOwner() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastExpiry(tokenId);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bonds.releaseEncumbrance(tokenId);
    }

    function testReleaseEncumbranceRevertsBeforeExpiry() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId);
        // still before expiry

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.OptionUnexpired.selector, owner, tokenId));
        bonds.releaseEncumbrance(tokenId);
    }

    function testReleaseEncumbranceRevertsForNonExistentOrSettledToken() public {
        // tokenId 999 never existed; expiry[999] == 0 so it should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.OptionUnexpired.selector, owner, 999));
        bonds.releaseEncumbrance(999);
    }

    function testReleaseEncumbranceMovesEthToUnencumberedAfterExpiry() public {
        (uint256 tokenId,,, uint256 entitlementEth) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastExpiry(tokenId);

        uint256 encBefore = esETHToken.balanceOf(encumberedHoldings);
        uint256 unencBefore = esETHToken.balanceOf(unencumberedHoldings);

        vm.prank(owner);
        bonds.releaseEncumbrance(tokenId);

        assertEq(esETHToken.balanceOf(encumberedHoldings), encBefore - entitlementEth);
        assertEq(esETHToken.balanceOf(unencumberedHoldings), unencBefore + entitlementEth);
        assertTrue(bonds.encumbranceReleased(tokenId));
    }

    function testReleaseEncumbranceRevertsIfCalledTwice() public {
        (uint256 tokenId,,,) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastExpiry(tokenId);

        vm.prank(owner);
        bonds.releaseEncumbrance(tokenId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EthStrategyConvertibleNote.EncumbranceAlreadyReleased.selector, tokenId));
        bonds.releaseEncumbrance(tokenId);
    }

    function testReleaseEncumbranceEmitsEvent() public {
        (uint256 tokenId,,, uint256 entitlementEth) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastExpiry(tokenId);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit EthStrategyConvertibleNote.EncumbranceReleased(tokenId, entitlementEth);
        bonds.releaseEncumbrance(tokenId);
    }

    function testRedeemSkipsEncumbranceTransferIfAlreadyReleased() public {
        (uint256 tokenId, uint256 settlementUsd,, uint256 entitlementEth) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastExpiry(tokenId);

        // Owner releases encumbrance beforehand
        vm.prank(owner);
        bonds.releaseEncumbrance(tokenId);

        uint256 encBefore = esETHToken.balanceOf(encumberedHoldings);
        uint256 unencBefore = esETHToken.balanceOf(unencumberedHoldings);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId, 0);

        // Encumbered holdings should NOT have moved again during redemption
        assertEq(esETHToken.balanceOf(encumberedHoldings), encBefore, "Encumbered should not change during redeem");

        // unencBefore is measured after releaseEncumbrance, so entitlementEth is already reflected in it.
        // During redemption (encumbranceReleased == true) the only change is the payout draining unencumbered.
        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
        assertEq(esETHToken.balanceOf(unencumberedHoldings), unencBefore - expectedEth);
    }

    function testRedeemWithoutPriorReleaseStillMovesEncumbranceInline() public {
        (uint256 tokenId, uint256 settlementUsd,, uint256 entitlementEth) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastExpiry(tokenId);

        uint256 encBefore = esETHToken.balanceOf(encumberedHoldings);
        uint256 unencBefore = esETHToken.balanceOf(unencumberedHoldings);

        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.redeemCdtForUsdNotional(tokenId, 0);

        uint256 expectedEth = (settlementUsd * 1e18) / ETH_USD_PRICE;
        assertEq(esETHToken.balanceOf(user) - userEthBefore, expectedEth);
        // Encumbered drained by entitlementEth inline; net change on unencumbered = entitlementEth - ethOut
        assertEq(esETHToken.balanceOf(encumberedHoldings), encBefore - entitlementEth);
        assertEq(esETHToken.balanceOf(unencumberedHoldings), unencBefore + entitlementEth - expectedEth);
    }

    // ========= BCF and NAV Pricing Tests =========

    /// @notice NAV-based pricing: raising NAV (donating ETH to the treasury without minting matching
    ///         debt) makes each STRAT more expensive, so a fixed USD notional buys fewer STRAT.
    /// @dev    ETH moves the other way: the premium is a fixed haircut on the numerator, so a larger NAV
    ///         dilutes it and the ETH conversion right settles closer to par (1:1) — hence more ETH.
    function testNAVBasedPricing_HigherNavMeansFewerStrat() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        (uint256 stratBaseline, uint256 ethBaseline) = bonds.conversionEntitlements(settlementUsd);

        // Donate ETH straight into the treasury (raises NAV without adding CDT debt).
        uint256 currentEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        vm.deal(owner, currentEth);
        vm.prank(owner);
        esETHToken.wrapAndMint{value: currentEth}(unencumberedHoldings);

        (uint256 stratHigherNav, uint256 ethHigherNav) = bonds.conversionEntitlements(settlementUsd);

        assertLt(stratHigherNav, stratBaseline, "Higher NAV should give fewer STRAT per USD");
        assertGt(ethHigherNav, ethBaseline, "Higher NAV dilutes the premium haircut, so ETH settles closer to par");
    }

    /// @notice Pricing is off NAV (net of debt), not GAV. With bcf = 0 the premium term drops out, leaving
    ///         numerator = NAV, so minting CDT debt (which lowers NAV without touching GAV) makes a fixed
    ///         USD notional buy MORE STRAT. Under GAV-based pricing this would not change at all.
    function testNAVBasedPricing_DebtSubtractedFromNumerator() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        // Isolate the NAV term by removing the premium contribution.
        vm.prank(owner);
        bonds.setBCF(0);

        (uint256 stratBaseline,) = bonds.conversionEntitlements(settlementUsd);

        // Mint CDT debt without adding ETH: GAV unchanged, NAV falls.
        vm.prank(owner);
        cdtToken.manageMinter(owner, true);
        vm.prank(owner);
        cdtToken.mint(user, 100_000 * 1e18);

        (uint256 stratMoreDebt,) = bonds.conversionEntitlements(settlementUsd);

        assertGt(stratMoreDebt, stratBaseline, "Lower NAV (more debt) should give more STRAT per USD");
    }

    /// @notice Invariant: BCF of 2*SCALE should have a similar effect to doubling CDT supply
    ///         (both grow the premium term of the numerator).
    function testBCFInvariant_DoublingBCFSimilarToDoublingCDT() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        // Scenario 1: Bond once to establish baseline CDT supply
        _bond(other, 1 ether, 0, 0, block.timestamp);
        uint256 baselineCdtSupply = cdtToken.totalSupply();

        (uint256 stratBaseline,) = bonds.conversionEntitlements(settlementUsd);

        // Scenario 2: Bond again to double the CDT supply
        _bond(user, 1 ether, 0, 0, block.timestamp);
        assertApproxEqRel(cdtToken.totalSupply(), baselineCdtSupply * 2, 0.01e18, "CDT supply should be ~2x");

        (uint256 stratWithDoubleCDT,) = bonds.conversionEntitlements(settlementUsd);

        // Scenario 3: Reset to baseline by having the user burn their CDT, then set bcf = 2*SCALE
        uint256 userCdtBalance = cdtToken.balanceOf(user);
        vm.prank(user);
        cdtToken.burn(userCdtBalance);

        vm.prank(owner);
        bonds.setBCF(2e18);

        (uint256 stratWithDoubleBCF,) = bonds.conversionEntitlements(settlementUsd);

        // Doubling BCF should have similar effect to doubling CDT (both increase premium term)
        // Both should decrease entitlements compared to baseline
        assertLt(stratWithDoubleCDT, stratBaseline, "2x CDT should give less STRAT than baseline");
        assertLt(stratWithDoubleBCF, stratBaseline, "BCF=2 should give less STRAT than baseline");

        // The effects should be approximately similar
        assertApproxEqRel(
            stratWithDoubleBCF,
            stratWithDoubleCDT,
            0.15e18,
            "BCF=2 should give similar STRAT entitlement as 2x CDT (within 15%)"
        );
    }

    /// @notice Test that changing BCF affects pricing for new bonds as expected
    function testBCFChangesAffectNewBondPricing() public {
        uint256 ethAmount = 1 ether;
        uint256 settlementUsd = (ethAmount * ETH_USD_PRICE) / 1e18;

        // Get conversion entitlements with default bcf = 1*SCALE
        (uint256 stratDefault, uint256 ethDefault) = bonds.conversionEntitlements(settlementUsd);

        // Set bcf = 0.5*SCALE
        vm.prank(owner);
        bonds.setBCF(0.5e18);
        (uint256 stratHalf, uint256 ethHalf) = bonds.conversionEntitlements(settlementUsd);

        // Set bcf = 3*SCALE
        vm.prank(owner);
        bonds.setBCF(3e18);
        (uint256 stratTriple, uint256 ethTriple) = bonds.conversionEntitlements(settlementUsd);

        // Lower BCF should give higher entitlements (lower premium, lower numerator)
        assertGt(stratHalf, stratDefault, "BCF=0.5 should give more STRAT than BCF=1");
        assertGt(ethHalf, ethDefault, "BCF=0.5 should give more ETH than BCF=1");

        // Higher BCF should give lower entitlements (higher premium, higher numerator)
        assertLt(stratTriple, stratDefault, "BCF=3 should give less STRAT than BCF=1");
        assertLt(ethTriple, ethDefault, "BCF=3 should give less ETH than BCF=1");
    }

    /// @notice Test extreme BCF values don't break the contract
    function testExtremeBCFValues() public {
        uint256 ethAmount = 0.1 ether;
        uint256 settlementUsd = (ethAmount * ETH_USD_PRICE) / 1e18;

        // Very large BCF
        vm.prank(owner);
        bonds.setBCF(1000e18);
        (uint256 stratLargeBCF, uint256 ethLargeBCF) = bonds.conversionEntitlements(settlementUsd);
        assertGt(stratLargeBCF, 0, "Large BCF should still give valid STRAT entitlement");
        assertGt(ethLargeBCF, 0, "Large BCF should still give valid ETH entitlement");

        // BCF = 0 leaves only the NAV term in the numerator
        vm.prank(owner);
        bonds.setBCF(0);
        (uint256 stratZeroBCF, uint256 ethZeroBCF) = bonds.conversionEntitlements(settlementUsd);
        assertGt(stratZeroBCF, 0, "BCF=0 should still give valid STRAT entitlement (from NAV term)");
        assertGt(ethZeroBCF, 0, "BCF=0 should still give valid ETH entitlement (from NAV term)");
    }

    // ========= NAV Floor Price Tests =========

    function testOnlyOwnerCanSetNavFloorPrice() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bonds.setNavFloorPrice(1e18);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit EthStrategyConvertibleNote.OwnerChangedNavFloorPrice(0, 500_000e18);
        bonds.setNavFloorPrice(500_000e18);
        assertEq(bonds.navFloorPrice(), 500_000e18);
    }

    /// @notice The floor defaults to 0 (disabled), and a floor below live NAV does not change pricing:
    ///         bonding prices off max(nav, navFloorPrice).
    function testNavFloorPriceBelowNavHasNoEffect() public {
        assertEq(bonds.navFloorPrice(), 0, "NAV floor price should default to 0 (disabled)");

        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;
        (uint256 stratBaseline, uint256 ethBaseline) = bonds.conversionEntitlements(settlementUsd);

        // Live NAV here is ~600k USD (200 ETH * $3000). A floor well below that must not move pricing.
        vm.prank(owner);
        bonds.setNavFloorPrice(100_000e18);

        (uint256 stratLowFloor, uint256 ethLowFloor) = bonds.conversionEntitlements(settlementUsd);
        assertEq(stratLowFloor, stratBaseline, "Floor below NAV should not change STRAT pricing");
        assertEq(ethLowFloor, ethBaseline, "Floor below NAV should not change ETH pricing");
    }

    /// @notice A floor above live NAV lifts the pricing NAV to the floor, making bonds more expensive
    ///         (fewer STRAT / less ETH per USD) — bonds are never sold as if NAV were below the floor.
    function testNavFloorPriceAboveNavLiftsPricing() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;
        (uint256 stratBaseline, uint256 ethBaseline) = bonds.conversionEntitlements(settlementUsd);

        // Live NAV is ~600k USD; set the floor to 2x that so pricing uses the floor.
        vm.prank(owner);
        bonds.setNavFloorPrice(1_200_000e18);

        (uint256 stratFloored, uint256 ethFloored) = bonds.conversionEntitlements(settlementUsd);

        assertLt(stratFloored, stratBaseline, "Floor above NAV should give fewer STRAT per USD");
        assertLt(ethFloored, ethBaseline, "Floor above NAV should give less ETH per USD");
    }

    /// @notice The floor only ever raises the pricing NAV (it is a floor, not a cap): raising the floor
    ///         monotonically reduces the STRAT entitlement for a fixed notional.
    function testNavFloorPriceIsMonotonic() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        vm.prank(owner);
        bonds.setNavFloorPrice(1_000_000e18);
        (uint256 stratFloorLow,) = bonds.conversionEntitlements(settlementUsd);

        vm.prank(owner);
        bonds.setNavFloorPrice(2_000_000e18);
        (uint256 stratFloorHigh,) = bonds.conversionEntitlements(settlementUsd);

        assertLt(stratFloorHigh, stratFloorLow, "A higher floor should give fewer STRAT per USD");
    }

    // ========= ETH Conversion Bounded By Deposit =========

    /// @notice A note can never carry the right to convert out more ETH than was deposited: the stored ETH
    ///         entitlement is capped at msg.value at bond time, across a range of bond sizes.
    function testEthEntitlementNeverExceedsDeposit() public {
        uint256[3] memory amounts = [uint256(0.5 ether), 1 ether, 5 ether];
        for (uint256 i = 0; i < amounts.length; i++) {
            (uint256 tokenId,,,) = _bond(user, amounts[i], 0, 0, block.timestamp);
            assertLe(bonds.conversionEntitlementEth(tokenId), amounts[i], "ETH entitlement must not exceed deposit");
        }
    }

    /// @notice With bcf = 0 and no debt the numerator is exactly NAV, so the raw ETH entitlement equals the
    ///         deposit. The stored entitlement equals the full deposit and the whole deposit backs the ETH
    ///         conversion right (unencumbered holdings receive nothing — the zero-value wrapAndMint is skipped).
    function testEthEntitlementEqualsDepositWhenNumeratorIsPureNav() public {
        vm.prank(owner);
        bonds.setBCF(0);

        uint256 ethAmount = 1 ether;
        uint256 unencBefore = esETHToken.balanceOf(unencumberedHoldings);
        uint256 encBefore = esETHToken.balanceOf(encumberedHoldings);

        (uint256 tokenId,,,) = _bond(user, ethAmount, 0, 0, block.timestamp);

        assertEq(bonds.conversionEntitlementEth(tokenId), ethAmount, "entitlement should equal the full deposit");
        assertEq(esETHToken.balanceOf(encumberedHoldings) - encBefore, ethAmount, "all deposit backs the ETH right");
        assertEq(esETHToken.balanceOf(unencumberedHoldings), unencBefore, "unencumbered receives nothing");

        // Converting to ETH after timelock pays out exactly the deposit — never more.
        _warpPastTimelock(tokenId);
        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);
        uint256 userEthBefore = esETHToken.balanceOf(user);
        vm.prank(user);
        bonds.convert(tokenId, true);
        assertEq(esETHToken.balanceOf(user) - userEthBefore, ethAmount, "ETH out must not exceed ETH in");
    }

    /// @notice The stored ETH entitlement is exactly min(rawEntitlement, deposit): the cap binds whenever the
    ///         raw (pricing-formula) entitlement would meet or exceed the deposited ETH.
    function testEthEntitlementIsClampedToDeposit() public {
        // Establish debt, then drop the premium term (bcf = 0) so the numerator is just NAV.
        _bond(other, 10 ether, 0, 0, block.timestamp);
        vm.prank(owner);
        bonds.setBCF(0);

        uint256 ethAmount = 1 ether;
        uint256 settlementUsd = (ethAmount * ETH_USD_PRICE) / 1e18;
        (, uint256 rawEth) = bonds.conversionEntitlements(settlementUsd);

        (uint256 tokenId,,,) = _bond(user, ethAmount, 0, 0, block.timestamp);

        uint256 expected = rawEth > ethAmount ? ethAmount : rawEth;
        assertEq(bonds.conversionEntitlementEth(tokenId), expected, "stored entitlement should be min(raw, deposit)");
        assertLe(bonds.conversionEntitlementEth(tokenId), ethAmount, "never more than deposited");
    }

    // ========= NAV-Based ETH Conversion Tests =========

    /// @notice Core invariant: ethAmount = stratAmount × (navETH / stratTotalSupply)
    function testInvariant_EthAmountIsStratAmountTimesNAVRatio() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        (uint256 stratAmount, uint256 ethAmount) = bonds.conversionEntitlements(settlementUsd);

        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 debtInEth = cdtToken.totalSupply() * 1e18 / ETH_USD_PRICE;
        uint256 navETH = totalEth - debtInEth;
        uint256 stratTotalSupply = stratToken.totalSupply();

        // Calculate expected ethAmount based on invariant
        uint256 expectedEthAmount = stratAmount * navETH / stratTotalSupply;

        assertApproxEqRel(
            ethAmount, expectedEthAmount, 0.0001e18, "ethAmount should equal stratAmount * (navETH / stratTotalSupply)"
        );
    }

    /// @notice Test that ETH entitlement uses NAV (net of debt), not gross assets
    function testNAVBasedETHConversion() public {
        // Create initial debt by bonding
        _bond(user, 10 ether, 0, 0, block.timestamp);

        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;
        (uint256 stratAmount, uint256 ethAmount) = bonds.conversionEntitlements(settlementUsd);

        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 debtInEth = cdtToken.totalSupply() * 1e18 / ETH_USD_PRICE;
        uint256 navETH = totalEth - debtInEth;

        // NAV should be less than totalEth due to debt
        assertLt(navETH, totalEth, "NAV should be less than total ETH when debt exists");

        // ETH entitlement should be based on NAV, not totalEth
        uint256 ethPerStrat = navETH * 1e18 / stratToken.totalSupply();
        uint256 expectedEthAmount = stratAmount * ethPerStrat / 1e18;

        assertApproxEqRel(ethAmount, expectedEthAmount, 0.001e18, "ETH should be based on NAV ratio");
    }

    /// @notice Test underwater scenario: debtInEth > totalEth results in ethAmount = 0
    function testUnderwater_EthAmountIsZero() public {
        // Create large debt to make protocol underwater
        // Start with 200 ETH in treasury ($600k at $3000/ETH)
        // Need to create debt WITHOUT adding proportional ETH
        // Strategy: Manually mint CDT to create debt without bonding ETH
        vm.prank(owner);
        cdtToken.manageMinter(owner, true);

        // Mint $1M CDT debt (333.33 ETH worth) but treasury only has 200 ETH
        vm.prank(owner);
        cdtToken.mint(user, 1_000_000 * 1e18);

        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 debtInEth = cdtToken.totalSupply() * 1e18 / ETH_USD_PRICE;

        // Verify we're underwater
        assertGt(debtInEth, totalEth, "Protocol should be underwater");

        // New bond should have ethAmount = 0
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;
        (uint256 stratAmount, uint256 ethAmount) = bonds.conversionEntitlements(settlementUsd);

        assertGt(stratAmount, 0, "STRAT entitlement should still exist");
        assertEq(ethAmount, 0, "ETH entitlement should be zero when underwater");
    }

    /// @notice Test that bonding continues when underwater with ethAmount = 0
    /// @dev The bond() function now skips esETH.wrapAndMint when conversionAmountEth_ = 0
    function testUnderwater_BondingContinues() public {
        // Make protocol underwater by minting CDT without adding ETH
        vm.prank(owner);
        cdtToken.manageMinter(owner, true);

        vm.prank(owner);
        cdtToken.mint(user, 1_000_000 * 1e18);

        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 debtInEth = cdtToken.totalSupply() * 1e18 / ETH_USD_PRICE;
        assertGt(debtInEth, totalEth, "Should be underwater");

        // Verify conversionEntitlements returns 0 for ETH
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;
        (, uint256 ethAmount) = bonds.conversionEntitlements(settlementUsd);
        assertEq(ethAmount, 0, "Should have zero ETH entitlement");

        // Track balances before bonding
        uint256 unencumberedBefore = esETHToken.balanceOf(unencumberedHoldings);
        uint256 encumberedBefore = esETHToken.balanceOf(encumberedHoldings);

        // Bonding should succeed (all ETH goes to unencumbered holdings)
        (uint256 tokenId,,,) = _bond(other, 1 ether, 0, 0, block.timestamp);

        // Verify bond was created correctly
        assertEq(bonds.ownerOf(tokenId), other);
        assertGt(bonds.conversionEntitlementStrat(tokenId), 0, "Should have STRAT entitlement");
        assertEq(bonds.conversionEntitlementEth(tokenId), 0, "Should have zero ETH entitlement");

        // Verify all ETH went to unencumbered holdings (none to encumbered)
        assertEq(
            esETHToken.balanceOf(encumberedHoldings), encumberedBefore, "No ETH should go to encumbered when underwater"
        );
        assertEq(
            esETHToken.balanceOf(unencumberedHoldings),
            unencumberedBefore + 1 ether,
            "All bonded ETH should go to unencumbered"
        );
    }

    /// @notice Test edge case: debtInEth exactly equals totalEth
    function testEdgeCase_DebtEqualsAssets() public {
        // Start with known treasury balance
        uint256 initialTotalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);

        // Mint CDT debt exactly equal to ETH assets (without bonding)
        vm.prank(owner);
        cdtToken.manageMinter(owner, true);

        uint256 targetDebtUsd = initialTotalEth * ETH_USD_PRICE / 1e18;
        vm.prank(owner);
        cdtToken.mint(user, targetDebtUsd);

        uint256 debtInEth = cdtToken.totalSupply() * 1e18 / ETH_USD_PRICE;
        uint256 currentTotalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);

        // Verify debt equals assets
        assertApproxEqRel(debtInEth, currentTotalEth, 0.001e18, "Debt should equal assets");

        // New bond should have ethAmount = 0 (uses >= comparison)
        uint256 settlementUsd = (0.1 ether * ETH_USD_PRICE) / 1e18;
        (, uint256 ethAmount) = bonds.conversionEntitlements(settlementUsd);

        assertEq(ethAmount, 0, "ETH entitlement should be zero when debt equals assets");
    }

    /// @notice Test that increasing debt decreases ETH entitlement for new bonds
    function testIncreasingDebt_DecreasesETHEntitlement() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        // Measure initial entitlements (minimal debt)
        (, uint256 ethAmount1) = bonds.conversionEntitlements(settlementUsd);

        // Add significant debt
        _bond(user, 50 ether, 0, 0, block.timestamp);

        // Measure new entitlements
        (, uint256 ethAmount2) = bonds.conversionEntitlements(settlementUsd);

        // More debt should mean less ETH entitlement for new bonds
        assertLt(ethAmount2, ethAmount1, "Higher debt should reduce ETH entitlement");

        // Add more debt
        _bond(other, 50 ether, 0, 0, block.timestamp);

        (, uint256 ethAmount3) = bonds.conversionEntitlements(settlementUsd);

        assertLt(ethAmount3, ethAmount2, "Even higher debt should further reduce ETH entitlement");
    }

    /// @notice Test that STRAT entitlement is independent of debt level
    function testStratEntitlement_IndependentOfDebt() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        // Measure initial STRAT entitlement
        (uint256 stratAmount1,) = bonds.conversionEntitlements(settlementUsd);

        // Add debt (but not enough to change GAV significantly)
        _bond(user, 1 ether, 0, 0, block.timestamp);

        // Measure new STRAT entitlement
        (uint256 stratAmount2,) = bonds.conversionEntitlements(settlementUsd);

        // STRAT uses numeratorUsd / stratTotalSupply, where numeratorUsd = NAV + premium. Bonding adds ETH
        // and an equal amount of CDT debt, so NAV is preserved; with bcf = 1 the premium's growth exactly
        // offsets the debt's NAV reduction, leaving the STRAT entitlement relatively stable.
        assertApproxEqRel(stratAmount2, stratAmount1, 0.1e18, "STRAT entitlement should be relatively stable");
    }

    /// @notice Test NAV calculation accounts for existing CDT supply correctly
    function testNAV_CorrectDebtCalculation() public {
        uint256 settlementUsd = (1 ether * ETH_USD_PRICE) / 1e18;

        // Bond to create known debt
        _bond(user, 10 ether, 0, 0, block.timestamp);
        uint256 cdtSupply = cdtToken.totalSupply();

        (uint256 stratAmount, uint256 ethAmount) = bonds.conversionEntitlements(settlementUsd);

        // Calculate NAV manually
        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 debtInEth = cdtSupply * 1e18 / ETH_USD_PRICE;
        uint256 navETH = totalEth - debtInEth;

        // Verify the relationship
        uint256 stratSupply = stratToken.totalSupply();
        uint256 expectedRatio = navETH * 1e18 / stratSupply;
        uint256 actualRatio = ethAmount * 1e18 / stratAmount;

        assertApproxEqRel(actualRatio, expectedRatio, 0.001e18, "NAV ratio should match expected");
    }

    /// @notice Test that stored conversionEntitlementEth reflects NAV at bonding time
    function testStoredETHEntitlement_ReflectsNAVAtBondTime() public {
        // Bond with low debt
        (uint256 tokenId1,,, uint256 ethEnt1) = _bond(user, 1 ether, 0, 0, block.timestamp);

        // Add significant debt
        _bond(other, 50 ether, 0, 0, block.timestamp);

        // Bond again with high debt
        (uint256 tokenId2,,, uint256 ethEnt2) = _bond(other, 1 ether, 0, 0, block.timestamp);

        // Second bond should have lower ETH entitlement due to higher debt
        assertLt(ethEnt2, ethEnt1, "Later bond should have lower ETH entitlement due to higher debt");

        // Stored values should match
        assertEq(bonds.conversionEntitlementEth(tokenId1), ethEnt1, "Stored ETH entitlement should match");
        assertEq(bonds.conversionEntitlementEth(tokenId2), ethEnt2, "Stored ETH entitlement should match");
    }

    /// @notice Test conversion uses stored entitlements (not recalculated)
    function testConversion_UsesStoredEntitlements() public {
        // Bond at specific NAV level
        (uint256 tokenId,, uint256 stratEnt, uint256 ethEnt) = _bond(user, 1 ether, 0, 0, block.timestamp);

        // Add massive debt to change NAV drastically (without adding ETH)
        vm.prank(owner);
        cdtToken.manageMinter(owner, true);
        vm.prank(owner);
        cdtToken.mint(address(this), 500_000 * 1e18); // $500k debt without ETH

        // Verify NAV changed (should now be much lower or negative)
        uint256 totalEth = esETHToken.balanceOf(unencumberedHoldings) + esETHToken.balanceOf(encumberedHoldings);
        uint256 debtInEth = cdtToken.totalSupply() * 1e18 / ETH_USD_PRICE;

        // Current entitlements should be very different from stored values
        uint256 settlementUsd = bonds.settlementEntitlementUsd(tokenId);
        (uint256 currentStrat,) = bonds.conversionEntitlements(settlementUsd);

        // Stored values should differ from current calculations
        assertNotEq(currentStrat, stratEnt, "Current STRAT should differ from stored");
        // Note: both might be 0 if underwater, so we just verify the conversion uses stored values

        // Convert to STRAT using stored entitlements
        _warpPastTimelock(tokenId);
        vm.prank(user);
        cdtToken.approve(address(bonds), type(uint256).max);

        uint256 stratBefore = stratToken.balanceOf(user);

        vm.prank(user);
        bonds.convert(tokenId, false);

        // Should receive stored entitlements, not recalculated values
        uint256 stratReceived = stratToken.balanceOf(user) - stratBefore;
        assertEq(stratReceived, stratEnt, "Should receive stored STRAT entitlement");

        // Test ETH conversion separately
        (uint256 tokenId2,,, uint256 ethEnt2) = _bond(user, 1 ether, 0, 0, block.timestamp);
        _warpPastTimelock(tokenId2);

        uint256 ethBefore = esETHToken.balanceOf(user);

        vm.prank(user);
        bonds.convert(tokenId2, true);

        uint256 ethReceived = esETHToken.balanceOf(user) - ethBefore;
        assertEq(ethReceived, ethEnt2, "Should receive stored ETH entitlement");
    }

    /// @notice Test that NAV-based pricing creates fair distribution among bonders
    function testNAV_FairDistributionAcrossBonds() public {
        uint256 bondAmount = 10 ether;

        // Three bonders at different debt levels
        (,, uint256 strat1, uint256 eth1) = _bond(user, bondAmount, 0, 0, block.timestamp);
        (,, uint256 strat2, uint256 eth2) = _bond(other, bondAmount, 0, 0, block.timestamp);
        (,, uint256 strat3, uint256 eth3) = _bond(permitOwner, bondAmount, 0, 0, block.timestamp);

        // STRAT entitlements vary due to increasing premium (each bond adds CDT debt)
        // The premium term increases with each bond, making later bonds more expensive
        assertApproxEqRel(strat1, strat2, 0.15e18, "STRAT entitlements should be reasonably similar");
        assertApproxEqRel(strat2, strat3, 0.15e18, "STRAT entitlements should be reasonably similar");

        // ETH entitlements should decrease as debt increases (NAV effect)
        assertGt(eth1, eth2, "First bond should have higher ETH entitlement");
        assertGt(eth2, eth3, "Second bond should have higher ETH entitlement than third");

        // But each bond's ratio should still match the NAV ratio at their bond time
        // This is tested by the invariant test above
    }
}
