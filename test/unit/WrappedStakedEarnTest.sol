// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {StryToken} from "../../src/StryToken.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";
import {WrappedStakedEarn} from "../../src/WrappedStakedEarn.sol";
import {WsEarnOracle} from "../../src/WsEarnOracle.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";
import {ITripwireGuard} from "../../src/interfaces/ITripwireGuard.sol";

contract WrappedStakedEarnTest is Test {
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

        _mintEarn(alice, 1_000 ether);
        _mintEarn(bob, 1_000 ether);
        _mintEarn(attacker, 1_000 ether);
        _mintEarn(safe, 1_000 ether);
        vm.prank(alice);
        earn.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        earn.approve(address(vault), type(uint256).max);
        vm.prank(safe);
        earn.approve(address(vault), type(uint256).max);
    }

    function _mintEarn(address to, uint256 amount) internal {
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        t[0] = to;
        a[0] = amount;
        earn.mintBatch(t, a);
    }

    /// @dev Fund the staking contract with USDS the way PeriodicYield does: transfer, then sync.
    function _fundYield(uint256 amount) internal {
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        t[0] = address(staking);
        a[0] = amount;
        usds.mintBatch(t, a);
        staking.syncRewards();
    }

    // -------------------------------------------------------------------------------------------- basics

    function testInitialState() external view {
        assertEq(vault.name(), "Wrapped Staked EARN");
        assertEq(vault.symbol(), "wsEARN");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(earn));
        assertEq(address(vault.usds()), address(usds));
        assertEq(vault.owner(), safe);
        assertEq(vault.depositCap(), CAP);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.convertToAssets(1e18), 1e18);
        assertEq(oracle.price(), 100e36);
    }

    function testDepositStakes() external {
        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertEq(shares, 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(staking.staked(address(vault)), 100 ether, "vault should have staked it");
        assertEq(earn.balanceOf(address(vault)), 0, "vault holds no loose EARN");
        assertEq(vault.totalAssets(), 100 ether);
    }

    function testRedeemUnstakes() external {
        vm.startPrank(alice);
        vault.deposit(100 ether, alice);
        uint256 assets = vault.redeem(40 ether, alice, alice);
        vm.stopPrank();
        assertEq(assets, 40 ether);
        assertEq(earn.balanceOf(alice), 940 ether);
        assertEq(staking.staked(address(vault)), 60 ether);
        assertEq(vault.totalSupply(), 60 ether);
    }

    function testWsEarnIsTransferable() external {
        vm.startPrank(alice);
        vault.deposit(100 ether, alice);
        vault.transfer(bob, 100 ether);
        vm.stopPrank();
        vm.prank(bob);
        vault.redeem(100 ether, bob, bob);
        assertEq(earn.balanceOf(bob), 1_100 ether);
    }

    // -------------------------------------------------------------------------------------------- yield cycle

    function testHarvestForwardsUsdsToOwner() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        _fundYield(2_800 ether); // 100 USDS/day over 28 days
        vm.warp(block.timestamp + 14 days);

        uint256 got = vault.harvest();
        assertApproxEqAbs(got, 1_400 ether, 1e6);
        assertEq(usds.balanceOf(safe), got);
        assertEq(usds.balanceOf(address(vault)), 0);
    }

    function testHarvestIsPermissionless() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        _fundYield(2_800 ether);
        vm.warp(block.timestamp + 28 days);
        vm.prank(attacker);
        vault.harvest();
        assertApproxEqAbs(usds.balanceOf(safe), 2_800 ether, 1e6, "still only goes to the owner");
        assertEq(usds.balanceOf(attacker), 0);
    }

    function testDonateRaisesSharePrice() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vm.prank(bob);
        vault.deposit(100 ether, bob);

        vm.prank(safe);
        vault.donate(20 ether); // +10%, released over VESTING_DURATION

        assertEq(vault.totalSupply(), 200 ether, "no shares minted");
        assertEq(vault.totalAssets(), 200 ether, "nothing vested yet");
        assertEq(vault.convertToAssets(1e18), 1e18);
        vm.warp(block.timestamp + 14 days);
        assertEq(vault.totalAssets(), 210 ether, "half vested");
        vm.warp(block.timestamp + 14 days);
        assertEq(vault.totalAssets(), 220 ether);
        // OZ 4626 carries 1 virtual share/asset, so ratios land 1 wei under the exact figure.
        assertApproxEqAbs(vault.convertToAssets(1e18), 1.1e18, 1);
        assertEq(oracle.price(), vault.convertToAssets(1e18) * PAR);
        assertApproxEqRel(oracle.price(), 110e36, 1e9); // within 1e-9

        vm.prank(alice);
        uint256 out = vault.redeem(100 ether, alice, alice);
        assertApproxEqAbs(out, 110 ether, 1);
    }

    function testWithdrawAfterYieldLeavesUsdsForHarvest() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        _fundYield(2_800 ether);
        vm.warp(block.timestamp + 28 days);

        vm.prank(alice);
        vault.redeem(100 ether, alice, alice); // unstake auto-claims USDS into the vault
        assertApproxEqAbs(usds.balanceOf(address(vault)), 2_800 ether, 1e6);
        assertEq(usds.balanceOf(alice), 0, "holder never receives USDS directly");

        vault.harvest();
        assertApproxEqAbs(usds.balanceOf(safe), 2_800 ether, 1e6);
    }

    function testFullCycleCompounds() external {
        vm.prank(alice);
        vault.deposit(1_000 ether, alice);
        _fundYield(2_800 ether);
        vm.warp(block.timestamp + 28 days);
        uint256 usdsOut = vault.harvest();
        // Safe swaps USDS -> EARN off-chain at 100 and donates. Simulated: 2,800 USDS -> 28 EARN.
        uint256 earnBought = usdsOut / 100;
        vm.prank(safe);
        vault.donate(earnBought);
        vm.warp(block.timestamp + vault.VESTING_DURATION());

        assertApproxEqAbs(vault.convertToAssets(1e18), 1.028e18, 1e9);
        vm.prank(alice);
        uint256 out = vault.redeem(1_000 ether, alice, alice);
        assertApproxEqAbs(out, 1_028 ether, 1e9);
    }

    // -------------------------------------------------------------------------------------------- inflation / griefing

    function testDirectTransferDoesNotMoveSharePrice() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vm.prank(attacker);
        earn.transfer(address(vault), 500 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.convertToAssets(1e18), 1e18);
        assertEq(oracle.price(), 100e36);
    }

    function testAttackerCannotInflateFirstDeposit() external {
        // Classic 4626 inflation attack: deposit 1 wei, then push assets up without minting shares.
        vm.startPrank(attacker);
        earn.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker);
        earn.transfer(address(vault), 999 ether); // ignored by totalAssets
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vault.donate(1 ether);
        vm.stopPrank();

        vm.prank(alice);
        uint256 shares = vault.deposit(100 ether, alice);
        assertEq(shares, 100 ether, "victim gets full shares");
    }

    function testSweepRecoversStrayTokensWithoutTouchingStake() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vm.prank(attacker);
        earn.transfer(address(vault), 5 ether);

        vm.prank(safe);
        vault.sweep(IERC20(address(earn)), safe);
        assertEq(earn.balanceOf(safe), 1_005 ether);
        assertEq(vault.totalAssets(), 100 ether);
        vm.prank(alice);
        assertEq(vault.redeem(100 ether, alice, alice), 100 ether);
    }

    // -------------------------------------------------------------------------------------------- cap

    function testDepositCap() external {
        assertEq(vault.maxDeposit(alice), CAP);
        _mintEarn(alice, CAP);
        vm.startPrank(alice);
        vault.deposit(CAP, alice);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1, 0));
        vault.deposit(1, alice);
        vm.stopPrank();

        vm.prank(safe);
        vault.setDepositCap(CAP + 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether, alice);
    }

    function testOnlyOwnerSetsCap() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositCap(1);
    }

    // -------------------------------------------------------------------------------------------- tripwire

    function testVaultTripBlocksEntryPoints() external {
        vm.prank(alice);
        vault.deposit(100 ether, alice);
        vm.prank(safe);
        ctrl.tripGlobal(address(vault));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITripwireGuard.Tripped.selector, vault.deposit.selector));
        vault.deposit(1 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(ITripwireGuard.Tripped.selector, vault.redeem.selector));
        vault.redeem(1 ether, alice, alice);
        vault.transfer(bob, 1 ether); // transfers still work while tripped
        vm.stopPrank();
    }

    function testStakingTripBubblesUp() external {
        vm.prank(safe);
        ctrl.tripGlobal(address(staking));
        vm.prank(alice);
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1 ether, 0));
        vault.deposit(1 ether, alice);
    }

    // -------------------------------------------------------------------------------------------- oracle

    function testOracleRejectsBadArgs() external {
        vm.expectRevert(WsEarnOracle.ZeroAddress.selector);
        new WsEarnOracle(WrappedStakedEarn(address(0)), PAR);
        vm.expectRevert(WsEarnOracle.ZeroPar.selector);
        new WsEarnOracle(vault, 0);
    }

    // -------------------------------------------------------------------------------------------- fuzz

    function testFuzzRoundTrip(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        vm.startPrank(alice);
        uint256 shares = vault.deposit(amount, alice);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertLe(out, amount);
        assertGe(out + 1, amount);
        assertEq(vault.totalSupply(), 0);
        assertEq(staking.staked(address(vault)), 0);
    }

    function testFuzzDonateNeverDecreasesPrice(uint256 dep, uint256 don) external {
        dep = bound(dep, 1 ether, 1_000 ether);
        don = bound(don, 1, 1_000 ether);
        vm.prank(alice);
        vault.deposit(dep, alice);
        uint256 before = vault.convertToAssets(1e18);
        vm.prank(safe);
        vault.donate(don);
        assertEq(vault.convertToAssets(1e18), before, "donate itself does not move the price");
        vm.warp(block.timestamp + vault.VESTING_DURATION());
        assertGe(vault.convertToAssets(1e18), before);
        assertEq(vault.totalAssets(), dep + don);
        assertEq(vault.totalSupply(), dep);
    }
}
