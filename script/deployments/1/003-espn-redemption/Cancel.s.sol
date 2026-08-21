// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "./BuildOrderLib.sol";
import {ConfigLib} from "../lib/ConfigLib.sol";
import {SafeBatchLib} from "../lib/SafeBatchLib.sol";

/// @notice Cancels the Track A Seaport order and revokes the USDS allowance. Never broadcasts —
/// the offerer is the treasury Safe. See Task 4 Step 21.
contract Cancel is Script {
    function run() external virtual {
        address redemptionToken = ConfigLib.addr("deploymentAddresses.json", ".espn-redemption-token");
        uint256 usdsOffer = vm.envUint("USDS_OFFER");
        uint256 espnAsk = vm.envUint("ESPN_ASK");
        uint256 redemptionAsk = vm.envUint("REDEMPTION_ASK");
        bytes32 expectedOrderHash = vm.envBytes32("EXPECTED_ORDER_HASH");

        (ISeaportMinimal.OrderComponents memory components,) =
            _cancel(redemptionToken, usdsOffer, espnAsk, redemptionAsk, expectedOrderHash);

        address treasury = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address seaportAddr = ConfigLib.addr("externalAddresses.json", ".opensea.seaport");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");

        ISeaportMinimal.OrderComponents[] memory componentsArr = new ISeaportMinimal.OrderComponents[](1);
        componentsArr[0] = components;

        SafeBatchLib.Tx[] memory txs = new SafeBatchLib.Tx[](2);
        txs[0] = SafeBatchLib.Tx({to: seaportAddr, data: abi.encodeCall(ISeaportMinimal.cancel, (componentsArr))});
        txs[1] = SafeBatchLib.Tx({to: usds, data: abi.encodeCall(IERC20.approve, (seaportAddr, 0))});

        SafeBatchLib.write(
            treasury,
            "003-espn-redemption",
            2,
            "ESPNv3 Track A: cancel + revoke redemption order",
            "Seaport.cancel([orderComponents]) then USDS.approve(Seaport, 0)",
            txs
        );
    }

    /// @dev Shared with `Verify.s.sol`. Rebuilds identical order components from explicit amounts
    /// — never from live NAV, which would produce a different hash than the validated order — and
    /// asserts the recomputed hash equals the one `BuildOrder.s.sol` logged. Never calls
    /// `Seaport.cancel` / `USDS.approve` itself; those run from `run()` (as Safe-batch calldata,
    /// never executed) and from `Verify.s.sol` (executed for real, under a prank).
    function _cancel(
        address redemptionToken,
        uint256 usdsOffer,
        uint256 espnAsk,
        uint256 redemptionAsk,
        bytes32 expectedOrderHash
    ) internal view returns (ISeaportMinimal.OrderComponents memory components, bytes32 orderHash) {
        address treasury = ConfigLib.addr("internalAddresses.json", ".protocol.multisigs.redemption");
        address seaportAddr = ConfigLib.addr("externalAddresses.json", ".opensea.seaport");
        address usds = ConfigLib.addr("externalAddresses.json", ".sky-money.USDS");
        address espn = ConfigLib.addr("externalAddresses.json", ".eth-strategy.espn");
        ISeaportMinimal seaport = ISeaportMinimal(seaportAddr);

        uint256 orderStartTime = ConfigLib.num("settings.json", ".espnv3.orderStartTime");
        uint256 orderEndTime = ConfigLib.num("settings.json", ".espnv3.orderEndTime");
        string memory orderSalt = ConfigLib.str("settings.json", ".espnv3.orderSalt");

        ISeaportMinimal.OrderParameters memory orderParams = BuildOrderLib.constructOrderParams(
            treasury,
            BuildOrderLib.buildRedemptionOrder(
                treasury,
                usds,
                usdsOffer,
                redemptionToken,
                redemptionAsk,
                espn,
                espnAsk,
                orderStartTime,
                orderEndTime,
                orderSalt
            )
        );

        components = BuildOrderLib.toOrderComponents(orderParams, seaport.getCounter(treasury));

        orderHash = seaport.getOrderHash(components);
        require(orderHash == expectedOrderHash, "Cancel: recomputed order hash does not match EXPECTED_ORDER_HASH");
    }
}
