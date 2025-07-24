//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IKuruRouter {
    struct MarketParams {
        uint32 pricePrecision;
        uint96 sizePrecision;
        address baseAssetAddress;
        uint256 baseAssetDecimals;
        address quoteAssetAddress;
        uint256 quoteAssetDecimals;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    function verifiedMarket(address market) external view returns (MarketParams memory);
}