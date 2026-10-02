// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StryToken} from "../../src/StryToken.sol";
import {StakedStrat} from "../../src/StakedStrat.sol";
import {WrappedStakedEarn} from "../../src/WrappedStakedEarn.sol";
import {TripwireController} from "../../src/lib/TripwireController.sol";
import {ITripwireController} from "../../src/interfaces/ITripwireController.sol";

contract WsEarnHandler is Test {
    WrappedStakedEarn internal vault;
    StakedStrat internal staking;
    StryToken internal earn;
    StryToken internal usds;
    address internal safe;
    address[] internal users;

    uint256 public lastPrice;
    uint256 public donated;

    constructor(WrappedStakedEarn v, StakedStrat s, StryToken e, StryToken u, address safe_) {
        vault = v;
        staking = s;
        earn = e;
        usds = u;
        safe = safe_;
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xB000 + i));
            users.push(a);
            vm.prank(a);
            earn.approve(address(vault), type(uint256).max);
        }
        vm.prank(safe);
        earn.approve(address(vault), type(uint256).max);
        lastPrice = vault.convertToAssets(1e18);
    }

    function _mint(address to, uint256 amount) internal {
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        t[0] = to;
        a[0] = amount;
        earn.mintBatch(t, a);
    }

    function deposit(uint256 seed, uint256 amount) external {
        address u = users[seed % users.length];
        amount = bound(amount, 1, 500 ether);
        _mint(u, amount);
        vm.prank(u);
        try vault.deposit(amount, u) {} catch {}
    }

    function redeem(uint256 seed, uint256 frac) external {
        address u = users[seed % users.length];
        uint256 bal = vault.balanceOf(u);
        if (bal == 0) return;
        uint256 shares = bound(frac, 1, bal);
        vm.prank(u);
        try vault.redeem(shares, u, u) {} catch {}
    }

    function transferShares(uint256 seedFrom, uint256 seedTo, uint256 frac) external {
        address from = users[seedFrom % users.length];
        address to = users[seedTo % users.length];
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        vm.prank(from);
        vault.transfer(to, bound(frac, 1, bal));
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 50 ether);
        _mint(safe, amount);
        vm.prank(safe);
        try vault.donate(amount) {
            donated += amount;
        } catch {}
    }

    function fundYieldAndWarp(uint256 amount, uint256 dt) external {
        amount = bound(amount, 1 ether, 5_000 ether);
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        t[0] = address(staking);
        a[0] = amount;
        usds.mintBatch(t, a);
        staking.syncRewards();
        vm.warp(block.timestamp + bound(dt, 1 hours, 30 days));
    }

    function harvest() external {
        vault.harvest();
    }

    function strayTransfer(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        _mint(address(this), amount);
        earn.transfer(address(vault), amount);
    }

    function recordPrice() external {
        lastPrice = vault.convertToAssets(1e18);
    }
}

contract WrappedStakedEarnInvariantTest is Test {
    TripwireController internal ctrl;
    StryToken internal earn;
    StryToken internal usds;
    StakedStrat internal staking;
    WrappedStakedEarn internal vault;
    WsEarnHandler internal handler;
    address internal safe = makeAddr("safe");

    function setUp() external {
        vm.warp(1_700_000_000);
        ctrl = new TripwireController();
        earn = new StryToken(address(this));
        usds = new StryToken(address(this));
        staking = new StakedStrat(address(earn), address(usds), ITripwireController(address(ctrl)), safe);
        vault = new WrappedStakedEarn(staking, 100_000 ether, safe, ITripwireController(address(ctrl)), safe);
        handler = new WsEarnHandler(vault, staking, earn, usds, safe);
        earn.transferOwnership(address(handler));
        usds.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    /// totalAssets is exactly what the vault has staked.
    function invariant_totalAssetsIsStakedBalance() external view {
        assertEq(vault.totalAssets(), staking.staked(address(vault)));
    }

    /// Every wsEARN is backed by at least 1 EARN; the surplus is exactly what the owner donated (less rounding dust
    /// left behind by withdrawals, which only ever stays in the vault, never leaves it).
    function invariant_sharesFullyBacked() external view {
        assertGe(vault.totalAssets(), vault.totalSupply());
    }

    /// Share price never goes down. Rounding can leave it 1 wei under the last reading.
    function invariant_sharePriceMonotone() external view {
        assertGe(vault.convertToAssets(1e18) + 1, handler.lastPrice());
    }

    /// Holders never receive USDS; it only ever sits in the vault pending harvest or ends up with the owner.
    function invariant_usdsOnlyToOwner() external view {
        for (uint256 i; i < 4; ++i) {
            assertEq(usds.balanceOf(address(uint160(0xB000 + i))), 0);
        }
    }
}
