// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";

// ============ Internal Interfaces Imports ============
import {ICranklessStorageOrderBook} from "./interfaces/ICranklessStorageOrderBook.sol";

// ============ Internal Contracts Imports ============
import {IERC20} from "./libraries/IERC20.sol";
import {MarginAccount} from  "./MarginAccount.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


// size is 10**10
// price is 10**2
contract CranklessStorageOrderBook is ICranklessStorageOrderBook, OwnableUpgradeable {
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
     * @dev Emitted when one or more orders are executed partially/completely by buy taker orders.
     * @param takerAddress Address of the taker.
     * corresponds to the order ID at the same index in the `orderIds` array.
     */
    event BuyIOC(
        address takerAddress,
        uint96 orderSize
    );

    /**
     * @dev Emitted when one or more orders are executed partially/completely by sell taker orders.
     * @param takerAddress Address of the taker.
     * corresponds to the order ID at the same index in the `orderIds` array.
     */
    event SellIOC(
        address takerAddress,
        uint96 orderSize
    );

    /**
     * @dev Emitted when one or more orders are updated.
     * @param orderIds Array of order identifiers that were updated.
     * @param updatedSizes Array of new sizes for the corresponding orders. Each size
     * corresponds to the order ID at the same index in the `orderIds` array.
     */
    event OrdersUpdated(
        uint40[] orderIds,
        uint96[] updatedSizes
    );

    event OrderUpdated(
        uint40 orderId,
        uint96 updatedSize,
        address takerAddress,
        uint96 filledSize
    );

    /**
     * @dev Emitted when one or more orders are completed or canceled.
     * @param orderId Array of order identifiers that were completed or canceled.
     */
    event OrdersCanceled(
        uint40[] orderId
    );

    mapping(uint40 => Order) public s_orders;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_buyPricePoints;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_sellPricePoints;
    TreeMath.TreeUint24 public s_buyTree;
    TreeMath.TreeUint24 public s_sellTree;

    uint40 public s_orderIdCounter;

    bool marketPaused;

    uint96 immutable sizePrecision;
    uint24 immutable pricePrecision;

    uint96 immutable tickSize;
    uint96 immutable minSize;
    uint96 immutable maxSize;

    // TODO: might have to be public
    uint256 immutable takerFeeBps;
    // TODO: add maker fee

    IERC20 immutable baseAsset;
    IERC20 immutable quoteAsset;
    MarginAccount immutable marginAccount;

    uint256 immutable baseAssetDecimals;
    uint256 immutable quoteAssetDecimals;

    uint256 constant BPS_MULTIPLIER = 10000;

    /**
     * @dev Constructor.
     * @param _baseAssetAddress Address of the first token used for trading.
     * @param _baseAssetDecimals Deciimal pricicsion of the first swap token.
     * @param _quoteAssetAddress Address of the second token used for trading.
     * @param _quoteAssetDecimals Deciimal pricicsion of the first swap token.
     */
    constructor (
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
        uint256 _takerFeeBps
    ) {
        baseAsset = IERC20(_baseAssetAddress);
        quoteAsset = IERC20(_quoteAssetAddress);

        baseAssetDecimals = _baseAssetDecimals;
        quoteAssetDecimals = _quoteAssetDecimals;

        marginAccount = MarginAccount(_marginAccountAddress);
        // initialize contract parameters
        sizePrecision = _sizePrecision;
        pricePrecision = _pricePrecision;
        tickSize = _tickSize;
        minSize = _minSize;
        maxSize = _maxSize;
        takerFeeBps = _takerFeeBps;
    }

    modifier marketActive() {
        require(!marketPaused, "OrderBook: market is paused");
        _;
    }

    /**
     * @param _owner The owner of the contract.
     */
    function initialize(address _owner) public initializer {
        __Ownable_init();
        _transferOwnership(_owner);
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
    function addBuyOrder(uint24 _price, uint96 size) public marketActive {
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");
        
        uint96 _remainingSize;
        uint24 _consumedFunds;
        (_remainingSize, _consumedFunds) = _matchAggressiveBuyWithCap(_price, size);
        _consumedFunds += uint24((_remainingSize * _price)/sizePrecision);

        _consumeFunds(quoteAsset, (((_consumedFunds) * 10**quoteAssetDecimals) / pricePrecision), msg.sender);

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
    function addSellOrder(uint24 _price, uint96 size) public marketActive {
        require(size > minSize, "OrderBook: Size too low");
        require(size < maxSize, "OrderBook: Size too large");
        require(_price % tickSize == 0, "OrderBook: Tick Size");

        _consumeFunds(baseAsset, ((size * 10**baseAssetDecimals) / sizePrecision), msg.sender);

        size = _matchAggressiveSell(_price, size, true);

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

        emit OrdersCanceled(_orderIds);
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
                ((((_order.size * _order.price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision),
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

    /// @notice Checks if an order has been cancelled before, and reverts if true
    /// Items to check : 
    /// 1. s_orders[id.prev].next = id
    /// 2. if prev == NULL, check for head requirement 
    /// 3. price point's head must be BEFORE or the SAME as order id (time priority constraint)
    /// @param _orderId ID of the order 
    /// @param _order Order details in memory
    function _checkIfCancelledOrFilled(uint40 _orderId, Order memory _order) internal view {
        if(_order.prev != OrderLinkedList.NULL) {
            require(s_orders[_order.prev].next == _orderId, "OrderBook: Order already cancelled");

            if(_order.isBuy) {
            require(s_buyPricePoints[_order.price].head <= _orderId, "Already filled!");
            }
            else {
                require(s_sellPricePoints[_order.price].head <= _orderId, "Already filled!");
            }

        } 
        else {
            if(_order.isBuy) {
                require(s_buyPricePoints[_order.price].head == _orderId, "OrderBook: Order already cancelled");
            }
            else {
                require(s_sellPricePoints[_order.price].head == _orderId, "OrderBook: Order already cancelled");
            }
        }
    }

    /**
     * @dev Decreases the size of multiple orders.
     * This function allows a user to decrease the size of multiple orders they own.
     * It iterates over the provided order IDs and updates their sizes accordingly.
     * @param _orderIds Array of order IDs to be decreased in size.
     * @param _updatedSizes Array of new sizes for the orders. Each size corresponds to the order ID at the same index in the _orderIds array.
     */
    function decreaseOrders(uint40[] calldata _orderIds, uint96[] calldata _updatedSizes, bool _useMargin) external marketActive {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _decreaseOrder(_orderIds[i], _updatedSizes[i], _useMargin);
        }

        emit OrdersUpdated(_orderIds, _updatedSizes);
    }

    /**
     * @dev Internal function to decrease the size of a single order.
     * This function updates the size of an order and manages the refund process.
     * It is called by decreaseOrders for each order that needs to be updated.
     * @param _orderId ID of the order to be decreased in size.
     * @param _updatedSize New size for the order. Must be less than the current size.
     */
    function _decreaseOrder(uint40 _orderId, uint96 _updatedSize, bool _useMargin) internal {
        Order memory _order = s_orders[_orderId];
        _checkIfCancelledOrFilled(_orderId, _order);
        require(msg.sender == _order.ownerAddress, "OrderBook: Only order owner can update order");
        require(_order.size > _updatedSize, "OrderBook: can't increase order size");
        require(_updatedSize > minSize, "Orderbook: size has to be greater than minimum");

        uint96 _decreasedSize = _order.size - _updatedSize;

        if (_order.isBuy) {
            marginAccount.creditUser(
                _order.ownerAddress,
                address(quoteAsset),
                ((((_decreasedSize * _order.price) * 10**quoteAssetDecimals) / pricePrecision) / sizePrecision),
                _useMargin
            );
        } else {
            marginAccount.creditUser(
                _order.ownerAddress,
                address(baseAsset),
                ((_decreasedSize * 10**baseAssetDecimals) / sizePrecision),
                _useMargin
            );
        }

        s_orders[_orderId].size = _updatedSize;
    }

    /**
     * @dev Places multiple limit buy orders in a single function call.
     * @param _prices Array of prices for the buy orders.
     * @param _sizes Array of sizes for the buy orders.
     */
    function placeMultipleBuyOrders(uint24[] calldata _prices, uint96[] calldata _sizes) external marketActive {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addBuyOrder(_prices[i], _sizes[i]);
        }
    }

    /**
     * @dev Places multiple limit sell orders in a single function call.
     * @param _prices Array of prices for the sell orders.
     * @param _sizes Array of sizes for the sell orders.
     */
    function placeMultipleSellOrders(uint24[] calldata _prices, uint96[] calldata _sizes) external marketActive {
        require(_prices.length == _sizes.length, "OrderBook: Prices and sizes array length must match");

        for (uint256 i = 0; i < _prices.length; i++) {
            addSellOrder(_prices[i], _sizes[i]);
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
    ) public override marketActive {
        uint24 _initQuoteSize = _quoteSize;
        quoteAsset.transferFrom(msg.sender, address(marginAccount), uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision));
        _quoteSize = _matchAggressiveBuy(type(uint24).max, _quoteSize, false);
        if (_quoteSize > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");
            marginAccount.creditUser(
                msg.sender,
                address(quoteAsset),
                uint256(_quoteSize * 10 ** quoteAssetDecimals / pricePrecision),
                false
            );
        }

        emit BuyIOC(msg.sender, _initQuoteSize - _quoteSize);
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _isFillOrKill bool representing if function should revert if full qty is not recieved.
     */
    function placeAndExecuteMarketSell(
        uint96 _size,
        bool _isFillOrKill
    ) public marketActive{
        // Transfer the base asset from the user to the contract
        uint96 _initSize = _size;
        baseAsset.transferFrom(
            msg.sender,
            address(marginAccount),
            (_size * 10 ** baseAssetDecimals) / sizePrecision
        );

        _size = _matchAggressiveSell(0, _size, false);

        if (_size > 0) {
            require(!_isFillOrKill, "OrderBook: insufficient volume on book");

            marginAccount.creditUser(
                msg.sender,
                address(baseAsset),
                ((_size * 10 ** baseAssetDecimals) / sizePrecision),
                false
            );
        }

        emit SellIOC(msg.sender, _initSize - _size);
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

            // @audit: This might make you consume lesser than what has to be consumed because of rounding down.
            fundsConsumed += uint24((sizeFilled * _bestAsk)/sizePrecision);

            makerCredits = bytes.concat(makerCredits, priceUpdate);
            
            _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);
        }

        if (_sizeToGet > 0) {
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(baseAsset), (_sizeToGet) * 10 ** quoteAssetDecimals * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * BPS_MULTIPLIER), true)));
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
    function _matchAggressiveBuy(uint24 _limitPrice, uint24 _quoteSize, bool _useMargin) internal returns(uint24) {
        uint96 _sizeToGet;
        uint24 _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);

        bytes memory makerCredits;
        while (_quoteSize > 0 && _bestAsk <= _limitPrice && _bestAsk != 0) {
            uint96 _size = _quoteSize * sizePrecision / _bestAsk;
            
            bytes memory priceUpdate;
            _sizeToGet += _size;
            (_size, priceUpdate) = _fillSizeForPrice(s_sellTree, _bestAsk, s_sellPricePoints[_bestAsk], _size);
            _sizeToGet -= _size;

            makerCredits = bytes.concat(makerCredits, priceUpdate);

            _quoteSize = uint24(_size * _bestAsk / sizePrecision);
            
            _bestAsk = TreeMath.findFirstLeft(s_sellTree, 0);
        }

        if (_sizeToGet > 0) {
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(baseAsset), (_sizeToGet) * 10 ** quoteAssetDecimals * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * BPS_MULTIPLIER), _useMargin)));
        } else if (makerCredits.length > 0) {
            marginAccount.creditUsersEncoded(makerCredits);
        }

        return _quoteSize;
    }

    /**
     * 
     * @param _limitPrice Price of the sell order.
     * @param size Size of the sell order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function _matchAggressiveSell(uint24 _limitPrice, uint96 size, bool _useMargin) internal returns(uint96) {
        uint96 _priceToGet = 0;
        uint24 _bestBid = TreeMath.findFirstRight(s_buyTree, type(uint24).max);

        bytes memory makerCredits;
        while (size > 0 && _bestBid >= _limitPrice && _bestBid != type(uint24).max) {
            uint96 _tmpSize = size;

            bytes memory priceUpdate;
            (size, priceUpdate) = _fillSizeForPrice(s_buyTree, _bestBid, s_buyPricePoints[_bestBid], size);
            _priceToGet += (_tmpSize - size) * _bestBid;

            makerCredits = bytes.concat(makerCredits, priceUpdate);

            _bestBid = TreeMath.findFirstRight(s_buyTree, type(uint24).max);
        }

        if (_priceToGet > 0) {
            marginAccount.creditUsersEncoded(bytes.concat(makerCredits, abi.encode(msg.sender, address(quoteAsset), (((_priceToGet * 10 ** quoteAssetDecimals)) * (BPS_MULTIPLIER - takerFeeBps) / (sizePrecision * pricePrecision * BPS_MULTIPLIER)), _useMargin)));
        } else if (makerCredits.length > 0) {
            marginAccount.creditUsersEncoded(makerCredits);
        }

        return size;
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
        if (remainingSize == 0) {
            if (_updatedSize != 0) {
                _nextHead = _orderId;
            }
            s_orders[_orderId].size -= _size;
        }
        // What if the whole book gets filled or the whole price point gets filled up?
        emit OrderUpdated(_orderId, _updatedSize, msg.sender, _size - remainingSize);
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
        uint256 amount = _isMarketBuy ? _amountPayable(_size, _price) : ((_size * 10 ** baseAssetDecimals) / sizePrecision);

        return abi.encode(_ownerAddress, creditAsset, amount, true);
    }

    /**
     * internal helper function to get payable amount
     * @param _size size of token
     * @param _price conversion price from A to B
     */
    function _amountPayable(uint96 _size, uint96 _price) internal view returns (uint256) {
        return (_size * _price  * 10 ** quoteAssetDecimals / (pricePrecision * sizePrecision));
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

    function getL2Book() external view returns (bytes memory) {
        bytes memory data = abi.encode(block.number);

        uint24 price = TreeMath.findFirstLeft(s_buyTree, 0); // Find the smallest ID in the tree
        while (price != type(uint24).max || price == 0) {
            uint40 orderId = s_buyPricePoints[price].head;
            uint96 _size = 0;
            while (orderId != 0) {
                _size += s_orders[orderId].size;
                orderId = s_orders[orderId].next;
            }

            data = bytes.concat(data, abi.encode(price, _size));
            // Find the next ID
            price = TreeMath.findFirstLeft(s_buyTree, price + 1);
            if (price == 0) break; // If there is no higher ID, stop the iteration
        }

        data = bytes.concat(data, abi.encode(0));

        price = TreeMath.findFirstLeft(s_sellTree, 0); // Find the smallest ID in the tree
        while (price != type(uint24).max || price == 0) {
            uint40 orderId = s_sellPricePoints[price].head;
            uint96 _size = 0;
            while (orderId != 0) {
                _size += s_orders[orderId].size;
                orderId = s_orders[orderId].next;
            }

            data = bytes.concat(data, abi.encode(price, _size));
            // Find the next ID
            price = TreeMath.findFirstLeft(s_sellTree, price + 1);
            if (price == 0) break; // If there is no higher ID, stop the iteration
        }

        return data;
    }

}
