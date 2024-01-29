// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title OrderLinkedList
 * @notice This library manages double-linked lists of orders for each price point.
 */
library OrderLinkedList {
    struct OrderVertex {
        uint256 next;
        uint256 prev;
    }

    struct PricePoint {
        uint256 head;
        uint256 tail;
        mapping(uint256 => OrderVertex) orders;
    }

    // Constant representing a null order ID
    uint256 constant NULL = 0;

    /**
     * @notice Inserts an order at the tail of the list for a given price point.
     * @param point The price point.
     * @param orderId The order ID to insert.
     */
    function insertAtTail(PricePoint storage point, uint256 orderId) internal {
        require(orderId != NULL, "Invalid order ID");

        OrderVertex memory order = OrderVertex(NULL, NULL);
        uint256 _pointTail = point.tail;
        if (_pointTail == NULL) {
            // The list is empty
            point.head = orderId;
            point.tail = orderId;
        } else {
            // The list is not empty
            order.prev = _pointTail;
            point.orders[_pointTail].next = orderId;
            point.tail = orderId;
        }

        point.orders[orderId] = order;
    }

    /**
     * @notice Deletes an order from the list for a given price point.
     * @param point The price point.
     * @param orderId The order ID to delete.
     */
    function deleteOrder(PricePoint storage point, uint256 orderId) internal returns (bool) {
        require(orderId != NULL, "Invalid order ID");

        OrderVertex storage orderToDelete = point.orders[orderId];

        uint256 nextOrder = orderToDelete.next;
        uint256 prevOrder = orderToDelete.prev;

        prevOrder == NULL ? point.head = nextOrder : point.orders[prevOrder].next = nextOrder;

        nextOrder == NULL ? point.tail = prevOrder : point.orders[nextOrder].prev = prevOrder;

        // Clear the order
        delete point.orders[orderId];

        return nextOrder == prevOrder;
    }

    /**
     * @notice Pops the head order from the list for a given price point.
     * @param point The price point.
     * @return _isEmpty A bool representing weather the price point is empty.
     */
    function popHead(PricePoint storage point) internal returns (bool _isEmpty) {
        uint256 headOrderId = point.head;
        require(headOrderId != NULL, "List is empty");

        OrderVertex memory order = point.orders[headOrderId];

        if (point.tail == headOrderId) {
            // The list has only one element
            point.head = NULL;
            point.tail = NULL;
            _isEmpty = true;
        } else {
            // The list has more than one element
            point.head = order.next;
            point.orders[order.next].prev = NULL;
        }

        // Clear the order
        delete point.orders[headOrderId];
    }
}
