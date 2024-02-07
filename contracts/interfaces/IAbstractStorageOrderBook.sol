// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAbstractStorageOrderBook {
    function addBuyOrder(uint24 _price, uint96 size, bool _useMargin) external;

    function addSellOrder(uint24 _price, uint96 size, bool _useMargin) external;

    function batchCancelOrders(
        uint256[] calldata _orderIds,
        bool _useMargin
    ) external;

    function placeMultipleBuyOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes,
        bool _useMargin
    ) external;

    function placeMultipleSellOrders(
        uint24[] memory _prices,
        uint96[] memory _sizes,
        bool _useMargin
    ) external;
}
