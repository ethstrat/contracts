// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StryToken} from "../../src/StryToken.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";
import {WrappedStakedEarn} from "../../src/WrappedStakedEarn.sol";
import {WsEarnOracle} from "../../src/WsEarnOracle.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

/// @dev Regression tests for the red-team findings. Each test replays an attack that used to work and asserts
///      it no longer does.
contract WrappedStakedEarnRedTeamTest is Test {
    TripwireController internal ctrl;
    StryToken internal earn;
    StryToken internal usds;
    StakedStrat internal staking;
    WrappedStakedEarn internal vault;
    WsEarnOracle internal oracle;

    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant CAP = 5_000 ether;
    uint256 internal constant PAR = 100 ether;

    function setUp() external {
        vm.warp(1_700_000_000);
        ctrl = new TripwireController();
        earn = new StryToken(address(this));
        usds = new StryToken(address(this));
        staking = new StakedStrat(address(earn), address(usds), ITripwireController(address(ctrl)), safe);
        vault = new WrappedStakedEarn(staking, CAP, safe, ITripwireController(address(ctrl)), safe);
        oracle = new WsEarnOracle(vault, PAR);

        address[4] memory who = [alice, bob, attacker, safe];
        for (uint256 i; i < who.length; ++i) {
            _mint(earn, who[i], 10_000 ether);
            vm.startPrank(who[i]);
            earn.approve(address(vault), type(uint256).max);
            earn.approve(address(staking), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _mint(StryToken token, address to, uint256 amount) internal {
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        t[0] = to;
        a[0] = amount;
        token.mintBatch(t, a);
    }

    /// @dev Stake directly, then migrate the stake onto the vault: `staking.staked(vault)` rises, no wsEARN is
    ///      minted. This used to be a permissionless donation.
    function _gift(address from, uint256 amount) internal {
        vm.startPrank(from);
        staking.stake(amount);
        staking.migrateStake(address(vault), amount);
        vm.stopPrank();
    }

    function _fundYield(uint256 amount) internal {
        _mint(usds, address(staking), amount);
        staking.syncRewards();
    }

    // ------------------------------------------------------------------------------------------------------
    // 1. Stake migrated onto the vault must not move the share price, the oracle, or the cap
    // ------------------------------------------------------------------------------------------------------

    function testMigratedStakeDoesNotMoveSharePriceOrOracle() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        _gift(attacker, 100 ether);

        assertEq(staking.staked(address(vault)), 200 ether);
        assertEq(vault.totalAssets(), 100 ether, "gift is not counted");
        assertEq(vault.convertToAssets(1e18), 1e18);
        assertEq(oracle.price(), 100e36);
    }

    function testFirstDepositorInflationFails() external {
        vm.prank(attacker);
        vault.deposit(1, attacker);
        _gift(attacker, 200 ether);

        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertEq(shares, 100 ether, "victim gets full shares");

        vm.prank(attacker);
        assertEq(vault.redeem(1, attacker, attacker), 1, "attacker's gift is simply gone");
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 100 ether);
    }

    function testGiftIntoEmptyVaultDoesNotWreckGranularity() external {
        _gift(attacker, 1 ether);

        vm.prank(alice);
        assertEq(vault.deposit(0.99 ether, alice), 0.99 ether);
        vm.prank(bob);
        uint256 shares = vault.deposit(100.9 ether, bob);
        assertEq(shares, 100.9 ether);
        vm.prank(bob);
        assertEq(vault.redeem(shares, bob, bob), 100.9 ether);
    }

    function testGiftDoesNotBypassOrConsumeDepositCap() external {
        vm.prank(alice);
        vault.deposit(CAP - 100 ether, alice);
        _gift(attacker, 4_000 ether);
        assertEq(vault.managedAssets(), CAP - 100 ether);
        assertEq(vault.maxDeposit(bob), 100 ether, "headroom unchanged by the gift");
    }

    function testOwnerSweepsExcessStake() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        _gift(attacker, 40 ether);

        vm.prank(attacker);
        vm.expectRevert();
        vault.sweepExcessStake(attacker);

        uint256 before = earn.balanceOf(safe);
        vm.prank(safe);
        vault.sweepExcessStake(safe);
        assertEq(earn.balanceOf(safe) - before, 40 ether);
        assertEq(staking.staked(address(vault)), 100 ether, "holders' stake untouched");
        assertEq(vault.totalAssets(), 100 ether);

        vm.prank(safe);
        vm.expectRevert(WrappedStakedEarn.ZeroAmount.selector);
        vault.sweepExcessStake(safe);
    }

    // ------------------------------------------------------------------------------------------------------
    // 2. Donations vest, so they cannot be captured just-in-time
    // ------------------------------------------------------------------------------------------------------

    function testSandwichDonateCapturesNothing() external {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        _fundYield(2_800 ether);
        vm.warp(block.timestamp + 28 days);
        uint256 earnBought = vault.harvest() / 100;

        vm.prank(attacker);
        uint256 shares = vault.deposit(4_000 ether, attacker);
        vm.prank(safe);
        vault.donate(earnBought);
        vm.prank(attacker);
        uint256 out = vault.redeem(shares, attacker, attacker);
        assertEq(out, 4_000 ether, "same-block round trip around donate() earns nothing");

        vm.warp(block.timestamp + vault.VESTING_DURATION());
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(1_000 ether, alice, alice);
        assertApproxEqAbs(aliceOut, 1_000 ether + earnBought, 1, "the holder who stayed gets all of it");
    }

    function testDonationVestsLinearlyAndPriceNeverJumps() external {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);

        uint256 before = oracle.price();
        vm.prank(safe);
        vault.donate(28 ether);
        assertEq(oracle.price(), before, "no step at donate()");
        assertEq(vault.unvestedAssets(), 28 ether);

        uint256 last = before;
        for (uint256 d = 1; d <= 28; ++d) {
            vm.warp(block.timestamp + 1 days);
            assertApproxEqAbs(vault.totalAssets(), 1_000 ether + d * 1 ether, 1);
            assertGt(oracle.price(), last);
            last = oracle.price();
        }
        assertEq(vault.unvestedAssets(), 0);
        assertEq(vault.totalAssets(), 1_028 ether);
    }

    /// A second donation mid-vest rolls the unvested remainder into a fresh window; nothing is lost or released
    /// early.
    function testOverlappingDonations() external {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        vm.prank(safe);
        vault.donate(28 ether);
        vm.warp(block.timestamp + 14 days);
        assertEq(vault.totalAssets(), 1_014 ether);

        vm.prank(safe);
        vault.donate(14 ether);
        assertEq(vault.totalAssets(), 1_014 ether, "no step");
        assertEq(vault.unvestedAssets(), 28 ether);
        vm.warp(block.timestamp + 28 days);
        assertEq(vault.totalAssets(), 1_042 ether);
    }

    /// If every holder leaves mid-vest, the unvested remainder belongs to nobody. It must not poison the price
    /// for the next depositor; the owner can recover it and donate again.
    function testFullExitMidVestResetsVault() external {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        vm.prank(safe);
        vault.donate(28 ether);
        vm.warp(block.timestamp + 14 days);

        vm.prank(alice);
        uint256 out = vault.redeem(1_000 ether, alice, alice);
        assertApproxEqAbs(out, 1_014 ether, 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.managedAssets(), 0);
        assertEq(vault.unvestedAssets(), 0);

        vm.warp(block.timestamp + 28 days);
        assertEq(vault.convertToAssets(1e18), 1e18, "back to 1:1");
        vm.prank(bob);
        assertEq(vault.deposit(100 ether, bob), 100 ether);

        uint256 before = earn.balanceOf(safe);
        vm.prank(safe);
        vault.sweepExcessStake(safe);
        assertApproxEqAbs(earn.balanceOf(safe) - before, 14 ether, 1);
        assertEq(staking.staked(address(vault)), 100 ether);
    }

    // ------------------------------------------------------------------------------------------------------
    // 3. Tripped vault or staking: max* report zero and the oracle refuses to quote
    // ------------------------------------------------------------------------------------------------------

    function testOracleRevertsWhileRedemptionsFrozen() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        assertTrue(vault.redeemable());

        // Pausing the staking contract alone freezes redemptions.
        vm.prank(safe);
        ctrl.tripGlobal(address(staking));
        assertFalse(vault.redeemable());
        vm.expectRevert(WsEarnOracle.RedemptionsFrozen.selector);
        oracle.price();
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);

        vm.prank(safe);
        ctrl.resetGlobal(address(staking));
        assertEq(oracle.price(), 100e36);
        assertEq(vault.maxRedeem(alice), 100 ether);

        // Same for a trip on the vault's own redeem.
        vm.prank(safe);
        ctrl.trip(address(vault), vault.redeem.selector);
        vm.expectRevert(WsEarnOracle.RedemptionsFrozen.selector);
        oracle.price();
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxDeposit(alice), CAP - 100 ether, "deposits are not tripped");
    }

    // ------------------------------------------------------------------------------------------------------
    // 4. Smaller items
    // ------------------------------------------------------------------------------------------------------

    function testDonateIntoEmptyVaultReverts() external {
        vm.prank(safe);
        vm.expectRevert(WrappedStakedEarn.NoShares.selector);
        vault.donate(10 ether);
    }

    function testRenounceOwnershipDisabled() external {
        vm.prank(safe);
        vm.expectRevert(WrappedStakedEarn.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), safe);
    }

    function testZeroAmountCallsAreNoOps() external {
        vm.startPrank(alice);
        assertEq(vault.deposit(0, alice), 0);
        assertEq(vault.mint(0, alice), 0);
        vault.deposit(10 ether, alice);
        assertEq(vault.withdraw(0, alice, alice), 0);
        assertEq(vault.redeem(0, alice, alice), 0);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 10 ether);
    }

    function testFuzzVestingNeverExceedsDonation(uint256 dep, uint256 don, uint256 dt) external {
        dep = bound(dep, 1 ether, 1_000 ether);
        don = bound(don, 1, 1_000 ether);
        dt = bound(dt, 0, 60 days);
        vm.prank(alice);
        vault.deposit(dep, alice);
        vm.prank(safe);
        vault.donate(don);
        vm.warp(block.timestamp + dt);
        assertLe(vault.totalAssets(), dep + don);
        assertGe(vault.totalAssets(), dep);
        vm.prank(alice);
        uint256 out = vault.redeem(dep, alice, alice);
        assertLe(out, dep + don);
        assertLe(vault.managedAssets(), staking.staked(address(vault)));
    }
}
