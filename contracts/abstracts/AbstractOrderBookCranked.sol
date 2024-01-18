// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC20} from "../libraries/IERC20.sol";
import {IAbstractOrderBook} from "../interfaces/IAbstractOrderBook.sol";

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
        uint96 executableSize; // market orders that have been executed and can be claimed by limit order owners
    }

    event OrderCreated(
        uint256 orderId,
        address owner,
        uint96 price,
        uint96 size,
        uint96 acceptableRange,
        bool isBuy
    );

    event OrderUpdated(
        uint256 orderId,
        address owner,
        uint96 price,
        uint96 size,
        uint96 acceptableRange,
        bool isBuy
    );

    event OrdersCompletedOrCanceled(
        uint256[] orderId
    );

    mapping(uint256 => Order) public s_orders;
    mapping(uint256 => PricePoint) public s_buyPricePoints;
    mapping(uint256 => PricePoint) public s_sellPricePoints;

    uint256 public s_orderIdCounter;

    IERC20 immutable baseAsset;
    IERC20 immutable quoteAsset;

    uint256 immutable baseAssetDecimals;
    uint256 immutable quoteAssetDecimals;

    uint256 constant sizePrecision = 10**10;
    uint256 constant pricePrecision = 10**2;

    /**
     * @dev Constructor.
     * @param _baseAssetAddress Address of the first token used for trading.
     * @param _baseAssetDecimals Deciimal pricicsion of the first swap token.
     * @param _quoteAssetAddress Address of the second token used for trading.
     * @param _quoteAssetDecimals Deciimal pricicsion of the first swap token.
     */
    constructor (address _baseAssetAddress, uint256 _baseAssetDecimals, address _quoteAssetAddress, uint256 _quoteAssetDecimals) {
        baseAsset = IERC20(_baseAssetAddress);
        quoteAsset = IERC20(_quoteAssetAddress);

        baseAssetDecimals = _baseAssetDecimals;
        quoteAssetDecimals = _quoteAssetDecimals;
    }

    /**
     * @dev Adds a buy order to the order book.
     * @param _price Price of the buy order.
     * @param size Size of the buy order.
     */
    function addBuyOrder(uint96 _price, uint96 size) public {
        uint256 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;

        PricePoint storage _pricePoint = s_buyPricePoints[_price];

        uint96 _acceptableRange = _addOrder(_pricePoint, _price, size, _orderId + 1, true);

        quoteAsset.transferFrom(msg.sender, address(this), ((((size * _price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision));

        emit OrderCreated(_orderId, msg.sender, _price, size, _acceptableRange, true);
    }

    /**
     * @dev Adds a sell order to the order book.
     * @param _price Price of the sell order.
     * @param size Size of the sell order.
     */
    function addSellOrder(uint96 _price, uint96 size) public {
        uint256 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;

        PricePoint storage _pricePoint = s_sellPricePoints[_price];

        uint96 _acceptableRange = _addOrder(_pricePoint, _price, size, _orderId + 1, false);

        baseAsset.transferFrom(msg.sender, address(this), ((size * 10**baseAssetDecimals) / sizePrecision));

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
    function batchCancelOrders(uint256[] memory _orderIds) external {
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

            quoteAsset.transfer(_order.ownerAddress, ((((_order.size * _order.price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision));
        } else {
            s_sellPricePoints[_order.price].totalCompletedOrCanceledOrders += _order.size;

            baseAsset.transfer(_order.ownerAddress, (_order.size * 10**baseAssetDecimals) / sizePrecision);
        }

        delete s_orders[_orderId];

        return _order.isBuy;
    }

    /**
     * @dev Places multiple limit buy orders in a single function call.
     * @param _prices Array of prices for the buy orders.
     * @param _sizes Array of sizes for the buy orders.
     */
    function placeMultipleBuyOrders(uint96[] memory _prices, uint96[] memory _sizes) external {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            this.addBuyOrder(_prices[i], _sizes[i]);
        }
    }

    /**
     * @dev Places multiple limit sell orders in a single function call.
     * @param _prices Array of prices for the sell orders.
     * @param _sizes Array of sizes for the sell orders.
     */
    function placeMultipleSellOrders(uint96[] memory _prices, uint96[] memory _sizes) external {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            this.addSellOrder(_prices[i], _sizes[i]);
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
    }
}
