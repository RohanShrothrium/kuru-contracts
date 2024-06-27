//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "../contracts/libraries/FixedPointMathLib.sol";
import {IOrderBook} from "../contracts/interfaces/IOrderBook.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {Router} from "../contracts/Router.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";
import {PropertiesAsserts} from "./Helper.sol";

contract OrderBookNativeBaseTest is Test, PropertiesAsserts {

    uint96 constant SIZE_PRECISION = 10**10;
    uint24 constant PRICE_PRECISION = 10**2;
    uint24 _tickSize;
    uint96 _minSize;
    uint96 _maxSize;
    uint96 _takerFeeBps;
    uint256 _makerFeeBps;
    uint24 _maxPrice;
    OrderBook orderBook;
    Router router;
    MarginAccount marginAccount;
    address eth = 0x0000000000000000000000000000000000000000;
    uint256 ethDecimals = 18;
    MintableERC20 usdc;
    uint256 SEED = 2;
    address lastGenAddress;

    function setUp() public {
        usdc = new MintableERC20("USDC", "USDC");
        uint96 _sizePrecision = 10**10;
        uint24 _pricePrecision = 10**2;
        _tickSize = _pricePrecision/2;
        _minSize = 2 * 10** 8;
        _maxSize = 10**12;
        _maxPrice = type(uint24).max / 100;
        _takerFeeBps = 50;
        _makerFeeBps = 30;
        OrderBook.OrderBookType _type = IOrderBook.OrderBookType.NATIVE_IN_BASE;
        OrderBook implementation = new OrderBook();

        router = new Router();

        marginAccount = new MarginAccount(address(router), address(router));

        router.initialize(address(this), address(marginAccount), address(implementation));

        address proxy = router.deployProxy(_type, address(0x0000000000000000000000000000000000000000), address(usdc), _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps, _makerFeeBps);
        orderBook = OrderBook(proxy);
    }
    
    function genAddress() internal returns (address) {
        uint256 _seed = SEED;
        uint256 privateKeyGen = uint256(keccak256(abi.encodePacked(bytes32(_seed))));
        address derived = vm.addr(privateKeyGen);
        ++SEED;
        lastGenAddress = derived;
        return derived;
    }
    
    function _adjustPriceAndSize(uint24 _price, uint96 _size) internal returns (uint24, uint96) {
        uint24 _newPrice = uint24(clampBetween(_price, _tickSize, _maxPrice));
        uint96 _newSize = uint96(clampBetween(_size, _minSize + 1, _maxSize - 1));
        _newPrice = _newPrice - _newPrice % _tickSize;

        return (_newPrice, _newSize);
    }

    function _amountPayableInQuote(uint24 _price, uint96 _size) internal returns (uint256) {
        return ((uint256(uint24((_price * _size) / SIZE_PRECISION)) * 10**usdc.decimals())) / PRICE_PRECISION;
    }

    function _calculateFeePortions(uint256 _amount) internal returns (uint256, uint256) {
        uint256 _totalFee = (FixedPointMathLib.mulDivUp(_amount, _takerFeeBps, 10**4));
        uint256 _protocolFee = ((_totalFee * (_takerFeeBps - _makerFeeBps)) / _takerFeeBps);
        uint256 _makerFee = ((_amount * (_makerFeeBps)) / 10**4);
        return (_protocolFee, _makerFee);
    }

    function _addBuyOrder(address _maker, uint24 _price, uint96 _size, uint24 extra, bool _postOnly) internal returns (address) {
        if (_maker == address(0)) {
            _maker = genAddress();
        }
        uint256 _amount = (uint256(mulDivUp(_price, _size)) + extra) * 10** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        orderBook.addBuyOrder(_price, _size, _postOnly);
        vm.stopPrank();

        return _maker;
    }

    function _addSellOrder(address _maker, uint24 _price, uint96 _size, bool _postOnly) internal returns (address) {
        if (_maker == address(0)) {
            _maker = genAddress();
        }
        uint256 _amount = _size * 10**ethDecimals / SIZE_PRECISION;
        vm.deal(_maker, _amount);
        vm.startPrank(_maker);
        marginAccount.deposit{value: _amount}(_maker, address(eth), _amount);
        orderBook.addSellOrder(_price, _size, _postOnly);
        vm.stopPrank();

        return _maker;
    }

    function testNativeBaseAddBuyOrderNoPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
        uint256 _amount = uint256((mulDivUp(_price, _size))) * 10** usdc.decimals() / PRICE_PRECISION;

        assertEq(marginAccount.getBalance(_maker, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(marginAccount)), _amount);
        assertEq(usdc.balanceOf(_maker), 0);
        assertEq(orderBook.s_orderIdCounter(), 1);
        (uint40 head, uint40 tail) = orderBook.s_buyPricePoints(_price);
        assertEq(head, 1);
        assertEq(tail, 1);
    }

    function testNativeBaseAddBuyOrderPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy sell order with higher price first which should not be filled
        _addSellOrder(address(0), _price + _tickSize, _size, false);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, true);
        uint256 _amount = uint256((mulDivUp(_price, _size))) * 10** usdc.decimals() / PRICE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(marginAccount)), _amount);
        assertEq(usdc.balanceOf(_maker), 0);
        assertEq(orderBook.s_orderIdCounter(), 2);
        (uint40 head, uint40 tail) = orderBook.s_buyPricePoints(_price);
        assertEq(head, 2);
        assertEq(tail, 2);
    }

    function testNativeBaseAddBuyOrderRevertInsufficientBalance(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        
        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size)) - 1) * 10** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("MarginAccoiunt: Insufficient Balance");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddBuyOrderRevertPostOnly(uint24 _price, uint96 _size) public {
        _price = uint24(clampBetween(_price, _tickSize, _maxPrice));
        _price = _price - _price%_tickSize;
        _size = uint96(clampBetween(_size, _minSize + 2, _maxSize - 2));

        address _makerSell = _addSellOrder(address(0), _price, _size - 1, false);

        uint96 _buySize = _size; //extra size of 1 than the sell order
        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _buySize)) + 1) * 10** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("OrderBook: Post only crossed the book");
        orderBook.addBuyOrder(_price, _buySize, true);
        vm.stopPrank();
    }

    function testNativeBaseAddBuyOrderRevertLessBalance(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = genAddress();
        //minting 1 price precision less here
        uint256 _amount = (uint256(mulDivUp(_price, _size)) - 1) * 10** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("MarginAccoiunt: Insufficient Balance");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddSellOrderNoPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint256 _amount = _size * 10** ethDecimals / SIZE_PRECISION;
        assertEq(address(marginAccount).balance, _amount);
        assertEq(_maker.balance, 0);
        assertEq(marginAccount.getBalance(_maker, address(eth)), 0);
    }

    function testNativeBaseAddSellOrderPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy buy order at _price which should not get filled, as sell order will be at _price + _tickSize
        _addBuyOrder(address(0), _price, _size, 0, false);

        address _maker = _addSellOrder(address(0), _price + _tickSize, _size, false);
        uint256 _amount = _size * 10** ethDecimals / SIZE_PRECISION;
        assertEq(address(marginAccount).balance, _amount);
        assertEq(_maker.balance, 0);
        assertEq(marginAccount.getBalance(_maker, address(eth)), 0);
        assertEq(orderBook.s_orderIdCounter(), 2);
        (uint40 head, uint40 tail) = orderBook.s_sellPricePoints(_price + _tickSize);
        assertEq(head, 2);
        assertEq(tail, 2);
    }

    function testNativeBaseAddSellOrderRevertPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy buy order at same price
        _addBuyOrder(address(0), _price, _size, 0, false);

        address _maker = genAddress();
        uint256 _amount = (_size * 10**ethDecimals) / SIZE_PRECISION;
        vm.deal(_maker, _amount);
        vm.startPrank(_maker);
        marginAccount.deposit{value: _amount}(_maker, address(eth), _amount);
        vm.expectRevert("OrderBook: Post only crossed the book");
        orderBook.addSellOrder(_price, _size, true);
        vm.stopPrank();
    }

    function testNativeBaseBuyAndSellEqualMatch(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
        address _taker = _addSellOrder(address(0), _price, _size, false);
        uint256 _usdcWithoutFee = uint256((uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        uint256 _usdcFee = FixedPointMathLib.mulDivUp(_usdcWithoutFee, _takerFeeBps, 10**4);
        uint256 _usdcAfterFee = _usdcWithoutFee - _usdcFee;
        (uint256 _usdcProtocolFee, uint256 _usdcRebate) = _calculateFeePortions(_usdcWithoutFee);
        uint256 _eth = (_size) * 10**ethDecimals / SIZE_PRECISION;
        orderBook.collectFees();
        assertEq(marginAccount.getBalance(_maker, address(eth)), _eth);
        assertEq(marginAccount.getBalance(_taker, address(usdc)), _usdcAfterFee);
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _usdcRebate);
        assertEq(marginAccount.getBalance(address(router), address(usdc)), _usdcProtocolFee);
    }

    function testNativeBaseSellAndBuyEqualMatch(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        address _taker = _addBuyOrder(address(0), _price, _size, 1, false);
        uint256 _usdc = (uint256((uint24((_price * _size) / SIZE_PRECISION))) * 10**usdc.decimals()) / PRICE_PRECISION;
        uint256 _ethWithoutFee = (_size) * 10**ethDecimals / SIZE_PRECISION;
        uint256 _ethFee = FixedPointMathLib.mulDivUp(_ethWithoutFee, _takerFeeBps, 10**4);
        (uint256 _ethProtocolFee, uint256 _ethRebate) = _calculateFeePortions(_ethWithoutFee);
        uint256 _ethAfterFee = _ethWithoutFee - _ethFee;
        orderBook.collectFees();
        assertEq(marginAccount.getBalance(_taker, address(eth)), _ethAfterFee);
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _usdc);
        assertEq(marginAccount.getBalance(_maker, address(eth)), _ethRebate);
        assertEq(marginAccount.getBalance(address(router), address(eth)), _ethProtocolFee);
    }

    function testNativeBaseCancelBuyOrder(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint40[] memory _cancelId = new uint40[](1);
        _cancelId[0] = 1;
        vm.startPrank(_maker);
        orderBook.batchCancelOrders(_cancelId);
        vm.stopPrank();
        uint256 _amount = (uint256((uint24((_price * _size) / SIZE_PRECISION))) * 10**usdc.decimals()) / PRICE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _amount);
        vm.prank(_maker);
        marginAccount.withdraw(_amount, address(usdc));
        assertEq(usdc.balanceOf(_maker), _amount);
    }

    function testNativeBaseCancelSellOrder(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);

        uint40[] memory _cancelId = new uint40[](1);
        _cancelId[0] = 1;
        vm.startPrank(_maker);
        orderBook.batchCancelOrders(_cancelId);
        vm.stopPrank();
        uint256 _amount = _size * 10**ethDecimals / SIZE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(eth)), _amount);
        vm.prank(_maker);
        marginAccount.withdraw(_amount, address(eth));
        assertEq(_maker.balance, _amount);
    }

    function testNativeBaseMarketBuy(uint24 _priceA, uint96 _sizeA, uint24 _priceB, uint96 _sizeB) public {
        uint256 decimals = usdc.decimals();
        
        //Claming price and size of our two sell orders 
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);

        address _makerA = _addSellOrder(address(0), _priceA, _sizeA, false);
        address _makerB = _addSellOrder(address(0), _priceB, _sizeB, false);

        //Expected quote tokens to be supplied for filling each sell order
        uint24 _amountA = mulDivUp(_priceA, _sizeA);
        uint24 _amountB = mulDivUp(_priceB, _sizeB);

        //Expected size credited for market order from each sell order
        uint96 _sizeCreditAFee = uint96(FixedPointMathLib.mulDivUp(_sizeA, _takerFeeBps, 10**4));
        uint96 _sizeCreditA = _sizeA - _sizeCreditAFee;
        uint256 _makerARebate = (((_sizeA * 10**ethDecimals) / SIZE_PRECISION) * _makerFeeBps) / 10**4;

        uint96 _sizeCreditBFee = uint96(FixedPointMathLib.mulDivUp(_sizeB, _takerFeeBps, 10**4));
        uint96 _sizeCreditB = _sizeB - _sizeCreditBFee;
        uint256 _makerBRebate = (((_sizeB * 10**ethDecimals) / SIZE_PRECISION) * _makerFeeBps) / 10**4;

        (uint256 _protocolFee, ) = _calculateFeePortions(((_sizeA + _sizeB) * 10**ethDecimals) / SIZE_PRECISION);

        //Maximum tolerance in credited base tokens from market buy
        uint96 _toleranceInBase = SIZE_PRECISION / uint96(_priceB);

        //Maximum tolerance in credited quote tokens (1 price precision)
        uint256 _toleranceInQuote = 10**decimals / PRICE_PRECISION;

        uint24 _totalAmount = _amountA + _amountB;

        address _taker = genAddress();
        usdc.mint(_taker, (_totalAmount * 10**usdc.decimals()) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_totalAmount * 10**decimals) / PRICE_PRECISION);
        orderBook.placeAndExecuteMarketBuy(_totalAmount, false);
        vm.stopPrank();

        orderBook.collectFees();
        assertGte(_taker.balance, ((_sizeCreditA + _sizeCreditB - _toleranceInBase) * 10**ethDecimals / SIZE_PRECISION), "Too much size lost");
        assertGte(marginAccount.getBalance(_makerA, address(usdc)), ((_amountA * 10**decimals) / PRICE_PRECISION) - _toleranceInQuote, "Too less quote credited A");
        assertGte(marginAccount.getBalance(_makerB, address(usdc)), ((_amountB * 10**decimals) / PRICE_PRECISION) - _toleranceInQuote, "Too less quote credited B");
        assertEq(marginAccount.getBalance(_makerA, address(eth)), _makerARebate);
        assertEq(marginAccount.getBalance(_makerB, address(eth)), _makerBRebate);
        assertLte(usdc.balanceOf(_taker), 2 * _toleranceInQuote, "Too less quote debited");
        assertApproxEqAbs(marginAccount.getBalance(address(router), address(eth)), _protocolFee, 10**18);
    }   

    function testNativeBaseMarketBuyPartialFill(uint24 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint24 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint24 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
        uint96 _toleranceInBase = SIZE_PRECISION / _price; //Size worth 1 price precision
        uint96 _creditSize = _size - uint96(FixedPointMathLib.mulDivUp(_size, _takerFeeBps, 10**4));

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10**_decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_quoteExtra * 10**_decimals) / PRICE_PRECISION);
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, false);
        vm.stopPrank();

        assertGte(usdc.balanceOf(_taker), (100 * 10**_decimals) / PRICE_PRECISION, "Too less refund credit");
        assertLte(usdc.balanceOf(_taker), (101 * 10**_decimals) / PRICE_PRECISION, "Too much refund credit");
        if(_creditSize > _toleranceInBase) { //sometimes creditsize is lower than tolerance
            assertGte(_taker.balance, (_creditSize - _toleranceInBase) * 10**ethDecimals / SIZE_PRECISION, "Too less size credit");
        }
        assertGte(marginAccount.getBalance(_maker, address(usdc)), (_quoteTokens - 1) * 10**_decimals / PRICE_PRECISION, "Too less quote credit");
    }

    function testNativeBaseMarketBuyRevertFillOrKill(uint24 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint24 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint24 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
        uint96 _toleranceInBase = SIZE_PRECISION / _price; //Size worth 1 price precision

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10**_decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_quoteExtra * 10**_decimals) / PRICE_PRECISION);
        vm.expectRevert("OrderBook: insufficient volume on book");
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, true);
        vm.stopPrank();
    }

    function testNativeBaseMarketBuyInsufficientAllowance(uint24 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint24 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint24 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
        uint96 _toleranceInBase = SIZE_PRECISION / _price; //Size worth 1 price precision

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10**_decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, false);
        vm.stopPrank();
    }

    function testNativeBaseMarketSell(uint24 _priceA, uint96 _sizeA, uint24 _priceB, uint96 _sizeB) public {
        uint256 _decimals = ethDecimals;
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);
        //Adding two buy orders which need to get filled
        address _makerA = _addBuyOrder(address(0), _priceA, _sizeA, 0, false);
        uint256 _expectedQuoteA = _amountPayableInQuote(_priceA, _sizeA);
        uint256 _expectedRebateA = (_expectedQuoteA * _makerFeeBps) / 10**4;
        address _makerB = _addBuyOrder(address(0), _priceB, _sizeB, 0, false);
        uint256 _expectedQuoteB = _amountPayableInQuote(_priceB, _sizeB);
        uint256 _expectedRebateB = (_expectedQuoteB * _makerFeeBps) / 10**4;

        uint256 _expectedQuote = _expectedQuoteA + _expectedQuoteB;
        (uint256 _protocolFee, ) = _calculateFeePortions(_expectedQuote);
        _expectedQuote -= FixedPointMathLib.mulDivUp(_expectedQuote, _takerFeeBps, 10**4);

        console.log(mulDivUp(_priceA, _sizeA));
        console.log(mulDivUp(_priceB, _sizeB));
        //quote tolerance is tokens equal to 1 price precision
        uint256 _quoteTolerance = 10**(usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_sizeA + _sizeB) * 10**_decimals / SIZE_PRECISION);
        address _taker = genAddress();
        vm.deal(_taker, _sizeForSale);
        vm.startPrank(_taker);
        orderBook.placeAndExecuteMarketSell{value: _sizeForSale}((_sizeA + _sizeB), true);
        vm.stopPrank();

        orderBook.collectFees();
        assertGte(usdc.balanceOf(_taker), _expectedQuote - _quoteTolerance, "Too less quote credit");
        assertGte(marginAccount.getBalance(_makerA, address(eth)), ((_sizeA - 1) * 10**_decimals) / SIZE_PRECISION, "Too less size credit A");
        assertEq(marginAccount.getBalance(_makerA, address(usdc)), _expectedRebateA);
        assertGte(marginAccount.getBalance(_makerB, address(eth)), ((_sizeB - 1) * 10**_decimals) / SIZE_PRECISION, "Too less size credit B");
        assertEq(marginAccount.getBalance(_makerA, address(usdc)), _expectedRebateA);
        assertGte(marginAccount.getBalance(address(router), address(usdc)), _protocolFee, "Fee collection failed");
    }
    
    function testNativeBaseMarketSellPartialFill(uint24 _price, uint96 _size) public {
        uint256 _decimals = ethDecimals;
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _expectedQuote = _amountPayableInQuote(_price, _size);
        (uint256 _protocolFee, ) = _calculateFeePortions(_expectedQuote);
        _expectedQuote -= FixedPointMathLib.mulDivUp(_expectedQuote, _takerFeeBps, 10**4);
        uint256 _quoteTolerance = 10**(usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_size + 10**6) * 10**_decimals) / SIZE_PRECISION; //extra 10**6 size for partial fill

        address _taker = genAddress();
        vm.deal(_taker, _sizeForSale);
        vm.startPrank(_taker);
        orderBook.placeAndExecuteMarketSell{value: _sizeForSale}(_size + 10**6, false);
        vm.stopPrank();

        orderBook.collectFees();
        if (_expectedQuote > _quoteTolerance) { //sometimes tolerance is higher than expected quote
            assertGte(usdc.balanceOf(_taker), _expectedQuote - _quoteTolerance, "Too less quote credit");
        }
        assertGte(marginAccount.getBalance(_maker, address(eth)), (_size * 10**_decimals) / SIZE_PRECISION, "Too less size credit");
        assertGte(_taker.balance, (10**6 * 10**_decimals) / SIZE_PRECISION, "Too much size spent");
        assertGte(marginAccount.getBalance(address(router), address(usdc)), _protocolFee, "Fee collection failed");
    }

    function testNativeBaseMarketSellRevertFillOrKill(uint24 _price, uint96 _size) public {
        uint256 _decimals = ethDecimals;
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _expectedQuote = _amountPayableInQuote(_price, _size);
        uint256 _quoteTolerance = 10**(usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_size + 10**6) * 10**_decimals) / SIZE_PRECISION; //extra 10**6 size for partial fill

        address _taker = genAddress();
        vm.deal(_taker, _sizeForSale);
        vm.startPrank(_taker);
        vm.expectRevert("OrderBook: insufficient volume on book");
        orderBook.placeAndExecuteMarketSell{value: _sizeForSale}(_size + 10**6, true);
        vm.stopPrank();
    }

    function testNativeBaseMarketSellInsufficientNative(uint24 _price, uint96 _size) public {
        uint256 _decimals = ethDecimals;
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _expectedQuote = _amountPayableInQuote(_price, _size);
        uint256 _quoteTolerance = 10**(usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_size + 10**6) * 10**_decimals) / SIZE_PRECISION; 

        address _taker = genAddress();
        vm.deal(_taker, _sizeForSale);
        vm.startPrank(_taker);
        vm.expectRevert("OrderBook: Native asset not enough");
        orderBook.placeAndExecuteMarketSell(_size + 10**6, false);
        vm.stopPrank();
    }

    function testNativeBaseCancelOrder(uint24 _price, uint96 _size, bool _isBuy) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        if(_isBuy) {
            address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelOrders(_orders);
            vm.stopPrank();
            uint256 _quoteBalance = (uint256((uint24((_price * _size) / SIZE_PRECISION)) * 10**usdc.decimals())) / PRICE_PRECISION;
            assertEq(marginAccount.getBalance(_maker, address(usdc)), _quoteBalance);
        }
        else {
            address _maker = _addSellOrder(address(0), _price, _size, false);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelOrders(_orders);
            vm.stopPrank();
            assertEq(marginAccount.getBalance(_maker, address(eth)), (_size * 10**ethDecimals) / SIZE_PRECISION);
        }
    }

    function testNativeBaseAddBuyOrderMinSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _minSize - 1;

        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size))) * 10**usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("OrderBook: Size too low");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddBuyOrderMaxSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _maxSize + 1;

        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size))) * 10**usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("OrderBook: Size too large");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddBuyOrderTickSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price -= 1; //wrong tick size

        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size))) * 10**usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("OrderBook: Tick Size");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddBuyOrderZeroPriceError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = 0;

        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size))) * 10**usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("OrderBook: Price too low");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseSellOrderMinSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _minSize - 1;

        address _maker = genAddress();

        uint256 _amount = _size * 10**ethDecimals / SIZE_PRECISION;
        vm.deal(_maker, _amount);
        vm.startPrank(_maker);
        marginAccount.deposit{value: _amount}(_maker, address(eth), _amount);
        vm.expectRevert("OrderBook: Size too low");
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseSellOrderMaxSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _maxSize + 1;

        address _maker = genAddress();

        uint256 _amount = _size * 10**ethDecimals / SIZE_PRECISION;
        vm.deal(_maker, _amount);
        vm.startPrank(_maker);
        marginAccount.deposit{value: _amount}(_maker, address(eth), _amount);
        vm.expectRevert("OrderBook: Size too large");
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddSellOrderTickSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price -= 1; //wrong tick size

        address _maker = genAddress();

        uint256 _amount = _size * 10**ethDecimals / SIZE_PRECISION;
        vm.deal(_maker, _amount);
        vm.startPrank(_maker);
        marginAccount.deposit{value: _amount}(_maker, address(eth), _amount);
        vm.expectRevert("OrderBook: Tick Size");
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testNativeBaseAddSellOrderZeroPriceError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = 0; 

        address _maker = genAddress();

        uint256 _amount = _size * 10**ethDecimals / SIZE_PRECISION;
        vm.deal(_maker, _amount);
        vm.startPrank(_maker);
        marginAccount.deposit{value: _amount}(_maker, address(eth), _amount);
        vm.expectRevert("OrderBook: Price too low");
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function mulDivUp(uint24 _price, uint96 _size) internal returns (uint24) {
        uint256 _result = FixedPointMathLib.mulDivUp(_price, _size, SIZE_PRECISION);
        if (_result >= type(uint24).max) {
            revert("OrderBook: Too much size being filled");
        }
        return uint24(_result);
    }
}