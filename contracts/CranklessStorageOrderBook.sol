// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";

// ============ Internal Interfaces Imports ============
import {ICranklessStorageOrderBook} from "./interfaces/ICranklessStorageOrderBook.sol";

// ============ Internal Contracts Imports ============
import {AbstractStorageOrderBook} from "./abstracts/AbstractStorageOrderBook.sol";

// size is 10**10
// price is 10**2
contract CranklessStorageOrderBook is AbstractStorageOrderBook, ICranklessStorageOrderBook {

    constructor(
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
    )
        AbstractStorageOrderBook(
            _baseAssetAddress,
            _baseAssetDecimals,
            _quoteAssetAddress,
            _quoteAssetDecimals,
            _marginAccountAddress,
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
     * @param _quoteSize amount of quote asset user is ready to pay.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketBuy(
        uint24 _quoteSize,
        bool _isFillOrKill
    ) public override marketActive returns (uint96) {
        uint96 _sizeToGet;
        quoteAsset.transferFrom(msg.sender, address(marginAccount), uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision));
        while (_quoteSize > 0) {
            uint24 _price = TreeMath.findFirstLeft(s_sellTree, 0);
            if (_price == 0) {
                break;
            }

            uint96 _size = _quoteSize * sizePrecision / _price;
            _sizeToGet += _size;

            _size = _fillSizeForPrice(s_sellPricePoints[_price], _size);
            if (_size > 0) {
                TreeMath.remove(s_sellTree, _price);
            }
            _sizeToGet -= _size;

            _quoteSize = uint24(_size * _price / sizePrecision);
        }

        if (_quoteSize > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");

            marginAccount.creditUser(
                msg.sender,
                address(quoteAsset),
                uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision),
                address(baseAsset),
                address(quoteAsset),
                false
            );
        }

        marginAccount.creditUser(
            msg.sender,
            address(baseAsset),
            _sizeToGet * 10 ** quoteAssetDecimals * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * BPS_MULTIPLIER),
            address(baseAsset),
            address(quoteAsset),
            false
        );

        return uint96(_quoteSize * pricePrecision / 10 ** quoteAssetDecimals);
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) public marketActive returns (uint96) {
        uint96 _priceToGet;

        // Transfer the base asset from the user to the contract
        baseAsset.transferFrom(
            msg.sender,
            address(marginAccount),
            (_size * 10 ** baseAssetDecimals) / sizePrecision
        );

        while (_size > 0) {
            uint24 _price = TreeMath.findFirstRight(s_buyTree, type(uint24).max);
            if (_price == type(uint24).max) {
                break;
            }
            
            uint96 _tmpSize = _size;
            _size = _fillSizeForPrice(s_buyPricePoints[_price], _size);
            if (_size > 0) {
                TreeMath.remove(s_buyTree, _price);
            }
            _priceToGet += (_tmpSize - _size) * _price;
        }

        if (_size > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");

            marginAccount.creditUser(
                msg.sender,
                address(baseAsset),
                ((_size * 10 ** baseAssetDecimals) / sizePrecision),
                address(baseAsset),
                address(quoteAsset),
                false
            );
        }

        marginAccount.creditUser(
            msg.sender,
            address(quoteAsset),
            (((_priceToGet * 10 ** quoteAssetDecimals)) * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * pricePrecision * BPS_MULTIPLIER)),
            address(baseAsset),
            address(quoteAsset),
            false
        );

        return _size;
    }

    /**
     * @dev This is an internal function that takes a size and a price point and tries to exhaustively fill the required size.
     * If the liquidity at the price point gets exhausted, the remaining size is returned.
     * @param _pricePoint The price point against which the order has to be filled.
     * @param _size Remaining size to be filled.
     */
    function _fillSizeForPrice(OrderLinkedList.PricePoint storage _pricePoint, uint96 _size) internal returns (uint96) {
        while (_size > 0 && _pricePoint.head != OrderLinkedList.NULL) {
            uint256 _orderId = _pricePoint.head;
            bool _shouldPop;
            (_size, _shouldPop) = _fillOrder(_orderId, _size);

            // pop head from linked list
            if (_shouldPop) {
                OrderLinkedList.popHead(_pricePoint);
            }
        }

        return _size;
    }

    function _fillOrder(uint256 _orderId, uint96 _size) internal returns (uint96, bool) {
        Order memory m_order = s_orders[_orderId];
        uint96 _remainingSize = _size > m_order.size ? _size - m_order.size : 0;
        uint96 _filledSize = _remainingSize == 0 ? _size : m_order.size;
        _creditMaker(!m_order.isBuy, m_order.ownerAddress, _filledSize, m_order.price, m_order.useMargin);

        if (_filledSize == m_order.size) {
            delete s_orders[_orderId];
        }

        return (_remainingSize, _filledSize == m_order.size);
    }

    function _creditMaker(bool _isMarketBuy, address _ownerAddress, uint96 _size, uint24 _price, bool _useMargin) internal {
        _isMarketBuy ? 
        marginAccount.creditUser(
            _ownerAddress,
            address(quoteAsset),
            _amountPayable(_size, _price),
            address(baseAsset),
            address(quoteAsset),
            _useMargin
        ) : 
        marginAccount.creditUser(
            _ownerAddress,
            address(baseAsset),
            ((_size * 10 ** baseAssetDecimals) / sizePrecision),
            address(baseAsset),
            address(quoteAsset),
            _useMargin
        );
    }


     /**
     * Places and executes an aggressive limit sell order
     * @param _size Size of the aggressive sell order
     * @param _price conversion price from A to B
     */
    function placeAggressivelimitSell(
        uint96 _size,
        uint24 _price,
        bool _useMargin
    ) external marketActive {
        uint96 _remainingSize = placeAndExecuteMarketSell(
            _size,
            false
        );

        addSellOrder(_price, _remainingSize, _useMargin);
    }

    /**
     * Places and executes an aggressive limit buy order
     * @param _quoteSize amount of quote asset user is ready to pay
     * @param _price conversion price from A to B
     */
    function placeAggressivelimitBuy(
        uint24 _quoteSize,
        uint24 _price,
        bool _useMargin
    ) external marketActive {
        uint96 _remainingSize = placeAndExecuteMarketBuy(
            _quoteSize,
            false
        );

        addBuyOrder(_price, (_remainingSize * sizePrecision / _price), _useMargin);
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
