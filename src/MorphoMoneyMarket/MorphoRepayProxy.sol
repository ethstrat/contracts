// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMorphoBase, MarketParams} from "./IMorpho.sol";
import {ProtocolWrappedEthToken} from "./ProtocolWrappedEthToken.sol";

/// @title A proxy that wraps ETH before repaying a user's morpho borrow/lend
/// @dev see ProtocolWrappedEthToken. Wrapping is a permissioned action, required
///      so the protocol can have fine grained control of liquidation incentives
contract MorphoRepayProxy {
    IMorphoBase public immutable morphoMoneyMarket;

    constructor(address _morphoMoneyMarket) {
        morphoMoneyMarket = IMorphoBase(_morphoMoneyMarket);
    }

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        ProtocolWrappedEthToken(marketParams.loanToken).mint{value: msg.value}(address(this));
        ProtocolWrappedEthToken(marketParams.loanToken).approve(morphoMoneyMarket, msg.value);

        (assetsRepaid, sharesRepaid) = morphoMoneyMarket.repay(marketParams, assets, shares, onBehalf, data);

        if (assetsRepaid < msg.value) {
            IMintableBurnableToken(marketParams.loanToken).transfer(msg.sender, msg.value - assetsRepaid);
        }
    }
}
