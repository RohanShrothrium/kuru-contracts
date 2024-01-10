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
        uint96 _price
    ) external;

    function placeAggressivelimitBuy(
        uint256[] calldata c_order_ids,
        uint96 _size,
        uint96 _price
    ) external;
}
