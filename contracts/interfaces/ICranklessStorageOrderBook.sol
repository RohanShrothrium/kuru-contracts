// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ICranklessStorageOrderBook {
    function placeAndExecuteMarketBuy(
        uint24 _quoteAmount,
        bool _isFillOrKill
    ) external returns (uint96);

    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) external returns (uint96);

    function placeAggressivelimitSell(
        uint96 _size,
        uint24 _price,
        bool _useMargin
    ) external;

    function placeAggressivelimitBuy(
        uint24 _size,
        uint24 _price,
        bool _useMargin
    ) external;

    function getSizePrecision() external view returns (uint96);

    function getPricePrecision() external view returns (uint96);

    function getBaseAssetDecimals() external view returns (uint256);

    function getQuoteAssetDecimals() external view returns (uint256);
}
