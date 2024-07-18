// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHLP2 {
    function rebalance(uint24 _extremePrice, uint256 _pricesMoved, bool _isBuy) external;
}
