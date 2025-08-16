// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============ Library Imports ============
import {OrderLinkedList} from "./libraries/OrderLinkedList.sol";
import {TreeMath} from "./libraries/TreeMath.sol";
import {OrderBookErrors} from "./libraries/Errors.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {ERC2771Context} from "./libraries/ERC2771Context.sol";
import {AbstractAMM} from "./AbstractAMM.sol";

// ============ Internal Contracts Imports ============
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

// ============ External Imports ============
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

contract OrderBook is Initializable, UUPSUpgradeable, ERC2771Context, AbstractAMM {
    OrderBookType orderBookType;
    address owner;
    address _trustedForwarder;

    using SafeTransferLib for address;

    mapping(uint40 => Order) public s_orders;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_buyPricePoints;
    mapping(uint256 => OrderLinkedList.PricePoint) public s_sellPricePoints;
    TreeMath.TreeUint32 public s_buyTree;
    TreeMath.TreeUint32 public s_sellTree;

    uint40 public s_orderIdCounter;
    MarketState public marketState;

    uint96 internal sizePrecision;
    uint32 internal pricePrecision;
    uint256 internal takerFeeBps;
    uint256 internal makerFeeBps;

    uint256 internal baseAssetDecimals;
    uint256 internal baseDecimalMultiplier;
    uint256 internal quoteAssetDecimals;
    uint256 internal quoteDecimalMultiplier;
    address internal baseAsset;
    address internal quoteAsset;

    uint32 tickSize;
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
        require(marketState == MarketState.ACTIVE, OrderBookErrors.MarketStateError());
        _;
    }

    modifier marketNotHardPaused() override {
        require(marketState != MarketState.HARD_PAUSED, OrderBookErrors.MarketStateError());
        _;
    }

    function isTrustedForwarder(address forwarder) public view virtual override returns (bool) {
        return forwarder == _trustedForwarder;
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
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        address _kuruAmmVault,
        uint96 _kuruAmmSpread,
        address __trustedForwarder
    ) public initializer {
        owner = _owner;

        require(_makerFeeBps <= _takerFeeBps && _takerFeeBps < BPS_MULTIPLIER, OrderBookErrors.MarketFeeError());
        require(_kuruAmmSpread % 10 == 0 && _kuruAmmSpread > 0 && _kuruAmmSpread < 500, OrderBookErrors.InvalidSpread());
        require(_minSize > 0 && _maxSize > _minSize, OrderBookErrors.MarketSizeError());
        orderBookType = _type;
        baseAsset = _baseAssetAddress;
        quoteAsset = _quoteAssetAddress;

        baseAssetDecimals = _baseAssetDecimals;
        baseDecimalMultiplier = 10 ** _baseAssetDecimals;
        quoteAssetDecimals = _quoteAssetDecimals;
        quoteDecimalMultiplier = 10 ** _quoteAssetDecimals;

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
        SPREAD_CONSTANT = _kuruAmmSpread;
        vaultBestAsk = type(uint256).max;
        _trustedForwarder = __trustedForwarder;
    }

    function _checkOwner() internal view {
        require(msg.sender == owner, OrderBookErrors.Unauthorized());
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
    function toggleMarket(MarketState _state) external {
        _checkOwner();
        require(_state != marketState, OrderBookErrors.MarketStateError());
        marketState = _state;
        emit MarketStateUpdated(marketState, _state);
    }

    /**
     * @dev Allows admin to transfer ownership of the contract.
     * @param _newOwner The new owner of the contract.
     */
    function transferOwnership(address _newOwner) external {
        _checkOwner();
        owner = _newOwner;
    }

    /**
     * @dev Adds a buy order to the order book.
     * @param _price Price of the buy order.
     * @param size Size of the buy order.
     * @param _postOnly Whether the order is post-only. The transaction reverts if the order is matched while placing.
     */
    function addBuyOrder(uint32 _price, uint96 size, bool _postOnly) public marketActive nonReentrant {
        require(_price > 0 && _price < type(uint32).max, OrderBookErrors.PriceError());
        require(size > minSize, OrderBookErrors.SizeError());
        require(size < maxSize, OrderBookErrors.SizeError());
        require(_price % tickSize == 0, OrderBookErrors.TickSizeError());

        //The buy order is filled aggressively and the leftover size is added as a limit buy order
        (uint96 _remainingSize, uint96 _consumedFunds) = _matchAggressiveBuyWithCap(uint256(_price), size);

        _consumedFunds += _quoteAmountRoundedUp(_price, _remainingSize);

        _consumeFunds(quoteAsset, (((_consumedFunds) * quoteDecimalMultiplier) / pricePrecision), _msgSender());
        if (_postOnly) {
            require(size == _remainingSize, OrderBookErrors.PostOnlyError());
        }
        if (_remainingSize == 0) {
            return;
        } else {
            uint40 _orderId = s_orderIdCounter + 1;
            s_orderIdCounter = _orderId;

            // Add price to the tree and update DLL of price point.
            uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_buyPricePoints[_price], _orderId);

            _addOrder(_price, _remainingSize, _orderId, true, _prevOrderId);
        }
    }

    /**
     * @notice Flip orders are not eligible for maker rebates as takers pay for the flipping.
     * @dev Adds a flip buy order to the order book. This function will just return if it matches against the book.
     * @param _price Price of the buy order.
     * @param _flippedPrice Price of the sell order to which this order will flip on a fill
     * @param _size Size of the buy order.
     * @param _provisionOrRevert The transaction reverts if this is set to true and the flip order matches on placement.
     */
    function addFlipBuyOrder(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _provisionOrRevert)
        public
        marketActive
        nonReentrant
    {
        require(_price > 0 && _flippedPrice > 0 && _flippedPrice < type(uint32).max, OrderBookErrors.PriceError());
        require(_price % tickSize == 0 && _flippedPrice % tickSize == 0, OrderBookErrors.TickSizeError());
        require(_price < _flippedPrice, OrderBookErrors.PriceError());
        require(_size > minSize && _size < maxSize, OrderBookErrors.SizeError());

        {
            (, uint256 _bestAsk) = bestAsk();
            if ((uint256(_price) * vaultPricePrecision / pricePrecision) >= _bestAsk && _bestAsk != 0) {
                if (_provisionOrRevert) {
                    revert OrderBookErrors.ProvisionError();
                } else {
                    return;
                }
            }
        }
        _consumeFunds(
            quoteAsset, _quoteAmountRoundedUp(_price, _size) * quoteDecimalMultiplier / pricePrecision, _msgSender()
        );

        uint40 _orderId = s_orderIdCounter + 1;
        s_orderIdCounter = _orderId;
        uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_buyPricePoints[_price], _orderId);
        _addFlipOrder(_price, _flippedPrice, _size, _msgSender(), _orderId, OrderLinkedList.NULL, true, _prevOrderId);
    }

    /**
     * @dev Adds a sell order to the order book.
     * @param _price Price of the sell order.
     * @param _size Size of the sell order.
     * @param _postOnly Whether the order is post-only. The transaction reverts if the order is matched while placing.
     */
    function addSellOrder(uint32 _price, uint96 _size, bool _postOnly) public marketActive nonReentrant {
        require(_size > minSize, OrderBookErrors.SizeError());
        require(_size < maxSize, OrderBookErrors.SizeError());
        require(_price % tickSize == 0, OrderBookErrors.TickSizeError());
        require(_price > 0 && _price < type(uint32).max, OrderBookErrors.PriceError());

        _consumeFunds(baseAsset, ((_size * baseDecimalMultiplier) / sizePrecision), _msgSender());

        // uint256 _tokenCredit;
        //The sell order is matched and filled aggressively and remaining size is added as limit sell order
        (uint96 _remainingSize,) = _matchAggressiveSell(uint256(_price), _size, true);
        if (_postOnly) {
            require(_remainingSize == _size, OrderBookErrors.PostOnlyError());
        }

        if (_remainingSize == 0) {
            return;
        } else {
            uint40 _orderId = s_orderIdCounter + 1;
            s_orderIdCounter = _orderId;
            // Add price to the tree and update DLL of price point.
            uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_sellPricePoints[_price], _orderId);
            _addOrder(_price, _remainingSize, _orderId, false, _prevOrderId);
        }
    }

    /**
     * @notice Flip orders are not eligible for maker rebates as takers pay for the flipping.
     * @dev Adds a flip sell order to the order book. This function will just return if it matches against the book.
     * @param _price Price of the sell order.
     * @param _flippedPrice Price of the buy order to which this order will flip on a fill
     * @param _size Size of the sell order.
     * @param _provisionOrRevert The transaction reverts if this is set to true and the flip order matches on placement.
     */
    function addFlipSellOrder(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _provisionOrRevert)
        public
        marketActive
        nonReentrant
    {
        require(_price > 0 && _flippedPrice > 0 && _price < type(uint32).max, OrderBookErrors.PriceError());
        require(_price % tickSize == 0 && _flippedPrice % tickSize == 0, OrderBookErrors.TickSizeError());
        require(_price > _flippedPrice, OrderBookErrors.PriceError());
        require(_size > minSize && _size < maxSize, OrderBookErrors.SizeError());

        {
            (, uint256 _bestBid) = bestBid();
            if ((uint256(_price) * vaultPricePrecision / pricePrecision) <= _bestBid && _bestBid != type(uint256).max) {
                if (_provisionOrRevert) {
                    revert OrderBookErrors.ProvisionError();
                } else {
                    return;
                }
            }
        }

        _consumeFunds(baseAsset, _size * baseDecimalMultiplier / sizePrecision, _msgSender());
        uint40 _orderId = s_orderIdCounter + 1;
        s_orderIdCounter = _orderId;
        uint40 _prevOrderId = OrderLinkedList.insertAtTail(s_sellPricePoints[_price], _orderId);
        _addFlipOrder(_price, _flippedPrice, _size, _msgSender(), _orderId, OrderLinkedList.NULL, false, _prevOrderId);
    }

    /**
     * @notice Flip orders are not eligible for maker rebates as takers pay for the flipping.
     * @dev Adds a paired liquidity order to the order book. This function will revert if the order matches against the book.
     * @param _bidPrice Price of the bid order.
     * @param _askPrice Price of the ask order.
     * @param _bidSize Size of the bid order.
     * @param _askSize Size of the ask order.
     */
    function addPairedLiquidity(uint32 _bidPrice, uint32 _askPrice, uint96 _bidSize, uint96 _askSize)
        public
        marketActive
        nonReentrant
    {
        require(_bidPrice > 0 && _askPrice > _bidPrice && _askPrice < type(uint32).max, OrderBookErrors.PriceError());
        require(_bidPrice % tickSize == 0 && _askPrice % tickSize == 0, OrderBookErrors.TickSizeError());
        require(_bidSize > minSize && _bidSize < maxSize, OrderBookErrors.SizeError());
        require(_askSize > minSize && _askSize < maxSize, OrderBookErrors.SizeError());
        {
            (, uint256 _bestBid) = bestBid();
            (, uint256 _bestAsk) = bestAsk();
            require(
                ((uint256(_bidPrice) * vaultPricePrecision / pricePrecision) < _bestAsk) || (_bestAsk == 0),
                OrderBookErrors.ProvisionError()
            );
            require(
                ((uint256(_askPrice) * vaultPricePrecision / pricePrecision) > _bestBid)
                    || (_bestBid == type(uint256).max),
                OrderBookErrors.ProvisionError()
            );
        }

        _consumeFunds(
            quoteAsset,
            _quoteAmountRoundedUp(_bidPrice, _bidSize) * quoteDecimalMultiplier / pricePrecision,
            _msgSender()
        );
        _consumeFunds(baseAsset, _askSize * baseDecimalMultiplier / sizePrecision, _msgSender());

        uint40 _bidOrderId = s_orderIdCounter + 1;
        uint40 _askOrderId = _bidOrderId + 1;
        s_orderIdCounter = _askOrderId;

        uint40 _bidPrevOrderId = OrderLinkedList.insertAtTail(s_buyPricePoints[_bidPrice], _bidOrderId);
        uint40 _askPrevOrderId = OrderLinkedList.insertAtTail(s_sellPricePoints[_askPrice], _askOrderId);
        _addFlipOrder(_bidPrice, _askPrice, _bidSize, _msgSender(), _bidOrderId, _askOrderId, true, _bidPrevOrderId);
        _addFlipOrder(_askPrice, _bidPrice, _askSize, _msgSender(), _askOrderId, _bidOrderId, false, _askPrevOrderId);
    }

    /**
     * @dev Internal function to add an order to the order book.
     * @param _price Price of the order.
     * @param _size Size of the order.
     * @param _orderId ID of the order.
     * @param _isBuy Whether the order is a buy order.
     * @param _prevOrderId ID of the previous order in the linked list.
     */
    function _addOrder(uint32 _price, uint96 _size, uint40 _orderId, bool _isBuy, uint40 _prevOrderId) internal {
        if (_isBuy) {
            TreeMath.add(s_buyTree, _price);
        } else {
            TreeMath.add(s_sellTree, _price);
        }
        s_orders[_orderId] =
            Order(_msgSender(), _size, _prevOrderId, OrderLinkedList.NULL, OrderLinkedList.NULL, _price, 0, _isBuy);
        if (_prevOrderId != OrderLinkedList.NULL) {
            s_orders[_prevOrderId].next = _orderId;
        }
        emit OrderCreated(_orderId, _msgSender(), _size, _price, _isBuy);
    }

    /**
     * @dev Internal function to add a flip order to the order book.
     * @param _price Price of the order.
     * @param _flippedPrice Price which the order will flip to on a fill.
     * @param _size Size of the order.
     * @param _owner Address of the owner of the order.
     * @param _orderId ID of the order.
     * @param _flippedId ID of the flipped order on the other side, in case of a paired liquidity order.
     * @param _isBuy Whether the order is a buy order.
     * @param _prevOrderId ID of the previous order in the linked list.
     */
    function _addFlipOrder(
        uint32 _price,
        uint32 _flippedPrice,
        uint96 _size,
        address _owner,
        uint40 _orderId,
        uint40 _flippedId,
        bool _isBuy,
        uint40 _prevOrderId
    ) internal {
        if (_isBuy) {
            TreeMath.add(s_buyTree, _price);
        } else {
            TreeMath.add(s_sellTree, _price);
        }
        s_orders[_orderId] =
            Order(_owner, _size, _prevOrderId, OrderLinkedList.NULL, _flippedId, _price, _flippedPrice, _isBuy);
        s_orders[_prevOrderId].next = _orderId;
        emit FlipOrderCreated(_orderId, _flippedId, _owner, _size, _price, _flippedPrice, _isBuy);
    }

    /**
     * @dev Internal function to add a flipped order to the order book. This function is called when a flip order is filled for the first time
     * @param _price Price of the order.
     * @param _flippedPrice Price which the order will flip to on a fill.
     * @param _size Size of the order.
     * @param _owner Address of the owner of the order.
     * @param _orderId ID of the order.
     * @param _flippedId ID of the flipped order on the other side, which is the flip order that was filled.
     * @param _isBuy Whether the order is a buy order.
     * @param _prevOrderId ID of the previous order in the linked list.
     */
    function _addFlippedOrder(
        uint32 _price,
        uint32 _flippedPrice,
        uint96 _size,
        address _owner,
        uint40 _orderId,
        uint40 _flippedId,
        bool _isBuy,
        uint40 _prevOrderId
    ) internal {
        if (_isBuy) {
            TreeMath.add(s_buyTree, _price);
        } else {
            TreeMath.add(s_sellTree, _price);
        }
        s_orders[_orderId] =
            Order(_owner, _size, _prevOrderId, OrderLinkedList.NULL, _flippedId, _price, _flippedPrice, _isBuy);
        s_orders[_prevOrderId].next = _orderId;
        emit FlippedOrderCreated(_orderId, _flippedId, _owner, _size, _price, _flippedPrice, _isBuy);
    }

    /**
     * @dev Consumes funds required to create a GTC order.
     * @param _consumableAsset Address of the asset that is being consumed by the market.
     * @param _amount Amount of _consumableAssets that should be consumed by the market.
     * @param _userAddress Address of the the user creating the order.
     */
    function _consumeFunds(address _consumableAsset, uint256 _amount, address _userAddress) internal {
        marginAccount.debitUser(_userAddress, _consumableAsset, _amount);
    }

    /**
     * @notice If you cancel a flip order, both sides of the order pair will be cancelled. You cannot cancel one side of the order pair alone.
     * @dev Cancels multiple flip orders in a batch. For a flip order pair, you only need to input ID of one of the orders.
     * @param _orderIds Array of order IDs to cancel.
     */
    function batchCancelFlipOrders(uint40[] calldata _orderIds) external marketNotHardPaused {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _cancelFlipOrder(_orderIds[i]);
        }

        emit FlipOrdersCanceled(_orderIds, _msgSender());
    }

    /**
     * @dev Cancels multiple orders in a batch.
     * @dev Reverts if you pass an order ID which is filled or cancelled already.
     * @param _orderIds Array of order IDs to cancel.
     */
    function batchCancelOrders(uint40[] calldata _orderIds) external marketNotHardPaused {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            _cancelOrder(_orderIds[i], true);
        }

        emit OrdersCanceled(_orderIds, _msgSender());
    }

    /**
     * @dev Cancels multiple orders in a batch.
     * @dev Does not revert if you pass an order ID which is filled or cancelled already.
     * @param _orderIds Array of order IDs to cancel.
     */
    function batchCancelOrdersNoRevert(uint40[] calldata _orderIds) external marketNotHardPaused {
        uint40[] memory _orderIdsCanceled = new uint40[](_orderIds.length);
        for (uint256 i = 0; i < _orderIds.length; i++) {
            bool _isCanceled = _cancelOrder(_orderIds[i], false);
            if (_isCanceled) {
                _orderIdsCanceled[i] = _orderIds[i];
            } else {
                _orderIdsCanceled[i] = 0;
            }
        }

        emit OrdersCanceled(_orderIdsCanceled, _msgSender());
    }

    /**
     * @dev Internal function to cancel both sides of a flip order pair.
     * @param _orderId ID of the order to cancel.
     */
    function _cancelFlipOrder(uint40 _orderId) internal nonReentrant {
        Order memory _order = s_orders[_orderId];
        require(!_checkIfCancelledOrFilled(_orderId, _order), OrderBookErrors.OrderAlreadyFilledOrCancelled());
        require(_msgSender() == _order.ownerAddress, OrderBookErrors.OnlyOwnerAllowedError());
        require(_order.flippedPrice != 0, OrderBookErrors.WrongOrderTypeCancel());
        if (_order.flippedId != OrderLinkedList.NULL) {
            _executeCancel(_order.flippedId, s_orders[_order.flippedId]);
        }
        _executeCancel(_orderId, _order);
    }

    /**
     * @dev Internal helper function to cancel a single order.
     * @param _orderId ID of the order to cancel.
     */
    function _cancelOrder(uint40 _orderId, bool _revertIfInvalid) internal nonReentrant returns (bool) {
        Order memory _order = s_orders[_orderId];
        require(_msgSender() == _order.ownerAddress, OrderBookErrors.OnlyOwnerAllowedError());
        require(_order.flippedPrice == 0, OrderBookErrors.WrongOrderTypeCancel());
        if (_checkIfCancelledOrFilled(_orderId, _order)) {
            if (_revertIfInvalid) {
                revert OrderBookErrors.OrderAlreadyFilledOrCancelled();
            } else {
                return false;
            }
        }
        _executeCancel(_orderId, _order);
        return true;
    }

    /**
     * @dev Internal function to cancel an order. This does all necessary state changes and credits the user.
     * @param _orderId ID of the order to cancel.
     * @param _order Order details in memory.
     */
    function _executeCancel(uint40 _orderId, Order memory _order) internal {
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
            } else {
                OrderLinkedList.adjustForTail(s_buyPricePoints[_order.price], _order.prev, _order.next);
            }

            marginAccount.creditUser(
                _order.ownerAddress,
                quoteAsset,
                (((toU96((_order.size * _order.price) / sizePrecision) * quoteDecimalMultiplier) / pricePrecision)),
                true
            );
        } else {
            if (_orderId == s_sellPricePoints[_order.price].head) {
                OrderLinkedList.updateHead(s_sellPricePoints[_order.price], _order.next);
                if (_order.next == OrderLinkedList.NULL) {
                    //If there are no more orders remaining in price point, we can remove the price point
                    TreeMath.remove(s_sellTree, _order.price);
                }
            } else {
                OrderLinkedList.adjustForTail(s_sellPricePoints[_order.price], _order.prev, _order.next);
            }

            marginAccount.creditUser(
                _order.ownerAddress, baseAsset, ((_order.size * baseDecimalMultiplier) / sizePrecision), true
            );
        }

        emit OrderCanceled(_orderId, _order.ownerAddress, _order.price, _order.size, _order.isBuy);
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
    function _checkIfCancelledOrFilled(uint40 _orderId, Order memory _order) internal view returns (bool) {
        if (_order.prev != OrderLinkedList.NULL) {
            if (s_orders[_order.prev].next != _orderId) {
                return true;
            }
            if (_order.isBuy) {
                //Since all orders are filled FCFS in each price point, if head > order id, it means order id was already filled
                uint40 _head = s_buyPricePoints[_order.price].head;
                if (_head > _orderId || _head == OrderLinkedList.NULL) {
                    return true;
                }
                return false;
            } else {
                uint40 _head = s_sellPricePoints[_order.price].head;
                if (_head > _orderId || _head == OrderLinkedList.NULL) {
                    return true;
                }
                return false;
            }
        } else {
            if (_order.isBuy) {
                if (s_buyPricePoints[_order.price].head != _orderId) {
                    return true;
                }
                return false;
            } else {
                if (s_sellPricePoints[_order.price].head != _orderId) {
                    return true;
                }
                return false;
            }
        }
    }

    /**
     * @notice Flip orders are not eligible for maker rebates as takers pay for the flipping.
     * @dev Batch adds paired liquidity to the order book.
     * @param bidPrices Array of prices for the bid orders.
     * @param askPrices Array of prices for the ask orders.
     * @param bidSizes Array of sizes for the bid orders.
     * @param askSizes Array of sizes for the ask orders.
     */
    function batchAddPairedLiquidity(
        uint32[] calldata bidPrices,
        uint32[] calldata askPrices,
        uint96[] calldata bidSizes,
        uint96[] calldata askSizes
    ) external {
        require(
            bidPrices.length == bidSizes.length && askPrices.length == askSizes.length, OrderBookErrors.LengthMismatch()
        );
        for (uint256 i = 0; i < bidPrices.length; i++) {
            addPairedLiquidity(bidPrices[i], askPrices[i], bidSizes[i], askSizes[i]);
        }
    }

    /**
     * @notice Flip orders are not eligible for maker rebates as takers pay for the flipping.
     * @dev Batch adds flip orders to the order book.
     * @param prices Array of prices for the flip orders.
     * @param flipPrices Array of prices for the flip orders.
     * @param sizes Array of sizes for the flip orders.
     * @param isBuy Array of booleans indicating if the i'th order is a buy order
     * @param _provisionOrRevert If set to true, if a flip order matches against the book, the transaction reverts.
     */
    function batchProvisionLiquidity(
        uint32[] calldata prices,
        uint32[] calldata flipPrices,
        uint96[] calldata sizes,
        bool[] calldata isBuy,
        bool _provisionOrRevert
    ) external {
        require(prices.length == flipPrices.length, OrderBookErrors.LengthMismatch());
        require(sizes.length == isBuy.length, OrderBookErrors.LengthMismatch());
        require(prices.length == sizes.length, OrderBookErrors.LengthMismatch());
        for (uint256 i = 0; i < prices.length; i++) {
            if (isBuy[i]) {
                addFlipBuyOrder(prices[i], flipPrices[i], sizes[i], _provisionOrRevert);
            } else {
                addFlipSellOrder(prices[i], flipPrices[i], sizes[i], _provisionOrRevert);
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
        uint32[] calldata buyPrices,
        uint96[] calldata buySizes,
        uint32[] calldata sellPrices,
        uint96[] calldata sellSizes,
        uint40[] calldata orderIdsToCancel,
        bool postOnly
    ) external marketNotHardPaused {
        // Ensure that the lengths of the buy prices and sizes match
        require(buyPrices.length == buySizes.length, OrderBookErrors.LengthMismatch());

        // Ensure that the lengths of the sell prices and sizes match
        require(sellPrices.length == sellSizes.length, OrderBookErrors.LengthMismatch());

        uint40[] memory orderIdsCanceled = new uint40[](orderIdsToCancel.length);
        // Cancel multiple orders
        for (uint256 i = 0; i < orderIdsToCancel.length; i++) {
            bool _isCanceled = _cancelOrder(orderIdsToCancel[i], false);
            if (_isCanceled) {
                orderIdsCanceled[i] = orderIdsToCancel[i];
            } else {
                orderIdsCanceled[i] = 0;
            }
        }

        // Place multiple buy orders
        for (uint256 i = 0; i < buyPrices.length; i++) {
            addBuyOrder(buyPrices[i], buySizes[i], postOnly);
        }

        // Place multiple sell orders
        for (uint256 i = 0; i < sellPrices.length; i++) {
            addSellOrder(sellPrices[i], sellSizes[i], postOnly);
        }

        // Emit an event for the canceled orders
        if (orderIdsCanceled.length > 0) {
            emit OrdersCanceled(orderIdsCanceled, _msgSender());
        }
    }

    /**
     * @dev Places and executes a market buy order.
     * @param _quoteSize amount of quote asset user is ready to pay.
     * @param _minAmountOut minimum amount of base asset user is willing to receive in base asset decimals.
     * @param _isMargin bool representing if the market order is to be debited from the margin account of the user.
     * @param _isFillOrKill bool representing if function should revert if full qty is not received.
     * @return _baseTokensCredited amount of base asset user received in base asset decimals.
     */
    function placeAndExecuteMarketBuy(uint96 _quoteSize, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        public
        payable
        override
        marketActive
        nonReentrant
        returns (uint256)
    {
        OrderBookType _type = orderBookType;

        if (_type == OrderBookType.NATIVE_IN_QUOTE && !_isMargin && (msg.sender != address(0))) {
            require(
                msg.value >= _pricePrecisionToQuoteAssetPrecision(_quoteSize), OrderBookErrors.NativeAssetInsufficient()
            );
            require(
                msg.value < _pricePrecisionToQuoteAssetPrecision(_quoteSize + 1), OrderBookErrors.NativeAssetSurplus()
            );
        } else if (msg.sender != address(0)) {
            require(msg.value == 0, OrderBookErrors.NativeAssetNotRequired());
            _isMargin
                ? marginAccount.debitUser(_msgSender(), quoteAsset, _pricePrecisionToQuoteAssetPrecision(_quoteSize))
                : quoteAsset.safeTransferFrom(
                    _msgSender(), address(marginAccount), _pricePrecisionToQuoteAssetPrecision(_quoteSize)
                );
        }

        uint256 _baseTokensCredited;
        (_quoteSize, _baseTokensCredited) = _marketBuyMatch(_quoteSize, _isMargin);
        if (msg.sender == address(0)) {
            return _baseTokensCredited;
        }
        if (_quoteSize > 0) {
            require(!_isFillOrKill, OrderBookErrors.InsufficientLiquidity());
            if (_type == OrderBookType.NATIVE_IN_QUOTE && !_isMargin) {
                //There are no more writes to the state after this, so read only reentrancies should be avoided
                uint256 _refund = _pricePrecisionToQuoteAssetPrecision(_quoteSize);
                _handleNativeMarketRefundTransfer(_refund);
            } else {
                marginAccount.creditUser(
                    _msgSender(), quoteAsset, _pricePrecisionToQuoteAssetPrecision(_quoteSize), _isMargin
                );
            }
        } else if (_type == OrderBookType.NATIVE_IN_QUOTE) {
            address(marginAccount).safeTransferETH(msg.value);
        }
        require(_baseTokensCredited >= _minAmountOut, OrderBookErrors.SlippageExceeded());

        return _baseTokensCredited;
    }

    /**
     * @dev Places and executes a market sell order.
     * @param _size Size of the market sell order.
     * @param _minAmountOut minimum amount of quote asset user is willing to receive in quote asset decimals.
     * @param _isMargin bool representing if the market order is to be debited from the margin account of the user.
     * @param _isFillOrKill bool representing if function should revert if full qty is not received.
     * @return _quoteCredited amount of quote asset user received in quote asset decimals.
     */
    function placeAndExecuteMarketSell(uint96 _size, uint256 _minAmountOut, bool _isMargin, bool _isFillOrKill)
        public
        payable
        marketActive
        nonReentrant
        returns (uint256)
    {
        OrderBookType _type = orderBookType;
        if (_type == OrderBookType.NATIVE_IN_BASE && !_isMargin && (msg.sender != address(0))) {
            require(msg.value >= _sizePrecisionToBaseAssetPrecision(_size), OrderBookErrors.NativeAssetInsufficient());
            require(msg.value < _sizePrecisionToBaseAssetPrecision(_size + 1), OrderBookErrors.NativeAssetSurplus());
        } else if (msg.sender != address(0)) {
            require(msg.value == 0, OrderBookErrors.NativeAssetNotRequired());
            _isMargin
                ? marginAccount.debitUser(_msgSender(), baseAsset, _sizePrecisionToBaseAssetPrecision(_size))
                : baseAsset.safeTransferFrom(
                    _msgSender(), address(marginAccount), _sizePrecisionToBaseAssetPrecision(_size)
                );
        }

        uint256 _quoteCredited;
        (_size, _quoteCredited) = _matchAggressiveSell(0, _size, _isMargin);
        if (msg.sender == address(0)) {
            return _quoteCredited;
        }
        if (_size > 0) {
            require(!_isFillOrKill, OrderBookErrors.InsufficientLiquidity());
            if (_type == OrderBookType.NATIVE_IN_BASE && !_isMargin) {
                uint256 _refund = _sizePrecisionToBaseAssetPrecision(_size);
                _handleNativeMarketRefundTransfer(_refund);
            } else {
                marginAccount.creditUser(_msgSender(), baseAsset, _sizePrecisionToBaseAssetPrecision(_size), _isMargin);
            }
        } else if (_type == OrderBookType.NATIVE_IN_BASE) {
            address(marginAccount).safeTransferETH(msg.value);
        }
        require(_quoteCredited >= _minAmountOut, OrderBookErrors.SlippageExceeded());
        return _quoteCredited;
    }

    /**
     * @dev Internal function to credit native token refunds for market orders
     * @param _refund The native token refund to be credited to the taker
     */
    function _handleNativeMarketRefundTransfer(uint256 _refund) internal {
        address(marginAccount).safeTransferETH(msg.value - _refund);
        _msgSender().safeTransferETH(_refund);
    }

    function _pricePrecisionToQuoteAssetPrecision(uint96 _quote) internal view returns (uint256) {
        return (uint256(_quote) * quoteDecimalMultiplier) / pricePrecision;
    }

    function _sizePrecisionToBaseAssetPrecision(uint96 _size) internal view returns (uint256) {
        return (uint256(_size) * baseDecimalMultiplier) / sizePrecision;
    }

    /**
     * @dev Calls the creditFee function in MarginAccount
     * @notice Anyone can call this function
     */
    function collectFees() external {
        uint256 _baseFeeCollected = baseFeeCollected;
        uint256 _quoteFeeCollected = quoteFeeCollected;
        baseFeeCollected = 0;
        quoteFeeCollected = 0;
        marginAccount.creditFee(baseAsset, _baseFeeCollected, quoteAsset, _quoteFeeCollected);
    }

    function _matchAggressiveBuyWithCap(uint256 _limitPrice, uint96 _sizeToBeFilled)
        internal
        returns (uint96, uint96)
    {
        uint96 sizeToCreditTaker;
        uint96 sizeToCreditViaVault;
        uint96 fundsConsumed;
        bytes memory makerCredits;
        (bool _isVaultFill, uint256 _bestAsk) = bestAsk();
        uint32 _pricePrecision = pricePrecision;
        _limitPrice = _limitPrice * vaultPricePrecision / _pricePrecision;

        while (_sizeToBeFilled > 0 && _bestAsk <= _limitPrice && _bestAsk != 0) {
            uint96 sizeToBeFilledBefore = _sizeToBeFilled; // Capture the size before filling
            bytes memory priceUpdate;

            if (_isVaultFill) {
                uint96 _vaultFundsConsumed;
                (_sizeToBeFilled, _vaultFundsConsumed, priceUpdate) =
                    _fillVaultForBuy(_getOBAsk() > _limitPrice ? _limitPrice + 1 : _getOBAsk(), _sizeToBeFilled);
                fundsConsumed += _vaultFundsConsumed;
            } else {
                (_sizeToBeFilled, priceUpdate) = _fillSizeForPrice(
                    s_sellTree,
                    toU32(_bestAsk * _pricePrecision / vaultPricePrecision),
                    s_sellPricePoints[_bestAsk * _pricePrecision / vaultPricePrecision],
                    _sizeToBeFilled
                );
            }

            uint96 sizeFilled = sizeToBeFilledBefore - _sizeToBeFilled;
            sizeToCreditTaker += sizeFilled;
            if (_isVaultFill) {
                sizeToCreditViaVault += sizeFilled;
            } else {
                fundsConsumed += _quoteAmountRoundedUp(
                    toU32(FixedPointMathLib.mulDivUp(_bestAsk, _pricePrecision, vaultPricePrecision)), sizeFilled
                );
            }
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestAsk) = bestAsk();
        }

        if (sizeToCreditTaker == 0) {
            return (_sizeToBeFilled, 0);
        }
        {
            uint96 _sizePrecision = sizePrecision;
            uint256 _baseDecimalMultiplier = baseDecimalMultiplier;
            uint256 _tokenCredit = (sizeToCreditTaker * _baseDecimalMultiplier) / _sizePrecision;
            if (sizeToCreditViaVault > 0) {
                marginAccount.debitUser(
                    kuruAmmVault, baseAsset, (sizeToCreditViaVault * _baseDecimalMultiplier) / _sizePrecision
                );
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                // Calculate what ratio of fee goes to the protocol
                baseFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            marginAccount.creditUsersEncoded(
                bytes.concat(makerCredits, abi.encode(_msgSender(), baseAsset, _tokenCredit, true))
            );
        }

        return (_sizeToBeFilled, fundsConsumed);
    }

    /**
     * @dev Match limit buy orders if it crosses the book.
     * @param _quoteSize amount of quote asset user is ready to pay.
     */
    function _marketBuyMatch(uint96 _quoteSize, bool _isMargin) internal returns (uint96, uint256) {
        uint96 sizeToCreditTaker;
        uint96 sizeToCreditViaVault;
        bytes memory makerCredits;
        uint32 _pricePrecision = pricePrecision;
        uint96 _sizePrecision = sizePrecision;

        (bool _isVaultFill, uint256 _bestAsk) = bestAsk();

        while (_quoteSize > 0 && _bestAsk != 0) {
            bytes memory priceUpdate;
            if (_isVaultFill) {
                uint96 _sizeFilled;
                (_quoteSize, _sizeFilled, priceUpdate) = _fillVaultBuyMatch(_getOBAsk(), _quoteSize);
                sizeToCreditViaVault += _sizeFilled;
                sizeToCreditTaker += _sizeFilled;
            } else {
                // Calculate base size fillable by current unconsumed quote size for a particular price
                uint96 _sizeFillableAtPriceLeft =
                    toU96(_quoteSize * _sizePrecision * vaultPricePrecision / (_bestAsk * _pricePrecision));
                uint96 _sizeFillableAtPriceBefore = _sizeFillableAtPriceLeft; // Save old size to be filled
                (_sizeFillableAtPriceLeft, priceUpdate) = _fillSizeForPrice(
                    s_sellTree,
                    toU32(_bestAsk * _pricePrecision / vaultPricePrecision),
                    s_sellPricePoints[(_bestAsk * _pricePrecision / vaultPricePrecision)],
                    _sizeFillableAtPriceLeft
                );
                sizeToCreditTaker += (_sizeFillableAtPriceBefore - _sizeFillableAtPriceLeft);
                _quoteSize = toU96(
                    FixedPointMathLib.mulDiv(
                        _bestAsk * _pricePrecision, _sizeFillableAtPriceLeft, _sizePrecision * vaultPricePrecision
                    )
                );
            }
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestAsk) = bestAsk();
        }

        if (sizeToCreditTaker == 0) {
            return (_quoteSize, 0);
        }

        {
            uint256 _baseDecimalMultiplier = baseDecimalMultiplier;
            uint256 _tokenCredit = (sizeToCreditTaker * _baseDecimalMultiplier) / _sizePrecision;
            if (sizeToCreditViaVault > 0 && msg.sender != address(0)) {
                marginAccount.debitUser(
                    kuruAmmVault, baseAsset, (sizeToCreditViaVault * _baseDecimalMultiplier) / _sizePrecision
                );
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(_tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                _tokenCredit -= _feeDebit;
                // Calculate protocol fee part of total fee
                baseFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            if (msg.sender != address(0)) {
                marginAccount.creditUsersEncoded(
                    bytes.concat(makerCredits, abi.encode(_msgSender(), baseAsset, _tokenCredit, _isMargin))
                );
            }
            return (_quoteSize, _tokenCredit);
        }
    }

    /**
     *
     * @param _limitPrice Price of the sell order.
     * @param _sizeToBeFilledLeft Size of the sell order.
     * @param _useMargin Bool representing whether the asset be consumed from the user's margin account.
     */
    function _matchAggressiveSell(uint256 _limitPrice, uint96 _sizeToBeFilledLeft, bool _useMargin)
        internal
        returns (uint96, uint256)
    {
        uint96 quoteCreditTaker;
        uint256 quoteCreditVaultTaker;
        uint256 tokenCredit;
        (bool _isVaultFill, uint256 _bestBid) = bestBid();
        bytes memory makerCredits;
        uint32 _pricePrecision = pricePrecision;
        _limitPrice = _limitPrice * vaultPricePrecision / _pricePrecision;
        while (_sizeToBeFilledLeft > 0 && _bestBid >= _limitPrice && _bestBid != type(uint256).max) {
            uint96 _sizeToBeFilledBefore = _sizeToBeFilledLeft; //save size left to fill

            bytes memory priceUpdate;

            if (_isVaultFill) {
                uint256 _quoteToTaker;
                (_sizeToBeFilledLeft, _quoteToTaker, priceUpdate) =
                    _fillVaultForSell(_getOBBid() >= _limitPrice ? _getOBBid() : _limitPrice - 1, _sizeToBeFilledLeft);
                quoteCreditVaultTaker += _quoteToTaker;
            } else {
                (_sizeToBeFilledLeft, priceUpdate) = _fillSizeForPrice(
                    s_buyTree,
                    toU32(_bestBid * _pricePrecision / vaultPricePrecision),
                    s_buyPricePoints[_bestBid * _pricePrecision / vaultPricePrecision],
                    _sizeToBeFilledLeft
                );
                quoteCreditTaker += toU96(
                    FixedPointMathLib.mulDiv(
                        _sizeToBeFilledBefore - _sizeToBeFilledLeft,
                        toU32(_bestBid * _pricePrecision / vaultPricePrecision),
                        sizePrecision
                    )
                );
            }
            makerCredits = bytes.concat(makerCredits, priceUpdate);

            (_isVaultFill, _bestBid) = bestBid();
        }

        if (quoteCreditTaker == 0 && quoteCreditVaultTaker == 0) {
            return (_sizeToBeFilledLeft, 0);
        }
        {
            uint256 _quoteDecimalMultiplier = quoteDecimalMultiplier;
            tokenCredit = ((quoteCreditTaker) * _quoteDecimalMultiplier) / _pricePrecision
                + (quoteCreditVaultTaker * _quoteDecimalMultiplier) / vaultPricePrecision;
            if (quoteCreditVaultTaker > 0 && msg.sender != address(0)) {
                marginAccount.debitUser(
                    kuruAmmVault, quoteAsset, (quoteCreditVaultTaker * _quoteDecimalMultiplier) / vaultPricePrecision
                );
            }
            uint256 _takerFeeBps = takerFeeBps;
            if (_takerFeeBps > 0) {
                uint256 _feeDebit = FixedPointMathLib.mulDivUp(tokenCredit, _takerFeeBps, BPS_MULTIPLIER);
                tokenCredit -= _feeDebit;
                //Calculate protocol fee part of total fee
                quoteFeeCollected += ((_feeDebit * (_takerFeeBps - makerFeeBps)) / _takerFeeBps);
            }
            if (msg.sender != address(0)) {
                marginAccount.creditUsersEncoded(
                    bytes.concat(makerCredits, abi.encode(_msgSender(), quoteAsset, tokenCredit, _useMargin))
                );
            }
        }

        return (_sizeToBeFilledLeft, tokenCredit);
    }

    /**
     * @notice Exhaustively fills the required size at a specific price point.
     * @dev Iterates through orders at `_pricePoint` to fill the order size `_size`.
     * @param _pricePoint The price point to fill orders against.
     * @param _size The size of the order to be filled.
     * @return remainingSize The size remaining unfilled.
     */
    function _fillSizeForPrice(
        TreeMath.TreeUint32 storage _tree,
        uint32 _price,
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
     * filled partially:
     * 1. if flip order id does not exist, make it and transfer size there
     * 2. if it exists, transfer size there
     * filled fully:
     * 1. everything remains same except we need to transfer size and change flip order id param of the order's flip order to null
     */

    /**
     * @notice Fills an order and credits the maker, possibly removing the order if fully filled.
     * @dev Attempts to fill order `_orderId` with size `_size`. Credits maker and removes order if fully filled.
     * @param _orderId The ID of the order to fill.
     * @param _incomingSizeToBeFilled The size to fill.
     * @return incomingOrderRemainingSize The remaining size after attempting to fill this order.
     * @return _nextHead next head of the price point.
     * @return _orderUpdate bytes encoded data for crediting the maker of the order
     */
    function _fillOrder(uint40 _orderId, uint96 _incomingSizeToBeFilled)
        internal
        returns (uint96 incomingOrderRemainingSize, uint40 _nextHead, bytes memory _orderUpdate)
    {
        _nextHead = s_orders[_orderId].next;
        uint96 _preExistingOrderSize = s_orders[_orderId].size;
        //remaining size is 0 if current order can fully fill required size
        incomingOrderRemainingSize =
            (_incomingSizeToBeFilled > _preExistingOrderSize) ? (_incomingSizeToBeFilled - _preExistingOrderSize) : 0;
        uint96 _preExistingOrderUpdatedSize;
        if (incomingOrderRemainingSize == 0) {
            //if order is partially filled, update its size
            _preExistingOrderUpdatedSize = _preExistingOrderSize - _incomingSizeToBeFilled;
        }
        if (s_orders[_orderId].flippedPrice == 0) {
            _orderUpdate = _creditMaker(
                !s_orders[_orderId].isBuy,
                s_orders[_orderId].ownerAddress,
                (incomingOrderRemainingSize == 0) ? _incomingSizeToBeFilled : s_orders[_orderId].size,
                s_orders[_orderId].price
            );
        }

        if (incomingOrderRemainingSize == 0) {
            if (_preExistingOrderUpdatedSize != 0) {
                _nextHead = _orderId;
            }
            s_orders[_orderId].size = _preExistingOrderUpdatedSize;
        }

        if (s_orders[_orderId].flippedPrice != 0) {
            _handleFlipOrderUpdate(
                _orderId,
                _incomingSizeToBeFilled - incomingOrderRemainingSize,
                _preExistingOrderUpdatedSize == 0 ? true : false
            );
        }
        // What if the whole book gets filled or the whole price point gets filled up?
        _emitTrade(
            _orderId,
            s_orders[_orderId].ownerAddress,
            !s_orders[_orderId].isBuy,
            (s_orders[_orderId].price * vaultPricePrecision) / pricePrecision,
            _preExistingOrderUpdatedSize,
            _incomingSizeToBeFilled - incomingOrderRemainingSize
        );
    }

    function _handleFlipOrderUpdate(uint40 _orderId, uint96 _size, bool nullify) internal {
        //check if flip order id exists
        if (s_orders[_orderId].flippedId == OrderLinkedList.NULL) {
            Order memory _filledOrder = s_orders[_orderId];
            //create flip order
            uint40 _flipOrderId = s_orderIdCounter + 1;
            s_orderIdCounter = _flipOrderId;
            uint40 _prevOrderId;
            if (!s_orders[_orderId].isBuy) {
                _size = toU96(FixedPointMathLib.mulDiv(_size, _filledOrder.price, _filledOrder.flippedPrice));
                _prevOrderId = OrderLinkedList.insertAtTail(s_buyPricePoints[_filledOrder.flippedPrice], _flipOrderId);
            } else {
                _prevOrderId = OrderLinkedList.insertAtTail(s_sellPricePoints[_filledOrder.flippedPrice], _flipOrderId);
            }
            if (!nullify) {
                s_orders[_orderId].flippedId = _flipOrderId;
            }
            _addFlippedOrder(
                _filledOrder.flippedPrice,
                _filledOrder.price,
                _size,
                _filledOrder.ownerAddress,
                _flipOrderId,
                nullify ? OrderLinkedList.NULL : _orderId,
                !_filledOrder.isBuy,
                _prevOrderId
            );
        } else {
            //transfer size
            uint40 _flipOrderId = s_orders[_orderId].flippedId;
            if (!s_orders[_orderId].isBuy) {
                _size =
                    toU96(FixedPointMathLib.mulDiv(_size, s_orders[_orderId].price, s_orders[_orderId].flippedPrice));
            }
            uint96 _updatedSize = s_orders[_flipOrderId].size + _size;
            s_orders[_flipOrderId].size = _updatedSize;
            emit FlipOrderUpdated(_flipOrderId, _updatedSize);
            if (nullify) {
                s_orders[_flipOrderId].flippedId = OrderLinkedList.NULL;
            }
        }
    }

    function _emitTrade(
        uint40 orderId,
        address makerAddress,
        bool isBuy,
        uint256 price,
        uint96 updatedSize,
        uint96 filledSize
    ) internal override {
        emit Trade(orderId, makerAddress, isBuy, price, updatedSize, _msgSender(), tx.origin, filledSize);
    }

    /**
     * internal helper function to calculate quote amounts with correct math
     * @param _price The price of the order.
     * @param _size The size of the order
     */
    function _quoteAmountRoundedUp(uint32 _price, uint96 _size) internal view returns (uint96) {
        uint256 _result = FixedPointMathLib.mulDivUp(_price, _size, sizePrecision);
        return toU96(_result);
    }

    /**
     * @notice Credits the maker of an order.
     * @dev Credits the maker's account based on the order details. Optimized by consolidating repetitive logic.
     * @param _isMarketBuy Whether the order is a market buy.
     * @param _ownerAddress The address of the order's maker.
     * @param _size The size of the order being credited.
     * @param _price The price of the order.
     */
    function _creditMaker(bool _isMarketBuy, address _ownerAddress, uint96 _size, uint32 _price)
        internal
        view
        returns (bytes memory)
    {
        address creditAsset = _isMarketBuy ? quoteAsset : baseAsset;
        uint256 amount =
            _isMarketBuy ? _quoteAmountRoundedDown(_size, _price) : ((_size * baseDecimalMultiplier) / sizePrecision);
        uint256 feeRebate;
        address feeAsset;
        bytes memory returnData;
        if (_isMarketBuy) {
            feeAsset = baseAsset;
            feeRebate = (((_size * baseDecimalMultiplier) / sizePrecision) * makerFeeBps) / BPS_MULTIPLIER;
        } else {
            feeAsset = quoteAsset;
            feeRebate = (_quoteAmountRoundedDown(_size, _price) * makerFeeBps) / BPS_MULTIPLIER;
        }
        //feeRebate only exists if makerFeeBps > 0
        if (feeRebate > 0) {
            returnData = abi.encode(_ownerAddress, feeAsset, feeRebate, true);
        }

        return bytes.concat(returnData, abi.encode(_ownerAddress, creditAsset, amount, true));
    }

    /**
     * internal helper function to get payable amount
     * @param _size filled size
     * @param _price price at which the size is filled
     */
    function _quoteAmountRoundedDown(uint256 _size, uint32 _price) internal view returns (uint256) {
        return ((_price * _size) / sizePrecision) * quoteDecimalMultiplier / pricePrecision;
    }

    function _getPricePrecision() internal view override returns (uint32) {
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
        returns (uint32, uint96, address, uint256, address, uint256, uint32, uint96, uint96, uint256, uint256)
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

    function _getOBAsk() internal view returns (uint256) {
        uint32 firstLeft = TreeMath.findFirstLeft(s_sellTree, 0);
        if (firstLeft != 0) {
            return firstLeft * vaultPricePrecision / pricePrecision;
        }
        return type(uint256).max;
    }

    function _getOBBid() internal view returns (uint256) {
        uint32 firstRight = TreeMath.findFirstRight(s_buyTree, type(uint32).max);
        if (firstRight != type(uint32).max) {
            return firstRight * vaultPricePrecision / pricePrecision;
        }
        return 0;
    }

    function bestAsk() internal view returns (bool, uint256) {
        uint256 firstLeft = TreeMath.findFirstLeft(s_sellTree, 0) * vaultPricePrecision / pricePrecision;
        if (firstLeft != 0) {
            if (vaultBestAsk != type(uint256).max) {
                if (firstLeft == vaultBestAsk) {
                    return (false, firstLeft);
                }
                return (FixedPointMathLib.min(firstLeft, vaultBestAsk)) == vaultBestAsk
                    ? (true, vaultBestAsk)
                    : (false, firstLeft);
            }
            return (false, firstLeft);
        }
        return (vaultBestAsk != type(uint256).max) ? (true, vaultBestAsk) : (false, 0);
    }

    function bestBid() internal view returns (bool, uint256) {
        uint256 firstRight = TreeMath.findFirstRight(s_buyTree, type(uint32).max) * vaultPricePrecision / pricePrecision;
        if (firstRight != type(uint32).max * vaultPricePrecision / pricePrecision) {
            if (vaultBestBid != 0) {
                if (firstRight == vaultBestBid) {
                    return (false, firstRight);
                }
                return (FixedPointMathLib.max(firstRight, vaultBestBid)) == vaultBestBid
                    ? (true, vaultBestBid)
                    : (false, firstRight);
            }
            return (false, firstRight);
        }
        return vaultBestBid != 0 ? (true, vaultBestBid) : (false, type(uint256).max);
    }

    /**
     * @notice Wrapper around getL2Book that returns all bid and ask price points
     * @dev This is useful if you want the complete order book, but may fail if the number of price points is a lot
     * @return data Encoded bytes containing the block number, prices, and sizes of the buy and sell orders.
     */
    function getL2Book() external view returns (bytes memory) {
        return getL2Book(type(uint32).max, type(uint32).max);
    }

    /**
     * @notice Returns the Level 2 order book data.
     * @dev Encodes the block number, buy orders, and sell orders. Pass the number of bid and ask price points you need
     * @return data Encoded bytes containing the block number, prices, and sizes of the buy and sell orders.
     */
    function getL2Book(uint32 _bidPricePoints, uint32 _askPricePoints) public view returns (bytes memory data) {
        uint256 dataStart;
        uint256 lastFree;

        assembly ("memory-safe") {
            dataStart := mload(0x40)
            lastFree := add(dataStart, 32)
            mstore(lastFree, number()) // block number
            lastFree := add(lastFree, 32)
            mstore(0x40, lastFree)
        }

        // -------------------- BID SIDE --------------------
        uint32 price = TreeMath.findFirstRight(s_buyTree, type(uint32).max);
        while (price != type(uint32).max && price != 0 && _bidPricePoints != 0) {
            uint40 orderId = s_buyPricePoints[price].head;
            uint96 size = 0;
            while (orderId != 0) {
                size += s_orders[orderId].size;
                orderId = s_orders[orderId].next;
            }
            assembly ("memory-safe") {
                let curFree := mload(0x40)
                if iszero(eq(curFree, lastFree)) {
                    // free pointer has moved, so we will copy data to a new memory region
                    let producedLen := sub(lastFree, dataStart)
                    for { let offset := 0 } lt(offset, producedLen) { offset := add(offset, 32) } {
                        mstore(add(curFree, offset), mload(add(dataStart, offset)))
                    }
                    dataStart := curFree
                    lastFree := add(curFree, producedLen)
                }

                mstore(lastFree, price)
                mstore(add(lastFree, 32), size)
                lastFree := add(lastFree, 64)
                mstore(0x40, lastFree)
            }
            price = TreeMath.findFirstRight(s_buyTree, price);
            --_bidPricePoints;
        }

        assembly ("memory-safe") {
            let curFree := mload(0x40)
            if iszero(eq(curFree, lastFree)) {
                let producedLen := sub(lastFree, dataStart)
                for { let offset := 0 } lt(offset, producedLen) { offset := add(offset, 32) } {
                    mstore(add(curFree, offset), mload(add(dataStart, offset)))
                }
                dataStart := curFree
                lastFree := add(curFree, producedLen)
            }

            mstore(lastFree, 0)
            lastFree := add(lastFree, 32)
            mstore(0x40, lastFree)
        }

        price = TreeMath.findFirstLeft(s_sellTree, 0);
        while (price != type(uint32).max && price != 0 && _askPricePoints != 0) {
            uint40 orderId = s_sellPricePoints[price].head;
            uint96 size = 0;
            while (orderId != 0) {
                size += s_orders[orderId].size;
                orderId = s_orders[orderId].next;
            }
            assembly ("memory-safe") {
                let curFree := mload(0x40)
                if iszero(eq(curFree, lastFree)) {
                    // free memory pointer has moved
                    let producedLen := sub(lastFree, dataStart)
                    for { let offset := 0 } lt(offset, producedLen) { offset := add(offset, 32) } {
                        mstore(add(curFree, offset), mload(add(dataStart, offset)))
                    }
                    dataStart := curFree
                    lastFree := add(curFree, producedLen)
                }

                mstore(lastFree, price)
                mstore(add(lastFree, 32), size)
                lastFree := add(lastFree, 64)
                mstore(0x40, lastFree)
            }
            price = TreeMath.findFirstLeft(s_sellTree, price);
            --_askPricePoints;
        }

        assembly ("memory-safe") {
            mstore(dataStart, sub(lastFree, add(dataStart, 32)))
            data := dataStart
        }
    }
}
