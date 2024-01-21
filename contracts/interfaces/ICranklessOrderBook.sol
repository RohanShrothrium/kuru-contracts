// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ICranklessOrderBook {
    function placeAndExecuteMarketBuy(
        uint256[] calldata c_order_ids,
        uint96 _quoteAmount,
        bool _isFillOrKill
    ) external returns (uint96);

    function placeAndExecuteMarketSell(
        uint256[] calldata c_prices,
        uint96 _size,
        bool _isFillOrKill
    ) external returns (uint96);

    function placeAggressivelimitSell(
        uint256[] calldata c_order_ids,
        uint96 _size,
        uint96 _price,
        bool _useMargin
    ) external;

    function placeAggressivelimitBuy(
        uint256[] calldata c_order_ids,
        uint96 _size,
        uint96 _price,
        bool _useMargin
    ) external;

    function getSizePrecision() external view returns (uint96);

    function getPricePrecision() external view returns (uint96);

    function getBaseAssetDecimals() external view returns (uint256);

    function getQuoteAssetDecimals() external view returns (uint256);
}
