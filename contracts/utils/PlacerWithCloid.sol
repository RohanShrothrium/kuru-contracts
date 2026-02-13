//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOrderBook} from "../interfaces/IOrderBook.sol";

contract PlacerWithCloid {
    address immutable _this;
    event batchUpdate(bytes32[] buyCloids, bytes32[] sellCloids, bytes32[] cancelCloids);

    struct BatchUpdateMMParams {
        address orderBook;
        bytes32[] buyCloids;
        bytes32[] sellCloids;
        bytes32[] cancelCloids;
        uint32[] buyPrices;
        uint96[] buySizes;
        uint32[] sellPrices;
        uint96[] sellSizes;
        uint40[] orderIdsToCancel;
        bool postOnly;
    }

    constructor() {
        _this = address(this);
    }

    modifier onlyDelegate() {
        require(address(this) != _this, "OnlyDelegate");
        require(msg.sender == address(this), "OnlySelf");
        _;
    }

    function batchUpdateMM(
        BatchUpdateMMParams calldata params
    ) external onlyDelegate {
        // process cancels first
        IOrderBook(params.orderBook).batchUpdate(new uint32[](0), new uint96[](0), new uint32[](0), new uint96[](0), params.orderIdsToCancel, true);
        try IOrderBook(params.orderBook).batchUpdate(params.buyPrices, params.buySizes, params.sellPrices, params.sellSizes, new uint40[](0), params.postOnly) {
        } catch {
            emit batchUpdate(new bytes32[](0), new bytes32[](0), params.cancelCloids);
            return;
        }
        emit batchUpdate(params.buyCloids, params.sellCloids, params.cancelCloids);
    }

    receive() external payable {}
}
