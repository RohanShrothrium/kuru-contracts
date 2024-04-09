// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAbstractStorageOrderBook {
    function addBuyOrder(uint24 _price, uint96 size) external;

    function addSellOrder(uint24 _price, uint96 size) external;

    function batchCancelOrders(
        uint40[] calldata _orderIds
    ) external;

    function placeMultipleBuyOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes
    ) external;

    function placeMultipleSellOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes
    ) external;
}
