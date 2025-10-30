// SPDX-License-Identifier: GPL-2.0-or-later

import {IOrderBook} from "./IOrderBook.sol";

pragma solidity ^0.8.20;

interface IRouter {
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

    // Event for market registration
    event MarketRegistered(
        address baseAsset,
        address quoteAsset,
        address market,
        address vaultAddress,
        uint32 pricePrecision,
        uint96 sizePrecision,
        uint32 tickSize,
        uint96 minSize,
        uint96 maxSize,
        uint256 takerFeeBps,
        uint256 makerFeeBps,
        uint96 kuruAmmSpread
    );

    event OBImplementationUpdated(address previousImplementation, address newImplementation);

    event VaultImplementationUpdated(address previousImplementation, address newImplementation);

    event KuruRouterSwap(
        address msgSender, address debitToken, address creditToken, uint256 amountIn, uint256 amountOut
    );

    function deployProxy(
        IOrderBook.OrderBookType _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) external returns (address);

    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        bool[] calldata _nativeSend,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external payable returns (uint256);
}
