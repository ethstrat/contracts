// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Seaport 1.6 interface needed for a partial-fill ERC20 basket order.
interface ISeaportMinimal {
    // -------------------------------------------------------------------------
    // Errors used by tests
    // -------------------------------------------------------------------------

    error OrderIsCancelled(bytes32 orderHash);

    // -------------------------------------------------------------------------
    // Enums
    // -------------------------------------------------------------------------

    enum ItemType {
        NATIVE,
        ERC20,
        ERC721,
        ERC1155,
        ERC721_WITH_CRITERIA,
        ERC1155_WITH_CRITERIA
    }

    enum OrderType {
        FULL_OPEN,
        PARTIAL_OPEN,
        FULL_RESTRICTED,
        PARTIAL_RESTRICTED,
        CONTRACT
    }

    enum Side {
        OFFER,
        CONSIDERATION
    }

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct OfferItem {
        ItemType itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
    }

    struct ConsiderationItem {
        ItemType itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
        address payable recipient;
    }

    /// @dev Used by fulfillAdvancedOrder(). Seaport's `salt` is uint256.
    struct OrderParameters {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        OrderType orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 totalOriginalConsiderationItems;
    }

    /// @dev Used by getOrderHash(). Same as OrderParameters, but with counter
    ///      instead of totalOriginalConsiderationItems.
    struct OrderComponents {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        OrderType orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 counter;
    }

    struct AdvancedOrder {
        OrderParameters parameters;
        uint120 numerator;
        uint120 denominator;
        bytes signature;
        bytes extraData;
    }

    struct CriteriaResolver {
        uint256 orderIndex;
        Side side;
        uint256 index;
        uint256 identifier;
        bytes32[] criteriaProof;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getCounter(address offerer) external view returns (uint256 counter);

    function getOrderHash(OrderComponents calldata order) external view returns (bytes32 orderHash);

    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);

    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);

    // -------------------------------------------------------------------------
    // Mutations
    // -------------------------------------------------------------------------

    function cancel(OrderComponents[] calldata orders) external returns (bool cancelled);

    function incrementCounter() external returns (uint256 newCounter);

    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);
}
