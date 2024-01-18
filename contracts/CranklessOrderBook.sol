// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Internal Interfaces Imports ============
import {ICranklessOrderBook} from "./interfaces/ICranklessOrderBook.sol";

// ============ Internal Contracts Imports ============
import {AbstractOrderBook} from "./abstracts/AbstractOrderBook.sol";

// size is 10**10
// price is 10**2
contract CranklessOrderBook is AbstractOrderBook, ICranklessOrderBook {

    constructor(
        address _baseAssetAddress,
        uint256 _baseAssetDecimals,
        address _quoteAssetAddress,
        uint256 _quoteAssetDecimals,
        uint96 _sizePrecision,
        uint96 _pricePrecision,
        uint96 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps
    )
        AbstractOrderBook(
            _baseAssetAddress,
            _baseAssetDecimals,
            _quoteAssetAddress,
            _quoteAssetDecimals,
            _sizePrecision,
            _pricePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps
        )
    {}

    /**
     * @dev Places and executes a market buy order.
     * @param c_order_ids order ids for execution of market order.
     * @param _quoteSize amount of quote asset user is ready to pay.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketBuy(
        uint256[] calldata c_order_ids,
        uint96 _quoteSize,
        bool _isFillOrKill
    ) public override marketActive returns (uint96) {
        uint256 _spentTokens = 0;
        uint96 _sizeToGet = 0;
        uint256 _quoteTokens = uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision);
        uint96[] memory _filledOrders = new uint96[](c_order_ids.length);

        // Transfer the total quote asset amount to the contract
        quoteAsset.transferFrom(msg.sender, address(this), _quoteTokens);

        for (uint256 _orderIndex = 0; _orderIndex < c_order_ids.length && _spentTokens < _quoteTokens; _orderIndex++) {
            Order storage _order = s_orders[c_order_ids[_orderIndex]];
            PricePoint storage s_pricePoint = s_sellPricePoints[_order.price];

            require(!_order.isBuy, "OrderBook: executing against a buy order");
            require(_order.acceptableRange <= s_pricePoint.totalCompletedOrCanceledOrders, "OrderBook: order not executable");

            uint256 orderValue = _amountPayable(_order.size, _order.price);
            uint256 spendable = _quoteTokens - _spentTokens;
            uint256 spendOnOrder = (orderValue > spendable) ? spendable : orderValue;

            _spentTokens += spendOnOrder;

            if (spendOnOrder == orderValue) {
                _sizeToGet += _order.size;

                _filledOrders[_orderIndex] = 0;

                // Transfer funds and update order book
                quoteAsset.transfer(_order.ownerAddress, _amountPayable(_order.size, _order.price));

                s_pricePoint.totalCompletedOrCanceledOrders += _order.size;
                _order.size = 0;
            } else {
                uint96 sizeToFill = uint96(spendOnOrder * sizePrecision / (_order.price * 10 ** quoteAssetDecimals));
                _sizeToGet += sizeToFill;

                _filledOrders[_orderIndex] = _order.price - sizeToFill;

                // Transfer funds and update order book
                quoteAsset.transfer(_order.ownerAddress, _amountPayable(sizeToFill, _order.price));

                s_pricePoint.totalCompletedOrCanceledOrders += sizeToFill;
                _order.size -= sizeToFill;
            }

            if (_spentTokens == _quoteTokens) {
                break;
            }
        }

        // Refund any unspent amount
        if (_spentTokens < _quoteTokens) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            quoteAsset.transfer(msg.sender, _quoteTokens - _spentTokens);
        }

        baseAsset.transfer(msg.sender, _sizeToGet * 10 ** quoteAssetDecimals * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * BPS_MULTIPLIER));

        emit BuyIOC(msg.sender, _sizeToGet, c_order_ids, _filledOrders);

        // Return the unspent amount
        return uint96((_quoteTokens - _spentTokens) * pricePrecision / 10 ** quoteAssetDecimals);
    }

    /**
     * @dev Places and executes a market sell order.
     * @param c_order_ids order ids for execution of market order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(
        uint256[] calldata c_order_ids,
        uint96 _size,
        bool _isFillOrKill
    ) public marketActive returns (uint96) {
        uint96 _initSize = _size;
        uint256 _orderIndex = 0;
        uint256 _priceToGet = 0;
        uint96[] memory _filledOrders = new uint96[](c_order_ids.length);

        // Transfer the base asset from the user to the contract
        baseAsset.transferFrom(
            msg.sender,
            address(this),
            (_size * 10 ** baseAssetDecimals) / sizePrecision
        );

        for (_orderIndex = 0; _orderIndex < c_order_ids.length && _size > 0; _orderIndex++) {
            Order storage _order = s_orders[c_order_ids[_orderIndex]];
            PricePoint storage s_pricePoint = s_buyPricePoints[_order.price];

            require(_order.isBuy, "OrderBook: executing against a sell order");
            require(_order.acceptableRange <= s_pricePoint.totalCompletedOrCanceledOrders, "OrderBook: order not executable");

            uint96 executableSize = _order.size > _size ? _size : _order.size;

            _priceToGet += executableSize * _order.price;
            _size -= executableSize;
            s_pricePoint.totalCompletedOrCanceledOrders += executableSize;

            baseAsset.transfer(_order.ownerAddress, (executableSize * 10 ** baseAssetDecimals) / sizePrecision);

            if (executableSize == _order.size) {
                _order.size = 0;
                _filledOrders[_orderIndex] = 0;
            } else {
                _order.size -= executableSize;
                _filledOrders[_orderIndex] = _order.size;
            }

            if(_size == 0) {
                break;
            }
        }

        if (_size > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            baseAsset.transfer(msg.sender, (_size * 10 ** baseAssetDecimals) / sizePrecision);
        }

        // Transfer the quote asset (proceeds from the sale) to the user
        quoteAsset.transfer(
            msg.sender,
            (((_priceToGet * 10 ** quoteAssetDecimals)) * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * pricePrecision * BPS_MULTIPLIER))
        );

        emit SellIOC(msg.sender, _initSize - _size, c_order_ids, _filledOrders);

        return _size;
    }


     /**
     * Places and executes an aggressive limit sell order
     * @param c_order_ids order ids for execution of aggressive order
     * @param _size Size of the aggressive sell order
     * @param _price conversion price from A to B
     */
    function placeAggressivelimitSell(
        uint256[] calldata c_order_ids,
        uint96 _size,
        uint96 _price
    ) external marketActive {
        uint96 _remainingSize = placeAndExecuteMarketSell(
            c_order_ids,
            _size,
            false
        );

        addSellOrder(_price, _remainingSize);
    }

    /**
     * Places and executes an aggressive limit buy order
     * @param c_order_ids order ids for execution of aggressive order
     * @param _quoteSize amount of quote asset user is ready to pay
     * @param _price conversion price from A to B
     */
    function placeAggressivelimitBuy(
        uint256[] calldata c_order_ids,
        uint96 _quoteSize,
        uint96 _price
    ) external marketActive {
        uint96 _remainingSize = placeAndExecuteMarketBuy(
            c_order_ids,
            _quoteSize,
            false
        );

        addBuyOrder(_price, (_remainingSize * sizePrecision / _price));
    }

    /**
     * internal helper function to get payable amount
     * @param _size size of token
     * @param _price conversion price from A to B
     */
    function _amountPayable(uint96 _size, uint96 _price) internal view returns (uint256) {
        return (_size * _price  * 10 ** quoteAssetDecimals / (pricePrecision * sizePrecision));
    }

    /**
     * @dev Getter function to fetch size precision.
     */
    function getSizePrecision() external view returns (uint96) {
        return sizePrecision;
    }

    /**
     * @dev Getter function to fetch price precision.
     */
    function getPricePrecision() external view returns (uint96) {
        return pricePrecision;
    }

    /**
     * @dev Getter function to fetch decimals of base asset.
     */
    function getBaseAssetDecimals() external view returns (uint256) {
        return baseAssetDecimals;
    }

    /**
     * @dev Getter function to fetch decimals of quote asset.
     */
    function getQuoteAssetDecimals() external view returns (uint256) {
        return quoteAssetDecimals;
    }
}
