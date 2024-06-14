// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";

// ============ Internal Interfaces Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";

// ============ Internal Contracts Imports ============
import {IERC20} from "./libraries/IERC20.sol";
import {MarginAccount} from  "./MarginAccount.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";


// size is 10**10
// price is 10**2
contract OrderBook is IOrderBook, OwnableUpgradeable, UUPSUpgradeable {

   struct Order {
        address ownerAddress;
        uint96 size;
        uint40 prev;
        uint40 next;
        uint24 price;
        bool isBuy;
    }

    /**
     * @dev Emitted when a new order is created.
     * @param orderId Unique identifier for the newly created order.
     * @param owner Address of the user who created the order.
     * @param price Price point of the order in the specified precision.
     * @param size Size of the order in the specified precision.
     * @param isBuy Boolean indicating if the order is a buy (true) or sell (false) order.
     */
    event OrderCreated(
        uint40 orderId,
        address owner,
        uint96 size,
        uint24 price,
        bool isBuy
    );

    /**
     * @dev Emitted when one or more orders are completed or canceled.
     * @param orderId Array of order identifiers that were completed or canceled.
     */
    event OrdersCanceled(
        uint40[] orderId,
        address owner
    );

    /***
     * @dev Emitted when a trade goes through.
     * @param orderId Order Id of the order that was filled.
     * PS. All data regarding the original order can be found out from the order ID
     * @param updatedSize New size of the order
     * @param takerAddress Address of the taker.
     * @param filledSize Size taken by the taker.
     */
    event Trade(
        uint40 orderId,
        address makerAddress,
        bool isBuy,
        uint24 price,
        uint96 updatedSize,
        address takerAddress,
        uint96 filledSize
    );

    OrderBookType orderBookType;

    mapping(uint40 => Order) public s_orders;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_buyPricePoints;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_sellPricePoints;
    TreeMath.TreeUint24 public s_buyTree;
    TreeMath.TreeUint24 public s_sellTree;

    uint40 public s_orderIdCounter;
    bool marketPaused;

    uint96 sizePrecision;
    uint24 pricePrecision;

    uint96 tickSize;
    uint96 minSize;
    uint96 maxSize;

    // TODO: might have to be public
    uint256 takerFeeBps;
    // TODO: add maker fee

    IERC20 baseAsset;
    IERC20 quoteAsset;
    MarginAccount marginAccount;

    uint256 baseAssetDecimals;
    uint256 quoteAssetDecimals;

    uint256 constant BPS_MULTIPLIER = 10000;

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
        uint96 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps) public initializer {

        __Ownable_init();
        _transferOwnership(_owner);
        orderBookType = _type;
        baseAsset = IERC20(_baseAssetAddress);
        quoteAsset = IERC20(_quoteAssetAddress);

        baseAssetDecimals = _baseAssetDecimals;
        quoteAssetDecimals = _quoteAssetDecimals;

        marginAccount = MarginAccount(payable(_marginAccountAddress));
        // initialize contract parameters
        sizePrecision = _sizePrecision;
        pricePrecision = _pricePrecision;
        tickSize = _tickSize;
        minSize = _minSize;
        maxSize = _maxSize;
        takerFeeBps = _takerFeeBps;
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
    function pauseMarkets() external onlyOwner {
        marketPaused = true;
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
        
        uint96 _remainingSize;
        uint24 _consumedFunds;
        (_remainingSize, _consumedFunds) = _matchAggressiveBuyWithCap(_price, size);
        
        _consumedFunds += mulDivUp(_price, _remainingSize);
        
        _consumeFunds(quoteAsset, (((_consumedFunds) * 10**quoteAssetDecimals) / pricePrecision), msg.sender);
        if (_postOnly) {
            require(size == _remainingSize, "OrderBook: Post only crossed the book");
        }
        if (_remainingSize > 0) {
            uint40 _orderId = s_orderIdCounter;
            s_orderIdCounter = _orderId + 1;

            // Add price to the tree and update DLL of price poit.
            TreeMath.add(s_buyTree, _price);
            uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_buyPricePoints[_price], _orderId + 1);

            _addOrder(_price, _remainingSize, _orderId + 1, true, _prevOrderId);

            emit OrderCreated(_orderId + 1, msg.sender, _remainingSize, _price, true);
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
        uint256 _tokenCredit;
        _consumeFunds(baseAsset, ((size * 10**baseAssetDecimals) / sizePrecision), msg.sender);

        (size, _tokenCredit) = _matchAggressiveSell(_price, size, true);
        if (_postOnly) {
            require(_tokenCredit == 0, "OrderBook: Post only crossed the book");
        }

        if (size == 0) return;

        uint40 _orderId = s_orderIdCounter;
        s_orderIdCounter = _orderId + 1;
        // Add price to the tree and update DLL of price poit.
        TreeMath.add(s_sellTree, _price);
        uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_sellPricePoints[_price], _orderId + 1);
        _addOrder(_price, size, _orderId + 1, false, _prevOrderId);

        emit OrderCreated(_orderId + 1, msg.sender, size, _price, false);
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
            if(_orderId == s_buyPricePoints[_order.price].head) {
                OrderLinkedList.updateHead(s_buyPricePoints[_order.price], _order.next);
            }
            OrderLinkedList.deleteOrder(s_buyPricePoints[_order.price], _order.prev, _order.next);
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
            addBuyOrder(buyPrices[i], buySizes[i], postOnly);
        }

        // Place multiple sell orders
        for (uint256 i = 0; i < sellPrices.length; i++) {
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
        (_quoteSize, _baseTokensCredited) = _matchAggressiveBuy(type(uint24).max, _quoteSize, false);
        if (_quoteSize > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            if (_type == OrderBookType.NATIVE_IN_QUOTE) {
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
        return _baseTokensCredited;
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(
        uint96 _size,
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

        return _quoteCredited;
    }

    function _handleNativeMarketRefundTransfer(uint256 _refund) internal {
        (bool _success, ) = address(marginAccount).call{value: msg.value - _refund}("");
        require(_success, "OrderBook: MarginAccount native transfer failed");
        (_success, ) = address(msg.sender).call{value: _refund}("");
        require(_success, "OrderBook: Refund failed");
    }

    function _matchAggressiveBuyWithCap(uint24 _limitPrice, uint96 _size) internal returns(uint96, uint24) {
        uint96 _sizeToGet;
        uint24 _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);
        uint24 fundsConsumed = 0;

        bytes memory makerCredits;
        while (_size > 0 && _bestAsk <= _limitPrice && _bestAsk != 0) {
            bytes memory priceUpdate;
            uint96 sizeBefore = _size; // Capture the size before filling

            (_size, priceUpdate) = _fillSizeForPrice(s_sellTree, _bestAsk, s_sellPricePoints[_bestAsk], _size);

            uint96 sizeFilled = sizeBefore - _size; // Calculate the filled size
            _sizeToGet += sizeFilled;

            // @audit This might make you consume lesser than what has to be consumed because of rounding down.
            fundsConsumed += mulDivUp(_bestAsk, sizeFilled);
            /// round up
            // ++fundsConsumed;
            makerCredits = bytes.concat(makerCredits, priceUpdate);
            
            _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);
        }

        if (_sizeToGet > 0) {
            uint256 _tokenCredit = ((((_sizeToGet) * (BPS_MULTIPLIER - takerFeeBps)) / BPS_MULTIPLIER ) * 10**baseAssetDecimals) / sizePrecision;
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(baseAsset), _tokenCredit, true)));
        } else if (makerCredits.length > 0) {
            marginAccount.creditUsersEncoded(makerCredits);
        }

        return (_size, fundsConsumed);
    }


    /**
     * @dev Match limit buy orders if it crosses the book.
     * @param _limitPrice Price of the buy order.
     * @param _quoteSize amount of quote asset user is ready to pay.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function _matchAggressiveBuy(uint24 _limitPrice, uint24 _quoteSize, bool _useMargin) internal returns(uint24, uint256) {
        uint96 _sizeToGet;
        uint24 _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);
        uint256 _tokenCredit;
        bytes memory makerCredits;
        while (_quoteSize > 0 && _bestAsk <= _limitPrice && _bestAsk != 0) {
            uint96 _size = _quoteSize * sizePrecision / _bestAsk;
            
            bytes memory priceUpdate;
            _sizeToGet += _size;
            (_size, priceUpdate) = _fillSizeForPrice(s_sellTree, _bestAsk, s_sellPricePoints[_bestAsk], _size);
            _sizeToGet -= _size;
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            _quoteSize = uint24((_bestAsk * _size) / sizePrecision);
            
            _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);
        }

        if (_sizeToGet > 0) {
            _tokenCredit = ((_sizeToGet * (BPS_MULTIPLIER - takerFeeBps)) / (BPS_MULTIPLIER)) * 10**baseAssetDecimals / sizePrecision;
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(baseAsset), _tokenCredit, _useMargin)));
        } else if (makerCredits.length > 0) {
            marginAccount.creditUsersEncoded(makerCredits);
        }

        return (_quoteSize, _tokenCredit);
    }

    /**
     * 
     * @param _limitPrice Price of the sell order.
     * @param size Size of the sell order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function _matchAggressiveSell(uint24 _limitPrice, uint96 size, bool _useMargin) internal returns(uint96, uint256) {
        uint24 _priceToGet = 0;
        uint24 _bestBid = TreeMath.findFirstRight(s_buyTree, type(uint24).max);
        uint256 _tokenCredit;
        bytes memory makerCredits;
        while (size > 0 && _bestBid >= _limitPrice && _bestBid != type(uint24).max) {
            uint96 _tmpSize = size;

            bytes memory priceUpdate;
            (size, priceUpdate) = _fillSizeForPrice(s_buyTree, _bestBid, s_buyPricePoints[_bestBid], size);
            _priceToGet += uint24((_tmpSize - size) * _bestBid / sizePrecision);

            makerCredits = bytes.concat(makerCredits, priceUpdate);

            _bestBid = TreeMath.findFirstRight(s_buyTree, type(uint24).max);
        }

        if (_priceToGet > 0) {
            _tokenCredit = ((_priceToGet * (BPS_MULTIPLIER - takerFeeBps) / BPS_MULTIPLIER) * 10**quoteAssetDecimals) / pricePrecision;
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(quoteAsset), _tokenCredit, _useMargin)));
        } else if (makerCredits.length > 0) {
            marginAccount.creditUsersEncoded(makerCredits);
        }

        return (size, _tokenCredit);
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
            bytes memory orderUpdate;
            (remainingSize, _orderId, orderUpdate) = _fillOrder(_orderId, remainingSize);
            makerCredits = bytes.concat(makerCredits, orderUpdate);
        }
        //Enforce head 
        // s_orders[_orderId].prev = OrderLinkedList.NULL;
        OrderLinkedList.updateHead(_pricePoint, _orderId);

        if (_orderId == OrderLinkedList.NULL) {
            TreeMath.remove(_tree, _price);
        }
    }

    /**
     * @notice Fills an order and credits the maker, possibly removing the order if fully filled.
     * @dev Attempts to fill order `_orderId` with size `_size`. Credits maker and removes order if fully filled.
     * @param _orderId The ID of the order to fill.
     * @param _size The size to fill.
     * @return remainingSize The remaining size after attempting to fill this order.
     * @return _nextHead next head of the price point.
     */
    function _fillOrder(uint40 _orderId, uint96 _size) internal returns (uint96 remainingSize, uint40 _nextHead, bytes memory _orderUpdate) {
        _nextHead = s_orders[_orderId].next;
        uint96 _orderSize = s_orders[_orderId].size;
        remainingSize = (_size > _orderSize) ? (_size - _orderSize) : 0;
        uint96 _updatedSize;
        if(remainingSize == 0) {
            _updatedSize = _orderSize - _size;
        }
        _orderUpdate = _creditMaker(!s_orders[_orderId].isBuy, s_orders[_orderId].ownerAddress, (remainingSize == 0) ? _size : s_orders[_orderId].size, s_orders[_orderId].price);

        //@audit cancel order vulnerability, check later
        if (remainingSize == 0 || (_nextHead == OrderLinkedList.NULL && s_orders[_orderId].prev == OrderLinkedList.NULL)) {
            if (_updatedSize != 0) {
                _nextHead = _orderId;
            }
            s_orders[_orderId].size = _updatedSize;
        }
        // What if the whole book gets filled or the whole price point gets filled up?
        emit Trade(_orderId, s_orders[_orderId].ownerAddress, s_orders[_orderId].isBuy, s_orders[_orderId].price, _updatedSize, msg.sender, _size - remainingSize);
    }

    /**
    * internal helper function to calculate quote amounts with correct math
    * @param _price The price of the order.
    * @param _size The size of the order
     */
    function mulDivUp(uint24 _price, uint96 _size) internal returns (uint24) {
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

        return abi.encode(_ownerAddress, creditAsset, amount, true);
    }

    /**
     * internal helper function to get payable amount
     * @param _size size of token
     * @param _price conversion price from A to B
     */
    function _amountPayable(uint96 _size, uint24 _price) internal view returns (uint256) {
        return (uint256(uint24((_price * _size) / sizePrecision)) * 10**quoteAssetDecimals) / pricePrecision;
    }

    /**
     * @dev Getter of market params.
     */
    // TODO: Should add fees in this as well.
    function getMarketParams() external view returns (uint24, uint96, address, uint256, address, uint256, uint96, uint256) {
        return (pricePrecision, sizePrecision, address(baseAsset), baseAssetDecimals, address(quoteAsset), quoteAssetDecimals, minSize, takerFeeBps);
    }

    /**
     * @dev Getter function to fetch price precision.
     */
    function getPricePrecision() external view returns (uint24) {
        return pricePrecision;
    }

    /**
     * @dev Getter function to fetch size precision.
     */
    function getSizePrecision() external view returns (uint96) {
        return sizePrecision;
    }

    /**
     * @dev Getter function to fetch decimals of base asset.
     */
    function getBaseAssetDecimals() external view returns (uint256) {
        return baseAssetDecimals;
    }

    /**
     * @dev Getter function to fetch decimals of quote asset.
     */
    function getQuoteAssetDecimals() external view returns (uint256) {
        return quoteAssetDecimals;
    }
    
    function buyOrdersLeft() external view returns (bool) {
        if(TreeMath.findFirstRight(s_buyTree, type(uint24).max) != type(uint24).max) {
            return true;
        }
        return false;
    }

    function sellOrdersLeft() external view returns (bool) {
        if(TreeMath.findFirstLeft(s_sellTree,0) != 0) {
            return true;
        }
        return false;
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
            price = TreeMath.findFirstLeft(s_buyTree, price + 1);
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
            price = TreeMath.findFirstLeft(s_sellTree, price + 1);
        }

        return data;
    }

    /**
     * @notice Returns the active buy orders for a given address.
     * @param _maker The address of the order maker.
     * @return Encoded bytes containing the block number and order IDs of the active buy orders.
     */
    function getActiveBuysForAddress(address _maker) external view returns (bytes memory) {
        bytes memory data = abi.encode(block.number);

        uint24 price = TreeMath.findFirstLeft(s_buyTree, 0);
        while (price != type(uint24).max && price != 0) {
            uint40 orderId = s_buyPricePoints[price].head;
            while (orderId != 0) {
                if (s_orders[orderId].ownerAddress == _maker) {
                    data = bytes.concat(data, abi.encode(orderId));
                }
                orderId = s_orders[orderId].next;
            }
            price = TreeMath.findFirstLeft(s_buyTree, price + 1);
        }

        return data;
    }

    /**
     * @notice Returns the active sell orders for a given address.
     * @param _maker The address of the order maker.
     * @return Encoded bytes containing the block number and order IDs of the active sell orders.
     */
    function getActiveSellsForAddress(address _maker) external view returns (bytes memory) {
        bytes memory data = abi.encode(block.number);

        uint24 price = TreeMath.findFirstLeft(s_sellTree, 0);
        while (price != type(uint24).max && price != 0) {
            uint40 orderId = s_sellPricePoints[price].head;
            while (orderId != 0) {
                if (s_orders[orderId].ownerAddress == _maker) {
                    data = bytes.concat(data, abi.encode(orderId));
                }
                orderId = s_orders[orderId].next;
            }
            price = TreeMath.findFirstLeft(s_sellTree, price + 1);
        }

        return data;
    }

    /**
     * @notice Returns all active orders (both buy and sell) for a given address.
     * @param _maker The address of the order maker.
     * @return Encoded bytes containing the block number and order IDs of all active orders.
     */
    function getActiveOrdersForAddress(address _maker) external view returns (bytes memory) {
        bytes memory data = abi.encode(block.number);

        // Get active buy orders
        uint24 price = TreeMath.findFirstLeft(s_buyTree, 0);
        while (price != type(uint24).max && price != 0) {
            uint40 orderId = s_buyPricePoints[price].head;
            while (orderId != 0) {
                if (s_orders[orderId].ownerAddress == _maker) {
                    data = bytes.concat(data, abi.encode(orderId));
                }
                orderId = s_orders[orderId].next;
            }
            price = TreeMath.findFirstLeft(s_buyTree, price + 1);
        }

        // Get active sell orders
        price = TreeMath.findFirstLeft(s_sellTree, 0);
        while (price != type(uint24).max && price != 0) {
            uint40 orderId = s_sellPricePoints[price].head;
            while (orderId != 0) {
                if (s_orders[orderId].ownerAddress == _maker) {
                    data = bytes.concat(data, abi.encode(orderId));
                }
                orderId = s_orders[orderId].next;
            }
            price = TreeMath.findFirstLeft(s_sellTree, price + 1);
        }

        return data;
    }

    /**
     * @notice Get the details of an order and its status.
     * @param _orderId The ID of the order to retrieve.
     * @return The order details and its status code.
     *         Status code:
     *         0 - Canceled order
     *         1 - Filled order
     *         2 - Active order
     */
    function getOrderDetails(uint40 _orderId) external view returns (Order memory, uint256) {
        Order memory _order = s_orders[_orderId];
        
        if (_order.prev != OrderLinkedList.NULL) {
            if (s_orders[_order.prev].next != _orderId) {
                return (_order, 0);
            }

            if (_order.isBuy) {
                if (s_buyPricePoints[_order.price].head > _orderId) {
                    return (_order, 1);
                }
            } else {
                if (s_sellPricePoints[_order.price].head > _orderId) {
                    return (_order, 1);
                }
            }
        } else {
            if (_order.isBuy) {
                if (s_buyPricePoints[_order.price].head != _orderId) {
                    if (_order.next == OrderLinkedList.NULL && _order.size == 0) {
                        return (_order, 1);
                    }
                    if (_order.next != OrderLinkedList.NULL && s_orders[_order.next].prev == _orderId) {
                        return (_order, 1);
                    }
                    return (_order, 0);
                }
            } else {
                if (s_sellPricePoints[_order.price].head != _orderId) {
                    if (_order.next == OrderLinkedList.NULL && _order.size == 0) {
                        return (_order, 1);
                    }
                    if (_order.next != OrderLinkedList.NULL && s_orders[_order.next].prev == _orderId) {
                        return (_order, 1);
                    }
                    return (_order, 0);
                }
            }
        }

        return (_order, 2);
    }
}