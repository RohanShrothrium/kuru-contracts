// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOrderBook {

    function initialize(
        address _factory,
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

    function addBuyOrder(uint24 _price, uint96 size) external;

    function addSellOrder(uint24 _price, uint96 size) external;

    function batchCancelOrders(uint40[] calldata _orderIds) external;

    function placeMultipleBuyOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes
    ) external;

    function placeMultipleSellOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes
    ) external;

    function placeAndExecuteMarketBuy(
        uint24 _quoteAmount,
        bool _isFillOrKill
    ) external returns (uint256);

    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) external returns (uint256);

    function getPricePrecision() external view returns (uint24);

    function getSizePrecision() external view returns (uint96);

    function getBaseAssetDecimals() external view returns (uint256);

    function getQuoteAssetDecimals() external view returns (uint256);
}
