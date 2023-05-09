// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

enum Side {
    LONG,
    SHORT
}

struct BnbPosition {
    uint256 size;
    uint256 collateralValue;
    uint256 reserveAmount;
    uint256 entryPrice;
    uint256 borrowIndex;
}

struct BnbPoolTokenInfo {
    uint256 feeReserve;
    uint256 poolBalance;
    uint256 lastAccrualTimestamp;
    uint256 borrowIndex;
    uint256 ___averageShortPrice;
}

struct Fee {
    uint256 positionFee;
    uint256 liquidationFee;
    uint256 baseSwapFee;
    uint256 taxBasisPoint;
    uint256 stableCoinBaseSwapFee;
    uint256 stableCoinTaxBasisPoint;
    uint256 daoFee;
}

struct BnbPositionData {
    address indexToken;
    address collateralToken;
    Side side;
}

interface IPool {
    function positions(bytes32) external view returns (uint256 size, uint256 collateralValue,uint256 reserveAmount, uint256 entryPrice, uint256 borrowIndex);
    function poolTokens(address) external view returns (BnbPoolTokenInfo memory);
    function fee() external view returns (Fee memory);
}
