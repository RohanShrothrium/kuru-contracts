// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.20;

interface IOrderBook {
    enum OrderBookType {
        NO_NATIVE,
        NATIVE_IN_BASE,
        NATIVE_IN_QUOTE
    }

    enum MarketState {
        ACTIVE,
        SOFT_PAUSED,
        HARD_PAUSED
    }

    struct Order {
        address ownerAddress;
        uint96 size;
        uint40 prev;
        uint40 next;
        uint40 flippedId;
        uint32 price;
        uint32 flippedPrice;
        bool isBuy;
    }

    event MarketStateUpdated(MarketState previousState, MarketState newState);

    /**
     * @dev Emitted when a new order is created.
     * @param orderId Unique identifier for the newly created order.
     * @param owner Address of the user who created the order.
     * @param price Price point of the order in the specified precision.
     * @param size Size of the order in the specified precision.
     * @param isBuy Boolean indicating if the order is a buy (true) or sell (false) order.
     */
    event OrderCreated(uint40 orderId, address owner, uint96 size, uint32 price, bool isBuy);

    /**
     * @dev Emitted when a flip order is created
     * @param orderId Unique identifier for the newly created order.
     * @param flippedId Unique identifier for the flipped order.
     * @param owner Address of the user who created the order.
     * @param size Size of the order in the specified precision.
     * @param price Price point of the order in the specified precision.
     * @param flippedPrice Price point of the flipped order in the specified precision.
     * @param isBuy Boolean indicating if the order is a buy (true) or sell (false) order.
     */
    event FlipOrderCreated(
        uint40 orderId, uint40 flippedId, address owner, uint96 size, uint32 price, uint32 flippedPrice, bool isBuy
    );

    /**
     * @dev Emitted when a flip order is partially/completely filled and it results in a new order
     * @param orderId Unique identifier for the newly created order.
     * @param flippedId Unique identifier for the flipped order.
     * @param owner Address of the user who created the order.
     * @param size Size of the order in the specified precision.
     * @param price Price point of the order in the specified precision.
     * @param flippedPrice Price point of the flipped order in the specified precision.
     * @param isBuy Boolean indicating if the order is a buy (true) or sell (false) order.
     */
    event FlippedOrderCreated(
        uint40 orderId, uint40 flippedId, address owner, uint96 size, uint32 price, uint32 flippedPrice, bool isBuy
    );

    /**
     * @dev Emitted when a flip order is updated
     * @param orderId Unique identifier for the order.
     * @param size Size of the order in the specified precision.
     */
    event FlipOrderUpdated(uint40 orderId, uint96 size);

    /**
     * @dev Emitted when one or more flip orders are canceled
     * @param orderIds Array of order identifiers that were canceled.
     * @param owner Address of the user who canceled the orders.
     */
    event FlipOrdersCanceled(uint40[] orderIds, address owner);

    /**
     * @dev Emitted when one or more orders are completed or canceled.
     * @param orderId Array of order identifiers that were completed or canceled.
     */
    event OrdersCanceled(uint40[] orderId, address owner);

    /**
     * @dev Emitted for each cancel
     */
    event OrderCanceled(uint40 orderId, address owner, uint32 price, uint96 size, bool isBuy);

    /**
     * @dev Emitted when the vault params are updated
     * @param _vaultAskOrderSize Size of the vault ask order
     * @param _vaultAskPartiallyFilledSize Size of the vault ask partially filled order
     * @param _vaultBidOrderSize Size of the vault bid order
     * @param _vaultBidPartiallyFilledSize Size of the vault bid partially filled order
     * @param _askPrice The vault best ask price
     * @param _bidPrice The vault best bid price
     */
    event VaultParamsUpdated(
        uint96 _vaultAskOrderSize,
        uint96 _vaultAskPartiallyFilledSize,
        uint96 _vaultBidOrderSize,
        uint96 _vaultBidPartiallyFilledSize,
        uint256 _askPrice,
        uint256 _bidPrice
    );

    /**
     *
     * @dev Emitted when a trade goes through.
     * @param orderId Order Id of the order that was filled.
     * PS. All data regarding the original order can be found out from the order ID
     * @param updatedSize New size of the order
     * @param takerAddress Address of the taker.
     * @param filledSize Size taken by the taker.
     */
    event Trade(
        uint40 orderId,
        address makerAddress,
        bool isBuy,
        uint256 price,
        uint96 updatedSize,
        address takerAddress,
        address txOrigin,
        uint96 filledSize
    );

    function initialize(
        address _factory,
        OrderBookType _type,
        address _baseAssetAddress,
        uint256 _baseAssetDecimals,
        address _quoteAssetAddress,
        uint256 _quoteAssetDecimals,
        address _marginAccountAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        address _kuruAmmVault,
        uint96 _kuruAmmSpread,
        address __trustedForwarder
    ) external;

    function toggleMarket(MarketState _state) external;

    function addBuyOrder(uint32 _price, uint96 size, bool _postOnly) external;

    function addFlipBuyOrder(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _provisionOrRevert) external;

    function addSellOrder(uint32 _price, uint96 size, bool _postOnly) external;

    function addFlipSellOrder(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _provisionOrRevert) external;

    function batchCancelOrders(uint40[] calldata _orderIds) external;

    function batchCancelFlipOrders(uint40[] calldata _orderIds) external;

    function batchUpdate(
        uint32[] calldata buyPrices,
        uint96[] calldata buySizes,
        uint32[] calldata sellPrices,
        uint96[] calldata sellSizes,
        uint40[] calldata orderIdsToCancel,
        bool postOnly
    ) external;

    function placeAndExecuteMarketBuy(uint96 _quoteAmount, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        external
        payable
        returns (uint256);

    function placeAndExecuteMarketSell(uint96 _size, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        external
        payable
        returns (uint256);

    function bestBidAsk() external view returns (uint256, uint256);

    function updateVaultOrdSz(
        uint96 _vaultAskOrderSize,
        uint96 _vaultBidOrderSize,
        uint256 _askPrice,
        uint256 _bidPrice,
        bool _nullifyPartialFills
    ) external;

    function getMarketParams()
        external
        view
        returns (uint32, uint96, address, uint256, address, uint256, uint32, uint96, uint96, uint256, uint256);

    function getVaultParams()
        external
        view
        returns (address, uint256, uint96, uint256, uint96, uint96, uint96, uint96);

    function vaultAskOrderSize() external view returns (uint96);

    function vaultBestAsk() external view returns (uint256);
}
