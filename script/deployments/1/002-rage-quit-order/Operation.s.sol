// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StokeOperation, OperationRunner, Context, JsonSource, Logger, Config, LoggerLib} from "stoke/Stoke.sol";
import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "./BuildOrderLib.sol";

contract Operation is StokeOperation {
    using OperationRunner for OperationRunner.Runner;
    using Config for JsonSource;
    using LoggerLib for Logger;

    address private multisig;
    ISeaportMinimal private seaport;
    BuildOrderLib.Order private order;

    function initialize(Context memory ctx) internal override {
        multisig = ctx.config.internalAddresses.requiredAddress(".protocol.multisigs.redemption");
        seaport = ISeaportMinimal(ctx.config.externalAddresses.requiredAddress(".opensea.seaport"));
        order = BuildOrderLib.minimalOrderParams(ctx, multisig);
    }

    function defineSteps() internal override {
        runner.multisigStep(multisig, "Create and verify the seaport order", verifyOrder);
    }

    function verifyOrder(Context memory, Logger memory logger) internal {
        ISeaportMinimal.OrderParameters memory orderParams = BuildOrderLib.constructOrderParams(multisig, order);
        ISeaportMinimal.Order[] memory orders = new ISeaportMinimal.Order[](1);
        orders[0] = ISeaportMinimal.Order({parameters: orderParams, signature: ""});

        ISeaportMinimal.OrderComponents memory components = ISeaportMinimal.OrderComponents({
            offerer: orderParams.offerer,
            zone: orderParams.zone,
            offer: orderParams.offer,
            consideration: orderParams.consideration,
            orderType: orderParams.orderType,
            startTime: orderParams.startTime,
            endTime: orderParams.endTime,
            zoneHash: orderParams.zoneHash,
            salt: orderParams.salt,
            conduitKey: orderParams.conduitKey,
            counter: seaport.getCounter(orderParams.offerer)
        });
        bytes32 orderHash = seaport.getOrderHash(components);
        logger.info("Order Hash:", orderHash);

        runner.multisigCall({
            to: address(seaport),
            value: 0,
            data: abi.encodeCall(ISeaportMinimal.validate, (orders)),
            label: "seaport.validate(orders)"
        });

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) = seaport.getOrderStatus(orderHash);
        require(isValidated == true, "order not validated");
        require(isCancelled == false, "order cancelled");
        require(totalFilled == 0, ">0 totalFilled");
        require(totalSize == 0, ">0 totalSize");
    }
}
