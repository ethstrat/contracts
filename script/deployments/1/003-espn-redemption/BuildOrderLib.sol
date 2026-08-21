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

    /// @notice Plain-argument replacement for the ported `minimalOrderParams(Context, address)`
    /// (Task 4 Step 18): assembles the redemption order's offer `[USDS]` / consideration
    /// `[REDEMPTION, ESPN]` legs from explicit addresses and amounts instead of a `Context`. The
    /// `[REDEMPTION, ESPN]` consideration ordering is load-bearing for the order hash — both
    /// `BuildOrder.s.sol` and `Cancel.s.sol` must build the identical order through this one
    /// function, never re-assemble it by hand, or the two can silently drift apart.
    function buildRedemptionOrder(
        address treasury,
        address usds,
        uint256 usdsOffer,
        address redemptionToken,
        uint256 redemptionAsk,
        address espn,
        uint256 espnAsk,
        uint256 startTime,
        uint256 endTime,
        string memory salt
    ) internal pure returns (Order memory) {
        TokenAndAmount[] memory offers = new TokenAndAmount[](1);
        offers[0] = TokenAndAmount({token: usds, amount: usdsOffer});
        TokenAndAmount[] memory asks = new TokenAndAmount[](2);
        asks[0] = TokenAndAmount({token: redemptionToken, amount: redemptionAsk});
        asks[1] = TokenAndAmount({token: espn, amount: espnAsk});
        return Order({
            offers: offers,
            asks: asks,
            askRecipient: treasury,
            startTimestamp: startTime,
            endTimestamp: endTime,
            salt: bytes(salt)
        });
    }

    /// @notice Rebuilds an `OrderComponents` from already-constructed `OrderParameters` plus the
    /// live Seaport counter — same fields, `counter` in place of `totalOriginalConsiderationItems`
    /// (Step 20 item 5 / Step 21). Shared so the hash computed by `BuildOrder.s.sol` and the hash
    /// recomputed by `Cancel.s.sol` can never diverge on a hand-copied field.
    function toOrderComponents(ISeaportMinimal.OrderParameters memory params, uint256 counter)
        internal
        pure
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
            counter: counter
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
    /// REDEMPTION leg is (in practice) always the smaller term. See Task 4 Step 18(c). Clamped to
    /// `fillGrid`: a holder owning more than the whole order (either leg) would otherwise get a
    /// numerator exceeding the denominator, which Seaport rejects with `BadFraction`.
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
        if (n > fillGrid) n = fillGrid;
    }
}
