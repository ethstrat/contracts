// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    StokeOperation,
    OperationRunner,
    Context,
    JsonSource,
    Logger,
    Config,
    LoggerLib,
    AnvilUtils
} from "stoke/Stoke.sol";
import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";
import {BuildOrderLib} from "./BuildOrderLib.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IStETH} from "./interfaces/IStETH.sol";

contract Verify is StokeOperation, StdCheats {
    using OperationRunner for OperationRunner.Runner;
    using Config for JsonSource;
    using LoggerLib for Logger;

    address private multisig;
    ISeaportMinimal private seaport;
    BuildOrderLib.Order private order;

    uint120 constant fillNumerator = 33;
    uint120 constant fillDenominator = 100;

    function initialize(Context memory ctx) internal override {
        multisig = ctx.config.internalAddresses.requiredAddress(".protocol.multisigs.redemption");
        seaport = ISeaportMinimal(ctx.config.externalAddresses.requiredAddress(".opensea.seaport"));
        order = BuildOrderLib.minimalOrderParams(ctx, multisig);
    }

    function defineSteps() internal override {
        runner.verifyStep("fund the multisig with stETH", fundMultisig);
        runner.verifyStep("fund the deployer with STRAT and USDS", fundDeployer);
        runner.verifyStep("Rage quit and verify state", rageQuit);
    }

    function _rageQuitterCreateAdvancedOrder(
        ISeaportMinimal.OrderParameters memory params,
        bytes memory signature,
        uint120 numerator,
        uint120 denominator
    ) internal pure returns (ISeaportMinimal.AdvancedOrder memory) {
        return ISeaportMinimal.AdvancedOrder({
            parameters: params, numerator: numerator, denominator: denominator, signature: signature, extraData: ""
        });
    }

    function _rageQuitterFulfill(ISeaportMinimal.AdvancedOrder memory advancedOrder) internal returns (bool) {
        ISeaportMinimal.CriteriaResolver[] memory criteriaResolvers = new ISeaportMinimal.CriteriaResolver[](0);

        return seaport.fulfillAdvancedOrder(advancedOrder, criteriaResolvers, BuildOrderLib.NO_CONDUIT, address(0));
    }

    function _scaleAmount(uint256 amount, uint120 numerator, uint120 denominator) internal pure returns (uint256) {
        return amount * numerator / denominator;
    }

    function fundMultisig(Context memory ctx, Logger memory logger) internal {
        IStETH steth = IStETH(address(order.offers[0].token));

        logger.info("multisig ETH balance before startActorBroadcast:", multisig.balance);
        runner.startActorImpersonation(multisig, 10 * order.offers[0].amount + 1 ether);
        logger.info("multisig ETH balance after startActorBroadcast:", multisig.balance);
        logger.info("multisig stETH balance:", steth.balanceOf(multisig));
        steth.submit{value: order.offers[0].amount}(address(0));
        steth.approve(address(seaport), order.offers[0].amount);
        logger.info("multisig ETH balance after stETH.submit:", multisig.balance);
        logger.info("multisig stETH balance after stETH.submit:", steth.balanceOf(multisig));
        runner.stopActorImpersonation();
    }

    function fundDeployer(
        Context memory ctx,
        Logger memory /*logger*/
    )
        internal
    {
        address stratWhale = 0x75eFa088E34DA03966a5D2b84fA16C77fF25Adfa;
        address usdsWhale = 0x467194771dAe2967Aef3ECbEDD3Bf9a310C76C65;

        runner.startActorImpersonation(stratWhale);
        order.asks[0].token.transfer(ctx.deployer, _scaleAmount(order.asks[0].amount, fillNumerator, fillDenominator));
        runner.stopActorImpersonation();

        runner.startActorImpersonation(usdsWhale);
        order.asks[1].token.transfer(ctx.deployer, _scaleAmount(order.asks[1].amount, fillNumerator, fillDenominator));
        runner.stopActorImpersonation();
    }

    function rageQuit(Context memory ctx, Logger memory logger) internal {
        ISeaportMinimal.OrderParameters memory orderParams = BuildOrderLib.constructOrderParams(multisig, order);
        ISeaportMinimal.AdvancedOrder memory advancedOrder =
            _rageQuitterCreateAdvancedOrder(orderParams, "", fillNumerator, fillDenominator);

        uint256 expectedStEthOut = _scaleAmount(order.offers[0].amount, fillNumerator, fillDenominator);
        uint256 expectedStratIn = _scaleAmount(order.asks[0].amount, fillNumerator, fillDenominator);
        uint256 expectedUsdsIn = _scaleAmount(order.asks[1].amount, fillNumerator, fillDenominator);

        logger.info("BEFORE:");
        logger.info(
            string.concat("multisig token balance:", order.offers[0].token.symbol()),
            order.offers[0].token.balanceOf(multisig)
        );
        logger.info(
            string.concat("multisig token balance:", order.asks[0].token.symbol()),
            order.asks[0].token.balanceOf(multisig)
        );
        logger.info(
            string.concat("multisig token balance:", order.asks[1].token.symbol()),
            order.asks[1].token.balanceOf(multisig)
        );
        logger.info(
            string.concat("deployer token balance:", order.offers[0].token.symbol()),
            order.offers[0].token.balanceOf(ctx.deployer)
        );
        logger.info(
            string.concat("deployer token balance:", order.asks[0].token.symbol()),
            order.asks[0].token.balanceOf(ctx.deployer)
        );
        logger.info(
            string.concat("deployer token balance:", order.asks[1].token.symbol()),
            order.asks[1].token.balanceOf(ctx.deployer)
        );

        uint256 treasuryStEthBefore = order.offers[0].token.balanceOf(multisig);
        uint256 treasuryStratBefore = order.asks[0].token.balanceOf(multisig);
        uint256 treasuryUsdsBefore = order.asks[1].token.balanceOf(multisig);

        uint256 userStEthBefore = order.offers[0].token.balanceOf(ctx.deployer);
        uint256 userStratBefore = order.asks[0].token.balanceOf(ctx.deployer);
        uint256 userUsdsBefore = order.asks[1].token.balanceOf(ctx.deployer);

        // Need to move into the order window
        if (block.timestamp < order.startTimestamp) {
            runner.warpFork(order.startTimestamp);
        }

        runner.startDeployerBroadcast();
        order.asks[0].token.approve(address(seaport), expectedStratIn);
        order.asks[1].token.approve(address(seaport), expectedUsdsIn);
        bool fulfilled = _rageQuitterFulfill(advancedOrder);
        runner.stopDeployerBroadcast();

        logger.info("AFTER:");
        logger.info(
            string.concat("multisig token balance:", order.offers[0].token.symbol()),
            order.offers[0].token.balanceOf(multisig)
        );
        logger.info(
            string.concat("multisig token balance:", order.asks[0].token.symbol()),
            order.asks[0].token.balanceOf(multisig)
        );
        logger.info(
            string.concat("multisig token balance:", order.asks[1].token.symbol()),
            order.asks[1].token.balanceOf(multisig)
        );
        logger.info(
            string.concat("deployer token balance:", order.offers[0].token.symbol()),
            order.offers[0].token.balanceOf(ctx.deployer)
        );
        logger.info(
            string.concat("deployer token balance:", order.asks[0].token.symbol()),
            order.asks[0].token.balanceOf(ctx.deployer)
        );
        logger.info(
            string.concat("deployer token balance:", order.asks[1].token.symbol()),
            order.asks[1].token.balanceOf(ctx.deployer)
        );

        require(fulfilled, "order not fulfilled");

        require(order.offers[0].token.balanceOf(multisig) == treasuryStEthBefore - expectedStEthOut, "multisig WETH");
        require(order.asks[0].token.balanceOf(multisig) == treasuryStratBefore + expectedStratIn, "multisig STRAT");
        require(order.asks[1].token.balanceOf(multisig) == treasuryUsdsBefore + expectedUsdsIn, "multisig USDS");

        // stETH might round down a little here because it tracks in shares.
        require(
            order.offers[0].token.balanceOf(ctx.deployer) >= userStEthBefore + expectedStEthOut - 1
                && order.offers[0].token.balanceOf(ctx.deployer) <= userStEthBefore + expectedStEthOut,
            "user WETH"
        );
        require(order.asks[0].token.balanceOf(ctx.deployer) == userStratBefore - expectedStratIn, "user STRAT");
        require(order.asks[1].token.balanceOf(ctx.deployer) == userUsdsBefore - expectedUsdsIn, "user USDS");
    }
}
