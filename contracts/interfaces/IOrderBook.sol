// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOrderBook {

    enum OrderBookType {
        NO_NATIVE,
        NATIVE_IN_BASE,
        NATIVE_IN_QUOTE
    }

    function initialize(
        address _factory,
        OrderBookType _type,
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
    ) external;

    function addBuyOrder(uint24 _price, uint96 size, bool _postOnly) external;

    function addSellOrder(uint24 _price, uint96 size, bool _postOnly) external;

    function batchCancelOrders(uint40[] calldata _orderIds) external;

    function placeMultipleBuyOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes,
        bool _postOnly
    ) external;

    function placeMultipleSellOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes,
        bool _postOnly
    ) external;

    function placeAndExecuteMarketBuy(
        uint24 _quoteAmount,
        bool _isFillOrKill
    ) payable external returns (uint256);

    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) payable external returns (uint256);

    function getPricePrecision() external view returns (uint24);

    function getSizePrecision() external view returns (uint96);

    function getBaseAssetDecimals() external view returns (uint256);

    function getQuoteAssetDecimals() external view returns (uint256);
}
