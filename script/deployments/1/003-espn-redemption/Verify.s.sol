// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {EspnRedemptionToken} from "src/EspnRedemptionToken.sol";
import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "./BuildOrderLib.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {HoldersLib} from "../lib/HoldersLib.sol";
import {Distribute} from "./Distribute.s.sol";
import {BuildOrder} from "./BuildOrder.s.sol";
import {Cancel} from "./Cancel.s.sol";

/// @notice Mainnet-fork verification of the whole Track A flow: mint, build, two partial fills,
/// an over-large clamp test, an InexactFraction negative test, and cancel. Calls the `internal`
/// entry points of `Distribute`, `BuildOrder` and `Cancel` — never their `run()`s, which write
/// config / Safe-batch files (Step 22). Pin the fork with `SNAPSHOT_BLOCK` (Step 12).
contract Verify is Distribute, BuildOrder, Cancel, StdCheats, StdAssertions {
    /// @dev Seaport 1.6's `InexactFraction()` — not declared on `ISeaportMinimal` (Step 17 says do
    /// not extend it), so it is redeclared here purely to match against with `vm.expectRevert`.
    error InexactFraction();

    ISeaportMinimal internal seaport;
    IERC20 internal usds;
    IERC4626 internal espn;
    EspnRedemptionToken internal token;
    address internal treasury;
    uint256 internal fillGrid;

    ISeaportMinimal.OrderParameters internal orderParams;
    bytes32 internal orderHash;
    uint256 internal usdsOffer;
    uint256 internal espnAsk;
    uint256 internal redemptionAsk;

    function run() external override(Distribute, BuildOrder, Cancel) {
        // --- 0. Fork block check (Step 22 item 0) ---
        uint256 snapshotBlockTarget = vm.envUint("SNAPSHOT_BLOCK");
        string memory holdersFile =
            string.concat("script/deployments/1/config/espn-holders-", vm.toString(snapshotBlockTarget), ".json");
        HoldersLib.Snapshot memory snapshot = HoldersLib.load(holdersFile);
        require(block.number >= snapshot.snapshotBlock, "Verify: fork block behind snapshotBlock");
        if (block.number != snapshot.snapshotBlock) {
            console2.log("WARNING: fork block != snapshotBlock; export SNAPSHOT_BLOCK to pin the fork (Step 12)");
        }

        treasury = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address seaportAddr = ConfigLib.addr("externalAddresses.json", ".opensea.seaport");
        seaport = ISeaportMinimal(seaportAddr);
        usds = IERC20(ConfigLib.addr("externalAddresses.json", ".sky-money.USDS"));
        espn = IERC4626(ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn"));
        fillGrid = ConfigLib.num("settings.json", ".espnv3.fillGrid");
        uint256 orderStartTime = ConfigLib.num("settings.json", ".espnv3.orderStartTime");

        // --- 1. Warp to just before startTime, unconditionally, in either direction, so a stale
        // committed window never breaks this run (Step 22 item 1). ---
        vm.warp(orderStartTime - 1 hours);

        // --- 2. Prank the deployer -> Distribute logic. Logs the mintBatch gas. ---
        address deployer = makeAddr("verify-deployer");
        vm.startPrank(deployer);
        token = _distribute(deployer, holdersFile);
        vm.stopPrank();

        // --- 3. Prank the treasury -> BuildOrder logic (pre-conditions still pass: block.timestamp
        // < orderStartTime), then move into the window and perform the real approve + validate. ---
        vm.deal(treasury, 1 ether);
        vm.startPrank(treasury);
        (orderParams, orderHash, usdsOffer, espnAsk, redemptionAsk) = _buildOrder(address(token), holdersFile);

        vm.warp(orderStartTime + 1);

        if (usds.balanceOf(treasury) < usdsOffer) {
            deal(address(usds), treasury, usdsOffer);
        }
        usds.approve(seaportAddr, usdsOffer);
        ISeaportMinimal.Order[] memory orders = new ISeaportMinimal.Order[](1);
        orders[0] = ISeaportMinimal.Order({parameters: orderParams, signature: ""});
        seaport.validate(orders);
        vm.stopPrank();

        {
            (bool isValidated, bool isCancelled, uint256 totalFilled,) = seaport.getOrderStatus(orderHash);
            require(isValidated, "Verify: order not validated");
            require(!isCancelled, "Verify: order cancelled");
            require(totalFilled == 0, "Verify: order already has fills");
        }

        // --- 4-6. Two holder partial fills at different numerators, same fillGrid denominator. ---
        (address holder1, uint256 holder1Balance, address holder2, uint256 holder2Balance) =
            _pickSampleHolders(snapshot);

        uint256 n1 = _fulfillForHolder(holder1, holder1Balance, true);
        uint256 n2 = _fulfillForHolder(holder2, holder2Balance, false);

        {
            (,, uint256 totalFilled, uint256 totalSize) = seaport.getOrderStatus(orderHash);
            assertEq(totalFilled, n1 + n2);
            assertEq(totalSize, fillGrid);
        }

        // --- 8. Negative test: non-grid denominator reverts InexactFraction. Run before item 7's
        // over-large fill — that fill, by construction, clamps to (and so exhausts) the order's
        // entire remaining capacity, after which there is no remaining capacity left to test against. ---
        _expectInexactFractionRevert(holder1);

        // --- 7. Deliberate over-large fill: numerator exceeds the remainder, Seaport clamps to
        // the exact remainder and the fill still settles exactly (the dust-tail regression test). ---
        _overLargeFill();

        // --- 9. Cancel logic, then the real cancel + allowance revocation. ---
        vm.startPrank(treasury);
        (ISeaportMinimal.OrderComponents memory components,) =
            _cancel(address(token), usdsOffer, espnAsk, redemptionAsk, orderHash);
        ISeaportMinimal.OrderComponents[] memory componentsArr = new ISeaportMinimal.OrderComponents[](1);
        componentsArr[0] = components;
        seaport.cancel(componentsArr);
        usds.approve(seaportAddr, 0);
        vm.stopPrank();

        (, bool isCancelledFinal,,) = seaport.getOrderStatus(orderHash);
        assertTrue(isCancelledFinal, "Verify: order not cancelled");
        assertEq(usds.allowance(treasury, seaportAddr), 0, "Verify: USDS allowance not revoked");
    }

    /// @dev Picks the two largest non-contract, non-excluded snapshot holders at runtime — a
    /// hand-written fixture cannot fulfil a real Seaport order (this is why Task 4 depends on
    /// Task 3's real snapshot, not just Tasks 1 and 2).
    function _pickSampleHolders(HoldersLib.Snapshot memory snapshot)
        private
        pure
        returns (address holder1, uint256 balance1, address holder2, uint256 balance2)
    {
        for (uint256 i = 0; i < snapshot.holders.length; i++) {
            HoldersLib.Holder memory h = snapshot.holders[i];
            if (h.excluded || h.isContract) continue;
            uint256 bal = vm.parseUint(h.balance);
            if (bal > balance1) {
                balance2 = balance1;
                holder2 = holder1;
                balance1 = bal;
                holder1 = h.addr;
            } else if (bal > balance2) {
                balance2 = bal;
                holder2 = h.addr;
            }
        }
        require(holder1 != address(0) && holder2 != address(0), "Verify: fewer than two eligible sample holders");
    }

    /// @dev A realistic partial fill by one sample holder, using the REDEMPTION-bound numerator
    /// from `BuildOrderLib.deriveNumerator` (Step 18(c)) — never a convenient round fraction,
    /// which would happen to divide and mask the whole `InexactFraction` class of bug.
    function _fulfillForHolder(address holder, uint256 holderBalance, bool logGas) private returns (uint256 n) {
        n = BuildOrderLib.deriveNumerator(holderBalance, holderBalance, espnAsk, redemptionAsk, fillGrid);
        uint256 espnCost = espnAsk * n / fillGrid;
        uint256 redemptionCost = redemptionAsk * n / fillGrid;
        require(espn.balanceOf(holder) >= espnCost, "Verify: sample holder cannot afford the ESPN leg");
        require(token.balanceOf(holder) >= redemptionCost, "Verify: sample holder cannot afford the REDEMPTION leg");

        uint256 holderUsdsBefore = usds.balanceOf(holder);
        uint256 holderEspnBefore = espn.balanceOf(holder);
        uint256 holderRedemptionBefore = token.balanceOf(holder);
        uint256 treasuryUsdsBefore = usds.balanceOf(treasury);
        uint256 treasuryEspnBefore = espn.balanceOf(treasury);
        uint256 treasuryRedemptionBefore = token.balanceOf(treasury);

        ISeaportMinimal.AdvancedOrder memory advancedOrder = ISeaportMinimal.AdvancedOrder({
            parameters: orderParams, numerator: uint120(n), denominator: uint120(fillGrid), signature: "", extraData: ""
        });
        ISeaportMinimal.CriteriaResolver[] memory noResolvers = new ISeaportMinimal.CriteriaResolver[](0);

        vm.startPrank(holder);
        espn.approve(address(seaport), espnCost);
        token.approve(address(seaport), redemptionCost);
        uint256 gasBefore = gasleft();
        seaport.fulfillAdvancedOrder(advancedOrder, noResolvers, bytes32(0), holder);
        uint256 gasAfter = gasleft();
        vm.stopPrank();

        // --- 10. Log gas for a single fulfilment. ---
        if (logGas) {
            _logGas(
                "fulfillAdvancedOrder",
                gasBefore - gasAfter,
                abi.encodeCall(ISeaportMinimal.fulfillAdvancedOrder, (advancedOrder, noResolvers, bytes32(0), holder))
            );
        }

        assertEq(usds.balanceOf(holder), holderUsdsBefore + usdsOffer * n / fillGrid);
        assertEq(espn.balanceOf(holder), holderEspnBefore - espnCost);
        assertEq(token.balanceOf(holder), holderRedemptionBefore - redemptionCost);
        assertEq(usds.balanceOf(treasury), treasuryUsdsBefore - usdsOffer * n / fillGrid);
        assertEq(espn.balanceOf(treasury), treasuryEspnBefore + espnCost);
        assertEq(token.balanceOf(treasury), treasuryRedemptionBefore + redemptionCost);
    }

    /// @dev Derives a denominator that divides none of the three amounts (never hardcodes `7` —
    /// at a different NAV a hardcoded small prime can silently stop testing anything) and asserts
    /// a fill against it reverts `InexactFraction`.
    function _expectInexactFractionRevert(address holder) private {
        uint256[6] memory candidates = [uint256(3), 7, 11, 13, 17, 19];
        uint256 badDenominator;
        for (uint256 i = 0; i < candidates.length; i++) {
            uint256 d = candidates[i];
            if (usdsOffer % d != 0 && espnAsk % d != 0 && redemptionAsk % d != 0) {
                badDenominator = d;
                break;
            }
        }
        require(badDenominator != 0, "Verify: no small prime divides none of the three amounts");
        console2.log("negative-test denominator (derived, not hardcoded):", badDenominator);

        ISeaportMinimal.AdvancedOrder memory badOrder = ISeaportMinimal.AdvancedOrder({
            parameters: orderParams, numerator: 1, denominator: uint120(badDenominator), signature: "", extraData: ""
        });
        ISeaportMinimal.CriteriaResolver[] memory noResolvers = new ISeaportMinimal.CriteriaResolver[](0);

        vm.startPrank(holder);
        vm.expectRevert(InexactFraction.selector);
        seaport.fulfillAdvancedOrder(badOrder, noResolvers, bytes32(0), holder);
        vm.stopPrank();
    }

    /// @dev A numerator deliberately larger than the remainder. Seaport clamps to the exact
    /// remainder; the fill must still settle exactly, with no dust-tail revert. Funds a synthetic
    /// filler via `deal` because no real snapshot holder owns enough to fill what's left.
    function _overLargeFill() private {
        (,, uint256 filledBefore, uint256 sizeBefore) = seaport.getOrderStatus(orderHash);
        uint256 remainder = sizeBefore - filledBefore;
        require(remainder > 0, "Verify: order already fully filled before the over-large fill test");
        uint256 requestedNumerator = remainder + 1;

        uint256 clampedEspn = espnAsk * remainder / fillGrid;
        uint256 clampedRedemption = redemptionAsk * remainder / fillGrid;
        uint256 clampedUsds = usdsOffer * remainder / fillGrid;

        address filler = makeAddr("verify-over-large-filler");
        deal(address(espn), filler, clampedEspn);
        deal(address(token), filler, clampedRedemption);

        ISeaportMinimal.AdvancedOrder memory advancedOrder = ISeaportMinimal.AdvancedOrder({
            parameters: orderParams,
            numerator: uint120(requestedNumerator),
            denominator: uint120(fillGrid),
            signature: "",
            extraData: ""
        });
        ISeaportMinimal.CriteriaResolver[] memory noResolvers = new ISeaportMinimal.CriteriaResolver[](0);

        vm.startPrank(filler);
        espn.approve(address(seaport), clampedEspn);
        token.approve(address(seaport), clampedRedemption);
        seaport.fulfillAdvancedOrder(advancedOrder, noResolvers, bytes32(0), filler);
        vm.stopPrank();

        assertEq(usds.balanceOf(filler), clampedUsds);
        (,, uint256 filledAfter, uint256 sizeAfter) = seaport.getOrderStatus(orderHash);
        assertEq(filledAfter, sizeAfter, "Verify: order not fully filled after the clamp");
    }
}
