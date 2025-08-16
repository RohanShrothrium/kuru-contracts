// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {OrderBookErrors} from "./libraries/Errors.sol";

// ============ Internal Interfaces Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

// ============ External Imports ============
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

abstract contract AbstractAMM is IOrderBook, ReentrancyGuardTransient {
    uint256 constant vaultPricePrecision = 10 ** 18;
    uint256 constant DOUBLE_BPS_MULTIPLIER = 20000;
    uint256 constant BPS_MULTIPLIER = 10000;
    uint256 internal vaultBestBid;
    address public kuruAmmVault;
    uint96 internal bidPartiallyFilledSize;
    uint256 public vaultBestAsk;
    uint96 internal askPartiallyFilledSize;
    uint96 public vaultAskOrderSize;
    uint96 internal vaultBidOrderSize;
    uint96 public SPREAD_CONSTANT;
    uint256[43] private __gap;

    modifier onlyVault() {
        if (msg.sender != kuruAmmVault) {
            revert OrderBookErrors.OnlyVaultAllowed();
        }
        _;
    }

    modifier marketNotHardPaused() virtual {
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

    /**
     * @dev Iteratively match discretized AMM orders until a given price point is reached for a particular quote size for market buys
     * @param _breakPoint Price point till which the AMM should fill
     * @param _quoteSize Quote size left to be filled
     * @return quoteLeft Remaining quote size that is not filled
     * @return sizeFilled Base asset size that was filled
     * @return makerCredits Encoded credits for the vault
     */
    function _fillVaultBuyMatch(uint256 _breakPoint, uint96 _quoteSize)
        internal
        returns (uint96 quoteLeft, uint96 sizeFilled, bytes memory makerCredits)
    {
        uint256 _price = vaultBestAsk;
        uint256 _quoteInput = _quoteSize * vaultPricePrecision / _getPricePrecision();
        uint96 _cachedLastVaultSize = vaultAskOrderSize;
        uint96 _cachedPartiallyFilledBid = bidPartiallyFilledSize;
        uint96 _availableSize = _cachedLastVaultSize - askPartiallyFilledSize;
        //handle equal to condition
        if (_quoteInput >= FixedPointMathLib.mulDivUp(_price, _availableSize, _getSizePrecision())) {
            askPartiallyFilledSize = 0;
        }

        while (_price < _breakPoint && _quoteInput > 0) {
            uint256 _quoteNeededForFill = FixedPointMathLib.mulDivUp(_price, _availableSize, _getSizePrecision());
            if (_quoteNeededForFill > _quoteInput) {
                uint96 _sizeFilledAtPrice = toU96(_quoteInput * _getSizePrecision() / _price);
                sizeFilled += _sizeFilledAtPrice;
                askPartiallyFilledSize += _sizeFilledAtPrice;
                _emitTrade(0, kuruAmmVault, true, _price, _availableSize - _sizeFilledAtPrice, _sizeFilledAtPrice);
                _quoteInput = 0;
                break;
            } else {
                sizeFilled += _availableSize;
                _quoteInput -= _quoteNeededForFill;
                _cachedLastVaultSize = toU96(
                    FixedPointMathLib.mulDiv(
                        _cachedLastVaultSize, DOUBLE_BPS_MULTIPLIER, DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT
                    )
                );
                _emitTrade(0, kuruAmmVault, true, _price, 0, _availableSize);
                _availableSize = _cachedLastVaultSize;
                _price = FixedPointMathLib.mulDivRound(_price, BPS_MULTIPLIER + SPREAD_CONSTANT, BPS_MULTIPLIER);
                _cachedPartiallyFilledBid = toU96(
                    FixedPointMathLib.mulDiv(
                        _cachedPartiallyFilledBid, BPS_MULTIPLIER, BPS_MULTIPLIER + SPREAD_CONSTANT
                    )
                );
            }
        }
        if (_price != vaultBestAsk) {
            vaultBestAsk = _price;
            vaultBestBid = FixedPointMathLib.mulDivRound(_price, BPS_MULTIPLIER, BPS_MULTIPLIER + SPREAD_CONSTANT);
            vaultAskOrderSize = _cachedLastVaultSize;
            vaultBidOrderSize = toU96(
                FixedPointMathLib.mulDiv(
                    _cachedLastVaultSize, DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT, DOUBLE_BPS_MULTIPLIER
                )
            );
        }
        bidPartiallyFilledSize = _cachedPartiallyFilledBid;
        quoteLeft = toU96(FixedPointMathLib.mulDiv(_quoteInput, _getPricePrecision(), vaultPricePrecision));
        makerCredits =
            _creditVaultOnMarketBuy(sizeFilled, (_quoteSize * vaultPricePrecision / _getPricePrecision() - _quoteInput));
    }

    /**
     * @dev Iteratively match discretized AMM orders until a given price point is reached for a particular quote size for limit order buys
     * @param _breakPoint Price point till which the AMM should fill
     * @param _size Base size left to be filled
     * @return sizeLeft Remaining base size that is not filled
     * @return fundsConsumed Quote size consumed in market price precision
     * @return makerCredits Encoded credits for the vault
     */
    function _fillVaultForBuy(uint256 _breakPoint, uint96 _size)
        internal
        returns (uint96 sizeLeft, uint96 fundsConsumed, bytes memory makerCredits)
    {
        uint256 _price = vaultBestAsk;
        sizeLeft = _size;

        uint96 _cachedLastVaultSize = vaultAskOrderSize;
        uint96 _cachedPartiallyFilledBid = bidPartiallyFilledSize;
        // should we muldivup here?
        uint256 _consumedQuote;
        uint96 _availableSize = _cachedLastVaultSize - askPartiallyFilledSize;
        if (_availableSize <= sizeLeft) {
            askPartiallyFilledSize = 0;
        }
        while (_price < _breakPoint && sizeLeft > 0) {
            if (_availableSize > sizeLeft) {
                askPartiallyFilledSize += sizeLeft;
                _consumedQuote += FixedPointMathLib.mulDivUp(sizeLeft, _price, _getSizePrecision());
                _emitTrade(0, kuruAmmVault, true, _price, _availableSize - sizeLeft, sizeLeft);
                sizeLeft = 0;
                break;
            } else {
                sizeLeft -= _availableSize;
                _consumedQuote += FixedPointMathLib.mulDivUp(_availableSize, _price, _getSizePrecision());
                _cachedLastVaultSize = toU96(
                    FixedPointMathLib.mulDiv(
                        _cachedLastVaultSize, DOUBLE_BPS_MULTIPLIER, DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT
                    )
                );
                _emitTrade(0, kuruAmmVault, true, _price, 0, _availableSize);
                _availableSize = _cachedLastVaultSize;
                _price = FixedPointMathLib.mulDivRound(_price, BPS_MULTIPLIER + SPREAD_CONSTANT, BPS_MULTIPLIER);
                _cachedPartiallyFilledBid = toU96(
                    FixedPointMathLib.mulDiv(
                        _cachedPartiallyFilledBid, BPS_MULTIPLIER, BPS_MULTIPLIER + SPREAD_CONSTANT
                    )
                );
            }
        }
        if (_price != vaultBestAsk) {
            vaultBestAsk = _price;
            vaultBestBid = FixedPointMathLib.mulDivRound(_price, BPS_MULTIPLIER, BPS_MULTIPLIER + SPREAD_CONSTANT);
            vaultAskOrderSize = _cachedLastVaultSize;
            vaultBidOrderSize = toU96(
                FixedPointMathLib.mulDiv(
                    _cachedLastVaultSize, DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT, DOUBLE_BPS_MULTIPLIER
                )
            );
        }
        bidPartiallyFilledSize = _cachedPartiallyFilledBid;
        fundsConsumed = toU96(FixedPointMathLib.mulDivUp(_consumedQuote, _getPricePrecision(), vaultPricePrecision));
        makerCredits = _creditVaultOnMarketBuy(_size - sizeLeft, _consumedQuote);
    }

    /**
     * @dev Iteratively match discretized AMM orders until a given price point is reached for a particular base size for limit/market sells
     * @param _breakPoint Price point till which the AMM should fill
     * @param _size Base size left to be filled
     * @return sizeLeft Remaining base size that is not filled
     * @return quoteOwedToUser Quote size owed to the user in vault price precision
     * @return makerCredits Encoded credits for the vault
     */
    function _fillVaultForSell(uint256 _breakPoint, uint96 _size)
        internal
        returns (uint96 sizeLeft, uint256 quoteOwedToUser, bytes memory makerCredits)
    {
        uint256 _price = vaultBestBid;
        uint96 _availableSize = vaultBidOrderSize - bidPartiallyFilledSize;
        uint96 _cachedLastVaultSize = vaultBidOrderSize;
        sizeLeft = _size;
        if (sizeLeft >= _availableSize) {
            bidPartiallyFilledSize = 0;
        }

        while (_price > _breakPoint && sizeLeft > 0) {
            if (_availableSize > sizeLeft) {
                bidPartiallyFilledSize += sizeLeft;
                quoteOwedToUser += FixedPointMathLib.mulDiv(_price, sizeLeft, _getSizePrecision());
                _emitTrade(0, kuruAmmVault, false, _price, _availableSize - sizeLeft, sizeLeft);
                sizeLeft = 0;
                break;
            } else {
                sizeLeft -= _availableSize;
                quoteOwedToUser += FixedPointMathLib.mulDiv(_price, _availableSize, _getSizePrecision());
                _cachedLastVaultSize = toU96(
                    FixedPointMathLib.mulDiv(
                        _cachedLastVaultSize, DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT, DOUBLE_BPS_MULTIPLIER
                    )
                );
                _emitTrade(0, kuruAmmVault, false, _price, 0, _availableSize);
                _availableSize = _cachedLastVaultSize;
                _price = FixedPointMathLib.mulDivRound(_price, BPS_MULTIPLIER, BPS_MULTIPLIER + SPREAD_CONSTANT);
            }
        }
        if (_price != vaultBestBid) {
            vaultBestBid = _price;
            vaultBestAsk = FixedPointMathLib.mulDivRound(_price, BPS_MULTIPLIER + SPREAD_CONSTANT, BPS_MULTIPLIER);
            vaultBidOrderSize = _cachedLastVaultSize;
            vaultAskOrderSize = toU96(
                FixedPointMathLib.mulDiv(
                    _cachedLastVaultSize, DOUBLE_BPS_MULTIPLIER, DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT
                )
            );
        }
        makerCredits = _creditVaultOnMarketSell(_size - sizeLeft, quoteOwedToUser);
    }

    /**
     * @dev Credit the vault on market buys
     * @param _sizeFilled Base size filled
     * @param _fundsOwed Quote size owed to the user in vault price precision
     * @return returnData Encoded credits for the vault
     */
    function _creditVaultOnMarketBuy(uint96 _sizeFilled, uint256 _fundsOwed)
        internal
        view
        returns (bytes memory returnData)
    {
        returnData = abi.encode(
            kuruAmmVault, _getQuoteAsset(), _fundsOwed * 10 ** _getQuoteAssetDecimals() / vaultPricePrecision, true
        );
        uint256 feeRebate =
            ((_sizeFilled * 10 ** _getBaseAssetDecimals() / _getSizePrecision()) * _getMakerFeeBps()) / BPS_MULTIPLIER;
        if (feeRebate > 0) {
            returnData = bytes.concat(returnData, abi.encode(kuruAmmVault, _getBaseAsset(), feeRebate, true));
        }
    }

    /**
     * @dev Credit the vault on limit/market sells
     * @param _sizeOwedToVault Base size owed to the vault
     * @param _fundsOwedToUser Quote size owed to the user in vault price precision
     * @return returnData Encoded credits for the vault
     */
    function _creditVaultOnMarketSell(uint96 _sizeOwedToVault, uint256 _fundsOwedToUser)
        internal
        view
        returns (bytes memory returnData)
    {
        returnData = abi.encode(
            kuruAmmVault, _getBaseAsset(), _sizeOwedToVault * 10 ** _getBaseAssetDecimals() / _getSizePrecision(), true
        );
        uint256 feeRebate = (
            (_fundsOwedToUser * 10 ** _getQuoteAssetDecimals() / vaultPricePrecision) * _getMakerFeeBps()
        ) / BPS_MULTIPLIER;
        if (feeRebate > 0) {
            returnData = bytes.concat(returnData, abi.encode(kuruAmmVault, _getQuoteAsset(), feeRebate, true));
        }
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
            SPREAD_CONSTANT
        );
    }
    /**
     * @notice Updates the vault order sizes and prices when a user deposits or withdraws
     * @param _vaultAskOrderSize The new ask order size
     * @param _vaultBidOrderSize The new bid order size
     * @param _askPrice The new ask price. Note: Only updated on the first deposit
     * @param _bidPrice The new bid price. Note: Only updated on the first deposit
     * @param _nullifyPartialFills Whether to nullify partial fills. Only done during specific withdrawals
     */

    function updateVaultOrdSz(
        uint96 _vaultAskOrderSize,
        uint96 _vaultBidOrderSize,
        uint256 _askPrice,
        uint256 _bidPrice,
        bool _nullifyPartialFills
    ) external onlyVault nonReentrant marketNotHardPaused {
        vaultBidOrderSize = _vaultBidOrderSize;
        vaultAskOrderSize = _vaultAskOrderSize;

        if (_nullifyPartialFills) {
            askPartiallyFilledSize = 0;
            bidPartiallyFilledSize = 0;
        }

        if (vaultBestAsk == type(uint256).max) {
            vaultBestAsk = _askPrice;
        }
        if (vaultBestBid == 0) {
            vaultBestBid = _bidPrice;
        }
        emit VaultParamsUpdated(
            _vaultAskOrderSize,
            askPartiallyFilledSize,
            _vaultBidOrderSize,
            bidPartiallyFilledSize,
            vaultBestAsk,
            vaultBestBid
        );
    }

    function toU32(uint256 _from) internal pure returns (uint32 _to) {
        require((_to = uint32(_from)) == _from, OrderBookErrors.Uint32Overflow());
    }

    function toU96(uint256 _from) internal pure returns (uint96 _to) {
        require((_to = uint96(_from)) == _from, OrderBookErrors.Uint96Overflow());
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
