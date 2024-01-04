// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";

import {ICranklessOrderBook} from "./interfaces/ICranklessOrderBook.sol";

import {AbstractOrderBook} from "./AbstractOrderBook.sol";

// size is 10**10
// price is 10**2
contract CranklessOrderBook is AbstractOrderBook, ICranklessOrderBook {

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
        uint96[] calldata c_order_ids,
        uint128 _size,
        bool _isFillOrKill
    ) external override returns (uint128) {
        uint256 _orderIndex = 0;
        Order memory _order = s_orders[c_order_ids[_orderIndex]];
        PricePoint memory m_pricePoint = s_buyPricePoints[_order.price];

        uint256 _executedSize = 0;
        uint256[] memory _filledOrders = new uint256[](c_order_ids.length);

        while (_size > _order.size && _orderIndex < c_order_ids.length) {
            require(!_order.isBuy, "OrderBook: executing against a buy order");
            require(_order.acceptableRange <= m_pricePoint.totalCompletedOrCanceledOrders, "OrderBook: order not executable");

            _filledOrders[_orderIndex] = c_order_ids[_orderIndex];

            _executedSize += _order.size;
            _size -= _order.size;
            m_pricePoint.totalCompletedOrCanceledOrders += _order.size;

            uint256 _existinPrice = _order.price;

            // TODO: Transfer tokens to limit order.
            tokenB.transferFrom(
                msg.sender,
                _order.ownerAddress,
                _amountPayable(_order.size, _order.price)
            );

            _order.size = 0;
            s_orders[c_order_ids[_orderIndex]] = _order;

            _orderIndex += 1;
            _order = s_orders[c_order_ids[_orderIndex]];
            if (_existinPrice != _order.price) {
                s_buyPricePoints[_existinPrice] = m_pricePoint;
                m_pricePoint = s_buyPricePoints[_order.price];
            }
        }
        
        if (_size > 0 && _orderIndex < c_order_ids.length) {
            require(!_order.isBuy, "OrderBook: executing against a buy order");
            require(_order.acceptableRange <= m_pricePoint.totalCompletedOrCanceledOrders, "OrderBook: order not executable");

            m_pricePoint.totalCompletedOrCanceledOrders += _size;
            _executedSize += _size;

            // TODO: Transfer tokens to limit order.
            tokenB.transferFrom(
                msg.sender,
                _order.ownerAddress,
                _amountPayable(_size, _order.price)
            );

            _order.size -= _size;
            s_orders[c_order_ids[_orderIndex]] = _order;
            s_buyPricePoints[_order.price] = m_pricePoint;
        }

        if (_isFillOrKill) {
            require(_size == 0, "insufficient volume on book");
        }

        tokenA.transfer(
            msg.sender,
            ((_executedSize * 10 ** tokenADecimals) * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * BPS_MULTIPLIER))
        );

        emit OrdersCompletedOrCanceled(_filledOrders);

        return _size;
    }

    /**
     * internal helper function to get payable amount
     * @param _size size of token
     * @param _price conversion price from A to B
     */
    function _amountPayable(uint256 _size, uint256 _price) internal view returns (uint256) {
        return ((((_size * _price) * 10 ** tokenBDecimals) / pricePrecision) / sizePrecision);
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     */
    function placeAndExecuteMarketSell(
        uint96[] calldata c_order_ids,
        uint128 _size,
        bool _isFillOrKill
    ) external returns (uint128) {
        uint256 _orderIndex = 0;
        Order memory _order = s_orders[c_order_ids[_orderIndex]];
        PricePoint memory m_pricePoint = s_sellPricePoints[_order.price];

        uint256 _priceToGet = 0;
        uint256[] memory _filledOrders = new uint256[](c_order_ids.length);

        while (_size > _order.size && _orderIndex < c_order_ids.length) {
            require(_order.isBuy, "OrderBook: executing against a sell order");
            require(_order.acceptableRange <= m_pricePoint.totalCompletedOrCanceledOrders, "OrderBook: order not executable");

            _filledOrders[_orderIndex] = c_order_ids[_orderIndex];

            _priceToGet += _order.size * _order.price;
            _size -= _order.size;
            m_pricePoint.totalCompletedOrCanceledOrders += _order.size;

            uint256 _existinPrice = _order.price;

            // TODO: Transfer tokens to limit order.
            tokenA.transferFrom(
                msg.sender,
                _order.ownerAddress,
                (_order.size * 10 ** tokenADecimals) / sizePrecision
            );

            _order.size = 0;
            s_orders[c_order_ids[_orderIndex]] = _order;

            _orderIndex += 1;
            _order = s_orders[c_order_ids[_orderIndex]];
            if (_existinPrice != _order.price) {
                s_sellPricePoints[_existinPrice] = m_pricePoint;
                m_pricePoint = s_sellPricePoints[_order.price];
            }
        }
        
        if (_size > 0 && _orderIndex < c_order_ids.length) {
            require(_order.isBuy, "OrderBook: executing against a sell order");
            require(_order.acceptableRange <= m_pricePoint.totalCompletedOrCanceledOrders, "OrderBook: order not executable");

            m_pricePoint.totalCompletedOrCanceledOrders += _size;
            _priceToGet += _size * _order.price;

            // TODO: Transfer tokens to limit order.
            tokenA.transferFrom(
                msg.sender,
                _order.ownerAddress,
                ((_size * 10 ** tokenADecimals) / sizePrecision)
            );

            _order.size -= _size;
            s_orders[c_order_ids[_orderIndex]] = _order;
            s_sellPricePoints[_order.price] = m_pricePoint;
        }

        if (_isFillOrKill) {
            require(_size == 0, "insufficient volume on book");
        }

        tokenB.transfer(
            msg.sender,
            (((_priceToGet * 10 ** tokenBDecimals)) * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * pricePrecision * BPS_MULTIPLIER))
        );

        emit OrdersCompletedOrCanceled(_filledOrders);

        return _size;
    }

     /**
     * Places and executes an aggressive limit sell order
     * @param c_order_ids order ids for execution of aggressive order
     * @param _size Size of the aggressive sell order
     * @param _price conversion price from A to B
     */
    function placeAggressivelimitSell(
        uint96[] calldata c_order_ids,
        uint128 _size,
        uint96 _price
    ) external {
        uint128 _remainingSize = this.placeAndExecuteMarketSell(
            c_order_ids,
            _size,
            false
        );

        this.addSellOrder(_price, _remainingSize);
    }

    /**
     * Places and executes an aggressive limit buy order
     * @param c_order_ids order ids for execution of aggressive order
     * @param _size Size of the aggressive buy order
     * @param _price conversion price from A to B
     */
    function placeAggressivelimitBuy(
        uint96[] calldata c_order_ids,
        uint128 _size,
        uint96 _price
    ) external {
        uint128 _remainingSize = this.placeAndExecuteMarketBuy(
            c_order_ids,
            _size,
            false
        );

        this.addBuyOrder(_price, _remainingSize);
    }
}
