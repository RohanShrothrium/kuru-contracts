// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// ============ Internal Interface Imports ============
import {IAbstractOrderBook} from "../interfaces/IAbstractOrderBook.sol";

// ============ Internal Contracts Imports ============
import {IERC20} from "../libraries/IERC20.sol";
import {MarginAccount} from  "../MarginAccount.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract AbstractOrderBook is IAbstractOrderBook, OwnableUpgradeable {
    struct Order {
        address ownerAddress;
        uint96 price;
        uint96 size;
        uint96 acceptableRange;
        bool isBuy;
        bool useMargin;
    }

    struct PricePoint {
        uint96 totalCompletedOrCanceledOrders;
        uint96 totalOrdersAtPrice; // sum of size of all orders placed at the price point
    }

    /**
     * @dev Emitted when a new order is created.
     * @param orderId Unique identifier for the newly created order.
     * @param owner Address of the user who created the order.
     * @param price Price point of the order in the specified precision.
     * @param size Size of the order in the specified precision.
     * @param acceptableRange The range within which the order is valid.
     * @param isBuy Boolean indicating if the order is a buy (true) or sell (false) order.
     */
    event OrderCreated(
        uint256 orderId,
        address owner,
        uint96 price,
        uint96 size,
        uint96 acceptableRange,
        bool isBuy
    );

    /**
     * @dev Emitted when one or more orders are executed partially/completely by buy taker orders.
     * @param takerAddress Address of the taker.
     * @param orderIds Array of order identifiers that were partially/completely executed.
     * @param updatedSizes Array of new sizes for the corresponding orders. Each size
     * corresponds to the order ID at the same index in the `orderIds` array.
     */
    event BuyIOC(
        address takerAddress,
        uint96 orderSize,
        uint256[] orderIds,
        uint96[] updatedSizes
    );

    /**
     * @dev Emitted when one or more orders are executed partially/completely by sell taker orders.
     * @param takerAddress Address of the taker.
     * @param orderIds Array of order identifiers that were partially/completely executed.
     * @param updatedSizes Array of new sizes for the corresponding orders. Each size
     * corresponds to the order ID at the same index in the `orderIds` array.
     */
    event SellIOC(
        address takerAddress,
        uint96 orderSize,
        uint256[] orderIds,
        uint96[] updatedSizes
    );

    /**
     * @dev Emitted when one or more orders are updated.
     * @param orderIds Array of order identifiers that were updated.
     * @param updatedSizes Array of new sizes for the corresponding orders. Each size
     * corresponds to the order ID at the same index in the `orderIds` array.
     */
    event OrdersUpdated(
        uint256[] orderIds,
        uint96[] updatedSizes
    );

    /**
     * @dev Emitted when one or more orders are completed or canceled.
     * @param orderId Array of order identifiers that were completed or canceled.
     */
    event OrdersCanceled(
        uint256[] orderId
    );

    mapping(uint256 => Order) public s_orders;
    mapping(uint256 => PricePoint) public s_buyPricePoints;
    mapping(uint256 => PricePoint) public s_sellPricePoints;

    uint256 public s_orderIdCounter;

    bool marketPaused;

    uint96 immutable sizePrecision;
    uint96 immutable pricePrecision;

    uint96 immutable tickSize;
    uint96 immutable minSize;
    uint96 immutable maxSize;

    // TODO: might have to be public
    uint256 immutable takerFeeBps;
    // TODO: add maker fee

    IERC20 immutable baseAsset;
    IERC20 immutable quoteAsset;
    MarginAccount immutable marginAccount;

    uint256 immutable baseAssetDecimals;
    uint256 immutable quoteAssetDecimals;

    uint256 constant BPS_MULTIPLIER = 10000;

    /**
     * @dev Constructor.
     * @param _baseAssetAddress Address of the first token used for trading.
     * @param _baseAssetDecimals Deciimal pricicsion of the first swap token.
     * @param _quoteAssetAddress Address of the second token used for trading.
     * @param _quoteAssetDecimals Deciimal pricicsion of the first swap token.
     */
    constructor (
        address _baseAssetAddress,
        uint256 _baseAssetDecimals,
        address _quoteAssetAddress,
        uint256 _quoteAssetDecimals,
        address _marginAccountAddress,
        uint96 _sizePrecision,
        uint96 _pricePrecision,
        uint96 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps
    ) {
        baseAsset = IERC20(_baseAssetAddress);
        quoteAsset = IERC20(_quoteAssetAddress);

        baseAssetDecimals = _baseAssetDecimals;
        quoteAssetDecimals = _quoteAssetDecimals;

        marginAccount = MarginAccount(_marginAccountAddress);
        // initialize contract parameters
        sizePrecision = _sizePrecision;
        pricePrecision = _pricePrecision;
        tickSize = _tickSize;
        minSize = _minSize;
        maxSize = _maxSize;
        takerFeeBps = _takerFeeBps;
    }

    modifier marketActive() {
        require(!marketPaused, "OrderBook: market is paused");
        _;
    }

    /**
     * @param _owner The owner of the contract.
     */
    function initialize(address _owner) public initializer {
        __Ownable_init();
        _transferOwnership(_owner);
    }

    /**
     * @dev Allows admin to pause the market.
     */
    function pauseMarkets() external onlyOwner {
        marketPaused = true;
    }

    /**
     * @dev Adds a buy order to the order book.
     * @param _price Price of the buy order.
     * @param size Size of the buy order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function addBuyOrder(uint96 _price, uint96 size, bool _useMargin) public marketActive {
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");

        uint256 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;

        PricePoint storage _pricePoint = s_buyPricePoints[_price];

        uint96 _acceptableRange = _addOrder(_pricePoint, _price, size, _orderId + 1, true, _useMargin);

        _consumeFunds(quoteAsset, ((((size * _price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision), _useMargin, msg.sender);

        emit OrderCreated(_orderId + 1, msg.sender, _price, size, _acceptableRange, true);
    }

    /**
     * @dev Adds a sell order to the order book.
     * @param _price Price of the sell order.
     * @param size Size of the sell order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function addSellOrder(uint96 _price, uint96 size, bool _useMargin) public marketActive {
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");

        uint256 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;

        PricePoint storage _pricePoint = s_sellPricePoints[_price];

        uint96 _acceptableRange = _addOrder(_pricePoint, _price, size, _orderId + 1, false, _useMargin);

        _consumeFunds(baseAsset, ((size * 10**baseAssetDecimals) / sizePrecision), _useMargin, msg.sender);

        emit OrderCreated(_orderId + 1, msg.sender, _price, size, _acceptableRange, false);
    }

    /**
     * @dev Internal function to add an order to the order book.
     * @param _pricePoint PricePoint storage object for the order's price point.
     * @param _price Price of the order.
     * @param _size Size of the order.
     */
    function _addOrder(PricePoint storage _pricePoint, uint96 _price, uint96 _size, uint256 _orderId, bool _isBuy, bool _useMargin) internal returns(uint96) {
        uint96 acceptableRange = _pricePoint.totalOrdersAtPrice;
        s_orders[_orderId] = Order(msg.sender, _price, _size, acceptableRange, _isBuy, _useMargin);

        _pricePoint.totalOrdersAtPrice += _size;

        return acceptableRange;
    }

    /**
     * @dev Consumes funds required to create a GTC order.
     * @param _consumableAsset Address of the asset that is being consumed by the market.
     * @param _amount Amount of _consumableAssets that should be consumed by the market.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     * @param _makerAddress Address of the the user creating the order.
     */
    function _consumeFunds(IERC20 _consumableAsset, uint256 _amount, bool _useMargin, address _makerAddress) internal {
        _useMargin
            ? marginAccount.debitUser(
                _makerAddress,
                address(_consumableAsset),
                _amount,
                address(baseAsset),
                address(quoteAsset)
            )
            : _consumableAsset.transferFrom(_makerAddress, address(marginAccount), _amount);
    }

    /**
     * @dev Cancels multiple orders in a batch.
     * @param _orderIds Array of order IDs to cancel.
     */
    function batchCancelOrders(uint256[] calldata _orderIds, bool _useMargin) external {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _cancelOrder(_orderIds[i], _useMargin);
        }

        emit OrdersCanceled(_orderIds);
    }

    /**
     * @dev Internal helper function to cancel a single order.
     * @param _orderId ID of the order to cancel.
     */
    function _cancelOrder(uint256 _orderId, bool _useMargin) internal returns (bool) {
        Order memory _order = s_orders[_orderId];

        require(msg.sender == _order.ownerAddress, "OrderBook: Only order owner can cancel order");

        if (_order.isBuy) {
            s_buyPricePoints[_order.price].totalCompletedOrCanceledOrders += _order.size;

            marginAccount.creditUser(
                _order.ownerAddress,
                address(quoteAsset),
                ((((_order.size * _order.price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision),
                address(baseAsset),
                address(quoteAsset),
                _useMargin
            );
        } else {
            s_sellPricePoints[_order.price].totalCompletedOrCanceledOrders += _order.size;

            marginAccount.creditUser(
                _order.ownerAddress,
                address(baseAsset),
                ((_order.size * 10**baseAssetDecimals) / sizePrecision),
                address(baseAsset),
                address(quoteAsset),
                _useMargin
            );
        }

        delete s_orders[_orderId];

        return _order.isBuy;
    }

    /**
     * @dev Decreases the size of multiple orders.
     * This function allows a user to decrease the size of multiple orders they own.
     * It iterates over the provided order IDs and updates their sizes accordingly.
     * @param _orderIds Array of order IDs to be decreased in size.
     * @param _updatedSizes Array of new sizes for the orders. Each size corresponds to the order ID at the same index in the _orderIds array.
     */
    function decreaseOrders(uint256[] calldata _orderIds, uint96[] calldata _updatedSizes, bool _useMargin) external marketActive {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _decreaseOrder(_orderIds[i], _updatedSizes[i], _useMargin);
        }

        emit OrdersUpdated(_orderIds, _updatedSizes);
    }

    /**
     * @dev Internal function to decrease the size of a single order.
     * This function updates the size of an order and manages the refund process.
     * It is called by decreaseOrders for each order that needs to be updated.
     * @param _orderId ID of the order to be decreased in size.
     * @param _updatedSize New size for the order. Must be less than the current size.
     */
    function _decreaseOrder(uint256 _orderId, uint96 _updatedSize, bool _useMargin) internal {
        Order memory _order = s_orders[_orderId];

        require(msg.sender == _order.ownerAddress, "OrderBook: Only order owner can update order");
        require(_order.size > _updatedSize, "OrderBook: can't increase order size");
        require(_updatedSize > minSize, "Orderbook: size has to be greater than minimum");

        uint96 _decreasedSize = _order.size - _updatedSize;

        if (_order.isBuy) {
            s_buyPricePoints[_order.price].totalCompletedOrCanceledOrders += _decreasedSize;

            marginAccount.creditUser(
                _order.ownerAddress,
                address(quoteAsset),
                ((((_decreasedSize * _order.price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision),
                address(baseAsset),
                address(quoteAsset),
                _useMargin
            );
        } else {
            s_sellPricePoints[_order.price].totalCompletedOrCanceledOrders += _decreasedSize;

            marginAccount.creditUser(
                _order.ownerAddress,
                address(baseAsset),
                ((_decreasedSize * 10**baseAssetDecimals) / sizePrecision),
                address(baseAsset),
                address(quoteAsset),
                _useMargin
            );
        }

        s_orders[_orderId].size = _updatedSize;
    }

    /**
     * @dev Places multiple limit buy orders in a single function call.
     * @param _prices Array of prices for the buy orders.
     * @param _sizes Array of sizes for the buy orders.
     */
    function placeMultipleBuyOrders(uint96[] calldata _prices, uint96[] calldata _sizes, bool _useMargin) external marketActive {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addBuyOrder(_prices[i], _sizes[i], _useMargin);
        }
    }

    /**
     * @dev Places multiple limit sell orders in a single function call.
     * @param _prices Array of prices for the sell orders.
     * @param _sizes Array of sizes for the sell orders.
     */
    function placeMultipleSellOrders(uint96[] calldata _prices, uint96[] calldata _sizes, bool _useMargin) external marketActive {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addSellOrder(_prices[i], _sizes[i], _useMargin);
        }
    }

    /**
     * @dev Replaces prices of existing orders
     * @param _orderIds list of orderIds that has to be updated
     * @param _prices new price that has to be set
     */
    function replaceOrders(
        uint256[] calldata _orderIds,
        uint96[] calldata _prices,
        uint96[] calldata _sizes,
        bool _useMargin
    ) external marketActive {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            // first cancel order
            bool _isBuy = _cancelOrder(_orderIds[i], _useMargin);

            // add new order
            _isBuy ? addBuyOrder(_prices[i], _sizes[i], _useMargin) : addSellOrder(_prices[i], _sizes[i], _useMargin);
        }

        emit OrdersCanceled(_orderIds);
    }
}
