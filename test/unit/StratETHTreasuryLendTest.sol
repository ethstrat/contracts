// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {StratETHTreasuryLend} from "../../src/StratETHTreasuryLend.sol";
import {CdtToken} from "../../src/CdtToken.sol";
import {StratToken} from "../../src/StratToken.sol";
import {esETH} from "../../src/esETH.sol";

import {MockWETH} from "../mocks/MockWETH.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

contract StratETHTreasuryLendTest is Test {
    address internal owner = address(0xABCD);
    address internal borrower = address(0xBEEF);
    address internal other = address(0xCAFE);

    StratToken internal strat;
    CdtToken internal cdt;
    MockWETH internal weth;
    esETH internal esEth;
    StratETHTreasuryLend internal lend;

    address internal unencumberedHoldings = address(0x1111);
    address internal encumberedHoldings = address(0x2222);

    ITripwireController internal ctrl;

    function setUp() public {
        ctrl = ITripwireController(address(new TripwireController()));
        vm.startPrank(owner);
        strat = new StratToken(owner, ctrl, owner);
        cdt = new CdtToken(owner, ctrl, owner);
        weth = new MockWETH();
        esEth = new esETH(owner, address(weth), ctrl, owner);
        esEth.setTokenConfig(address(weth), esETH.TokenType.ERC20, true, true);
        esEth.addMinter(owner);
        esEth.addMinter(borrower);
        esEth.addMinter(other);

        // 10% APR
        lend = new StratETHTreasuryLend(
            address(cdt),
            address(strat),
            address(esEth),
            unencumberedHoldings,
            encumberedHoldings,
            0.1e18,
            owner,
            ctrl,
            owner
        );

        // Allow owner + lend to mint STRAT/CDT (lend needs this to return collateral on repay/roll).
        strat.manageMinter(owner, true);
        strat.manageMinter(address(lend), true);
        cdt.manageMinter(owner, true);
        cdt.manageMinter(address(lend), true);
        vm.stopPrank();

        // Seed holdings with esETH.
        vm.deal(owner, 2_000 ether);
        vm.prank(owner);
        esEth.wrapAndMint{value: 1_500 ether}(unencumberedHoldings);
        vm.prank(owner);
        esEth.wrapAndMint{value: 500 ether}(encumberedHoldings);

        // Holdings must approve TreasuryLend to spend esETH for loan payouts.
        vm.startPrank(unencumberedHoldings);
        esEth.approve(address(lend), type(uint256).max);
        vm.stopPrank();

        // Seed supplies/balances.
        vm.prank(owner);
        strat.mint(borrower, 1_000 ether);
        vm.prank(owner);
        cdt.mint(borrower, 1_000 ether);

        // Approvals for collateral burns.
        vm.startPrank(borrower);
        strat.approve(address(lend), type(uint256).max);
        cdt.approve(address(lend), type(uint256).max);
        esEth.approve(address(lend), type(uint256).max);
        vm.stopPrank();
    }

    function _borrow(uint256 stratIn, uint256 cdtIn) internal returns (uint256 tokenId) {
        vm.prank(borrower);
        lend.borrow(stratIn, cdtIn, 0, block.timestamp + 1 hours);
        tokenId = lend.nextTokenId() - 1;
        assertEq(lend.ownerOf(tokenId), borrower);
    }

    function test_Constructor_DefaultsAndRoles() public view {
        assertEq(lend.loanDuration(), 180 days);
        assertEq(lend.borrowRate(), 0.1e18);
        assertEq(lend.rateSetter(), owner);
        assertEq(lend.feeSetter(), owner);
        assertEq(lend.interestRevenueRecipient(), owner);
    }

    function test_US000_Roles_OwnerCanSetAndNonOwnerCannot() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        lend.setRateSetter(other);

        vm.prank(owner);
        lend.setRateSetter(other);
        assertEq(lend.rateSetter(), other);

        vm.prank(owner);
        vm.expectRevert(StratETHTreasuryLend.ZeroAddress.selector);
        lend.setFeeSetter(address(0));

        vm.prank(owner);
        lend.setFeeSetter(other);
        assertEq(lend.feeSetter(), other);
    }

    function test_US101_PreviewBorrow_MatchesBorrowAndCoverage() public {
        // Make CDT the limiting factor: only 60 STRAT is covered.
        uint256 stratIn = 100 ether;
        uint256 cdtIn = 60 ether;

        (
            uint256 coveredStrat,
            uint256 coveredCdt,
            uint256 ethBacking,
            uint256 borrowAmount,
            uint256 maxTermInterest,
            uint256 delinquentFee
        ) = lend.previewBorrow(stratIn, cdtIn);

        assertEq(coveredStrat, 60 ether);
        assertEq(coveredCdt, 60 ether);
        assertGt(ethBacking, 0);
        assertGt(borrowAmount, 0);
        assertGt(maxTermInterest, 0);

        uint256 stratBalBefore = strat.balanceOf(borrower);
        uint256 cdtBalBefore = cdt.balanceOf(borrower);
        uint256 esEthBalBefore = esEth.balanceOf(borrower);

        uint256 tokenId = _borrow(stratIn, cdtIn);

        // Only the covered portion should be pulled.
        assertEq(stratBalBefore - strat.balanceOf(borrower), 60 ether);
        assertEq(cdtBalBefore - cdt.balanceOf(borrower), 60 ether);

        // Borrow proceeds are paid out as esETH.
        assertEq(esEth.balanceOf(borrower) - esEthBalBefore, borrowAmount);

        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);
        assertEq(p.stratCollateral, 60 ether);
        assertEq(p.cdtCollateral, 60 ether);
        assertEq(p.principal, borrowAmount);
        assertEq(p.maxTermInterest, maxTermInterest);
        assertEq(p.rate, lend.borrowRate());
        assertEq(p.delinquentFee, delinquentFee);
    }

    function test_US201_Repay_OnlyPositionOwner_And_BeforeExpiry() public {
        uint256 tokenId = _borrow(100 ether, 100 ether);

        // Transfer NFT; new owner controls repayment.
        vm.prank(borrower);
        lend.transferFrom(borrower, other, tokenId);
        assertEq(lend.ownerOf(tokenId), other);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(StratETHTreasuryLend.NotPositionOwner.selector, borrower, tokenId));
        lend.repay(tokenId);

        // Fund interest so other can repay.
        vm.startPrank(other);
        esEth.approve(address(lend), type(uint256).max);
        vm.stopPrank();

        // Move slightly forward to make interest non-zero.
        vm.warp(block.timestamp + 7 days);
        uint256 interest = lend.accruedInterest(tokenId);
        if (interest > esEth.balanceOf(other)) {
            vm.deal(other, interest);
            vm.prank(other);
            esEth.wrapAndMint{value: interest}(other);
        }

        // Transfer principal esETH from borrower to other so other can repay fully.
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);
        vm.prank(borrower);
        esEth.transfer(other, p.principal);

        vm.prank(other);
        lend.repay(tokenId);

        // NFT burned
        vm.expectRevert();
        lend.ownerOf(tokenId);
    }

    function test_US200_Interest_Linear_And_DistributedOnRepay() public {
        // Route interest to a revenue recipient (US-600 intent).
        address revenue = address(0xD00D);
        vm.prank(owner);
        lend.setInterestRevenueRecipient(revenue);

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);

        // Half term should accrue ~half maxTermInterest.
        vm.warp(p.startTime + lend.loanDuration() / 2);
        uint256 accrued = lend.accruedInterest(tokenId);
        assertApproxEqAbs(accrued, p.maxTermInterest / 2, 1e12);

        // Ensure borrower has enough esETH for principal + interest.
        uint256 need = p.principal + accrued;
        uint256 bal = esEth.balanceOf(borrower);
        if (bal < need) {
            vm.deal(borrower, need - bal);
            vm.prank(borrower);
            esEth.wrapAndMint{value: need - bal}(borrower);
        }

        uint256 unencBefore = esEth.balanceOf(unencumberedHoldings);
        uint256 revenueBefore = esEth.balanceOf(revenue);

        vm.prank(borrower);
        lend.repay(tokenId);

        // Full backing (principal + reserved interest + delinquent fee) returned to unencumbered holdings.
        assertEq(esEth.balanceOf(unencumberedHoldings), unencBefore + p.principal + p.maxTermInterest + p.delinquentFee);
        // Accrued interest routed as esETH to revenue recipient.
        assertEq(esEth.balanceOf(revenue) - revenueBefore, accrued);
    }

    function test_US300_301_302_Roll_SettlesInterest_And_AdjustsPrincipal() public {
        vm.startPrank(owner);
        address revenue = address(0xD00D);
        lend.setInterestRevenueRecipient(revenue);
        vm.stopPrank();

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p0 = lend.getPosition(tokenId);

        // Accrue some interest.
        vm.warp(block.timestamp + 30 days);
        uint256 interest = lend.accruedInterest(tokenId);
        if (interest > 0) {
            uint256 bal = esEth.balanceOf(borrower);
            if (bal < interest) {
                vm.deal(borrower, interest - bal);
                vm.prank(borrower);
                esEth.wrapAndMint{value: interest - bal}(borrower);
            }
        }

        uint256 revenueBefore = esEth.balanceOf(revenue);

        // Increase collateral -> should increase principal and pay out delta.
        vm.prank(owner);
        strat.mint(borrower, 100 ether);
        vm.prank(owner);
        cdt.mint(borrower, 100 ether);

        uint256 esEthBefore = esEth.balanceOf(borrower);
        vm.prank(borrower);
        lend.roll(tokenId, 200 ether, 200 ether, 0, block.timestamp + 1 hours);

        // Interest settled to revenue recipient.
        assertEq(esEth.balanceOf(revenue) - revenueBefore, interest);

        StratETHTreasuryLend.Position memory p1 = lend.getPosition(tokenId);
        assertEq(p1.stratCollateral, 200 ether);
        assertEq(p1.cdtCollateral, 200 ether);
        assertGt(p1.principal, p0.principal);
        assertEq(p1.rate, lend.borrowRate());
        assertEq(p1.startTime, block.timestamp);
        assertEq(p1.expiry, block.timestamp + lend.loanDuration());

        // Net esETH change = principal delta payout - interest paid during roll.
        assertEq(esEth.balanceOf(borrower) - esEthBefore, (p1.principal - p0.principal) - interest);

        // Now roll down collateral -> should require pay-in.
        uint256 tokenId2 = tokenId;
        StratETHTreasuryLend.Position memory pBeforeDown = lend.getPosition(tokenId2);

        // Ensure borrower has enough esETH to pay-in delta and accrued interest.
        vm.warp(block.timestamp + 7 days);
        uint256 interest2 = lend.accruedInterest(tokenId2);

        // Compute expected new principal for 150/150 by previewing via borrow preview formula.
        // We'll just roll and then compare treasury delta.
        uint256 unencBefore = esEth.balanceOf(unencumberedHoldings);

        // Top up esETH for interest + potential delta pay-in.
        uint256 topUp = interest2 + 10 ether;
        vm.deal(borrower, topUp);
        vm.prank(borrower);
        esEth.wrapAndMint{value: topUp}(borrower);

        vm.prank(borrower);
        lend.roll(tokenId2, 150 ether, 150 ether, 0, block.timestamp + 1 hours);

        StratETHTreasuryLend.Position memory pAfterDown = lend.getPosition(tokenId2);
        assertLt(pAfterDown.principal, pBeforeDown.principal);
        // Unencumbered holdings should receive the full backing reduction (principal + reserved interest + fee delta).
        // Allow 1-wei tolerance for integer division rounding.
        uint256 oldBacking = pBeforeDown.principal + pBeforeDown.maxTermInterest + pBeforeDown.delinquentFee;
        uint256 newBacking = pAfterDown.principal + pAfterDown.maxTermInterest + pAfterDown.delinquentFee;
        assertApproxEqAbs(esEth.balanceOf(unencumberedHoldings) - unencBefore, oldBacking - newBacking, 1);
    }

    // ======== Invariant / property-check tests ========
    //
    // INVARIANT PRECONDITION: interestRevenueRecipient must NOT be unencumberedHoldings
    // or encumberedHoldings.  Interest sent to a holdings address would increase
    // _totalHoldingsInETH() and violate ethPerStrat neutrality.  Every invariant
    // test below explicitly sets the recipient to address(0xFEED), a neutral address.

    /// @dev ethPerStrat = (esEth.balanceOf(unencumbered) + esEth.balanceOf(encumbered)) * 1e18 / strat.totalSupply()
    /// This mirrors the price used by previewBorrow: ethBacking = totalHoldingsInETH * stratIn / stratSupply.
    function _ethPerStrat() internal view returns (uint256) {
        uint256 totalHoldings = esEth.balanceOf(unencumberedHoldings) + esEth.balanceOf(encumberedHoldings);
        return totalHoldings * 1e18 / strat.totalSupply();
    }

    /// US-800: borrow must not change ethPerStrat.
    /// Proof: H_new = H - H*stratIn/S, S_new = S - stratIn
    ///        => H_new/S_new = H*(S-stratIn)/S / (S-stratIn) = H/S
    function test_Invariant_Borrow_EthPerStratPreserved() public {
        // Recipient must be outside holdings for the invariant to hold.
        vm.prank(owner);
        lend.setInterestRevenueRecipient(address(0xFEED));

        uint256 before = _ethPerStrat();
        _borrow(100 ether, 100 ether);
        assertApproxEqAbs(_ethPerStrat(), before, 1);
    }

    /// US-800: repay must not change ethPerStrat (it exactly reverses the borrow).
    function test_Invariant_Repay_EthPerStratPreserved() public {
        // Recipient must be outside holdings for the invariant to hold.
        vm.prank(owner);
        lend.setInterestRevenueRecipient(address(0xFEED));

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);

        vm.warp(block.timestamp + 45 days);
        uint256 interest = lend.accruedInterest(tokenId);

        // Top up borrower to cover principal + interest if needed.
        uint256 need = p.principal + interest;
        uint256 bal = esEth.balanceOf(borrower);
        if (bal < need) {
            vm.deal(borrower, need - bal);
            vm.prank(borrower);
            esEth.wrapAndMint{value: need - bal}(borrower);
        }

        uint256 before = _ethPerStrat();
        vm.prank(borrower);
        lend.repay(tokenId);

        assertApproxEqAbs(_ethPerStrat(), before, 1);
    }

    /// US-800: roll (up then down) must not change ethPerStrat.
    ///
    /// The borrower starts with 1000 STRAT / 1000 CDT.  After the initial
    /// borrow of 100/100 they have 900/900 remaining, enough to roll up to
    /// 200/200 (burns another 100/100 delta) and then down to 150/150 (mints
    /// back 50/50 delta).
    ///
    /// NOTE: we do NOT mint extra STRAT between rolls.  External minting without
    /// adding ETH backing changes ethPerStrat by design — the invariant only
    /// covers protocol-internal flows.
    ///
    /// NOTE on deadline: after each vm.warp, we read block.timestamp into a local
    /// variable *and* assert against position fields that embed the timestamp.
    /// Both steps are required to prevent the Solidity optimizer from caching the
    /// TIMESTAMP opcode result across vm.warp boundaries.
    function test_Invariant_Roll_EthPerStratPreserved() public {
        // Recipient must be outside holdings for the invariant to hold.
        vm.prank(owner);
        lend.setInterestRevenueRecipient(address(0xFEED));

        uint256 tokenId = _borrow(100 ether, 100 ether);

        // ---- Roll up: 100/100 → 200/200 ----
        vm.warp(block.timestamp + 30 days);
        // Capture fresh timestamp into a local to guard against optimizer caching.
        uint256 ts1 = block.timestamp;

        uint256 interest = lend.accruedInterest(tokenId);
        uint256 bal = esEth.balanceOf(borrower);
        if (bal < interest) {
            vm.deal(borrower, interest - bal);
            vm.prank(borrower);
            esEth.wrapAndMint{value: interest - bal}(borrower);
        }

        uint256 beforeUp = _ethPerStrat();
        vm.prank(borrower);
        lend.roll(tokenId, 200 ether, 200 ether, 0, ts1 + 1 hours);

        // Assert position timestamps — this forces additional TIMESTAMP opcode reads in
        // the test frame and prevents the compiler from reusing ts1 for the next warp.
        StratETHTreasuryLend.Position memory p1 = lend.getPosition(tokenId);
        assertEq(p1.startTime, block.timestamp);
        assertEq(p1.expiry, block.timestamp + lend.loanDuration());
        assertApproxEqAbs(_ethPerStrat(), beforeUp, 2);

        // ---- Roll down: 200/200 → 150/150 ----
        vm.warp(block.timestamp + 7 days);
        // Capture fresh timestamp after the second warp.
        uint256 ts2 = block.timestamp;

        uint256 interest2 = lend.accruedInterest(tokenId);
        StratETHTreasuryLend.Position memory p2 = lend.getPosition(tokenId);

        uint256 maxPayIn = p2.principal + interest2;
        uint256 bal2 = esEth.balanceOf(borrower);
        if (bal2 < maxPayIn) {
            vm.deal(borrower, maxPayIn - bal2);
            vm.prank(borrower);
            esEth.wrapAndMint{value: maxPayIn - bal2}(borrower);
        }

        uint256 beforeDown = _ethPerStrat();
        vm.prank(borrower);
        lend.roll(tokenId, 150 ether, 150 ether, 0, ts2 + 1 hours);
        assertApproxEqAbs(_ethPerStrat(), beforeDown, 2);
    }

    /// US-801: liquidation must increase ethPerStrat by exactly delinquentFee / STRAT.totalSupply().
    ///
    /// On liquidation:
    ///   - STRAT supply is unchanged (collateral was burned at origination, not returned).
    ///   - delinquentFee esETH is returned from TreasuryLend to unencumberedHoldings.
    ///   => ethPerStrat_after = ethPerStrat_before + delinquentFee / stratSupply
    function test_Invariant_Liquidate_EthPerStratIncreasedByDelinquentFee() public {
        // Recipient must be outside holdings so only delinquentFee (not maxTermInterest)
        // flows into holdings on liquidation.
        vm.prank(owner);
        lend.setInterestRevenueRecipient(address(0xFEED));

        // Set a non-zero delinquent fee so the test is meaningful.
        vm.prank(owner);
        lend.setDelinquentFeeRate(0.05e18); // 5 %

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);
        assertGt(p.delinquentFee, 0, "delinquentFee should be non-zero");

        // Capture supply after borrow (STRAT burned at origination, not returned on liquidation).
        uint256 stratSupply = strat.totalSupply();

        uint256 ethPerStratBefore = _ethPerStrat();

        vm.warp(p.expiry);
        vm.prank(other);
        lend.liquidate(tokenId);

        uint256 ethPerStratAfter = _ethPerStrat();

        // Must increase.
        assertGt(ethPerStratAfter, ethPerStratBefore);

        // Increase must equal delinquentFee / stratSupply (scaled by 1e18), within 1 wei.
        assertApproxEqAbs(ethPerStratAfter - ethPerStratBefore, p.delinquentFee * 1e18 / stratSupply, 1);
    }

    function test_US400_401_Liquidation_Rules() public {
        address revenue = address(0xD00D);
        vm.prank(owner);
        lend.setInterestRevenueRecipient(revenue);

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(StratETHTreasuryLend.LoanUnexpired.selector, tokenId));
        lend.liquidate(tokenId);

        uint256 unencBefore = esEth.balanceOf(unencumberedHoldings);
        uint256 revenueBefore = esEth.balanceOf(revenue);

        vm.warp(p.expiry);
        vm.prank(other);
        lend.liquidate(tokenId);

        // Full-term interest (reserved at origination) routed from TreasuryLend to revenue recipient.
        assertEq(esEth.balanceOf(revenue), revenueBefore + p.maxTermInterest);
        // Delinquent fee (reserved at origination) returned from TreasuryLend to unencumbered holdings.
        assertEq(esEth.balanceOf(unencumberedHoldings), unencBefore + p.delinquentFee);

        // NFT burned
        vm.expectRevert();
        lend.ownerOf(tokenId);
    }
}
