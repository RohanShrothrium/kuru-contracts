// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {Errors} from "./libraries/Errors.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {AbstractAMM} from "./AbstractAMM.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

// ============ Internal Contracts Imports ============
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

// ============ External Imports ============
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

contract OrderBook is Ownable, Initializable, AbstractAMM, UUPSUpgradeable {
    OrderBookType orderBookType;

    using SafeTransferLib for address;

    mapping(uint40 => Order) public s_orders;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_buyPricePoints;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_sellPricePoints;
    TreeMath.TreeUint24 public s_buyTree;
    TreeMath.TreeUint24 public s_sellTree;

    uint40 public s_orderIdCounter;
    bool marketPaused;

    uint96 internal sizePrecision;
    uint24 internal pricePrecision;
    uint256 internal takerFeeBps;
    uint256 internal makerFeeBps;

    uint256 internal baseAssetDecimals;
    uint256 internal quoteAssetDecimals;
    address internal baseAsset;
    address internal quoteAsset;

    uint24 tickSize;
    uint96 minSize;
    uint96 maxSize;

    uint256 quoteFeeCollected;
    uint256 baseFeeCollected;

    IMarginAccount marginAccount;

    /**
     * @dev Constructor.
     */
    constructor() {
        _disableInitializers();
    }

    modifier marketActive() {
        require(!marketPaused, Errors.MarketStateError());
        _;
    }

    /**
     * @param _owner The owner of the contract.
     * @param _baseAssetAddress Address of the first token used for trading.
     * @param _baseAssetDecimals Deciimal pricicsion of the first swap token.
     * @param _quoteAssetAddress Address of the second token used for trading.
     * @param _quoteAssetDecimals Deciimal pricicsion of the first swap token.
     */
    function initialize(
        address _owner,
        OrderBookType _type,
        address _baseAssetAddress,
        uint256 _baseAssetDecimals,
        address _quoteAssetAddress,
        uint256 _quoteAssetDecimals,
        address _marginAccountAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint24 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        address _kuruAmmVault,
        uint96 _kuruAmmSpread
    ) public initializer {
        _initializeOwner(_owner);

        require(
            _makerFeeBps <= 8000 * _takerFeeBps / BPS_MULTIPLIER && _takerFeeBps < BPS_MULTIPLIER,
            Errors.MarketFeeError()
        );
        require(_kuruAmmSpread % 10 == 0 && _kuruAmmSpread > 0 && _kuruAmmSpread < 500, Errors.InvalidSpread());

        orderBookType = _type;
        baseAsset = _baseAssetAddress;
        quoteAsset = _quoteAssetAddress;

        baseAssetDecimals = _baseAssetDecimals;
        quoteAssetDecimals = _quoteAssetDecimals;

        marginAccount = IMarginAccount(payable(_marginAccountAddress));
        // initialize contract parameters
        sizePrecision = _sizePrecision;
        pricePrecision = _pricePrecision;
        tickSize = _tickSize;
        minSize = _minSize;
        maxSize = _maxSize;
        takerFeeBps = _takerFeeBps;
        makerFeeBps = _makerFeeBps;
        kuruAmmVault = _kuruAmmVault;
        SPREAD_CONSTANT = _kuruAmmSpread / 10;
        vaultBestAsk = type(uint256).max;
    }

    /**
     * @dev Overrides the function in Ownable so that owner is initialized only once
     */
    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    /**
     * @dev Makes sure owner is the one upgrading contract
     */
    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    /**
     * @dev Allows admin to pause the market.
     */
    function toggleMarkets(bool _state) external {
        _checkOwner();
        require(_state != marketPaused, Errors.MarketStateError());
        marketPaused = _state;
    }

    /**
     * @dev Adds a buy order to the order book.
     * @param _price Price of the buy order.
     * @param size Size of the buy order.
     */
    function addBuyOrder(uint24 _price, uint96 size, bool _postOnly) public marketActive {
        require(_price > 0, Errors.PriceError());
        require(size > minSize, Errors.SizeError());
        require(size < maxSize, Errors.SizeError());
        require(_price % tickSize == 0, Errors.TickSizeError());

        //The buy order is filled aggressively and the leftover size is added as a limit buy order
        (uint96 _remainingSize, uint24 _consumedFunds) = _matchAggressiveBuyWithCap(_price, size);

        _consumedFunds += _calculateFundsConsumed(_price, _remainingSize);

        _consumeFunds(quoteAsset, (((_consumedFunds) * 10 ** quoteAssetDecimals) / pricePrecision), msg.sender);
        if (_postOnly) {
            require(size == _remainingSize, Errors.PostOnlyError());
        }
        if (_remainingSize > 0) {
            uint40 _orderId = s_orderIdCounter + 1;
            s_orderIdCounter = _orderId;

            // Add price to the tree and update DLL of price poit.
            TreeMath.add(s_buyTree, _price);
            uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_buyPricePoints[_price], _orderId);

            _addOrder(_price, _remainingSize, _orderId, true, _prevOrderId);

            emit OrderCreated(_orderId, msg.sender, _remainingSize, _price, true);
        }
    }

    /**
     * @dev Adds a sell order to the order book.
     * @param _price Price of the sell order.
     * @param size Size of the sell order.
     */
    function addSellOrder(uint24 _price, uint96 size, bool _postOnly) public marketActive {
        require(size > minSize, Errors.SizeError());
        require(size < maxSize, Errors.SizeError());
        require(_price % tickSize == 0, Errors.TickSizeError());
        require(_price > 0, Errors.PriceError());

        _consumeFunds(baseAsset, ((size * 10 ** baseAssetDecimals) / sizePrecision), msg.sender);

        uint256 _tokenCredit;
        //The sell order is matched and filled aggressively and remaining size is added as limit sell order
        (size, _tokenCredit) = _matchAggressiveSell(_price, size, true);
        if (_postOnly) {
            require(_tokenCredit == 0, Errors.PostOnlyError());
        }

        if (size == 0) return;

        uint40 _orderId = s_orderIdCounter + 1;
        s_orderIdCounter = _orderId;
        // Add price to the tree and update DLL of price poit.
        TreeMath.add(s_sellTree, _price);
        uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_sellPricePoints[_price], _orderId);
        _addOrder(_price, size, _orderId, false, _prevOrderId);

        emit OrderCreated(_orderId, msg.sender, size, _price, false);
    }

    /**
     * @dev Internal function to add an order to the order book.
     * @param _price Price of the order.
     * @param _size Size of the order.
     */
    function _addOrder(uint24 _price, uint96 _size, uint40 _orderId, bool _isBuy, uint40 _prevOrderId) internal {
        s_orders[_orderId] = Order(msg.sender, _size, _prevOrderId, OrderLinkedList.NULL, _price, _isBuy);
        s_orders[_prevOrderId].next = _orderId;
    }

    /**
     * @dev Consumes funds required to create a GTC order.
     * @param _consumableAsset Address of the asset that is being consumed by the market.
     * @param _amount Amount of _consumableAssets that should be consumed by the market.
     * @param _makerAddress Address of the the user creating the order.
     */
    function _consumeFunds(address _consumableAsset, uint256 _amount, address _makerAddress) internal {
        marginAccount.debitUser(_makerAddress, _consumableAsset, _amount);
    }

    /**
     * @dev Cancels multiple orders in a batch.
     * @param _orderIds Array of order IDs to cancel.
     */
    function batchCancelOrders(uint40[] calldata _orderIds) external {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _cancelOrder(_orderIds[i]);
        }

        emit OrdersCanceled(_orderIds, msg.sender);
    }

    /**
     * @dev Internal helper function to cancel a single order.
     * @param _orderId ID of the order to cancel.
     */
    function _cancelOrder(uint40 _orderId) internal returns (bool) {
        Order memory _order = s_orders[_orderId];
        _checkIfCancelledOrFilled(_orderId, _order);
        require(msg.sender == _order.ownerAddress, Errors.OnlyOwnerAllowedError());
        // update neighbouring orders
        if (_order.prev != OrderLinkedList.NULL) {
            s_orders[_order.prev].next = _order.next;
        }
        if (_order.next != OrderLinkedList.NULL) {
            s_orders[_order.next].prev = _order.prev;
        }

        if (_order.isBuy) {
            //If cancelled order is the head of corresponding price point, we need to update to new head
            if (_orderId == s_buyPricePoints[_order.price].head) {
                OrderLinkedList.updateHead(s_buyPricePoints[_order.price], _order.next);
                if (_order.next == OrderLinkedList.NULL) {
                    //If there are no more orders remaining in price point, we can remove the price point
                    TreeMath.remove(s_buyTree, _order.price);
                }
            }
            OrderLinkedList.deleteOrder(s_buyPricePoints[_order.price], _order.prev, _order.next);
            marginAccount.creditUser(
                _order.ownerAddress,
                quoteAsset,
                (((uint24((_order.size * _order.price) / sizePrecision) * 10 ** quoteAssetDecimals) / pricePrecision)),
                true
            );
        } else {
            if (_orderId == s_sellPricePoints[_order.price].head) {
                OrderLinkedList.updateHead(s_sellPricePoints[_order.price], _order.next);
                if (_order.next == OrderLinkedList.NULL) {
                    //If there are no more orders remaining in price point, we can remove the price point
                    TreeMath.remove(s_sellTree, _order.price);
                }
            }
            OrderLinkedList.deleteOrder(s_sellPricePoints[_order.price], _order.prev, _order.next);
            marginAccount.creditUser(
                _order.ownerAddress, baseAsset, ((_order.size * 10 ** baseAssetDecimals) / sizePrecision), true
            );
        }

        return _order.isBuy;
    }

    /**
     * @notice Checks if an order has been cancelled or filled, and reverts if true.
     * @dev Items to check:
     *      1. The next order of the previous order in the list must be the current order.
     *      2. If the previous order is NULL, check the head requirement.
     *      3. The price point's head must be before or the same as the order ID (time priority constraint).
     * @param _orderId ID of the order.
     * @param _order Order details in memory.
     */
    function _checkIfCancelledOrFilled(uint40 _orderId, Order memory _order) internal view {
        if (_order.prev != OrderLinkedList.NULL) {
            require(s_orders[_order.prev].next == _orderId, Errors.OrderAlreadyFilledOrCancelled());
            if (_order.isBuy) {
                //Since all orders are filled FCFS in each price point, if head > order id, it means order id was already filled
                uint40 _head = s_buyPricePoints[_order.price].head;
                require(_head <= _orderId && _head != OrderLinkedList.NULL, Errors.OrderAlreadyFilledOrCancelled());
            } else {
                uint40 _head = s_sellPricePoints[_order.price].head;
                require(_head <= _orderId && _head != OrderLinkedList.NULL, Errors.OrderAlreadyFilledOrCancelled());
            }
        } else {
            if (_order.isBuy) {
                require(s_buyPricePoints[_order.price].head == _orderId, Errors.OrderAlreadyFilledOrCancelled());
            } else {
                require(s_sellPricePoints[_order.price].head == _orderId, Errors.OrderAlreadyFilledOrCancelled());
            }
        }
    }

    /**
     * @dev Batch updates orders by placing multiple buy and sell orders and canceling orders.
     * @param buyPrices Array of prices for the buy orders.
     * @param buySizes Array of sizes for the buy orders.
     * @param sellPrices Array of prices for the sell orders.
     * @param sellSizes Array of sizes for the sell orders.
     * @param orderIdsToCancel Array of order IDs to cancel.
     * @param postOnly Boolean indicating if the orders should be post-only.
     */
    function batchUpdate(
        uint24[] calldata buyPrices,
        uint96[] calldata buySizes,
        uint24[] calldata sellPrices,
        uint96[] calldata sellSizes,
        uint40[] calldata orderIdsToCancel,
        bool postOnly
    ) external marketActive {
        // Ensure that the lengths of the buy prices and sizes match
        require(buyPrices.length == buySizes.length, Errors.LengthMismatch());

        // Ensure that the lengths of the sell prices and sizes match
        require(sellPrices.length == sellSizes.length, Errors.LengthMismatch());

        // Place multiple buy orders
        for (uint256 i = 0; i < buyPrices.length; i++) {
            if (buyPrices[i] == 0) break;
            addBuyOrder(buyPrices[i], buySizes[i], postOnly);
        }

        // Place multiple sell orders
        for (uint256 i = 0; i < sellPrices.length; i++) {
            if (sellPrices[i] == 0) break;
            addSellOrder(sellPrices[i], sellSizes[i], postOnly);
        }

        // Cancel multiple orders
        for (uint256 i = 0; i < orderIdsToCancel.length; i++) {
            _cancelOrder(orderIdsToCancel[i]);
        }

        // Emit an event for the canceled orders
        emit OrdersCanceled(orderIdsToCancel, msg.sender);
    }

    /**
     * @dev Places multiple limit buy orders in a single function call.
     * @param _prices Array of prices for the buy orders.
     * @param _sizes Array of sizes for the buy orders.
     */
    function placeMultipleBuyOrders(uint24[] calldata _prices, uint96[] calldata _sizes, bool _postOnly)
        external
        marketActive
    {
        require(_prices.length == _sizes.length, Errors.LengthMismatch());

        for (uint256 i = 0; i < _prices.length; i++) {
            addBuyOrder(_prices[i], _sizes[i], _postOnly);
        }
    }

    /**
     * @dev Places multiple limit sell orders in a single function call.
     * @param _prices Array of prices for the sell orders.
     * @param _sizes Array of sizes for the sell orders.
     */
    function placeMultipleSellOrders(uint24[] calldata _prices, uint96[] calldata _sizes, bool _postOnly)
        external
        marketActive
    {
        require(_prices.length == _sizes.length, Errors.LengthMismatch());

        for (uint256 i = 0; i < _prices.length; i++) {
            addSellOrder(_prices[i], _sizes[i], _postOnly);
        }
    }

    /**
     * @dev Places and executes a market buy order.
     * @param _quoteSize amount of quote asset user is ready to pay.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketBuy(uint24 _quoteSize, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        public
        payable
        override
        marketActive
        returns (uint256)
    {
        OrderBookType _type = orderBookType;

        if (_type == OrderBookType.NATIVE_IN_QUOTE && !_isMargin) {
            require(
                msg.value >= _pricePrecisionToQuoteAssetPrecision(_quoteSize)
                    && msg.value < _pricePrecisionToQuoteAssetPrecision(_quoteSize + 1),
                Errors.NativeAssetInsufficient()
            );
        } else {
            require(msg.value == 0, Errors.NativeAssetNotRequired());
            _isMargin
                ? marginAccount.debitUser(msg.sender, quoteAsset, _pricePrecisionToQuoteAssetPrecision(_quoteSize))
                : quoteAsset.safeTransferFrom(
                    msg.sender, address(marginAccount), _pricePrecisionToQuoteAssetPrecision(_quoteSize)
                );
        }

        uint256 _baseTokensCredited;
        (_quoteSize, _baseTokensCredited) = _marketBuyMatch(_quoteSize, _isMargin);
        if (_quoteSize > 0) {
            require(!_isFillOrKill, Errors.InsufficientLiquidity());
            if (_type == OrderBookType.NATIVE_IN_QUOTE && !_isMargin) {
                //There are no more writes to the state after this, so read only reentrancies should be avoided
                uint256 _refund = _pricePrecisionToQuoteAssetPrecision(_quoteSize);
                _handleNativeMarketRefundTransfer(_refund);
            } else {
                marginAccount.creditUser(
                    msg.sender, quoteAsset, _pricePrecisionToQuoteAssetPrecision(_quoteSize), _isMargin
                );
            }
        } else if (_type == OrderBookType.NATIVE_IN_QUOTE) {
            (bool _success,) = address(marginAccount).call{value: msg.value}("");
            require(_success, Errors.NativeAssetTransferFail());
        }
        unchecked {
            require(_baseTokensCredited >= _minAmountOut, Errors.SlippageExceeded());
        }
        return _baseTokensCredited;
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(uint96 _size, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        public
        payable
        marketActive
        returns (uint256)
    {
        OrderBookType _type = orderBookType;
        if (_type == OrderBookType.NATIVE_IN_BASE && !_isMargin) {
            require(
                msg.value >= _sizePrecisionToBaseAssetPrecision(_size)
                    && msg.value < _sizePrecisionToBaseAssetPrecision(_size + 1),
                Errors.NativeAssetInsufficient()
            );
        } else {
            require(msg.value == 0, Errors.NativeAssetNotRequired());
            _isMargin
                ? marginAccount.debitUser(msg.sender, baseAsset, _sizePrecisionToBaseAssetPrecision(_size))
                : baseAsset.safeTransferFrom(msg.sender, address(marginAccount), _sizePrecisionToBaseAssetPrecision(_size));
        }

        uint256 _quoteCredited;
        (_size, _quoteCredited) = _matchAggressiveSell(0, _size, _isMargin);

        if (_size > 0) {
            require(!_isFillOrKill, Errors.InsufficientLiquidity());
            if (_type == OrderBookType.NATIVE_IN_BASE && !_isMargin) {
                uint256 _refund = _sizePrecisionToBaseAssetPrecision(_size);
                _handleNativeMarketRefundTransfer(_refund);
            } else {
                marginAccount.creditUser(msg.sender, baseAsset, _sizePrecisionToBaseAssetPrecision(_size), _isMargin);
            }
        } else if (_type == OrderBookType.NATIVE_IN_BASE) {
            (bool _success,) = address(marginAccount).call{value: msg.value}("");
            require(_success, Errors.NativeAssetTransferFail());
        }
        unchecked {
            require(_quoteCredited >= _minAmountOut, Errors.SlippageExceeded());
        }
        return _quoteCredited;
    }

    /**
     * @dev Internal function to credit native token refunds for market orders
     * @param _refund The native token refund to be credited to the taker
     */
    function _handleNativeMarketRefundTransfer(uint256 _refund) internal {
        (bool _success,) = address(marginAccount).call{value: msg.value - _refund}("");
        require(_success, Errors.NativeAssetTransferFail());

        // @audit: Does this lead to bugs?
        (_success,) = address(msg.sender).call{value: _refund}("");
        require(_success, Errors.NativeAssetTransferFail());
    }

    function _pricePrecisionToQuoteAssetPrecision(uint24 _quote) internal view returns (uint256) {
        return (uint256(_quote) * 10 ** quoteAssetDecimals) / pricePrecision;
    }

    function _sizePrecisionToBaseAssetPrecision(uint96 _size) internal view returns (uint256) {
        return (uint256(_size) * 10 ** baseAssetDecimals) / sizePrecision;
    }

    /**
     * @dev Calls the creditFee function in MarginAccount
     * @notice Anyone can call this function
     */
    function collectFees() external {
        marginAccount.creditFee(baseAsset, baseFeeCollected, quoteAsset, quoteFeeCollected);
        baseFeeCollected = 0;
        quoteFeeCollected = 0;
    }

    function _matchAggressiveBuyWithCap(uint24 _limitPrice, uint96 _sizeToBeFilled) internal returns (uint96, uint24) {
        uint96 _sizeToCreditTaker;
        uint96 _sizeToCreditViaVault;
        (bool _isVaultFill, uint256 _bestAsk) = bestAsk();
        uint24 fundsConsumed;
        bytes memory makerCredits;
        while (_sizeToBeFilled > 0 && _bestAsk <= (_limitPrice * vaultPricePrecision / pricePrecision) && _bestAsk != 0)
        {
            bytes memory priceUpdate;
            uint96 sizeToBeFilledBefore = _sizeToBeFilled; // Capture the size before filling
            // _sizeToBeFilled always signifies size left to be filled
            (_sizeToBeFilled, priceUpdate) = _isVaultFill
                ? _fillVaultForBuy(_sizeToBeFilled)
                : _fillSizeForPrice(
                    s_sellTree,
                    uint24(_bestAsk * pricePrecision / vaultPricePrecision),
                    s_sellPricePoints[_bestAsk * pricePrecision / vaultPricePrecision],
                    _sizeToBeFilled
                );
            _sizeToCreditTaker += (sizeToBeFilledBefore - _sizeToBeFilled);
            _sizeToCreditViaVault += (_isVaultFill ? (sizeToBeFilledBefore - _sizeToBeFilled) : 0);
            fundsConsumed += _calculateFundsConsumed(
                uint24(FixedPointMathLib.mulDivUp(_bestAsk, pricePrecision, vaultPricePrecision)),
                (sizeToBeFilledBefore - _sizeToBeFilled)
            );
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestAsk) = bestAsk();
        }

        if (_sizeToCreditTaker > 0) {
            uint256 _tokenCredit = (_sizeToCreditTaker * 10 ** baseAssetDecimals) / sizePrecision;
            if (_sizeToCreditViaVault > 0) {
                marginAccount.debitUser(
                    kuruAmmVault, baseAsset, (_sizeToCreditViaVault * 10 ** baseAssetDecimals) / sizePrecision
                );
            }
            if (takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                // Calculate what ratio of fee goes to the protocol
                baseFeeCollected += ((_feeDebit * (takerFeeBps - makerFeeBps)) / takerFeeBps);
            }
            marginAccount.creditUsersEncoded(
                bytes.concat(makerCredits, abi.encode(msg.sender, baseAsset, _tokenCredit, true))
            );
        }

        return (_sizeToBeFilled, fundsConsumed);
    }

    /**
     * @dev Match limit buy orders if it crosses the book.
     * @param _quoteSize amount of quote asset user is ready to pay.
     */
    function _marketBuyMatch(uint24 _quoteSize, bool _isMargin) internal returns (uint24, uint256) {
        uint96 _sizeToCreditTaker;
        uint96 _sizeToCreditViaVault;
        (bool _isVaultFill, uint256 _bestAsk) = bestAsk();
        uint256 _tokenCredit;
        bytes memory makerCredits;
        while (_quoteSize > 0 && _bestAsk != 0) {
            //Calculate base size fillable by current unconsumed quote size for a particular price
            uint96 _sizeFillableAtPriceLeft =
                uint96(_quoteSize * sizePrecision * vaultPricePrecision / (_bestAsk * pricePrecision));

            bytes memory priceUpdate;
            uint96 _sizeFillableAtPriceBefore = _sizeFillableAtPriceLeft; //save old size to be filled
            // The unfilled size is returned here, from which we can calculate filled size
            (_sizeFillableAtPriceLeft, priceUpdate) = _isVaultFill
                ? _fillVaultForBuy(_sizeFillableAtPriceLeft)
                : _fillSizeForPrice(
                    s_sellTree,
                    uint24(_bestAsk * pricePrecision / vaultPricePrecision),
                    s_sellPricePoints[uint24(_bestAsk * pricePrecision / vaultPricePrecision)],
                    _sizeFillableAtPriceLeft
                );
            _sizeToCreditViaVault += (_isVaultFill ? (_sizeFillableAtPriceBefore - _sizeFillableAtPriceLeft) : 0);
            _sizeToCreditTaker += (_sizeFillableAtPriceBefore - _sizeFillableAtPriceLeft); //add size filled already at price
            makerCredits = bytes.concat(makerCredits, priceUpdate);
            // Calculate current quote size left with size that can be filled at current price point
            _quoteSize = uint24(
                FixedPointMathLib.mulDiv(
                    _bestAsk * pricePrecision, _sizeFillableAtPriceLeft, sizePrecision * vaultPricePrecision
                )
            );
            (_isVaultFill, _bestAsk) = bestAsk();
        }

        if (_sizeToCreditTaker > 0) {
            _tokenCredit = ((_sizeToCreditTaker) * 10 ** baseAssetDecimals) / sizePrecision;
            address _baseAsset = baseAsset;
            if (_sizeToCreditViaVault > 0) {
                marginAccount.debitUser(
                    kuruAmmVault, _baseAsset, (_sizeToCreditViaVault * 10 ** baseAssetDecimals) / sizePrecision
                );
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                // Calculate protocol fee part of total fee
                baseFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            marginAccount.creditUsersEncoded(
                bytes.concat(makerCredits, abi.encode(msg.sender, _baseAsset, _tokenCredit, _isMargin))
            );
        }

        return (_quoteSize, _tokenCredit);
    }

    /**
     *
     * @param _limitPrice Price of the sell order.
     * @param _sizeToBeFilledLeft Size of the sell order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function _matchAggressiveSell(uint24 _limitPrice, uint96 _sizeToBeFilledLeft, bool _useMargin)
        internal
        returns (uint96, uint256)
    {
        uint24 _quoteCreditTaker = 0;
        uint256 _quoteCreditVaultTaker;
        (bool _isVaultFill, uint256 _bestBid) = bestBid();
        bytes memory makerCredits;
        while (
            _sizeToBeFilledLeft > 0 && _bestBid >= (_limitPrice * vaultPricePrecision / pricePrecision)
                && _bestBid != type(uint24).max
        ) {
            uint96 _sizeToBeFilledBefore = _sizeToBeFilledLeft; //save size left to fill

            bytes memory priceUpdate;
            // The function returns unfilled size, from which we can calculate filled size
            (_sizeToBeFilledLeft, priceUpdate) = _isVaultFill && vaultBidOrderSize > 0
                ? _fillVaultForSell(_sizeToBeFilledLeft)
                : _fillSizeForPrice(
                    s_buyTree,
                    uint24(_bestBid * pricePrecision / vaultPricePrecision),
                    s_buyPricePoints[_bestBid * pricePrecision / vaultPricePrecision],
                    _sizeToBeFilledLeft
                );
            // Calculate the quote size which needs to be credited for the size that was filled at the particular price point
            if (_isVaultFill) {
                _quoteCreditVaultTaker +=
                    FixedPointMathLib.mulDiv(_sizeToBeFilledBefore - _sizeToBeFilledLeft, vaultBestBid, sizePrecision);
            } else {
                _quoteCreditTaker += uint24(
                    FixedPointMathLib.mulDiv(
                        _sizeToBeFilledBefore - _sizeToBeFilledLeft,
                        uint24(_bestBid * pricePrecision / vaultPricePrecision),
                        sizePrecision
                    )
                );
            }
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestBid) = bestBid();
        }

        if (_quoteCreditTaker > 0 || _quoteCreditVaultTaker > 0) {
            uint256 _tokenCredit = ((_quoteCreditTaker) * 10 ** quoteAssetDecimals) / pricePrecision
                + (_quoteCreditVaultTaker * 10 ** quoteAssetDecimals) / vaultPricePrecision;
            if (_quoteCreditVaultTaker > 0) {
                marginAccount.debitUser(
                    kuruAmmVault, quoteAsset, (_quoteCreditVaultTaker * 10 ** quoteAssetDecimals) / vaultPricePrecision
                );
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                //Calculate protocol fee part of total fee
                quoteFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            marginAccount.creditUsersEncoded(
                bytes.concat(makerCredits, abi.encode(msg.sender, quoteAsset, _tokenCredit, _useMargin))
            );
            return (_sizeToBeFilledLeft, _tokenCredit);
        }

        return (_sizeToBeFilledLeft, 0);
    }

    /**
     * @notice Exhaustively fills the required size at a specific price point.
     * @dev Iterates through orders at `_pricePoint` to fill the order size `_size`.
     * @param _pricePoint The price point to fill orders against.
     * @param _size The size of the order to be filled.
     * @return remainingSize The size remaining unfilled.
     */
    function _fillSizeForPrice(
        TreeMath.TreeUint24 storage _tree,
        uint24 _price,
        OrderLinkedList.PricePoint storage _pricePoint,
        uint96 _size
    ) internal returns (uint96, bytes memory makerCredits) {
        uint40 _orderId = _pricePoint.head;
        while (_size > 0 && _orderId != OrderLinkedList.NULL) {
            //orderUpdate contains byte encoded data for token credit to be executed by Margin Account
            bytes memory orderUpdate;
            //_orderId returned contains the next order in line to be filled
            (_size, _orderId, orderUpdate) = _fillOrder(_orderId, _size);
            //prepare into a single bytes encoding to be batched as a single call to margin account
            makerCredits = bytes.concat(makerCredits, orderUpdate);
        }
        OrderLinkedList.updateHead(_pricePoint, _orderId);
        if (_orderId == OrderLinkedList.NULL) {
            TreeMath.remove(_tree, _price);
        }
        return (_size, makerCredits);
    }

    /**
     * @notice Fills an order and credits the maker, possibly removing the order if fully filled.
     * @dev Attempts to fill order `_orderId` with size `_size`. Credits maker and removes order if fully filled.
     * @param _orderId The ID of the order to fill.
     * @param _sizeToBeFilled The size to fill.
     * @return remainingSize The remaining size after attempting to fill this order.
     * @return _nextHead next head of the price point.
     */
    function _fillOrder(uint40 _orderId, uint96 _sizeToBeFilled)
        internal
        returns (uint96 remainingSize, uint40 _nextHead, bytes memory _orderUpdate)
    {
        _nextHead = s_orders[_orderId].next;
        uint96 _orderSize = s_orders[_orderId].size;
        //remaining size is 0 if current order can fully fill required size
        remainingSize = (_sizeToBeFilled > _orderSize) ? (_sizeToBeFilled - _orderSize) : 0;
        uint96 _updatedSize;
        if (remainingSize == 0) {
            //if order is partially filled, update its size
            _updatedSize = _orderSize - _sizeToBeFilled;
        }
        _orderUpdate = _creditMaker(
            !s_orders[_orderId].isBuy,
            s_orders[_orderId].ownerAddress,
            (remainingSize == 0) ? _sizeToBeFilled : s_orders[_orderId].size,
            s_orders[_orderId].price
        );

        if (
            remainingSize == 0 || (_nextHead == OrderLinkedList.NULL && s_orders[_orderId].prev == OrderLinkedList.NULL)
        ) {
            if (_updatedSize != 0) {
                _nextHead = _orderId;
            }
            s_orders[_orderId].size = _updatedSize;
        }
        // What if the whole book gets filled or the whole price point gets filled up?
        emit Trade(
            _orderId,
            s_orders[_orderId].ownerAddress,
            !s_orders[_orderId].isBuy,
            (s_orders[_orderId].price * vaultPricePrecision) / pricePrecision,
            _updatedSize,
            msg.sender,
            _sizeToBeFilled - remainingSize
        );
    }

    /**
     * internal helper function to calculate quote amounts with correct math
     * @param _price The price of the order.
     * @param _size The size of the order
     */
    function _calculateFundsConsumed(uint24 _price, uint96 _size) internal view returns (uint24) {
        uint256 _result = FixedPointMathLib.mulDivUp(_price, _size, sizePrecision);
        require(_result < type(uint24).max, Errors.TooMuchSizeFilled());
        return uint24(_result);
    }

    /**
     * @notice Credits the maker of an order.
     * @dev Credits the maker's account based on the order details. Optimized by consolidating repetitive logic.
     * @param _isMarketBuy Whether the order is a market buy.
     * @param _ownerAddress The address of the order's maker.
     * @param _size The size of the order being credited.
     * @param _price The price of the order.
     */
    function _creditMaker(bool _isMarketBuy, address _ownerAddress, uint96 _size, uint24 _price)
        internal
        view
        returns (bytes memory)
    {
        address creditAsset = _isMarketBuy ? quoteAsset : baseAsset;
        uint256 amount =
            _isMarketBuy ? _amountPayable(_size, _price) : ((_size * 10 ** baseAssetDecimals) / sizePrecision);
        uint256 feeRebate;
        address feeAsset;
        bytes memory returnData;
        if (_isMarketBuy) {
            feeAsset = baseAsset;
            feeRebate = (((_size * 10 ** baseAssetDecimals) / sizePrecision) * makerFeeBps) / BPS_MULTIPLIER;
        } else {
            feeAsset = quoteAsset;
            feeRebate = (_amountPayable(_size, _price) * makerFeeBps) / BPS_MULTIPLIER;
        }
        //feeRebate only exists if makerFeeBps > 0
        if (feeRebate > 0) {
            returnData = abi.encode(_ownerAddress, feeAsset, feeRebate, true);
        }

        return bytes.concat(returnData, abi.encode(_ownerAddress, creditAsset, amount, true));
    }

    /**
     * internal helper function to get payable amount
     * @param _size size of token
     * @param _price conversion price from A to B
     */
    function _amountPayable(uint96 _size, uint24 _price) internal view returns (uint256) {
        return (uint256(uint24((_price * _size) / sizePrecision)) * 10 ** quoteAssetDecimals) / pricePrecision;
    }

    function _getPricePrecision() internal view override returns (uint24) {
        return pricePrecision;
    }

    function _getSizePrecision() internal view override returns (uint96) {
        return sizePrecision;
    }

    function _getTakerFeeBps() internal view override returns (uint256) {
        return takerFeeBps;
    }

    function _getMakerFeeBps() internal view override returns (uint256) {
        return makerFeeBps;
    }

    function _getBaseAssetDecimals() internal view override returns (uint256) {
        return baseAssetDecimals;
    }

    function _getQuoteAssetDecimals() internal view override returns (uint256) {
        return quoteAssetDecimals;
    }

    function _getBaseAsset() internal view override returns (address) {
        return baseAsset;
    }

    function _getQuoteAsset() internal view override returns (address) {
        return quoteAsset;
    }

    /**
     * @dev Getter of market params.
     */
    function getMarketParams()
        external
        view
        returns (uint24, uint96, address, uint256, address, uint256, uint24, uint96, uint96, uint256, uint256)
    {
        return (
            pricePrecision,
            sizePrecision,
            baseAsset,
            baseAssetDecimals,
            quoteAsset,
            quoteAssetDecimals,
            tickSize,
            minSize,
            maxSize,
            takerFeeBps,
            makerFeeBps
        );
    }

    /**
     * @dev Returns the best bid and the best ask of the market.
     */
    function bestBidAsk() external view returns (uint256, uint256) {
        (, uint256 _bestBid) = bestBid();
        (, uint256 _bestAsk) = bestAsk();
        return (_bestBid, _bestAsk);
    }

    function bestAsk() internal view returns (bool, uint256) {
        uint24 firstLeft = TreeMath.findFirstLeft(s_sellTree, 0);
        if (firstLeft != 0) {
            if (vaultBestAsk != type(uint256).max) {
                return (FixedPointMathLib.min(firstLeft * vaultPricePrecision / pricePrecision, vaultBestAsk))
                    == vaultBestAsk ? (true, vaultBestAsk) : (false, firstLeft * vaultPricePrecision / pricePrecision);
            }
            return (false, firstLeft * vaultPricePrecision / pricePrecision);
        }
        return (vaultBestAsk != type(uint256).max) ? (true, vaultBestAsk) : (false, 0);
    }

    function bestBid() internal view returns (bool, uint256) {
        uint24 firstRight = TreeMath.findFirstRight(s_buyTree, type(uint24).max);
        if (firstRight != type(uint24).max) {
            if (vaultBestBid != 0) {
                return (FixedPointMathLib.max(firstRight * vaultPricePrecision / pricePrecision, vaultBestBid))
                    == vaultBestBid ? (true, vaultBestBid) : (false, firstRight * vaultPricePrecision / pricePrecision);
            }
            return (false, firstRight * vaultPricePrecision / pricePrecision);
        }
        return vaultBestBid != 0 ? (true, vaultBestBid) : (false, type(uint24).max);
    }

    /**
     * @notice Returns the Level 2 order book data.
     * @dev Encodes the block number, buy orders, and sell orders.
     * @return Encoded bytes containing the block number, prices, and sizes of the buy and sell orders.
     */
    function getL2Book() external view returns (bytes memory) {
        bytes memory data = abi.encode(block.number);

        // Encode buy orders
        uint24 price = TreeMath.findFirstLeft(s_buyTree, 0);
        while (price != type(uint24).max && price != 0) {
            uint40 orderId = s_buyPricePoints[price].head;
            uint96 size = 0;
            while (orderId != 0) {
                size += s_orders[orderId].size;
                orderId = s_orders[orderId].next;
            }
            data = bytes.concat(data, abi.encode(price, size));
            price = TreeMath.findFirstLeft(s_buyTree, price);
        }

        data = bytes.concat(data, abi.encode(0)); // Separator between buy and sell orders

        // Encode sell orders
        price = TreeMath.findFirstLeft(s_sellTree, 0);
        while (price != type(uint24).max && price != 0) {
            uint40 orderId = s_sellPricePoints[price].head;
            uint96 size = 0;
            while (orderId != 0) {
                size += s_orders[orderId].size;
                orderId = s_orders[orderId].next;
            }
            data = bytes.concat(data, abi.encode(price, size));
            price = TreeMath.findFirstLeft(s_sellTree, price);
        }

        return data;
    }
}
