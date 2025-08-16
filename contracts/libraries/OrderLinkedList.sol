// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

/**
 * @title OrderLinkedList
 * @notice This library manages double-linked lists of orders for each price point.
 */
library OrderLinkedList {
    struct PricePoint {
        uint40 head;
        uint40 tail;
    }

    // Constant representing a null order ID
    uint40 constant NULL = 0;

    /**
     * @notice Inserts an order at the tail of the list for a given price point.
     * @param point The price point.
     * @param orderId The order ID to insert.
     */
    function insertAtTail(PricePoint storage point, uint40 orderId) internal returns (uint40) {
        uint40 _pointTail = point.tail;
        if (_pointTail == NULL) {
            // The list is empty
            point.head = orderId;
            point.tail = orderId;
        } else {
            point.tail = orderId;
        }

        return _pointTail;
    }

    function adjustForTail(PricePoint storage point, uint40 prev, uint40 next) internal {
        if (next == NULL) {
            point.tail = prev;
        }
    }

    /**
     * @notice Deletes one or multiple orders from the head.
     * @param point The price point.
     * @param orderId The new orderId that has to be set as the head.
     */
    function updateHead(PricePoint storage point, uint40 orderId) internal {
        if (orderId == NULL) {
            point.head = NULL;
            point.tail = NULL;
        }

        point.head = orderId;
    }
}
