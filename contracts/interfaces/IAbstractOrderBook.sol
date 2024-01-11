// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAbstractOrderBook {
    function addBuyOrder(uint96 _price, uint96 size) external;

    function addSellOrder(uint96 _price, uint96 size) external;

    function batchCancelOrders(
        uint256[] calldata _orderIds
    ) external;

    function placeMultipleBuyOrders(
        uint96[] memory _prices,
        uint96[] memory _sizes
    ) external;

    function placeMultipleSellOrders(
        uint96[] memory _prices,
        uint96[] memory _sizes
    ) external;

    function replaceOrders(
        uint256[] calldata _orderIds,
        uint96[] calldata _prices,
        uint96[] calldata _sizes
    ) external;
}
