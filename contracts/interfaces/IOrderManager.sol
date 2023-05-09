// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./IPool.sol";

enum UpdatePositionType {
    INCREASE,
    DECREASE
}

enum OrderType {
    MARKET,
    LIMIT
}

interface IOrderManager {
    function placeOrder(
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes calldata data
    ) external payable;

    function orders(uint256 _orderId) external view returns ( address pool, address owner,address indexToken ,address collateralToken ,address payToken ,uint256 expiresAt ,uint256 submissionBlock ,uint256 price ,uint256 executionFee ,bool triggerAboveThreshold );

    function requests(uint256 _orderid) external view returns (uint8 side, uint256 sizeChange, uint256 collateral, uint8 updateType );

    function nextOrderId() external view returns (uint256);

    function executeOrder(uint256 _orderId, address payable _feeTo) external;

    function minPerpetualExecutionFee() external view returns (uint256);

    function minSwapExecutionFee() external view returns (uint256);
}
