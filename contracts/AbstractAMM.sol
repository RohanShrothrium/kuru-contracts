// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {OrderBookErrors} from "./libraries/Errors.sol";

// ============ Internal Interfaces Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";

// ============ Internal Contracts Imports ============
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

abstract contract AbstractAMM is IOrderBook {
    uint256 constant vaultPricePrecision = 10 ** 18;
    address kuruAmmVault;
    uint256 vaultBestBid;
    uint96 bidPartiallyFilledSize;
    uint256 public vaultBestAsk;
    uint96 askPartiallyFilledSize;
    uint96 vaultBidOrderSize;
    uint96 public vaultAskOrderSize;
    uint256 constant BPS_MULTIPLIER = 10000;
    uint96 SPREAD_CONSTANT;

    modifier onlyVault() {
        if (msg.sender != kuruAmmVault) {
            revert OrderBookErrors.OnlyVaultAllowed();
        }
        _;
    }

    function _emitTrade(
        uint40 orderId,
        address makerAddress,
        bool isBuy,
        uint256 price,
        uint96 updatedSize,
        uint96 filledSize
    ) internal virtual;

    function _fillVaultForBuy(uint96 _size) internal returns (uint96 remainingSize, bytes memory makerCredits) {
        uint256 _price = vaultBestAsk;
        uint96 availableSize = vaultAskOrderSize - askPartiallyFilledSize;
        uint96 _fillSize = _size < availableSize ? _size : availableSize;

        // Update askPartiallyFilledSize
        if (_size < availableSize) {
            askPartiallyFilledSize += _size;
        } else {
            askPartiallyFilledSize = 0;
            vaultBidOrderSize = vaultAskOrderSize;
            vaultAskOrderSize = uint96(FixedPointMathLib.mulDivUp(vaultAskOrderSize, 2000, 2000 + SPREAD_CONSTANT));
            vaultBestAsk = FixedPointMathLib.mulDivRound(_price, 1000 + SPREAD_CONSTANT, 1000);
            bidPartiallyFilledSize =
                uint96(FixedPointMathLib.mulDiv(bidPartiallyFilledSize, 1000, 1000 + SPREAD_CONSTANT));
            vaultBestBid = _price;
        }
        remainingSize = _size - _fillSize;
        makerCredits = _creditVaultAsMaker(true, _fillSize, _price);
        _emitTrade(0, kuruAmmVault, true, _price, availableSize - _fillSize, _fillSize);
    }

    function _fillVaultForSell(uint96 _size) internal returns (uint96 remainingSize, bytes memory makerCredits) {
        uint256 _price = vaultBestBid;
        uint96 availableSize = vaultBidOrderSize - bidPartiallyFilledSize;
        uint96 _fillSize = _size < availableSize ? _size : availableSize;

        // Update bidPartiallyFilledSize
        if (_size < availableSize) {
            bidPartiallyFilledSize += _size;
        } else {
            bidPartiallyFilledSize = 0;
            vaultAskOrderSize = vaultBidOrderSize;
            vaultBidOrderSize = uint96(FixedPointMathLib.mulDiv(vaultAskOrderSize, 2000 + SPREAD_CONSTANT, 2000)); //@note: changed to muldivdown from up
            vaultBestBid = FixedPointMathLib.mulDivRound(_price, 1000, 1000 + SPREAD_CONSTANT);
            vaultBestAsk = _price;
        }

        remainingSize = _size - _fillSize;
        makerCredits = _creditVaultAsMaker(false, _fillSize, _price);
        _emitTrade(0, kuruAmmVault, false, _price, availableSize - _fillSize, _fillSize);
    }

    function _creditVaultAsMaker(bool _isMarketBuy, uint96 _size, uint256 _price)
        internal
        view
        returns (bytes memory)
    {
        address _creditAsset = _isMarketBuy ? _getQuoteAsset() : _getBaseAsset();
        uint256 _amount = _isMarketBuy
            ? (((_price * _size) / _getSizePrecision()) * 10 ** _getQuoteAssetDecimals()) / vaultPricePrecision
            : (_size * 10 ** _getBaseAssetDecimals()) / _getSizePrecision();
        uint256 feeRebate;
        address feeAsset;
        bytes memory returnData;
        if (_isMarketBuy) {
            feeAsset = _getBaseAsset();
            feeRebate =
                (((_size * 10 ** _getBaseAssetDecimals()) / _getSizePrecision()) * _getMakerFeeBps()) / BPS_MULTIPLIER;
        } else {
            feeAsset = _getQuoteAsset();
            feeRebate = (
                ((((_price * _size) / _getSizePrecision()) * 10 ** _getQuoteAssetDecimals()) / vaultPricePrecision)
                    * _getMakerFeeBps()
            ) / BPS_MULTIPLIER;
        }
        //feeRebate only exists if makerFeeBps > 0
        if (feeRebate > 0) {
            returnData = abi.encode(kuruAmmVault, feeAsset, feeRebate, true);
        }
        return bytes.concat(returnData, abi.encode(kuruAmmVault, _creditAsset, _amount, true));
    }

    function getVaultParams()
        external
        view
        returns (address, uint256, uint96, uint256, uint96, uint96, uint96, uint96)
    {
        return (
            kuruAmmVault,
            vaultBestBid,
            bidPartiallyFilledSize,
            vaultBestAsk,
            askPartiallyFilledSize,
            vaultBidOrderSize,
            vaultAskOrderSize,
            SPREAD_CONSTANT * 10
        );
    }

    function updateVaultOrdSz(
        uint96 _vaultAskOrderSize,
        uint96 _vaultBidOrderSize,
        uint256 _askPrice,
        uint256 _bidPrice
    ) external onlyVault {
        vaultBidOrderSize = _vaultBidOrderSize;
        vaultAskOrderSize = _vaultAskOrderSize;
        if (vaultBestAsk == type(uint256).max) {
            vaultBestAsk = _askPrice;
        }
        if (vaultBestBid == 0) {
            vaultBestBid = _bidPrice;
        }
    }

    function _getPricePrecision() internal view virtual returns (uint32);

    function _getSizePrecision() internal view virtual returns (uint96);

    function _getTakerFeeBps() internal view virtual returns (uint256);

    function _getMakerFeeBps() internal view virtual returns (uint256);

    function _getBaseAssetDecimals() internal view virtual returns (uint256);

    function _getQuoteAssetDecimals() internal view virtual returns (uint256);

    function _getBaseAsset() internal view virtual returns (address);

    function _getQuoteAsset() internal view virtual returns (address);
}
