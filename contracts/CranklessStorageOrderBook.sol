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
        uint24 _pricePrecision,
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
    ) public override marketActive {
        uint24 _initQuoteSize = _quoteSize;
        quoteAsset.transferFrom(msg.sender, address(marginAccount), uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision));
        _quoteSize = _matchAggressiveBuy(type(uint24).max, _quoteSize, false);
        if (_quoteSize >= 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            marginAccount.creditUser(
                msg.sender,
                address(quoteAsset),
                uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision),
                false
            );
        }

        emit BuyIOC(msg.sender, _initQuoteSize - _quoteSize);
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) public marketActive{
        // Transfer the base asset from the user to the contract
        uint96 _initSize = _size;
        baseAsset.transferFrom(
            msg.sender,
            address(marginAccount),
            (_size * 10 ** baseAssetDecimals) / sizePrecision
        );

        _size = _matchAggressiveSell(0, _size, false);

        if (_size > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");

            marginAccount.creditUser(
                msg.sender,
                address(baseAsset),
                ((_size * 10 ** baseAssetDecimals) / sizePrecision),
                false
            );
        }

        emit SellIOC(msg.sender, _initSize - _size);
    }

    /**
     * @dev Getter function to fetch price precision.
     */
    function getPricePrecision() external view returns (uint24) {
        return pricePrecision;
    }

    /**
     * @dev Getter function to fetch size precision.
     */
    function getSizePrecision() external view returns (uint96) {
        return sizePrecision;
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
