// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {StratETHTreasuryLend} from "../../src/StratETHTreasuryLend.sol";
import {CdtToken} from "../../src/CdtToken.sol";
import {StratToken} from "../../src/StratToken.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";

import {MockTreasury} from "../mocks/MockTreasury.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract StratETHTreasuryLendTest is Test {
    address internal owner = address(0xABCD);
    address internal borrower = address(0xBEEF);
    address internal other = address(0xCAFE);

    StratToken internal strat;
    CdtToken internal cdt;
    MockTreasury internal treasury;
    MockWETH internal weth;
    StratETHTreasuryLend internal lend;

    function setUp() public {
        vm.startPrank(owner);
        strat = new StratToken(owner);
        cdt = new CdtToken(owner);
        treasury = new MockTreasury();
        treasury.setWithdrawAllowed(true);
        weth = new MockWETH();

        // 10% APR
        lend = new StratETHTreasuryLend(address(cdt), address(strat), address(treasury), address(weth), 0.10e18, owner);

        // Allow owner + lend to mint STRAT/CDT (lend needs this to return collateral on repay/roll).
        strat.manageMinter(owner, true);
        strat.manageMinter(address(lend), true);
        cdt.manageMinter(owner, true);
        cdt.manageMinter(address(lend), true);
        vm.stopPrank();

        // Seed supplies/balances.
        vm.prank(owner);
        strat.mint(borrower, 1_000 ether);
        vm.prank(owner);
        cdt.mint(borrower, 1_000 ether);

        // Fund treasury with ETH liquidity.
        vm.deal(address(treasury), 1_000 ether);

        // Approvals for collateral burns.
        vm.startPrank(borrower);
        strat.approve(address(lend), type(uint256).max);
        cdt.approve(address(lend), type(uint256).max);
        weth.approve(address(lend), type(uint256).max);
        vm.stopPrank();
    }

    function _borrow(uint256 stratIn, uint256 cdtIn) internal returns (uint256 tokenId) {
        vm.prank(borrower);
        lend.borrow(stratIn, cdtIn, 0, block.timestamp + 1 hours);
        tokenId = lend.nextTokenId() - 1;
        assertEq(lend.ownerOf(tokenId), borrower);
    }

    function test_Constructor_DefaultsAndRoles() public view {
        assertEq(lend.maxLTV(), 0.9e18);
        assertEq(lend.loanDuration(), 180 days);
        assertEq(lend.borrowRate(), 0.10e18);
        assertEq(lend.debtPerStrat(), 1e18);
        assertEq(lend.rateSetter(), owner);
        assertEq(lend.feeSetter(), owner);
        assertEq(lend.revenueRecipient(), owner);
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

        (uint256 coveredStrat, uint256 maxBorrowBeforeInterest, uint256 maxTermInterest, uint256 borrowAmount) =
            lend.previewBorrow(stratIn, cdtIn);

        assertEq(coveredStrat, 60 ether);
        assertGt(maxBorrowBeforeInterest, 0);
        assertGt(borrowAmount, 0);
        assertGt(maxTermInterest, 0);

        uint256 stratBalBefore = strat.balanceOf(borrower);
        uint256 cdtBalBefore = cdt.balanceOf(borrower);
        uint256 wethBalBefore = weth.balanceOf(borrower);

        uint256 tokenId = _borrow(stratIn, cdtIn);

        // Only the covered portion should be pulled.
        assertEq(stratBalBefore - strat.balanceOf(borrower), 60 ether);
        assertEq(cdtBalBefore - cdt.balanceOf(borrower), 60 ether);

        // Borrow proceeds are paid out as wrapped ETH.
        assertEq(weth.balanceOf(borrower) - wethBalBefore, borrowAmount);

        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);
        assertEq(p.stratCollateral, 60 ether);
        assertEq(p.cdtCollateral, 60 ether);
        assertEq(p.principal, borrowAmount);
        assertEq(p.maxTermInterest, maxTermInterest);
        assertEq(p.rate, lend.borrowRate());
        assertEq(p.fee, lend.delinquentFee());
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
        uint256 interest = lend.accruedInterest(tokenId);
        vm.deal(other, 10 ether);
        vm.prank(other);
        weth.deposit{value: 1 ether}();
        vm.prank(other);
        weth.approve(address(lend), type(uint256).max);

        // Move slightly forward to make interest non-zero.
        vm.warp(block.timestamp + 7 days);
        interest = lend.accruedInterest(tokenId);
        if (interest > weth.balanceOf(other)) {
            vm.deal(other, interest);
            vm.prank(other);
            weth.deposit{value: interest}();
        }

        // Transfer principal WETH from borrower to other so other can repay fully.
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);
        vm.prank(borrower);
        weth.transfer(other, p.principal);

        vm.prank(other);
        lend.repay(tokenId);

        // NFT burned
        vm.expectRevert();
        lend.ownerOf(tokenId);
    }

    function test_US200_Interest_Linear_And_DistributedOnRepay() public {
        // Route interest to a staking pool (US-600 intent).
        vm.startPrank(owner);
        StakedStrat staked = new StakedStrat(address(strat), address(weth));
        lend.setRevenueRecipient(address(staked));
        vm.stopPrank();

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);

        // Half term should accrue ~half maxTermInterest.
        vm.warp(p.startTime + lend.loanDuration() / 2);
        uint256 accrued = lend.accruedInterest(tokenId);
        assertApproxEqAbs(accrued, p.maxTermInterest / 2, 1e12);

        // Ensure borrower has enough WETH for principal + interest.
        uint256 need = p.principal + accrued;
        uint256 bal = weth.balanceOf(borrower);
        if (bal < need) {
            vm.deal(borrower, need - bal);
            vm.prank(borrower);
            weth.deposit{value: need - bal}();
        }

        uint256 treasuryEthBefore = address(treasury).balance;
        uint256 stakedWethBefore = weth.balanceOf(address(staked));

        vm.prank(borrower);
        lend.repay(tokenId);

        // Principal returned to treasury as ETH.
        assertEq(address(treasury).balance, treasuryEthBefore + p.principal);
        // Interest routed as WETH to revenue recipient.
        assertEq(weth.balanceOf(address(staked)) - stakedWethBefore, accrued);
    }

    function test_US300_301_302_Roll_SettlesInterest_And_AdjustsPrincipal() public {
        vm.startPrank(owner);
        address revenue = address(0xD00D);
        lend.setRevenueRecipient(revenue);
        vm.stopPrank();

        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p0 = lend.getPosition(tokenId);

        // Accrue some interest.
        vm.warp(block.timestamp + 30 days);
        uint256 interest = lend.accruedInterest(tokenId);
        if (interest > 0) {
            uint256 bal = weth.balanceOf(borrower);
            if (bal < interest) {
                vm.deal(borrower, interest - bal);
                vm.prank(borrower);
                weth.deposit{value: interest - bal}();
            }
        }

        uint256 revenueBefore = weth.balanceOf(revenue);

        // Increase collateral -> should increase principal and pay out delta.
        vm.prank(owner);
        strat.mint(borrower, 100 ether);
        vm.prank(owner);
        cdt.mint(borrower, 100 ether);

        uint256 wethBefore = weth.balanceOf(borrower);
        vm.prank(borrower);
        lend.roll(tokenId, 200 ether, 200 ether, block.timestamp + 1 hours);

        // Interest settled to revenue recipient.
        assertEq(weth.balanceOf(revenue) - revenueBefore, interest);

        StratETHTreasuryLend.Position memory p1 = lend.getPosition(tokenId);
        assertEq(p1.stratCollateral, 200 ether);
        assertEq(p1.cdtCollateral, 200 ether);
        assertGt(p1.principal, p0.principal);
        assertEq(p1.rate, lend.borrowRate());
        assertEq(p1.startTime, block.timestamp);
        assertEq(p1.expiry, block.timestamp + lend.loanDuration());

        // Net WETH change = principal delta payout - interest paid during roll.
        assertEq(weth.balanceOf(borrower) - wethBefore, (p1.principal - p0.principal) - interest);

        // Now roll down collateral -> should require pay-in.
        uint256 tokenId2 = tokenId;
        StratETHTreasuryLend.Position memory pBeforeDown = lend.getPosition(tokenId2);

        // Ensure borrower has enough WETH to pay-in delta and accrued interest.
        vm.warp(block.timestamp + 7 days);
        uint256 interest2 = lend.accruedInterest(tokenId2);

        // Compute expected new principal for 150/150 by previewing via borrow preview formula.
        // We'll just roll and then compare treasury delta.
        uint256 treasuryBefore = address(treasury).balance;

        // Top up WETH for interest + potential delta pay-in.
        uint256 topUp = interest2 + 10 ether;
        vm.deal(borrower, topUp);
        vm.prank(borrower);
        weth.deposit{value: topUp}();

        vm.prank(borrower);
        lend.roll(tokenId2, 150 ether, 150 ether, block.timestamp + 1 hours);

        StratETHTreasuryLend.Position memory pAfterDown = lend.getPosition(tokenId2);
        assertLt(pAfterDown.principal, pBeforeDown.principal);
        // Treasury should have received the principal reduction as ETH.
        assertEq(address(treasury).balance - treasuryBefore, pBeforeDown.principal - pAfterDown.principal);
    }

    function test_US400_401_Liquidation_Rules() public {
        uint256 tokenId = _borrow(100 ether, 100 ether);
        StratETHTreasuryLend.Position memory p = lend.getPosition(tokenId);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(StratETHTreasuryLend.LoanUnexpired.selector, tokenId));
        lend.liquidate(tokenId);

        vm.warp(p.expiry);
        vm.prank(other);
        lend.liquidate(tokenId);

        // NFT burned
        vm.expectRevert();
        lend.ownerOf(tokenId);
    }
}

