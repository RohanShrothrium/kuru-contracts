// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC20} from "./libraries/IERC20.sol";
import {IAbstractOrderBook} from "./interfaces/IAbstractOrderBook.sol";

abstract contract AbstractOrderBook is IAbstractOrderBook {
    struct Order {
        address ownerAddress;
        uint96 price;
        uint96 size;
        uint96 acceptableRange;
        bool isBuy;
    }

    struct PricePoint {
        uint96 totalCompletedOrCanceledOrders;
        uint96 totalOrdersAtPrice; // sum of size of all orders placed at the price point
    }

    event OrderCreated(
        uint256 orderId,
        address owner,
        uint96 price,
        uint96 size,
        uint96 acceptableRange,
        bool isBuy
    );

    event OrdersUpdated(
        uint256[] orderIds,
        uint96[] updatedSizes
    );

    event OrdersCompletedOrCanceled(
        uint256[] orderId
    );

    mapping(uint256 => Order) public s_orders;
    mapping(uint256 => PricePoint) public s_buyPricePoints;
    mapping(uint256 => PricePoint) public s_sellPricePoints;

    uint256 public s_orderIdCounter;

    IERC20 immutable tokenA;
    IERC20 immutable tokenB;

    uint256 immutable tokenADecimals;
    uint256 immutable tokenBDecimals;

    uint96 constant sizePrecision = 10**10;
    uint96 constant pricePrecision = 10**2;

    uint96 constant tickSize = pricePrecision/2;
    uint96 constant minSize = 10**5;
    uint96 constant maxSize = 10**12;

    uint256 constant takerFeeBps = 0;

    uint256 constant BPS_MULTIPLIER = 10000;

    /**
     * @dev Constructor.
     * @param _tokenAAddress Address of the first token used for trading.
     * @param _tokenADecimals Deciimal pricicsion of the first swap token.
     * @param _tokenBAddress Address of the second token used for trading.
     * @param _tokenBDecimals Deciimal pricicsion of the first swap token.
     */
    constructor (address _tokenAAddress, uint256 _tokenADecimals, address _tokenBAddress, uint256 _tokenBDecimals) {
        tokenA = IERC20(_tokenAAddress);
        tokenB = IERC20(_tokenBAddress);

        tokenADecimals = _tokenADecimals;
        tokenBDecimals = _tokenBDecimals;
    }

    /**
     * @dev Adds a buy order to the order book.
     * @param _price Price of the buy order.
     * @param size Size of the buy order.
     */
    function addBuyOrder(uint96 _price, uint96 size) public {
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");

        uint256 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;

        PricePoint storage _pricePoint = s_buyPricePoints[_price];

        uint96 _acceptableRange = _addOrder(_pricePoint, _price, size, _orderId + 1, true);

        tokenB.transferFrom(msg.sender, address(this), ((((size * _price) * 10**tokenBDecimals) / pricePrecision) / sizePrecision));

        emit OrderCreated(_orderId, msg.sender, _price, size, _acceptableRange, true);
    }

    /**
     * @dev Adds a sell order to the order book.
     * @param _price Price of the sell order.
     * @param size Size of the sell order.
     */
    function addSellOrder(uint96 _price, uint96 size) public {
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");

        uint256 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;

        PricePoint storage _pricePoint = s_sellPricePoints[_price];

        uint96 _acceptableRange = _addOrder(_pricePoint, _price, size, _orderId + 1, false);

        tokenA.transferFrom(msg.sender, address(this), ((size * 10**tokenADecimals) / sizePrecision));

        emit OrderCreated(_orderId, msg.sender, _price, size, _acceptableRange, false);
    }

    /**
     * @dev Internal function to add an order to the order book.
     * @param _pricePoint PricePoint storage object for the order's price point.
     * @param _price Price of the order.
     * @param _size Size of the order.
     */
    function _addOrder(PricePoint storage _pricePoint, uint96 _price, uint96 _size, uint256 _orderId, bool _isBuy) internal returns(uint96) {
        uint96 acceptableRange = _pricePoint.totalOrdersAtPrice;
        s_orders[_orderId] = Order(msg.sender, _price, _size, acceptableRange, _isBuy);

        _pricePoint.totalOrdersAtPrice += _size;

        return acceptableRange;
    }

    /**
     * @dev Cancels multiple orders in a batch.
     * @param _orderIds Array of order IDs to cancel.
     */
    function batchCancelOrders(uint256[] calldata _orderIds) external {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _cancelOrder(_orderIds[i]);
        }

        emit OrdersCompletedOrCanceled(_orderIds);
    }

    /**
     * @dev Internal helper function to cancel a single order.
     * @param _orderId ID of the order to cancel.
     */
    function _cancelOrder(uint256 _orderId) internal returns (bool) {
        Order memory _order = s_orders[_orderId];

        require(msg.sender == _order.ownerAddress, "OrderBook: Only order owner can cancel order");

        if (_order.isBuy) {
            s_buyPricePoints[_order.price].totalCompletedOrCanceledOrders += _order.size;

            tokenB.transfer(_order.ownerAddress, ((((_order.size * _order.price) * 10**tokenBDecimals) / pricePrecision) / sizePrecision));
        } else {
            s_sellPricePoints[_order.price].totalCompletedOrCanceledOrders += _order.size;

            tokenA.transfer(_order.ownerAddress, (_order.size * 10**tokenADecimals) / sizePrecision);
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
    function decreaseOrders(uint256[] calldata _orderIds, uint96[] calldata _updatedSizes) external {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _decreaseOrder(_orderIds[i], _updatedSizes[i]);
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
    function _decreaseOrder(uint256 _orderId, uint96 _updatedSize) internal {
        Order memory _order = s_orders[_orderId];

        require(msg.sender == _order.ownerAddress, "OrderBook: Only order owner can update order");
        require(_order.size > _updatedSize, "OrderBook: can't increase order size");

        uint96 _decreasedSize = _order.size - _updatedSize;

        if (_order.isBuy) {
            s_buyPricePoints[_order.price].totalCompletedOrCanceledOrders += _decreasedSize;

            tokenB.transfer(_order.ownerAddress, ((((_decreasedSize * _order.price) * 10**tokenBDecimals) / pricePrecision) / sizePrecision));
        } else {
            s_sellPricePoints[_order.price].totalCompletedOrCanceledOrders += _decreasedSize;

            tokenA.transfer(_order.ownerAddress, (_decreasedSize * 10**tokenADecimals) / sizePrecision);
        }

        s_orders[_orderId].size = _updatedSize;
    }

    /**
     * @dev Places multiple limit buy orders in a single function call.
     * @param _prices Array of prices for the buy orders.
     * @param _sizes Array of sizes for the buy orders.
     */
    function placeMultipleBuyOrders(uint96[] calldata _prices, uint96[] calldata _sizes) external {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addBuyOrder(_prices[i], _sizes[i]);
        }
    }

    /**
     * @dev Places multiple limit sell orders in a single function call.
     * @param _prices Array of prices for the sell orders.
     * @param _sizes Array of sizes for the sell orders.
     */
    function placeMultipleSellOrders(uint96[] calldata _prices, uint96[] calldata _sizes) external {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addSellOrder(_prices[i], _sizes[i]);
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
        uint96[] calldata _sizes
    ) external {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            // first cancel order
            bool _isBuy = _cancelOrder(_orderIds[i]);

            // add new order
            _isBuy ? addBuyOrder(_prices[i], _sizes[i]) : addSellOrder(_prices[i], _sizes[i]);
        }

        emit OrdersCompletedOrCanceled(_orderIds);
    }
}
