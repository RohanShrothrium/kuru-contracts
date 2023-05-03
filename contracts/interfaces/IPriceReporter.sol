// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface IPriceReporter {
    function postPriceAndExecuteOrders(address[] calldata tokens, uint256[] calldata prices, uint256[] calldata orders) external;
}
