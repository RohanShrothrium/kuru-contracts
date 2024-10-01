//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "../contracts/libraries/FixedPointMathLib.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {IOrderBook} from "../contracts/interfaces/IOrderBook.sol";
import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {Router} from "../contracts/Router.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";
import {PropertiesAsserts} from "./Helper.sol";

contract OrderBookTest is Test, PropertiesAsserts {
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint24 constant PRICE_PRECISION = 10 ** 2;
    uint24 _tickSize;
    uint96 _minSize;
    uint96 _maxSize;
    uint96 _takerFeeBps;
    uint256 _makerFeeBps;
    uint24 _maxPrice;
    uint256 vaultPricePrecision;
    OrderBook orderBook;
    KuruAMMVault vault;
    Router router;
    MarginAccount marginAccount;

    MintableERC20 eth;
    MintableERC20 usdc;
    uint256 SEED = 2;
    address lastGenAddress;

    function setUp() public {
        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USDC", "USDC");
        uint96 _sizePrecision = 10 ** 10;
        uint24 _pricePrecision = 10 ** 2;
        vaultPricePrecision = 10 ** 18;
        _tickSize = _pricePrecision / 2;
        _minSize = 2 * 10 ** 8;
        _maxSize = 10 ** 12;
        _maxPrice = type(uint24).max / 100;
        _takerFeeBps = 0;
        _makerFeeBps = 0;
        OrderBook.OrderBookType _type;
        OrderBook implementation = new OrderBook();
        Router routerImplementation = new Router();
        address routerProxy = Create2.deploy(
                0,
                bytes32(keccak256("")),
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(routerImplementation, bytes("")))
            );
        router = Router(payable(routerProxy));
        marginAccount = new MarginAccount(address(router), address(router));
        uint96 SPREAD = 100;

        router.initialize(address(this), address(marginAccount), address(implementation));

        address proxy = router.deployProxy(
            _type,
            address(eth),
            address(usdc),
            _sizePrecision,
            _pricePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps,
            SPREAD
        );
        orderBook = OrderBook(proxy);
        (address _kuruVault,,,,,,) = orderBook.getVaultParams();
        vault = KuruAMMVault(payable(_kuruVault));
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

    function _adjustPriceAndSizeForVault(uint256 _price, uint96 _size) internal returns (uint256, uint96) {
        _price = clampBetween(_price, vaultPricePrecision / 2, _maxPrice * vaultPricePrecision / PRICE_PRECISION);
        _size = uint96(clampBetween(_size, _minSize + 1, _maxSize * 2));
        return (_price, _size);
    }

    function _amountPayableInQuote(uint24 _price, uint96 _size) internal returns (uint256) {
        return ((uint256(uint24((_price * _size) / SIZE_PRECISION)) * 10 ** usdc.decimals())) / PRICE_PRECISION;
    }

    function _calculateFeePortions(uint256 _amount) internal returns (uint256, uint256) {
        if (_takerFeeBps > 0) {
            uint256 _totalFee = (FixedPointMathLib.mulDivUp(_amount, _takerFeeBps, 10 ** 4));
            uint256 _protocolFee = ((_totalFee * (_takerFeeBps - _makerFeeBps)) / _takerFeeBps);
            uint256 _makerFee = ((_amount * (_makerFeeBps)) / 10 ** 4);
            return (_protocolFee, _makerFee);
        }
        return (0, 0);
    }

    function _addBuyOrder(address _maker, uint24 _price, uint96 _size, uint24 extra, bool _postOnly)
        internal
        returns (address)
    {
        if (_maker == address(0)) {
            _maker = genAddress();
        }
        uint256 _amount = ((uint256(mulDivUp(_price, _size) + extra)) * 10 ** usdc.decimals()) / PRICE_PRECISION;
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
        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        orderBook.addSellOrder(_price, _size, _postOnly);
        vm.stopPrank();

        return _maker;
    }

    function testAddBuyOrderNoPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
        uint256 _amount = uint256((mulDivUp(_price, _size))) * 10 ** usdc.decimals() / PRICE_PRECISION;

        assertEq(marginAccount.getBalance(_maker, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(marginAccount)), _amount);
        assertEq(usdc.balanceOf(_maker), 0);
        assertEq(orderBook.s_orderIdCounter(), 1);
        (uint40 head, uint40 tail) = orderBook.s_buyPricePoints(_price);
        assertEq(head, 1);
        assertEq(tail, 1);
    }

    function testAddBuyOrderPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy sell order with higher price first which should not be filled
        _addSellOrder(address(0), _price + _tickSize, _size, false);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, true);
        uint256 _amount = uint256((mulDivUp(_price, _size))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(marginAccount)), _amount);
        assertEq(usdc.balanceOf(_maker), 0);
        assertEq(orderBook.s_orderIdCounter(), 2);
        (uint40 head, uint40 tail) = orderBook.s_buyPricePoints(_price);
        assertEq(head, 2);
        assertEq(tail, 2);
    }

    function testAddBuyOrderRevertInsufficientBalance(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size)) - 1) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("MarginAccoiunt: Insufficient Balance");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderRevertPostOnly(uint24 _price, uint96 _size) public {
        _price = uint24(clampBetween(_price, _tickSize, _maxPrice));
        _price = _price - _price % _tickSize;
        _size = uint96(clampBetween(_size, _minSize + 2, _maxSize - 2));

        address _makerSell = _addSellOrder(address(0), _price, _size - 1, false);

        uint96 _buySize = _size; //extra size of 1 than the sell order
        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _buySize)) + 1) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(Errors.PostOnlyError.selector);
        orderBook.addBuyOrder(_price, _buySize, true);
        vm.stopPrank();
    }

    function testAddBuyOrderRevertLessBalance(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = genAddress();
        //minting 1 price precision less here
        uint256 _amount = (uint256(mulDivUp(_price, _size)) - 1) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert("MarginAccoiunt: Insufficient Balance");
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddSellOrderNoPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        assertEq(eth.balanceOf(address(marginAccount)), _amount);
        assertEq(eth.balanceOf(_maker), 0);
        assertEq(marginAccount.getBalance(_maker, address(eth)), 0);
    }

    function testAddSellOrderPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy buy order at _price which should not get filled, as sell order will be at _price + _tickSize
        _addBuyOrder(address(0), _price, _size, 0, false);

        address _maker = _addSellOrder(address(0), _price + _tickSize, _size, false);
        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        assertEq(eth.balanceOf(address(marginAccount)), _amount);
        assertEq(eth.balanceOf(_maker), 0);
        assertEq(marginAccount.getBalance(_maker, address(eth)), 0);
        assertEq(orderBook.s_orderIdCounter(), 2);
        (uint40 head, uint40 tail) = orderBook.s_sellPricePoints(_price + _tickSize);
        assertEq(head, 2);
        assertEq(tail, 2);
    }

    function testAddSellOrderRevertPostOnly(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy buy order at same price
        _addBuyOrder(address(0), _price, _size, 0, false);

        address _maker = genAddress();
        uint256 _amount = (_size * 10 ** eth.decimals()) / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(Errors.PostOnlyError.selector);
        orderBook.addSellOrder(_price, _size, true);
        vm.stopPrank();
    }

    function testBuyAndSellEqualMatch(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
        address _taker = _addSellOrder(address(0), _price, _size, false);
        uint256 _usdcWithoutFee =
            uint256((uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        uint256 _usdcFee = FixedPointMathLib.mulDivUp(_usdcWithoutFee, _takerFeeBps, 10 ** 4);
        uint256 _usdcAfterFee = _usdcWithoutFee - _usdcFee;
        (uint256 _usdcProtocolFee, uint256 _usdcRebate) = _calculateFeePortions(_usdcWithoutFee);
        uint256 _eth = (_size) * 10 ** eth.decimals() / SIZE_PRECISION;
        orderBook.collectFees();
        assertEq(marginAccount.getBalance(_maker, address(eth)), _eth);
        assertEq(marginAccount.getBalance(_taker, address(usdc)), _usdcAfterFee);
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _usdcRebate);
        assertEq(marginAccount.getBalance(address(router), address(usdc)), _usdcProtocolFee);
        uint256 _usdcUtilized =
            marginAccount.getBalance(address(router), address(usdc)) + marginAccount.getBalance(_maker, address(usdc));
        uint256 _usdcMinted =
            FixedPointMathLib.mulDivUp(_price, _size, SIZE_PRECISION) * 10 ** usdc.decimals() / PRICE_PRECISION;
        uint256 _usdcWasted = _usdcMinted - _usdcUtilized;
        console.log("Wasted: ", _usdcWasted);
    }

    function testSellAndBuyEqualMatch(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        address _taker = _addBuyOrder(address(0), _price, _size, 1, false);
        uint256 _usdc = uint256(uint24((_price * _size) / SIZE_PRECISION)) * 10 ** usdc.decimals() / PRICE_PRECISION;
        uint256 _ethWithoutFee = (_size) * 10 ** eth.decimals() / SIZE_PRECISION;
        uint256 _ethFee = FixedPointMathLib.mulDivUp(_ethWithoutFee, _takerFeeBps, 10 ** 4);
        (uint256 _ethProtocolFee, uint256 _ethRebate) = _calculateFeePortions(_ethWithoutFee);
        uint256 _ethAfterFee = _ethWithoutFee - _ethFee;
        orderBook.collectFees();
        assertEq(marginAccount.getBalance(_taker, address(eth)), _ethAfterFee);
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _usdc);
        assertEq(marginAccount.getBalance(_maker, address(eth)), _ethRebate);
        assertEq(marginAccount.getBalance(address(router), address(eth)), _ethProtocolFee);
    }

    function testCancelBuyOrder(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint40[] memory _cancelId = new uint40[](1);
        _cancelId[0] = 1;
        vm.startPrank(_maker);
        orderBook.batchCancelOrders(_cancelId);
        vm.stopPrank();
        uint256 _amount = (uint256(uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _amount);
        vm.prank(_maker);
        marginAccount.withdraw(_amount, address(usdc));
        assertEq(usdc.balanceOf(_maker), _amount);
    }

    function testCancelSellOrder(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);

        uint40[] memory _cancelId = new uint40[](1);
        _cancelId[0] = 1;
        vm.startPrank(_maker);
        orderBook.batchCancelOrders(_cancelId);
        vm.stopPrank();
        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(eth)), _amount);
        vm.prank(_maker);
        marginAccount.withdraw(_amount, address(eth));
        assertEq(eth.balanceOf(_maker), _amount);
    }

    function testMarketBuy(uint24 _priceA, uint96 _sizeA, uint24 _priceB, uint96 _sizeB) public {
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
        uint96 _sizeCreditAFee = uint96(FixedPointMathLib.mulDivUp(_sizeA, _takerFeeBps, 10 ** 4));
        uint96 _sizeCreditA = _sizeA - _sizeCreditAFee;
        uint256 _makerARebate = (((_sizeA * 10 ** eth.decimals()) / SIZE_PRECISION) * _makerFeeBps) / 10 ** 4;

        uint96 _sizeCreditBFee = uint96(FixedPointMathLib.mulDivUp(_sizeB, _takerFeeBps, 10 ** 4));
        uint96 _sizeCreditB = _sizeB - _sizeCreditBFee;
        uint256 _makerBRebate = (((_sizeB * 10 ** eth.decimals()) / SIZE_PRECISION) * _makerFeeBps) / 10 ** 4;

        (uint256 _protocolFee,) = _calculateFeePortions(((_sizeA + _sizeB) * 10 ** eth.decimals()) / SIZE_PRECISION);

        //Maximum tolerance in credited base tokens from market buy
        uint96 _toleranceInBase = SIZE_PRECISION / uint96(_priceB);

        //Maximum tolerance in credited quote tokens (1 price precision)
        uint256 _toleranceInQuote = 10 ** decimals / PRICE_PRECISION;

        uint24 _totalAmount = _amountA + _amountB;

        address _taker = genAddress();
        usdc.mint(_taker, (_totalAmount * 10 ** usdc.decimals()) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_totalAmount * 10 ** decimals) / PRICE_PRECISION);
        orderBook.placeAndExecuteMarketBuy(_totalAmount, 0, false, false);
        vm.stopPrank();

        orderBook.collectFees();
        assertGte(
            eth.balanceOf(_taker),
            ((_sizeCreditA + _sizeCreditB - _toleranceInBase) * 10 ** eth.decimals() / SIZE_PRECISION),
            "Too much size lost"
        );
        assertGte(
            marginAccount.getBalance(_makerA, address(usdc)),
            ((_amountA * 10 ** decimals) / PRICE_PRECISION) - _toleranceInQuote,
            "Too less quote credited A"
        );
        assertGte(
            marginAccount.getBalance(_makerB, address(usdc)),
            ((_amountB * 10 ** decimals) / PRICE_PRECISION) - _toleranceInQuote,
            "Too less quote credited B"
        );
        assertEq(marginAccount.getBalance(_makerA, address(eth)), _makerARebate);
        assertEq(marginAccount.getBalance(_makerB, address(eth)), _makerBRebate);
        assertLte(usdc.balanceOf(_taker), 2 * _toleranceInQuote, "Too less quote debited");
        assertApproxEqAbs(marginAccount.getBalance(address(router), address(eth)), _protocolFee, 10 ** 18);
    }

    function testMarketBuyMargin(uint24 _priceA, uint96 _sizeA, uint24 _priceB, uint96 _sizeB) public {
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
        uint96 _sizeCreditAFee = uint96(FixedPointMathLib.mulDivUp(_sizeA, _takerFeeBps, 10 ** 4));
        uint96 _sizeCreditA = _sizeA - _sizeCreditAFee;
        uint256 _makerARebate = (((_sizeA * 10 ** eth.decimals()) / SIZE_PRECISION) * _makerFeeBps) / 10 ** 4;

        uint96 _sizeCreditBFee = uint96(FixedPointMathLib.mulDivUp(_sizeB, _takerFeeBps, 10 ** 4));
        uint96 _sizeCreditB = _sizeB - _sizeCreditBFee;
        uint256 _makerBRebate = (((_sizeB * 10 ** eth.decimals()) / SIZE_PRECISION) * _makerFeeBps) / 10 ** 4;

        (uint256 _protocolFee,) = _calculateFeePortions(((_sizeA + _sizeB) * 10 ** eth.decimals()) / SIZE_PRECISION);

        //Maximum tolerance in credited base tokens from market buy
        uint96 _toleranceInBase = SIZE_PRECISION / uint96(_priceB);

        //Maximum tolerance in credited quote tokens (1 price precision)
        uint256 _toleranceInQuote = 10 ** decimals / PRICE_PRECISION;

        uint24 _totalAmount = _amountA + _amountB;

        address _taker = genAddress();
        usdc.mint(_taker, (_totalAmount * 10 ** usdc.decimals()) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(marginAccount), (_totalAmount * 10 ** decimals) / PRICE_PRECISION);
        marginAccount.deposit(_taker, address(usdc), _totalAmount * 10 ** decimals / PRICE_PRECISION);
        orderBook.placeAndExecuteMarketBuy(_totalAmount, 0, true, false);
        vm.stopPrank();

        orderBook.collectFees();
        assertGte(
            marginAccount.getBalance(_taker, address(eth)),
            ((_sizeCreditA + _sizeCreditB - _toleranceInBase) * 10 ** eth.decimals() / SIZE_PRECISION),
            "Too much size lost"
        );
        assertGte(
            marginAccount.getBalance(_makerA, address(usdc)),
            ((_amountA * 10 ** decimals) / PRICE_PRECISION) - _toleranceInQuote,
            "Too less quote credited A"
        );
        assertGte(
            marginAccount.getBalance(_makerB, address(usdc)),
            ((_amountB * 10 ** decimals) / PRICE_PRECISION) - _toleranceInQuote,
            "Too less quote credited B"
        );
        assertEq(marginAccount.getBalance(_makerA, address(eth)), _makerARebate);
        assertEq(marginAccount.getBalance(_makerB, address(eth)), _makerBRebate);
        assertLte(usdc.balanceOf(_taker), 2 * _toleranceInQuote, "Too less quote debited");
        assertApproxEqAbs(marginAccount.getBalance(address(router), address(eth)), _protocolFee, 10 ** 18);
    }

    function testMarketBuyPartialFill(uint24 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint24 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint24 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
        uint96 _toleranceInBase = SIZE_PRECISION / _price; //Size worth 1 price precision
        uint96 _creditSize = _size - uint96(FixedPointMathLib.mulDivUp(_size, _takerFeeBps, 10 ** 4));

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, 0, false, false);
        vm.stopPrank();

        assertGte(usdc.balanceOf(_taker), (100 * 10 ** _decimals) / PRICE_PRECISION, "Too less refund credit");
        assertLte(usdc.balanceOf(_taker), (101 * 10 ** _decimals) / PRICE_PRECISION, "Too much refund credit");
        if (_creditSize > _toleranceInBase) {
            //sometimes creditsize is lower than tolerance
            assertGte(
                eth.balanceOf(_taker),
                (_creditSize - _toleranceInBase) * 10 ** (eth.decimals()) / SIZE_PRECISION,
                "Too less size credit"
            );
        }
        assertGte(
            marginAccount.getBalance(_maker, address(usdc)),
            (_quoteTokens - 1) * 10 ** _decimals / PRICE_PRECISION,
            "Too less quote credit"
        );
        orderBook.collectFees();
        uint256 _ethMinted = (_size * 10 ** eth.decimals()) / SIZE_PRECISION;
        uint256 _ethTaker = eth.balanceOf(_taker);
        uint256 _ethFee = marginAccount.getBalance(address(router), address(eth));
        uint256 _ethWasted = _ethMinted - (_ethTaker + _ethFee);
        console.log("Market Buy Partial Fill Eth wasted: ", _ethWasted);
    }

    function testMarketBuyRevertFillOrKill(uint24 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint24 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint24 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
        uint96 _toleranceInBase = SIZE_PRECISION / _price; //Size worth 1 price precision

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, 0, false, true);
        vm.stopPrank();
    }

    function testMarketBuyInsufficientAllowance(uint24 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint24 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint24 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
        uint96 _toleranceInBase = SIZE_PRECISION / _price; //Size worth 1 price precision

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        vm.expectRevert(Errors.TransferFromFailed.selector);
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, 0, false, false);
        vm.stopPrank();
    }

    function testMarketSell(uint24 _priceA, uint96 _sizeA, uint24 _priceB, uint96 _sizeB) public {
        uint256 _decimals = eth.decimals();
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);
        //Adding two buy orders which need to get filled
        address _makerA = _addBuyOrder(address(0), _priceA, _sizeA, 0, false);
        uint256 _expectedQuoteA = _amountPayableInQuote(_priceA, _sizeA);
        uint256 _expectedRebateA = (_expectedQuoteA * _makerFeeBps) / 10 ** 4;
        address _makerB = _addBuyOrder(address(0), _priceB, _sizeB, 0, false);
        uint256 _expectedQuoteB = _amountPayableInQuote(_priceB, _sizeB);
        uint256 _expectedRebateB = (_expectedQuoteB * _makerFeeBps) / 10 ** 4;

        uint256 _expectedQuote = _expectedQuoteA + _expectedQuoteB;
        (uint256 _protocolFee,) = _calculateFeePortions(_expectedQuote);
        _expectedQuote -= FixedPointMathLib.mulDivUp(_expectedQuote, _takerFeeBps, 10 ** 4);

        console.log(mulDivUp(_priceA, _sizeA));
        console.log(mulDivUp(_priceB, _sizeB));
        //quote tolerance is tokens equal to 1 price precision
        uint256 _quoteTolerance = 10 ** (usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_sizeA + _sizeB) * 10 ** _decimals / SIZE_PRECISION);
        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeForSale);
        orderBook.placeAndExecuteMarketSell((_sizeA + _sizeB), 0, false, true);
        vm.stopPrank();

        orderBook.collectFees();
        assertGte(usdc.balanceOf(_taker), _expectedQuote - _quoteTolerance, "Too less quote credit");
        assertGte(
            marginAccount.getBalance(_makerA, address(eth)),
            ((_sizeA - 1) * 10 ** _decimals) / SIZE_PRECISION,
            "Too less size credit A"
        );
        assertEq(marginAccount.getBalance(_makerA, address(usdc)), _expectedRebateA);
        assertGte(
            marginAccount.getBalance(_makerB, address(eth)),
            ((_sizeB - 1) * 10 ** _decimals) / SIZE_PRECISION,
            "Too less size credit B"
        );
        assertEq(marginAccount.getBalance(_makerA, address(usdc)), _expectedRebateA);
        assertGte(marginAccount.getBalance(address(router), address(usdc)), _protocolFee, "Fee collection failed");
    }

    function testMarketSellMargin(uint24 _priceA, uint96 _sizeA, uint24 _priceB, uint96 _sizeB) public {
        uint256 _decimals = eth.decimals();
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);
        //Adding two buy orders which need to get filled
        address _makerA = _addBuyOrder(address(0), _priceA, _sizeA, 0, false);
        uint256 _expectedQuoteA = _amountPayableInQuote(_priceA, _sizeA);
        uint256 _expectedRebateA = (_expectedQuoteA * _makerFeeBps) / 10 ** 4;
        address _makerB = _addBuyOrder(address(0), _priceB, _sizeB, 0, false);
        uint256 _expectedQuoteB = _amountPayableInQuote(_priceB, _sizeB);
        uint256 _expectedRebateB = (_expectedQuoteB * _makerFeeBps) / 10 ** 4;

        uint256 _expectedQuote = _expectedQuoteA + _expectedQuoteB;
        (uint256 _protocolFee,) = _calculateFeePortions(_expectedQuote);
        _expectedQuote -= FixedPointMathLib.mulDivUp(_expectedQuote, _takerFeeBps, 10 ** 4);

        console.log(mulDivUp(_priceA, _sizeA));
        console.log(mulDivUp(_priceB, _sizeB));
        //quote tolerance is tokens equal to 1 price precision
        uint256 _quoteTolerance = 10 ** (usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_sizeA + _sizeB) * 10 ** _decimals / SIZE_PRECISION);
        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        eth.approve(address(marginAccount), _sizeForSale);
        marginAccount.deposit(_taker, address(eth), _sizeForSale);
        orderBook.placeAndExecuteMarketSell((_sizeA + _sizeB), 0, true, true);
        vm.stopPrank();

        orderBook.collectFees();
        assertGte(marginAccount.getBalance(_taker, address(usdc)), _expectedQuote - _quoteTolerance, "Too less quote credit");
        assertGte(
            marginAccount.getBalance(_makerA, address(eth)),
            ((_sizeA - 1) * 10 ** _decimals) / SIZE_PRECISION,
            "Too less size credit A"
        );
        assertEq(marginAccount.getBalance(_makerA, address(usdc)), _expectedRebateA);
        assertGte(
            marginAccount.getBalance(_makerB, address(eth)),
            ((_sizeB - 1) * 10 ** _decimals) / SIZE_PRECISION,
            "Too less size credit B"
        );
        assertEq(marginAccount.getBalance(_makerA, address(usdc)), _expectedRebateA);
        assertGte(marginAccount.getBalance(address(router), address(usdc)), _protocolFee, "Fee collection failed");
    }

    function testMarketSellPartialFill(uint24 _price, uint96 _size) public {
        uint256 _decimals = eth.decimals();
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _expectedQuote = _amountPayableInQuote(_price, _size);
        (uint256 _protocolFee,) = _calculateFeePortions(_expectedQuote);
        _expectedQuote -= FixedPointMathLib.mulDivUp(_expectedQuote, _takerFeeBps, 10 ** 4);
        uint256 _quoteTolerance = 10 ** (usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_size + 10 ** 6) * 10 ** _decimals) / SIZE_PRECISION; //extra 10**6 size for partial fill

        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeForSale);
        orderBook.placeAndExecuteMarketSell(_size, 0, false, false);
        vm.stopPrank();

        orderBook.collectFees();
        if (_expectedQuote > _quoteTolerance) {
            //sometimes tolerance is higher than expected quote
            assertGte(usdc.balanceOf(_taker), _expectedQuote - _quoteTolerance, "Too less quote credit");
        }
        assertGte(
            marginAccount.getBalance(_maker, address(eth)),
            (_size * 10 ** _decimals) / SIZE_PRECISION,
            "Too less size credit"
        );
        assertGte(eth.balanceOf(_taker), (10 ** 6 * 10 ** _decimals) / SIZE_PRECISION, "Too much size spent");
        assertGte(marginAccount.getBalance(address(router), address(usdc)), _protocolFee, "Fee collection failed");
    }

    function testMarketSellRevertFillOrKill(uint24 _price, uint96 _size) public {
        uint256 _decimals = eth.decimals();
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _expectedQuote = _amountPayableInQuote(_price, _size);
        uint256 _quoteTolerance = 10 ** (usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_size + 10 ** 6) * 10 ** _decimals) / SIZE_PRECISION; //extra 10**6 size for partial fill

        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeForSale);
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        orderBook.placeAndExecuteMarketSell(_size + 10 ** 6, 0, false, true);
        vm.stopPrank();
    }

    function testMarketSellInsufficientAllowance(uint24 _price, uint96 _size) public {
        uint256 _decimals = eth.decimals();
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _expectedQuote = _amountPayableInQuote(_price, _size);
        uint256 _quoteTolerance = 10 ** (usdc.decimals()) / PRICE_PRECISION;
        uint256 _sizeForSale = ((_size + 10 ** 6) * 10 ** _decimals) / SIZE_PRECISION;

        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        vm.expectRevert(Errors.TransferFromFailed.selector);
        orderBook.placeAndExecuteMarketSell(_size + 10 ** 6, 0, false, false);
        vm.stopPrank();
    }

    function testCancelOrder(uint24 _price, uint96 _size, bool _isBuy) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        if (_isBuy) {
            address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelOrders(_orders);
            vm.stopPrank();
            uint256 _quoteBalance =
                (uint256(uint24((_price * _size) / SIZE_PRECISION)) * 10 ** usdc.decimals()) / PRICE_PRECISION;
            assertEq(marginAccount.getBalance(_maker, address(usdc)), _quoteBalance);
        } else {
            address _maker = _addSellOrder(address(0), _price, _size, false);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelOrders(_orders);
            vm.stopPrank();
            assertEq(marginAccount.getBalance(_maker, address(eth)), (_size * 10 ** eth.decimals()) / SIZE_PRECISION);
        }
    }

    function testAddBuyOrderMinSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _minSize - 1;

        address _maker = genAddress();
        uint256 _amount = (uint256(uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(Errors.SizeError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderMaxSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _maxSize + 1;

        address _maker = genAddress();
        uint256 _amount = (uint256(uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(Errors.SizeError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderTickSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price -= 1; //wrong tick size

        address _maker = genAddress();
        uint256 _amount = (uint256(uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(Errors.TickSizeError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderZeroPriceError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = 0;

        address _maker = genAddress();
        uint256 _amount = (uint256(uint24((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(Errors.PriceError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testSellOrderMinSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _minSize - 1;

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(Errors.SizeError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testSellOrderMaxSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _maxSize + 1;

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(Errors.SizeError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddSellOrderTickSizeError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price -= 1; //wrong tick size

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(Errors.TickSizeError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddSellOrderZeroPriceError(uint24 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = 0;

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(Errors.PriceError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testKuruVaultInitLiquidityAddition(uint24 _price, uint96 _size) public {
        //TODO: VAULT MAY NOT HAVE ADJUSTED PRICE. TRY NOT CONFORMING TO TICK SIZE
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        address _maker = genAddress();
        uint256 _amountBase = (_size * 10 ** eth.decimals()) / SIZE_PRECISION;
        eth.mint(_maker, _amountBase);
        uint256 _amountQuote = (_amountBase * 10 ** usdc.decimals() * PRICE_PRECISION) / (_price * 10 ** eth.decimals());
        usdc.mint(_maker, _amountQuote);
        vm.startPrank(_maker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _maker);
        (, uint256 _vaultBestBid,, uint256 _vaultBestAsk,,,) = orderBook.getVaultParams();
        console.log((_vaultBestAsk * 10000000 / _vaultBestBid));
        vm.stopPrank();
    }

    function testKuruVaultMarketSell(uint24 _price, uint96 _size) public {
        //TODO: VAULT MAY NOT HAVE ADJUSTED PRICE. TRY NOT CONFORMING TO TICK SIZE
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = uint24(clampBetween(_price, 10000, _maxPrice));
        _size *= 10;
        address _maker = genAddress();
        uint256 _amountBase = (_size * 10 ** eth.decimals()) / SIZE_PRECISION;
        eth.mint(_maker, _amountBase);
        uint256 _amountQuote = (_amountBase * 10 ** usdc.decimals() * _price) / (PRICE_PRECISION * 10 ** eth.decimals());
        usdc.mint(_maker, _amountQuote);
        vm.startPrank(_maker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _maker);
        vm.stopPrank();
        address _taker = genAddress();
        eth.mint(_taker, _amountBase);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _amountBase);
        orderBook.placeAndExecuteMarketSell((_size * 7) / 10, 0, false, false);
        vm.stopPrank();
        uint256 _vaultEthBalance = marginAccount.getBalance(address(vault), address(eth));
        console.log("Vault ETH:", _vaultEthBalance);
        uint256 _vaultUsdcBalance = marginAccount.getBalance(address(vault), address(usdc));
        console.log("Vault USDC:", _vaultUsdcBalance);
        (,,, uint256 _askPrice,,,) = orderBook.getVaultParams();
        console.log((_vaultUsdcBalance * PRICE_PRECISION) / _vaultEthBalance);
        console.log(_askPrice * PRICE_PRECISION / 10 ** 18);
    }

    function testKuruVaultMarketBuy(uint24 _price, uint96 _size) public {
        //TODO: VAULT MAY NOT HAVE ADJUSTED PRICE. TRY NOT CONFORMING TO TICK SIZE
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = uint24(clampBetween(_price, 10000, _maxPrice));
        _size *= 10;
        address _maker = genAddress();
        uint256 _amountBase = (_size * 10 ** eth.decimals()) / SIZE_PRECISION;
        eth.mint(_maker, _amountBase);
        uint256 _amountQuote = (_amountBase * 10 ** usdc.decimals() * _price) / (PRICE_PRECISION * 10 ** eth.decimals());
        usdc.mint(_maker, _amountQuote);
        vm.startPrank(_maker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _maker);
        vm.stopPrank();
        address _taker = genAddress();
        usdc.mint(_taker, _amountQuote);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), _amountQuote);
        orderBook.placeAndExecuteMarketBuy(uint24(((_amountQuote / 10) * PRICE_PRECISION) / 10 ** 18), 0, false, false);
        vm.stopPrank();
        uint256 _vaultEthBalance = marginAccount.getBalance(address(vault), address(eth));
        console.log("Vault ETH:", _vaultEthBalance);
        uint256 _vaultUsdcBalance = marginAccount.getBalance(address(vault), address(usdc));
        console.log("Vault USDC:", _vaultUsdcBalance);
        (,,, uint256 _askPrice,,,) = orderBook.getVaultParams();
        console.log((_vaultUsdcBalance * PRICE_PRECISION) / _vaultEthBalance);
        console.log(_askPrice * PRICE_PRECISION / 10 ** 18);
    }

    function testKuruVaultMarketBuySpl() public {
        //TODO: VAULT MAY NOT HAVE ADJUSTED PRICE. TRY NOT CONFORMING TO TICK SIZE
        address _maker = genAddress();
        eth.mint(_maker, 1000000000 ether);
        usdc.mint(_maker, 1 ether);
        vm.startPrank(_maker);
        eth.approve(address(vault), 1000000000 ether);
        usdc.approve(address(vault), 1 ether);
        vault.deposit(1000000000 ether, 1 ether, _maker);
        vm.stopPrank();
        address _taker = genAddress();
        usdc.mint(_taker, 43 * 10 ** 16);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), 43 * 10 ** 16);
        orderBook.placeAndExecuteMarketBuy(43, 0, false, true);
        vm.stopPrank();
        uint256 _vaultEthBalance = marginAccount.getBalance(address(vault), address(eth));
        console.log("Vault ETH:", _vaultEthBalance);
        uint256 _vaultUsdcBalance = marginAccount.getBalance(address(vault), address(usdc));
        console.log("Vault USDC:", _vaultUsdcBalance);
        (,,, uint256 _askPrice,,,) = orderBook.getVaultParams();
        console.log((_vaultUsdcBalance * PRICE_PRECISION) / _vaultEthBalance);
        console.log(_askPrice * PRICE_PRECISION / 10 ** 18);
    }

    function testKuruVaultRepeatedMarketSell(uint256 _targetVaultPrice, uint96 _targetVaultSize) public {
        (_targetVaultPrice, _targetVaultSize) = _adjustPriceAndSizeForVault(_targetVaultPrice, _targetVaultSize);
        uint256 _amountBase = (_targetVaultSize * 10 ** eth.decimals()) / SIZE_PRECISION;
        uint256 _amountQuote =
            (_targetVaultSize * 10 ** usdc.decimals() * _targetVaultPrice) / (vaultPricePrecision * SIZE_PRECISION);
        address _vaultMaker = genAddress();
        eth.mint(_vaultMaker, _amountBase);
        usdc.mint(_vaultMaker, _amountQuote);
        vm.startPrank(_vaultMaker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _vaultMaker);
        vm.stopPrank();
        for (uint256 i; i < 20; i++) {
            uint96 _takerBaseSize = _targetVaultSize / 10; //fill 1/10th of the vault size
            uint256 _takerBaseAmount = (_takerBaseSize * 10 ** eth.decimals()) / SIZE_PRECISION;
            address _takerAddress = genAddress();
            eth.mint(_takerAddress, _takerBaseAmount);
            vm.startPrank(_takerAddress);
            eth.approve(address(orderBook), _takerBaseAmount);
            orderBook.placeAndExecuteMarketSell(_takerBaseSize, 0, false, true);
            vm.stopPrank();
        }
        uint256 _vaultEthBalance = marginAccount.getBalance(address(vault), address(eth));
        console.log("Vault ETH:", _vaultEthBalance);
        uint256 _vaultUsdcBalance = marginAccount.getBalance(address(vault), address(usdc));
        console.log("Vault USDC:", _vaultUsdcBalance);
        (,,, uint256 _askPrice,,,) = orderBook.getVaultParams();
        uint256 _actualPrice = (_vaultUsdcBalance * 10 ** 18) / _vaultEthBalance;
        console.log(_actualPrice);
        console.log(_askPrice);
    }

    function testKuruVaultPartiallyFilledBidFullyFilledAsk(uint256 _targetVaultPrice, uint96 _targetVaultSize) public {
        (_targetVaultPrice, _targetVaultSize) = _adjustPriceAndSizeForVault(_targetVaultPrice, _targetVaultSize);
        uint256 _amountBase = (_targetVaultSize * 10 ** eth.decimals()) / SIZE_PRECISION;
        uint256 _amountQuote =
            (_targetVaultSize * 10 ** usdc.decimals() * _targetVaultPrice) / (vaultPricePrecision * SIZE_PRECISION);
        address _vaultMaker = genAddress();
        eth.mint(_vaultMaker, _amountBase);
        usdc.mint(_vaultMaker, _amountQuote);
        vm.startPrank(_vaultMaker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _vaultMaker);
        vm.stopPrank();
        (,,, uint256 _vaultBestAsk,, uint96 _vaultBidOrderSize, uint96 _vaultAskOrderSize) = orderBook.getVaultParams();
        uint256 _bidTakerBaseAmount = (_vaultBidOrderSize * 10 ** eth.decimals()) / (2 * SIZE_PRECISION); //half of bid order size
        address _partialBidTaker = genAddress();
        eth.mint(_partialBidTaker, _bidTakerBaseAmount);
        vm.startPrank(_partialBidTaker);
        eth.approve(address(orderBook), _bidTakerBaseAmount);
        orderBook.placeAndExecuteMarketSell(_vaultBidOrderSize / 2, 0, false, true);
        vm.stopPrank();
        address _fullAskTaker = genAddress();
        uint256 _quoteForFillingAsk = (
            (((_vaultAskOrderSize * _vaultBestAsk) * 12) / (10 * SIZE_PRECISION)) * 10 ** usdc.decimals()
        ) / vaultPricePrecision;
        usdc.mint(_fullAskTaker, _quoteForFillingAsk);
        vm.startPrank(_fullAskTaker);
        usdc.approve(address(orderBook), _quoteForFillingAsk);
        orderBook.placeAndExecuteMarketBuy(uint24((_quoteForFillingAsk * PRICE_PRECISION) / 10 ** 18), 0, false, true);
        (,,, uint256 _vaultBestAskNew,, uint96 _vaultBidOrderSizeNew, uint96 _vaultAskOrderSizeNew) =
            orderBook.getVaultParams();
        console.log(_vaultBestAskNew * 1000 / _vaultBestAsk);
    }

    function testKuruVaultRevertWrongPriceAsserted(uint256 _targetVaultPrice, uint96 _targetVaultSize) public {
        _targetVaultPrice = clampBetween(
            _targetVaultPrice, vaultPricePrecision * 3 / 2, _maxPrice * vaultPricePrecision / PRICE_PRECISION
        );
        _targetVaultSize = uint96(clampBetween(_targetVaultSize, _minSize + 1, _maxSize * 2));
        uint256 _amountBase = (_targetVaultSize * 10 ** eth.decimals()) / SIZE_PRECISION;
        uint256 _amountQuote =
            (_targetVaultSize * 10 ** usdc.decimals() * _targetVaultPrice) / (vaultPricePrecision * SIZE_PRECISION);
        address _vaultMaker = genAddress();
        eth.mint(_vaultMaker, _amountBase);
        usdc.mint(_vaultMaker, _amountQuote);
        vm.startPrank(_vaultMaker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _vaultMaker);
        vm.stopPrank();
        _targetVaultPrice = 10 ** 18;
        _amountBase = (_targetVaultSize * 10 ** eth.decimals()) / SIZE_PRECISION;
        _amountQuote =
            (_targetVaultSize * 10 ** usdc.decimals() * _targetVaultPrice) / (vaultPricePrecision * SIZE_PRECISION);
        _vaultMaker = genAddress();
        eth.mint(_vaultMaker, _amountBase);
        usdc.mint(_vaultMaker, _amountQuote);
        vm.startPrank(_vaultMaker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vm.expectRevert("KuruAMMVault: INSUFFICIENT TOKEN SUPPLIED");
        vault.deposit(_amountBase, _amountQuote, _vaultMaker);
        vm.stopPrank();
    }

    function testKuruVaultRevertInitialDepositMinSize() public {
        uint256 _amountBase = 10 * 10 ** 18;
        uint256 _amountQuote = 10 * 10 ** 18;
        address _vaultMaker = genAddress();
        eth.mint(_vaultMaker, _amountBase);
        usdc.mint(_vaultMaker, _amountQuote);
        vm.startPrank(_vaultMaker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        vault.deposit(_amountBase, _amountQuote, _vaultMaker);
        vm.stopPrank();
        _amountBase = 0;
        _amountQuote = 0;
        vm.startPrank(_vaultMaker);
        vm.expectRevert("KuruAMMVault: INSUFFICIENT_LIQUIDITY_MINTED");
        vault.deposit(0, 0, _vaultMaker);
        vm.stopPrank();
    }

    function testKuruVaultReverPartialFilledSizeExceedsNewSize(uint256 _targetVaultPrice, uint96 _targetVaultSize)
        public
    {
        (_targetVaultPrice, _targetVaultSize) = _adjustPriceAndSizeForVault(_targetVaultPrice, _targetVaultSize);
        uint256 _amountBase = (_targetVaultSize * 10 ** eth.decimals()) / SIZE_PRECISION;
        uint256 _amountQuote =
            (_targetVaultSize * 10 ** usdc.decimals() * _targetVaultPrice) / (vaultPricePrecision * SIZE_PRECISION);
        address _vaultMaker = genAddress();
        eth.mint(_vaultMaker, _amountBase);
        usdc.mint(_vaultMaker, _amountQuote);
        vm.startPrank(_vaultMaker);
        eth.approve(address(vault), _amountBase);
        usdc.approve(address(vault), _amountQuote);
        uint256 _shares = vault.deposit(_amountBase, _amountQuote, _vaultMaker);
        vm.stopPrank();
        (,,, uint256 _vaultBestAsk,, uint96 _vaultBidOrderSize, uint96 _vaultAskOrderSize) = orderBook.getVaultParams();
        uint256 _bidTakerBaseAmount = (_vaultBidOrderSize * 10 ** eth.decimals()) / (2 * SIZE_PRECISION); //half of bid order size
        address _partialBidTaker = genAddress();
        eth.mint(_partialBidTaker, _bidTakerBaseAmount);
        vm.startPrank(_partialBidTaker);
        eth.approve(address(orderBook), _bidTakerBaseAmount);
        orderBook.placeAndExecuteMarketSell(_vaultBidOrderSize / 2, 0, false, true);
        vm.stopPrank();
        vm.startPrank(_vaultMaker);
        vm.expectRevert(KuruAMMVault.NewSizeExceedsPartiallyFilledSize.selector);
        vault.withdraw(_shares, _vaultMaker, _vaultMaker);
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
