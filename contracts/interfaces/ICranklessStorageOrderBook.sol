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
}
