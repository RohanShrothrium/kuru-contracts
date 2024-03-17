// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ICranklessStorageOrderBook {
    function placeAndExecuteMarketBuy(
        uint24 _quoteAmount,
        bool _isFillOrKill
    ) external;

    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) external;

    function getPricePrecision() external view returns (uint24);

    function getSizePrecision() external view returns (uint96);

    function getBaseAssetDecimals() external view returns (uint256);

    function getQuoteAssetDecimals() external view returns (uint256);
}
