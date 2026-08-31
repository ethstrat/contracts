// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeaportMinimal} from "../interfaces/ISeaportMinimal.sol";

/// @notice Helpers for signing Seaport orders in tests.
library SeaportOrderLib {
    function toOrderComponents(ISeaportMinimal seaport, ISeaportMinimal.OrderParameters memory params)
        internal
        view
        returns (ISeaportMinimal.OrderComponents memory)
    {
        return ISeaportMinimal.OrderComponents({
            offerer: params.offerer,
            zone: params.zone,
            offer: params.offer,
            consideration: params.consideration,
            orderType: params.orderType,
            startTime: params.startTime,
            endTime: params.endTime,
            zoneHash: params.zoneHash,
            salt: params.salt,
            conduitKey: params.conduitKey,
            counter: seaport.getCounter(params.offerer)
        });
    }

    function getOrderDigest(ISeaportMinimal seaport, ISeaportMinimal.OrderParameters memory params)
        internal
        view
        returns (bytes32)
    {
        bytes32 orderHash = seaport.getOrderHash(toOrderComponents(seaport, params));

        (, bytes32 domainSeparator,) = seaport.information();

        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash));
    }
}
