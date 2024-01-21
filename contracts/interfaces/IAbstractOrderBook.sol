// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAbstractOrderBook {
    function addBuyOrder(uint96 _price, uint96 size, bool _useMargin) external;

    function addSellOrder(uint96 _price, uint96 size, bool _useMargin) external;

    function batchCancelOrders(
        uint256[] calldata _orderIds,
        bool _useMargin
    ) external;

    function placeMultipleBuyOrders(
        uint96[] memory _prices,
        uint96[] memory _sizes,
        bool _useMargin
    ) external;

    function placeMultipleSellOrders(
        uint96[] memory _prices,
        uint96[] memory _sizes,
        bool _useMargin
    ) external;

    function replaceOrders(
        uint256[] calldata _orderIds,
        uint96[] calldata _prices,
        uint96[] calldata _sizes,
        bool _useMargin
    ) external;
}
