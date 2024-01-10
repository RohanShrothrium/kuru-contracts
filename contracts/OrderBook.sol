// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";

import {IOrderBook} from "./interfaces/IOrderBook.sol";

import {AbstractOrderBook} from "./AbstractOrderBookCranked.sol";

// size is 10**10
// price is 10**2
contract OrderBook is AbstractOrderBook, IOrderBook {
    using SafeMath for uint96;
    using SafeMath for uint256;

    constructor(
        address _tokenAAddress,
        uint256 _tokenADecimals,
        address _tokenBAddress,
        uint256 _tokenBDecimals
    )
        AbstractOrderBook(
            _tokenAAddress,
            _tokenADecimals,
            _tokenBAddress,
            _tokenBDecimals
        )
    {}

    /**
     * @dev Places and executes a market buy order.
     * @param _size Size of the market buy order.
     */
    function placeAndExecuteMarketBuy(
        uint256[] calldata c_min_asks,
        uint96 _size
    ) external {
        require(_size > 0, "OrderBook: size must be greater than 0");

        uint96 _price_counter = 0;
        // load the first price point into memory
        uint256 _minAsk = c_min_asks[_price_counter];

        PricePoint memory m_pricePoint = s_sellPricePoints[_minAsk];
        uint96 _volumeAtPricePoint = m_pricePoint.totalOrdersAtPrice -
            m_pricePoint.totalCompletedOrCanceledOrders -
            m_pricePoint.executableSize;

        uint256 _priceToPay = 0;
        uint256 _executedSize = 0;

        while (_size >= _volumeAtPricePoint) {
            _priceToPay += _volumeAtPricePoint.mul(_minAsk);
            m_pricePoint.executableSize += _volumeAtPricePoint;
            _size -= _volumeAtPricePoint;
            _executedSize += _volumeAtPricePoint;

            // update price point storage variable
            s_sellPricePoints[_minAsk] = m_pricePoint;

            // update _price_counter variable
            _price_counter += 1;

            // load the next price point into memory if exists
            if (_price_counter == c_min_asks.length) {
                break;
            }
            _minAsk = c_min_asks[_price_counter];
            m_pricePoint = s_sellPricePoints[_minAsk];

            _volumeAtPricePoint =
                m_pricePoint.totalOrdersAtPrice -
                m_pricePoint.totalCompletedOrCanceledOrders -
                m_pricePoint.executableSize;
        }

        if (_size > 0 && _price_counter < c_min_asks.length) {
            _priceToPay += _size.mul(_minAsk);
            m_pricePoint.executableSize += _size;

            // update overall executed size
            _executedSize += _size;

            // update price point storage variable
            s_sellPricePoints[_minAsk] = m_pricePoint;
        }

        // transfer the tokens
        tokenB.transferFrom(
            msg.sender,
            address(this),
            _priceToPay.mul(10 ** tokenBDecimals).div(pricePrecision).div(
                sizePrecision
            )
        );
        tokenA.transfer(
            msg.sender,
            _executedSize.mul(10 ** tokenADecimals).div(sizePrecision)
        );
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     */
    function placeAndExecuteMarketSell(
        uint256[] calldata c_max_bids,
        uint96 _size
    ) external {
        require(_size > 0, "OrderBook: size must be greater than 0");

        uint96 _price_counter = 0;
        // load the first price point into memory
        uint256 _maxBid = c_max_bids[_price_counter];

        PricePoint memory m_pricePoint = s_buyPricePoints[_maxBid];
        uint96 _volumeAtPricePoint = m_pricePoint.totalOrdersAtPrice -
            m_pricePoint.totalCompletedOrCanceledOrders -
            m_pricePoint.executableSize;

        uint256 _priceToGet = 0;
        uint256 _executedSize = 0;

        while (_size > _volumeAtPricePoint) {
            _priceToGet += _volumeAtPricePoint.mul(_maxBid);
            m_pricePoint.executableSize += _volumeAtPricePoint;
            _size -= _volumeAtPricePoint;
            _executedSize += _volumeAtPricePoint;

            // update price point storage variable
            s_buyPricePoints[_maxBid] = m_pricePoint;

            // update _price_counter variable
            _price_counter += 1;

            // load the next price point into memory if exists
            if (_price_counter == c_max_bids.length) {
                break;
            }
            _maxBid = c_max_bids[_price_counter];
            m_pricePoint = s_buyPricePoints[_maxBid];

            _volumeAtPricePoint =
                m_pricePoint.totalOrdersAtPrice -
                m_pricePoint.totalCompletedOrCanceledOrders -
                m_pricePoint.executableSize;
        }

        if (_size > 0 && _price_counter < c_max_bids.length) {
            _priceToGet += _size.mul(_maxBid);
            m_pricePoint.executableSize += _size;

            // update overall executed size
            _executedSize += _size;

            // update price point storage variable
            s_buyPricePoints[_maxBid] = m_pricePoint;
        }

        // transfer the tokens
        tokenA.transferFrom(
            msg.sender,
            address(this),
            _executedSize.mul(10 ** tokenADecimals).div(sizePrecision)
        );
        tokenB.transfer(
            msg.sender,
            _priceToGet.mul(10 ** tokenBDecimals).div(pricePrecision).div(
                sizePrecision
            )
        );
    }

    /**
     * @dev Claims a sell limit order.
     * @param _orderId ID of the sell limit order to claim.
     */
    function claimSellLimitOrder(uint256 _orderId) external {
        Order storage _order = s_orders[_orderId];
        require(
            _order.ownerAddress != address(0),
            "OrderBook: order doesn't exist"
        );
        require(
            msg.sender == _order.ownerAddress,
            "OrderBook: only order owner can claim"
        );

        PricePoint storage _pricePoint = s_sellPricePoints[_order.price];
        require(
            _order.acceptableRange <
                _pricePoint.executableSize +
                    _pricePoint.totalCompletedOrCanceledOrders,
            "OrderBook: order not executable"
        );

        uint96 _executableSize = _pricePoint.executableSize +
            _pricePoint.totalCompletedOrCanceledOrders -
            _order.acceptableRange;

        uint96 _sizeToExecute = _executableSize > _order.size
            ? _order.size
            : _executableSize;

        _order.size -= _sizeToExecute;
        _pricePoint.totalCompletedOrCanceledOrders += _sizeToExecute;
        _pricePoint.executableSize -= _sizeToExecute;

        tokenB.transfer(
            _order.ownerAddress,
            _sizeToExecute
                .mul(_order.price)
                .mul(10 ** tokenBDecimals)
                .div(pricePrecision)
                .div(sizePrecision)
        );

        if (_order.size == 0) {
            delete s_orders[_orderId];
        }
    }

    /**
     * @dev Claims a buy limit order.
     * @param _orderId ID of the buy limit order to claim.
     */
    function claimBuyLimitOrder(uint256 _orderId) external {
        Order storage _order = s_orders[_orderId];
        require(
            _order.ownerAddress != address(0),
            "OrderBook: order doesn't exist"
        );
        require(
            msg.sender == _order.ownerAddress,
            "OrderBook: only order owner can claim"
        );

        PricePoint storage _pricePoint = s_buyPricePoints[_order.price];
        require(
            _order.acceptableRange <
                _pricePoint.executableSize +
                    _pricePoint.totalCompletedOrCanceledOrders,
            "OrderBook: order not executable"
        );

        uint96 _executableSize = _pricePoint.executableSize +
            _pricePoint.totalCompletedOrCanceledOrders -
            _order.acceptableRange;

        uint96 _sizeToExecute = _executableSize > _order.size
            ? _order.size
            : _executableSize;

        _order.size -= _sizeToExecute;
        _pricePoint.totalCompletedOrCanceledOrders += _sizeToExecute;
        _pricePoint.executableSize -= _sizeToExecute;

        tokenA.transfer(
            _order.ownerAddress,
            _sizeToExecute.mul(10 ** tokenADecimals).div(sizePrecision)
        );

        if (_order.size == 0) {
            delete s_orders[_orderId];
        }
    }
}
