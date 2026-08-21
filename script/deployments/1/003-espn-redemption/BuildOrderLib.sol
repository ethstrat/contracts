// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeaportMinimal} from "./interfaces/ISeaportMinimal.sol";

/// @notice Order construction and the fill-grid arithmetic for the ESPN redemption Seaport order.
/// Ported from `6484357:script/deployments/1/002-rage-quit-order/BuildOrderLib.sol` with the stoke
/// `Context`/`Config` plumbing removed — `constructOrderParams` takes plain arguments instead of a
/// `Context`.
library BuildOrderLib {
    bytes32 internal constant NO_CONDUIT = bytes32(0);

    struct TokenAndAmount {
        address token;
        uint256 amount;
    }

    struct Order {
        TokenAndAmount[] offers;
        TokenAndAmount[] asks;
        address askRecipient;
        uint256 startTimestamp;
        uint256 endTimestamp;
        bytes salt;
    }

    function constructOrderParams(address offerer, Order memory order)
        internal
        pure
        returns (ISeaportMinimal.OrderParameters memory)
    {
        ISeaportMinimal.OfferItem[] memory offer = new ISeaportMinimal.OfferItem[](order.offers.length);
        for (uint256 i; i < order.offers.length; ++i) {
            offer[i] = ISeaportMinimal.OfferItem({
                itemType: ISeaportMinimal.ItemType.ERC20,
                token: order.offers[i].token,
                identifierOrCriteria: 0,
                startAmount: order.offers[i].amount,
                endAmount: order.offers[i].amount
            });
        }

        ISeaportMinimal.ConsiderationItem[] memory consideration =
            new ISeaportMinimal.ConsiderationItem[](order.asks.length);
        for (uint256 i; i < order.asks.length; ++i) {
            consideration[i] = ISeaportMinimal.ConsiderationItem({
                itemType: ISeaportMinimal.ItemType.ERC20,
                token: order.asks[i].token,
                identifierOrCriteria: 0,
                startAmount: order.asks[i].amount,
                endAmount: order.asks[i].amount,
                recipient: payable(order.askRecipient)
            });
        }

        return ISeaportMinimal.OrderParameters({
            offerer: offerer,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: ISeaportMinimal.OrderType.PARTIAL_OPEN,
            startTime: order.startTimestamp,
            endTime: order.endTimestamp,
            zoneHash: bytes32(0),
            salt: uint256(keccak256(order.salt)),
            conduitKey: NO_CONDUIT,
            totalOriginalConsiderationItems: consideration.length
        });
    }

    /// @notice Derives the three order amounts from live NAV, snapped down to `fillGrid`. The
    /// offer IS the target (no round-trip through espnAsk); see Task 4 Step 18(a).
    function deriveAmounts(
        uint256 targetRedemptionUsd,
        uint256 redemptionRatio,
        uint256 fillGrid,
        uint256 totalAssets,
        uint256 totalSupply
    ) internal pure returns (uint256 usdsOffer, uint256 espnAsk, uint256 redemptionAsk, uint256 navPerEspn) {
        navPerEspn = totalAssets * 1e18 / totalSupply;

        uint256 usdsOfferRaw = targetRedemptionUsd;
        uint256 espnAskRaw = targetRedemptionUsd * 1e18 / navPerEspn;
        uint256 redemptionAskRaw = espnAskRaw * redemptionRatio;

        usdsOffer = (usdsOfferRaw / fillGrid) * fillGrid;
        espnAsk = (espnAskRaw / fillGrid) * fillGrid;
        redemptionAsk = (redemptionAskRaw / fillGrid) * fillGrid;
    }

    /// @notice The holder's fill numerator. REDEMPTION binds, not ESPN — REDEMPTION is airdropped
    /// 1:1 with ESPN but the order consumes `redemptionRatio` REDEMPTION per ESPN, so the
    /// REDEMPTION leg is (in practice) always the smaller term. See Task 4 Step 18(c).
    function deriveNumerator(
        uint256 espnBalance,
        uint256 redemptionBalance,
        uint256 espnAsk,
        uint256 redemptionAsk,
        uint256 fillGrid
    ) internal pure returns (uint256 n) {
        uint256 fromEspn = espnBalance * fillGrid / espnAsk;
        uint256 fromRedemption = redemptionBalance * fillGrid / redemptionAsk;
        n = fromEspn < fromRedemption ? fromEspn : fromRedemption;
    }
}
