// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title OrderLinkedList
 * @notice This library manages double-linked lists of orders for each price point.
 */
library OrderLinkedList {
    struct PricePoint {
        uint256 head;
        uint256 tail;
    }

    // Constant representing a null order ID
    uint256 constant NULL = 0;

    /**
     * @notice Inserts an order at the tail of the list for a given price point.
     * @param point The price point.
     * @param orderId The order ID to insert.
     */
    function insertAtTail(PricePoint storage point, uint256 orderId) internal returns (uint256) {
        uint256 _pointTail = point.tail;
        if (_pointTail == NULL) {
            // The list is empty
            point.head = orderId;
            point.tail = orderId;
        } else {
            point.tail = orderId;
        }

        return _pointTail;
    }

    function deleteOrder(PricePoint storage point, uint256 prev, uint256 next) internal {
        if (prev == NULL) {point.head = next;}
        if (next == NULL) {point.tail = prev;}
    }
    
    /**
     * @notice Deletes one or multiple orders from the tail.
     * @param point The price point.
     * @param orderId The new orderId that has to be set as the tail.
     */
    function updateTail(PricePoint storage point, uint256 orderId) internal returns (bool) {
        if (orderId == NULL) {
            point.head = NULL;
            point.tail = NULL;

            return true;
        }

        point.tail = orderId;

        return false;
    }

    /**
     * @notice Deletes one or multiple orders from the head.
     * @param point The price point.
     * @param orderId The new orderId that has to be set as the head.
     */
    function updateHead(PricePoint storage point, uint256 orderId) internal returns (bool) {
        if (orderId == NULL) {
            point.head = NULL;
            point.tail = NULL;

            return true;
        }

        point.head = orderId;

        return false;
    }
}
