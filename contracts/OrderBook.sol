// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {AbstractAMM} from "./AbstractAMM.sol";

// ============ Internal Interfaces Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";

// ============ Internal Contracts Imports ============
import {IERC20} from "./libraries/IERC20.sol";
import {IMarginAccount} from  "./interfaces/IMarginAccount.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract OrderBook is OwnableUpgradeable, UUPSUpgradeable, AbstractAMM {    
    OrderBookType orderBookType;

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
    IERC20 internal baseAsset;
    IERC20 internal quoteAsset;  

    uint24 tickSize;
    uint96 minSize;
    uint96 maxSize;

    uint256 quoteFeeCollected;
    uint256 baseFeeCollected;

    IMarginAccount marginAccount;


    /**
     * @dev Constructor.
     */
    constructor () {
        _disableInitializers();
    }

    modifier marketActive() {
        require(!marketPaused, "OrderBook: market is paused");
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
        address _kuruAmmVault
    ) public initializer {

        __Ownable_init();
        _transferOwnership(_owner);
        require(_makerFeeBps <= 8000 * _takerFeeBps / BPS_MULTIPLIER, "OrderBook: Maker fee should be lower than taker fee");
        orderBookType = _type;
        baseAsset = IERC20(_baseAssetAddress);
        quoteAsset = IERC20(_quoteAssetAddress);

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
        vaultBestAsk = type(uint256).max;
    }


    /**
    * @dev Makes sure owner is the one upgrading contract
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function upgradeTo(address newImplementation) public virtual override onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, new bytes(0), false);
    }

    /**
     * @dev Allows admin to pause the market.
     */
    function toggleMarkets(bool _state) external onlyOwner {
        require(_state != marketPaused, "OrderBook: Markets are already in requested state!");
        marketPaused = _state;
    }

    /**
     * @dev Adds a buy order to the order book.
     * @param _price Price of the buy order.
     * @param size Size of the buy order.
     */
    function addBuyOrder(uint24 _price, uint96 size, bool _postOnly) public marketActive {
        require(_price > 0, "OrderBook: Price too low");
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");
        
        //The buy order is filled aggressively and the leftover size is added as a limit buy order
        (uint96 _remainingSize, uint24 _consumedFunds) = _matchAggressiveBuyWithCap(_price, size);

        _consumedFunds += _calculateFundsConsumed(_price, _remainingSize);

        _consumeFunds(quoteAsset, (((_consumedFunds) * 10**quoteAssetDecimals) / pricePrecision), msg.sender);
        if (_postOnly) {
            require(size == _remainingSize, "OrderBook: Post only crossed the book");
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
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");
        require(_price > 0, "OrderBook: Price too low");

        _consumeFunds(baseAsset, ((size * 10**baseAssetDecimals) / sizePrecision), msg.sender);

        uint256 _tokenCredit;
        //The sell order is matched and filled aggressively and remaining size is added as limit sell order
        (size, _tokenCredit) = _matchAggressiveSell(_price, size, true);
        if (_postOnly) {
            require(_tokenCredit == 0, "OrderBook: Post only crossed the book");
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
    function _consumeFunds(IERC20 _consumableAsset, uint256 _amount, address _makerAddress) internal {
        marginAccount.debitUser(
            _makerAddress,
            address(_consumableAsset),
            _amount
        );
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
        require(msg.sender == _order.ownerAddress, "OrderBook: Only order owner can cancel order");
        // update neighbouring orders
        if (_order.prev != OrderLinkedList.NULL) {
            s_orders[_order.prev].next = _order.next;
        }
        if (_order.next != OrderLinkedList.NULL) {
            s_orders[_order.next].prev = _order.prev;
        }

        if (_order.isBuy) {
            //If cancelled order is the head of corresponding price point, we need to update to new head
            if(_orderId == s_buyPricePoints[_order.price].head) {
                OrderLinkedList.updateHead(s_buyPricePoints[_order.price], _order.next);
            }
            OrderLinkedList.deleteOrder(s_buyPricePoints[_order.price], _order.prev, _order.next);
            //If there are no more orders remaining in price point, we can remove the price point
            if (_order.prev == _order.next) {
                TreeMath.remove(s_buyTree, _order.price);
            }

            marginAccount.creditUser(
                _order.ownerAddress,
                address(quoteAsset),
                (((uint24((_order.size * _order.price) / sizePrecision) * 10**quoteAssetDecimals) / pricePrecision)),
                true
            );
        } else {
            if(_orderId == s_sellPricePoints[_order.price].head) {
                OrderLinkedList.updateHead(s_sellPricePoints[_order.price], _order.next);
            }
            OrderLinkedList.deleteOrder(s_sellPricePoints[_order.price], _order.prev, _order.next);
            if (_order.prev == _order.next) {
                TreeMath.remove(s_sellTree, _order.price);
            }

            marginAccount.creditUser(
                _order.ownerAddress,
                address(baseAsset),
                ((_order.size * 10**baseAssetDecimals) / sizePrecision),
                true
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
            require(s_orders[_order.prev].next == _orderId, "OrderBook: Order already cancelled");
            if (_order.isBuy) {
                //Since all orders are filled FCFS in each price point, if head > order id, it means order id was already filled
                require(s_buyPricePoints[_order.price].head <= _orderId, "OrderBook: Order already filled");
            } else {
                require(s_sellPricePoints[_order.price].head <= _orderId, "OrderBook: Order already filled");
            }
        } else {
            if (_order.isBuy) {
                require(s_buyPricePoints[_order.price].head == _orderId, "OrderBook: Order already cancelled");
            } else {
                require(s_sellPricePoints[_order.price].head == _orderId, "OrderBook: Order already cancelled");
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
        require(buyPrices.length == buySizes.length, "OrderBook: Buy prices and sizes array length must match");

        // Ensure that the lengths of the sell prices and sizes match
        require(sellPrices.length == sellSizes.length, "OrderBook: Sell prices and sizes array length must match");

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
    function placeMultipleBuyOrders(uint24[] calldata _prices, uint96[] calldata _sizes, bool _postOnly) external marketActive {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addBuyOrder(_prices[i], _sizes[i], _postOnly);
        }
    }

    /**
     * @dev Places multiple limit sell orders in a single function call.
     * @param _prices Array of prices for the sell orders.
     * @param _sizes Array of sizes for the sell orders.
     */
    function placeMultipleSellOrders(uint24[] calldata _prices, uint96[] calldata _sizes, bool _postOnly) external marketActive {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addSellOrder(_prices[i], _sizes[i], _postOnly);
        }
    }


    /**
     * @dev Places and executes a market buy order.
     * @param _quoteSize amount of quote asset user is ready to pay.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketBuy(
        uint24 _quoteSize,
        uint256 _minTokensOut,
        bool _isFillOrKill
    ) payable public override marketActive returns (uint256) {
        OrderBookType _type = orderBookType;
        if (_type == OrderBookType.NATIVE_IN_QUOTE) {
            require(msg.value >= (_quoteSize) * 10**quoteAssetDecimals / pricePrecision, "OrderBook: Native asset not enough");
        }
        else {
            quoteAsset.transferFrom(msg.sender, address(marginAccount), uint256(_quoteSize * 10**quoteAssetDecimals / pricePrecision));
        }
        uint256 _baseTokensCredited;
        (_quoteSize, _baseTokensCredited) = _marketBuyMatch(_quoteSize);
        if (_quoteSize > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            if (_type == OrderBookType.NATIVE_IN_QUOTE) {
                //There are no more writes to the state after this, so read only reentrancies should be avoided
                uint256 _refund = _quoteSize * 10**quoteAssetDecimals / pricePrecision;
                _handleNativeMarketRefundTransfer(_refund);
            }
            else {
                marginAccount.creditUser(
                    msg.sender,
                    address(quoteAsset),
                    uint256(_quoteSize * 10**quoteAssetDecimals / pricePrecision),
                    false
                );
            }
        }
        else if (_type == OrderBookType.NATIVE_IN_QUOTE) {
            (bool _success, ) = address(marginAccount).call{value: msg.value}("");
            require(_success, "OrderBook: MarginAccount native transfer failed");
        }
        require(_baseTokensCredited >= _minTokensOut, "OrderBook: Slippage Exceeded");
        return _baseTokensCredited;
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(
        uint96 _size,
        uint256 _minTokensOut,
        bool _isFillOrKill
    ) payable public marketActive returns (uint256) {
        OrderBookType _type = orderBookType;
        if (_type == OrderBookType.NATIVE_IN_BASE) {
            require(msg.value >= _size * 10**baseAssetDecimals / sizePrecision, "OrderBook: Native asset not enough");
        }
        else {
            baseAsset.transferFrom(
                msg.sender,
                address(marginAccount),
                (_size * 10**baseAssetDecimals) / sizePrecision
            );
        }

        uint256 _quoteCredited;
        (_size, _quoteCredited) = _matchAggressiveSell(0, _size, false);

        if (_size > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            if (_type == OrderBookType.NATIVE_IN_BASE) {
                uint256 _refund = (_size * 10**baseAssetDecimals) / sizePrecision;
                _handleNativeMarketRefundTransfer(_refund);
            }
            else {
                marginAccount.creditUser(
                    msg.sender,
                    address(baseAsset),
                    ((_size * 10**baseAssetDecimals) / sizePrecision),
                    false
                );
            } 
        }
        else if (_type == OrderBookType.NATIVE_IN_BASE) {
            (bool _success, ) = address(marginAccount).call{value: msg.value}("");
            require(_success, "OrderBook: MarginAccount native transfer failed");
        }
        require(_quoteCredited >= _minTokensOut, "OrderBook: Slippage Exceeded");
        return _quoteCredited;
    }

    /**
    * @dev Internal function to credit native token refunds for market orders
    * @param _refund The native token refund to be credited to the taker
     */
    function _handleNativeMarketRefundTransfer(uint256 _refund) internal {
        (bool _success, ) = address(marginAccount).call{value: msg.value - _refund}("");
        require(_success, "OrderBook: MarginAccount native transfer failed");

        // @audit: Does this lead to bugs?
        (_success, ) = address(msg.sender).call{value: _refund}("");
        require(_success, "OrderBook: Refund failed");
    }

    /**
    * @dev Calls the creditFee function in MarginAccount
    * @notice Anyone can call this function
     */
    function collectFees() external {
        marginAccount.creditFee(address(baseAsset), baseFeeCollected, address(quoteAsset), quoteFeeCollected);
        baseFeeCollected = 0;
        quoteFeeCollected = 0;
    }

    function _matchAggressiveBuyWithCap(uint24 _limitPrice, uint96 _sizeToBeFilled) internal returns(uint96, uint24) {
        uint96 _sizeToCreditTaker;
        uint96 _sizeToCreditViaVault;
        (bool _isVaultFill, uint24 _bestAsk) = bestAsk();
        uint24 fundsConsumed;
        bytes memory makerCredits;
        while (_sizeToBeFilled > 0 && _bestAsk <= _limitPrice && _bestAsk != 0) {
            bytes memory priceUpdate;
            uint96 sizeToBeFilledBefore = _sizeToBeFilled; // Capture the size before filling
            // _sizeToBeFilled always signifies size left to be filled
            (_sizeToBeFilled, priceUpdate) = _isVaultFill
                ? _fillVaultForBuy(_sizeToBeFilled)
                : _fillSizeForPrice(
                    s_sellTree,
                    _bestAsk,
                    s_sellPricePoints[_bestAsk],
                    _sizeToBeFilled
                );

            uint96 sizeFilled = sizeToBeFilledBefore - _sizeToBeFilled; // Calculate the filled size
            _sizeToCreditTaker += sizeFilled;
            _sizeToCreditViaVault += (_isVaultFill? sizeFilled : 0);
            fundsConsumed += _calculateFundsConsumed(_bestAsk, sizeFilled);
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestAsk) = bestAsk();
        }

        if (_sizeToCreditTaker > 0) {
            uint256 _tokenCredit = (_sizeToCreditTaker * 10**baseAssetDecimals) / sizePrecision;
            if(_sizeToCreditViaVault > 0) {
                marginAccount.debitUser(kuruAmmVault, address(baseAsset), (_sizeToCreditViaVault * 10**baseAssetDecimals) / sizePrecision);
            }
            if (takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                // Calculate what ratio of fee goes to the protocol
                baseFeeCollected += ((_feeDebit * (takerFeeBps - makerFeeBps)) / takerFeeBps);
            }
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(baseAsset), _tokenCredit, true)));
        }

        return (_sizeToBeFilled, fundsConsumed);
    }

    /**
     * @dev Match limit buy orders if it crosses the book.
     * @param _quoteSize amount of quote asset user is ready to pay.
     */
    function _marketBuyMatch(uint24 _quoteSize) internal returns(uint24, uint256) {
        uint96 _sizeToCreditTaker;
        uint96 _sizeToCreditViaVault;
        (bool _isVaultFill, uint24 _bestAsk) = bestAsk();
        uint256 _tokenCredit;
        bytes memory makerCredits;
        while (_quoteSize > 0 && _bestAsk < type(uint24).max && _bestAsk != 0) {
            //Calculate base size fillable by current unconsumed quote size for a particular price
            uint96 _sizeFillableAtPriceLeft = _quoteSize * sizePrecision / _bestAsk;
            
            bytes memory priceUpdate;
            uint96 _sizeFillableAtPriceBefore = _sizeFillableAtPriceLeft; //save old size to be filled
            // The unfilled size is returned here, from which we can calculate filled size
            (_sizeFillableAtPriceLeft, priceUpdate) = _isVaultFill
                ? _fillVaultForBuy(_sizeFillableAtPriceLeft)
                : _fillSizeForPrice(
                    s_sellTree,
                    _bestAsk,
                    s_sellPricePoints[_bestAsk],
                    _sizeFillableAtPriceLeft
                );
            _sizeToCreditViaVault += (_isVaultFill? (_sizeFillableAtPriceBefore - _sizeFillableAtPriceLeft) : 0);
            _sizeToCreditTaker += (_sizeFillableAtPriceBefore - _sizeFillableAtPriceLeft); //add size filled already at price
            makerCredits = bytes.concat(makerCredits, priceUpdate);
            // Calculate current quote size left with size that can be filled at current price point
            _quoteSize = uint24((_bestAsk * _sizeFillableAtPriceLeft) / sizePrecision);

            (_isVaultFill, _bestAsk) = bestAsk();
        }

        if (_sizeToCreditTaker > 0) {
            _tokenCredit = ((_sizeToCreditTaker) * 10**baseAssetDecimals) / sizePrecision;
            address _baseAsset = address(baseAsset);
            if(_sizeToCreditViaVault > 0) {
                marginAccount.debitUser(kuruAmmVault, _baseAsset, (_sizeToCreditViaVault * 10**baseAssetDecimals) / sizePrecision);
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                // Calculate protocol fee part of total fee
                baseFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, _baseAsset, _tokenCredit, false)));
        }

        return (_quoteSize, _tokenCredit);
    }

    /**
     * 
     * @param _limitPrice Price of the sell order.
     * @param _sizeToBeFilledLeft Size of the sell order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function _matchAggressiveSell(uint24 _limitPrice, uint96 _sizeToBeFilledLeft, bool _useMargin) internal returns(uint96, uint256) {
        uint24 _quoteCreditTaker = 0;
        uint256 _quoteCreditVaultTaker;
        (bool _isVaultFill, uint24 _bestBid) = bestBid();
        uint256 _tokenCredit;
        bytes memory makerCredits;
        while (_sizeToBeFilledLeft > 0 && _bestBid >= _limitPrice && _bestBid != type(uint24).max) {
            uint96 _sizeToBeFilledBefore = _sizeToBeFilledLeft; //save size left to fill

            bytes memory priceUpdate;
            // The function returns unfilled size, from which we can calculate filled size
            (_sizeToBeFilledLeft, priceUpdate) = _isVaultFill && vaultBidOrderSize > 0
                ? _fillVaultForSell(_sizeToBeFilledLeft)
                : _fillSizeForPrice(s_buyTree, _bestBid, s_buyPricePoints[_bestBid], _sizeToBeFilledLeft);
            // Calculate the quote size which needs to be credited for the size that was filled at the particular price point
            if(_isVaultFill) {
                _quoteCreditVaultTaker += FixedPointMathLib.mulDivDown(_sizeToBeFilledBefore - _sizeToBeFilledLeft, vaultBestBid, sizePrecision);
            } else {
                _quoteCreditTaker += uint24(FixedPointMathLib.mulDivDown(_sizeToBeFilledBefore - _sizeToBeFilledLeft, _bestBid, sizePrecision));
            }
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestBid) = bestBid();
        }

        if (_quoteCreditTaker > 0 || _quoteCreditVaultTaker > 0) {
            _tokenCredit = ((_quoteCreditTaker) * 10**quoteAssetDecimals) / pricePrecision + 
                            (_quoteCreditVaultTaker * 10**quoteAssetDecimals) / vaultPricePrecision;
            if(_quoteCreditVaultTaker > 0) {
                marginAccount.debitUser(kuruAmmVault, address(quoteAsset), (_quoteCreditVaultTaker * 10**quoteAssetDecimals) / vaultPricePrecision);
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                //Calculate protocol fee part of total fee
                quoteFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(quoteAsset), _tokenCredit, _useMargin)));
        }

        return (_sizeToBeFilledLeft, _tokenCredit);
    }

    /**
     * @notice Exhaustively fills the required size at a specific price point.
     * @dev Iterates through orders at `_pricePoint` to fill the order size `_size`.
     * @param _pricePoint The price point to fill orders against.
     * @param _size The size of the order to be filled.
     * @return remainingSize The size remaining unfilled.
     */
    function _fillSizeForPrice(TreeMath.TreeUint24 storage _tree, uint24 _price, OrderLinkedList.PricePoint storage _pricePoint, uint96 _size) internal returns (uint96 remainingSize, bytes memory makerCredits) {
        remainingSize = _size;
        uint40 _orderId = _pricePoint.head;
        while (remainingSize > 0 && _orderId != OrderLinkedList.NULL) {
            //orderUpdate contains byte encoded data for token credit to be executed by Margin Account
            bytes memory orderUpdate;
            //_orderId returned contains the next order in line to be filled
            (remainingSize, _orderId, orderUpdate) = _fillOrder(_orderId, remainingSize);
            //prepare into a single bytes encoding to be batched as a single call to margin account
            makerCredits = bytes.concat(makerCredits, orderUpdate);
        }
        OrderLinkedList.updateHead(_pricePoint, _orderId);
        if (_orderId == OrderLinkedList.NULL) {
            TreeMath.remove(_tree, _price);
        }
    }


    /**
     * @notice Fills an order and credits the maker, possibly removing the order if fully filled.
     * @dev Attempts to fill order `_orderId` with size `_size`. Credits maker and removes order if fully filled.
     * @param _orderId The ID of the order to fill.
     * @param _sizeToBeFilled The size to fill.
     * @return remainingSize The remaining size after attempting to fill this order.
     * @return _nextHead next head of the price point.
     */
    function _fillOrder(uint40 _orderId, uint96 _sizeToBeFilled) internal returns (uint96 remainingSize, uint40 _nextHead, bytes memory _orderUpdate) {
        _nextHead = s_orders[_orderId].next;
        uint96 _orderSize = s_orders[_orderId].size;
        //remaining size is 0 if current order can fully fill required size
        remainingSize = (_sizeToBeFilled > _orderSize) ? (_sizeToBeFilled - _orderSize) : 0;
        uint96 _updatedSize;
        if(remainingSize == 0) {
            //if order is partially filled, update its size
            _updatedSize = _orderSize - _sizeToBeFilled;
        }
        _orderUpdate = _creditMaker(!s_orders[_orderId].isBuy, s_orders[_orderId].ownerAddress, (remainingSize == 0) ? _sizeToBeFilled : s_orders[_orderId].size, s_orders[_orderId].price);

        if (remainingSize == 0 || (_nextHead == OrderLinkedList.NULL && s_orders[_orderId].prev == OrderLinkedList.NULL)) {
            if (_updatedSize != 0) {
                _nextHead = _orderId;
            }
            s_orders[_orderId].size = _updatedSize;
        }
        // What if the whole book gets filled or the whole price point gets filled up?
        emit Trade(_orderId, s_orders[_orderId].ownerAddress, s_orders[_orderId].isBuy, (s_orders[_orderId].price * vaultPricePrecision) / pricePrecision, _updatedSize, msg.sender, _sizeToBeFilled - remainingSize);
    }

    /**
    * internal helper function to calculate quote amounts with correct math
    * @param _price The price of the order.
    * @param _size The size of the order
     */
    function _calculateFundsConsumed(uint24 _price, uint96 _size) internal view returns (uint24) {
        uint256 _result = FixedPointMathLib.mulDivUp(_price, _size, sizePrecision);
        if (_result >= type(uint24).max) {
            revert("OrderBook: Too much size being filled");
        }
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
    function _creditMaker(bool _isMarketBuy, address _ownerAddress, uint96 _size, uint24 _price) internal view returns (bytes memory) {
        address creditAsset = _isMarketBuy ? address(quoteAsset) : address(baseAsset);
        uint256 amount = _isMarketBuy ? _amountPayable(_size, _price) : ((_size * 10**baseAssetDecimals) / sizePrecision);
        uint256 feeRebate;
        address feeAsset;
        bytes memory returnData;
        if (_isMarketBuy) {
            feeAsset = address(baseAsset);
            feeRebate = (((_size * 10**baseAssetDecimals) / sizePrecision) * makerFeeBps) / BPS_MULTIPLIER;
        }
        else {
            feeAsset = address(quoteAsset);
            feeRebate = (_amountPayable(_size, _price) * makerFeeBps) / BPS_MULTIPLIER;
        }
        //feeRebate only exists if makerFeeBps > 0
        if(feeRebate > 0) {
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
        return (uint256(uint24((_price * _size) / sizePrecision)) * 10**quoteAssetDecimals) / pricePrecision;
    }

    function _getPricePrecision() internal override view returns (uint24) {
        return pricePrecision;
    }

    function _getSizePrecision() internal override view returns (uint96) {
        return sizePrecision;
    }

    function _getTakerFeeBps() internal override view returns (uint256) {
        return takerFeeBps;
    }

    function _getMakerFeeBps() internal override view returns (uint256) {
        return makerFeeBps;
    }

    function _getBaseAssetDecimals() internal override view returns (uint256) {
        return baseAssetDecimals;
    }

    function _getQuoteAssetDecimals() internal override view returns (uint256) {
        return quoteAssetDecimals;
    }

    function _getBaseAsset() internal override view returns (IERC20) {
        return baseAsset;
    }

    function _getQuoteAsset() internal override view returns (IERC20) {
        return quoteAsset;
    }

    /**
     * @dev Getter of market params.
     */
    function getMarketParams() external view returns (uint24, uint96, address, uint256, address, uint256, uint24, uint96, uint96, uint256, uint256) {
        return (
            pricePrecision,
            sizePrecision,
            address(baseAsset),
            baseAssetDecimals,
            address(quoteAsset),
            quoteAssetDecimals,
            tickSize,
            minSize,
            maxSize,
            takerFeeBps,
            makerFeeBps
        );
    }


    function bestAsk() internal view returns(bool, uint24) {
        uint24 firstLeft = TreeMath.findFirstLeft(s_sellTree, 0);
        uint24 _vaultBestAskNormalized = vaultBestAsk == type(uint256).max ? type(uint24).max : uint24((vaultBestAsk * pricePrecision) / vaultPricePrecision);
        if(firstLeft != 0) {
            if(_vaultBestAskNormalized != type(uint24).max) {
                return uint24(FixedPointMathLib.min(firstLeft, _vaultBestAskNormalized)) == _vaultBestAskNormalized ? (true, _vaultBestAskNormalized) : (false, firstLeft);
            }
            return (false, firstLeft);
        }
        return (_vaultBestAskNormalized != type(uint24).max) ? (true, _vaultBestAskNormalized) : (false, 0);
    }

    function bestBid() internal view returns(bool, uint24) {
        uint24 firstRight = TreeMath.findFirstRight(s_buyTree, type(uint24).max);
        uint24 _vaultBestBidNormalized = vaultBestBid != 0 ? uint24((vaultBestBid * pricePrecision) / vaultPricePrecision) : 0;
        if(firstRight != type(uint24).max) {
            if(_vaultBestBidNormalized != 0) {
                return uint24(FixedPointMathLib.max(firstRight, _vaultBestBidNormalized)) == _vaultBestBidNormalized ? (true, _vaultBestBidNormalized) : (false, firstRight);
            }
            return (false, firstRight);
        }
        return _vaultBestBidNormalized != 0 ? (true, _vaultBestBidNormalized) : (false, type(uint24).max);
    }

    /**
     * @dev Returns the best bid and the best ask of the market.
     */
    function bestBidAsk() external view returns (uint24, uint24) {
        (, uint24 _bestBid) = bestBid();
        (, uint24 _bestAsk) = bestAsk();
        return (_bestBid, _bestAsk);
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