// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0; 

interface IOrderBook {
    function placeAndExecuteMarketBuy(uint256[] calldata c_prices, uint96 _size) external;
    function placeAndExecuteMarketSell(uint256[] calldata c_prices, uint96 _size) external;
    function claimSellLimitOrder(uint256 _orderId) external;
    function claimBuyLimitOrder(uint256 _orderId) external;
}
