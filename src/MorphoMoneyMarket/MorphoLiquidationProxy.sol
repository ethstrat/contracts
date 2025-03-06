// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMorphoBase, MarketParams} from "./IMorpho.sol";
import {ProtocolWrappedEthToken} from "./ProtocolWrappedEthToken.sol";
import {IERC20MintableBurnable} from "../interfaces/IERC20.sol";

/// @title A proxy that wraps ETH before liquidating a user's morpho borrow/lend
/// @dev see ProtocolWrappedEthToken. Wrapping is a permissioned action, required
///      so the protocol can have fine grained control of liquidation incentives
contract MorphoLiquidationProxy {
    IMorphoBase public immutable morphoMoneyMarket;

    constructor(address _morphoMoneyMarket) {
        morphoMoneyMarket = IMorphoBase(_morphoMoneyMarket);
    }

    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256) {
        ProtocolWrappedEthToken loanToken = ProtocolWrappedEthToken(marketParams.loanToken);
        IERC20MintableBurnable collateralToken = IERC20MintableBurnable(marketParams.collateralToken);

        loanToken.mint{value: msg.value}(address(this));
        loanToken.approve(morphoMoneyMarket, msg.value);

        (seizedAssets, repaidShares) = morphoMoneyMarket.liquidate(marketParams, seizedAssets, repaidShares, 0x0);

        collateralToken.transfer(msg.sender, seizedAssets * 1e16 / 1e18);
        collateralToken.burn(collateralToken.balanceOf(address(this)));

        return (seizedAssets, repaidShares);
    }
}
