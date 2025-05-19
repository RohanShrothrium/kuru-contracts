//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "../contracts/libraries/FixedPointMathLib.sol";
import {OrderBookErrors, KuruAMMVaultErrors, MarginAccountErrors} from "../contracts/libraries/Errors.sol";
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
    uint32 constant PRICE_PRECISION = 10 ** 2;
    uint32 _tickSize;
    uint96 _minSize;
    uint96 _maxSize;
    uint96 _takerFeeBps;
    uint256 _makerFeeBps;
    uint32 _maxPrice;
    uint256 vaultPricePrecision;
    OrderBook orderBook;
    KuruAMMVault vault;
    Router router;
    MarginAccount marginAccount;

    MintableERC20 eth;
    MintableERC20 usdc;
    uint256 SEED = 2;
    address lastGenAddress;
    address trustedForwarder;

    function setUp() public {
        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USDC", "USDC");
        uint96 _sizePrecision = 10 ** 10;
        uint32 _pricePrecision = 10 ** 2;
        vaultPricePrecision = 10 ** 18;
        _tickSize = _pricePrecision / 2;
        _minSize = 2 * 10 ** 8;
        _maxSize = 10 ** 12;
        _maxPrice = type(uint32).max / 200;
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
        trustedForwarder = address(0x123);
        marginAccount = new MarginAccount();
        marginAccount = MarginAccount(payable(address(new ERC1967Proxy(address(marginAccount), ""))));
        marginAccount.initialize(address(this), address(router), address(router), trustedForwarder);
        uint96 SPREAD = 100;
        KuruAMMVault kuruAmmVaultImplementation = new KuruAMMVault();
        router.initialize(address(this), address(marginAccount), address(implementation), address(kuruAmmVaultImplementation), trustedForwarder);

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
        (address _kuruVault,,,,,,,) = orderBook.getVaultParams();
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

    function _adjustPriceAndSize(uint32 _price, uint96 _size) internal returns (uint32, uint96) {
        uint32 _newPrice = uint32(clampBetween(_price, _tickSize, _maxPrice));
        uint96 _newSize = uint96(clampBetween(_size, _minSize + 1, _maxSize - 1));
        _newPrice = _newPrice - _newPrice % _tickSize;

        return (_newPrice, _newSize);
    }

    function _adjustPriceAndSizeFlip(uint32 _price, uint32 _flipPrice, uint96 _size, bool isBuy)
        internal
        returns (uint32, uint32, uint96)
    {
        uint32 _newPrice = uint32(clampBetween(_price, _tickSize, _maxPrice - 3 * _tickSize));
        uint32 _newFlipPrice = uint32(
            clampBetween(
                _flipPrice, isBuy ? _newPrice + _tickSize : _tickSize, isBuy ? _maxPrice : _newPrice - _tickSize
            )
        );
        uint96 _newSize = uint96(clampBetween(_size, _minSize + 1, _maxSize - 1));
        _newPrice = _newPrice - _newPrice % _tickSize;
        _newFlipPrice = _newFlipPrice - _newFlipPrice % _tickSize;
        return (_newPrice, _newFlipPrice, _newSize);
    }

    function _adjustPriceAndSizeForVault(uint256 _price, uint96 _size) internal returns (uint256, uint96) {
        _price = clampBetween(_price, vaultPricePrecision / 2, _maxPrice * vaultPricePrecision / PRICE_PRECISION);
        _size = uint96(clampBetween(_size, _minSize + 1, _maxSize * 2));
        return (_price, _size);
    }

    function _amountPayableInQuote(uint32 _price, uint96 _size) internal view returns (uint256) {
        return ((uint256(((_price * _size) / SIZE_PRECISION)) * 10 ** usdc.decimals())) / PRICE_PRECISION;
    }

    function _calculateFeePortions(uint256 _amount) internal view returns (uint256, uint256) {
        if (_takerFeeBps > 0) {
            uint256 _totalFee = (FixedPointMathLib.mulDivUp(_amount, _takerFeeBps, 10 ** 4));
            uint256 _protocolFee = ((_totalFee * (_takerFeeBps - _makerFeeBps)) / _takerFeeBps);
            uint256 _makerFee = ((_amount * (_makerFeeBps)) / 10 ** 4);
            return (_protocolFee, _makerFee);
        }
        return (0, 0);
    }

    function _addBuyOrder(address _maker, uint32 _price, uint96 _size, uint32 extra, bool _postOnly)
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

    function _addFlipBuyOrder(address _maker, uint32 _price, uint32 _flippedPrice, uint96 _size, uint32 extra)
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
        orderBook.addFlipBuyOrder(_price, _flippedPrice, _size, true);
        vm.stopPrank();
        return _maker;
    }

    function _addSellOrder(address _maker, uint32 _price, uint96 _size, bool _postOnly) internal returns (address) {
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

    function _addFlipSellOrder(address _maker, uint32 _price, uint32 _flippedPrice, uint96 _size)
        internal
        returns (address)
    {
        if (_maker == address(0)) {
            _maker = genAddress();
        }
        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        orderBook.addFlipSellOrder(_price, _flippedPrice, _size, true);
        vm.stopPrank();

        return _maker;
    }

    function testAddBuyOrderNoPostOnly(uint32 _price, uint96 _size) public {
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

    /**
     * test add flip order for buy -> test for if order is added, test for checking matching
     * test add flip order for sell -> test for if order is added, test for checking matching
     */
    function testAddBuyFlipOrder(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        _flippedPrice = uint32(bound(_flippedPrice, _price + _tickSize, _maxPrice));
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, true);
        _addFlipBuyOrder(address(0), _price, _flippedPrice, _size, 0);
        assertEq(orderBook.s_orderIdCounter(), 1);
        (uint40 head, uint40 tail) = orderBook.s_buyPricePoints(_price);
        assertEq(head, 1);
        assertEq(tail, 1);
    }

    function testAddBuyFlipOrderPartialFill(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        _flippedPrice = uint32(bound(_flippedPrice, _price + _tickSize, _maxPrice));
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, true);
        _addFlipBuyOrder(address(0), _price, _flippedPrice, _size, 0);
        uint256 _sizeToSell = (_size / 2) * 10 ** eth.decimals() / SIZE_PRECISION; //half the size
        address _taker = genAddress();
        eth.mint(_taker, _sizeToSell);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeToSell);
        orderBook.placeAndExecuteMarketSell(_size / 2, 0, false, false);
        vm.stopPrank();
        (,,,, uint40 initFlippedId,, uint32 initFlippedPrice,) = orderBook.s_orders(1);
        assertEq(initFlippedId, 2);
        assertEq(initFlippedPrice, _flippedPrice);
        (,,,, uint40 flippedFlippedId,, uint32 flippedFlippedPrice,) = orderBook.s_orders(2);
        assertEq(flippedFlippedId, 1);
        assertEq(flippedFlippedPrice, _price);
    }

    function testAddBuyFlipOrderFullFill(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        _flippedPrice = uint32(bound(_flippedPrice, _price + _tickSize, _maxPrice));
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, true);
        _addFlipBuyOrder(address(0), _price, _flippedPrice, _size, 0);
        uint256 _sizeToSell = (_size + 10 ** 6) * 10 ** eth.decimals() / SIZE_PRECISION; //half the size
        address _taker = genAddress();
        eth.mint(_taker, _sizeToSell);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeToSell);
        orderBook.placeAndExecuteMarketSell(_size + 10 ** 6, 0, false, false);
        vm.stopPrank();
        (,,,, uint40 initFlippedId,, uint32 initFlippedPrice,) = orderBook.s_orders(1);
        assertEq(initFlippedId, 0);
        assertEq(initFlippedPrice, _flippedPrice);
        (,,,, uint40 flippedFlippedId,, uint32 flippedFlippedPrice,) = orderBook.s_orders(2);
        assertEq(flippedFlippedId, 0);
        assertEq(flippedFlippedPrice, _price);
    }

    function testAddBuyFlipOrderFullFillAndPartialFill(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        _flippedPrice = uint32(bound(_flippedPrice, _price + _tickSize, _maxPrice));
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, true);
        testAddBuyFlipOrderFullFill(_price, _flippedPrice, _size);
        uint96 _sizeToBuy = _size / 2;
        uint256 _quoteToBuy = ((_sizeToBuy * _flippedPrice) / SIZE_PRECISION) * 10 ** usdc.decimals() / PRICE_PRECISION;
        address _taker = genAddress();
        usdc.mint(_taker, _quoteToBuy);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), _quoteToBuy);
        orderBook.placeAndExecuteMarketBuy(
            uint96(_quoteToBuy * PRICE_PRECISION / 10 ** usdc.decimals()), 0, false, false
        );
        vm.stopPrank();
        (,,,, uint40 flippedId1,, uint32 flippedPrice1,) = orderBook.s_orders(1);
        assertEq(flippedId1, 0);
        assertEq(flippedPrice1, _flippedPrice);
        (,,,, uint40 flippedId2,, uint32 flippedPrice2,) = orderBook.s_orders(2);
        assertEq(flippedId2, 3);
        assertEq(flippedPrice2, _price);
        (,,,, uint40 flippedId3,, uint32 flippedPrice3,) = orderBook.s_orders(3);
        assertEq(flippedId3, 2);
        assertEq(flippedPrice3, _flippedPrice);
    }

    function testAddBuyOrderPostOnly(uint32 _price, uint96 _size) public {
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

    function testAddBuyOrderRevertInsufficientBalance(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _size)) - 1) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(MarginAccountErrors.InsufficientBalance.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderRevertPostOnly(uint32 _price, uint96 _size) public {
        _price = uint32(clampBetween(_price, _tickSize, _maxPrice));
        _price = _price - _price % _tickSize;
        _size = uint96(clampBetween(_size, _minSize + 2, _maxSize - 2));

        _addSellOrder(address(0), _price, _size - 1, false);

        uint96 _buySize = _size; //extra size of 1 than the sell order
        address _maker = genAddress();
        uint256 _amount = (uint256(mulDivUp(_price, _buySize)) + 1) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(OrderBookErrors.PostOnlyError.selector);
        orderBook.addBuyOrder(_price, _buySize, true);
        vm.stopPrank();
    }

    function testAddBuyOrderRevertLessBalance(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = genAddress();
        //minting 1 price precision less here
        uint256 _amount = (uint256(mulDivUp(_price, _size)) - 1) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(MarginAccountErrors.InsufficientBalance.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddSellFlipOrder(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        vm.assume(_size > _minSize && _size < _maxSize);
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, false);
        _addFlipSellOrder(address(0), _price, _flippedPrice, _size);
        assertEq(orderBook.s_orderIdCounter(), 1);
        (uint40 head, uint40 tail) = orderBook.s_sellPricePoints(_price);
        assertEq(head, 1);
        assertEq(tail, 1);
    }

    function testAddSellFlipOrderPartialFill(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        vm.assume(_size > _minSize && _size < _maxSize);
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, false);
        _addFlipSellOrder(address(0), _price, _flippedPrice, _size);
        uint96 _sizeToBuy = _size / 2;
        uint256 _quoteToBuy = ((_sizeToBuy * _price) / SIZE_PRECISION) * 10 ** usdc.decimals() / PRICE_PRECISION;
        address _taker = genAddress();
        usdc.mint(_taker, _quoteToBuy);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), _quoteToBuy);
        orderBook.placeAndExecuteMarketBuy(
            uint96(_quoteToBuy * PRICE_PRECISION / 10 ** usdc.decimals()), 0, false, false
        );
        vm.stopPrank();
        (,,,, uint40 flippedId1,, uint32 flippedPrice1,) = orderBook.s_orders(1);
        assertEq(flippedId1, 2);
        assertEq(flippedPrice1, _flippedPrice);
        (,,,, uint40 flippedId2,, uint32 flippedPrice2,) = orderBook.s_orders(2);
        assertEq(flippedId2, 1);
        assertEq(flippedPrice2, _price);
    }

    function testAddSellFlipOrderFullFill(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        vm.assume(_size > _minSize && _size < _maxSize);
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, false);
        _addFlipSellOrder(address(0), _price, _flippedPrice, _size);
        uint256 _sizeToBuy = _size + 10 ** 10;
        uint256 _quoteToBuy =
            (((_sizeToBuy + 10 ** 6) * _price) / SIZE_PRECISION) * 10 ** usdc.decimals() / PRICE_PRECISION;
        address _taker = genAddress();
        usdc.mint(_taker, _quoteToBuy);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), _quoteToBuy);
        orderBook.placeAndExecuteMarketBuy(
            uint96(_quoteToBuy * PRICE_PRECISION / 10 ** usdc.decimals()), 0, false, false
        );
        vm.stopPrank();
        (,,,, uint40 flippedId1,, uint32 flippedPrice1,) = orderBook.s_orders(1);
        assertEq(flippedId1, 0);
        assertEq(flippedPrice1, _flippedPrice);
        (,,,, uint40 flippedId2,, uint32 flippedPrice2,) = orderBook.s_orders(2);
        assertEq(flippedId2, 0);
        assertEq(flippedPrice2, _price);
    }

    function testAddSellFlipOrderFullFillAndPartialFill(uint32 _price, uint32 _flippedPrice, uint96 _size) public {
        vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
        vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
        vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
        vm.assume(_size > _minSize && _size < _maxSize);
        (_price, _flippedPrice, _size) = _adjustPriceAndSizeFlip(_price, _flippedPrice, _size, false);
        testAddSellFlipOrderFullFill(_price, _flippedPrice, _size);
        uint256 _sizeToSell = (_size / 2) * 10 ** eth.decimals() / SIZE_PRECISION;
        address _taker = genAddress();
        eth.mint(_taker, _sizeToSell);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeToSell);
        orderBook.placeAndExecuteMarketSell(_size / 2, 0, false, false);
        vm.stopPrank();
        (,,,, uint40 flippedId1,, uint32 flippedPrice1,) = orderBook.s_orders(1);
        assertEq(flippedId1, 0);
        assertEq(flippedPrice1, _flippedPrice);
        (,,,, uint40 flippedId2,, uint32 flippedPrice2,) = orderBook.s_orders(2);
        assertEq(flippedId2, 3);
        assertEq(flippedPrice2, _price);
        (,,,, uint40 flippedId3,, uint32 flippedPrice3,) = orderBook.s_orders(3);
        assertEq(flippedId3, 2);
        assertEq(flippedPrice3, _flippedPrice);
    }

    function testAddSellOrderNoPostOnly(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        assertEq(eth.balanceOf(address(marginAccount)), _amount);
        assertEq(eth.balanceOf(_maker), 0);
        assertEq(marginAccount.getBalance(_maker, address(eth)), 0);
    }

    function testAddSellOrderPostOnly(uint32 _price, uint96 _size) public {
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

    function testAddSellOrderRevertPostOnly(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        //Executing dummy buy order at same price
        _addBuyOrder(address(0), _price, _size, 0, false);

        address _maker = genAddress();
        uint256 _amount = (_size * 10 ** eth.decimals()) / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(OrderBookErrors.PostOnlyError.selector);
        orderBook.addSellOrder(_price, _size, true);
        vm.stopPrank();
    }

    function testBuyAndSellEqualMatch(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
        address _taker = _addSellOrder(address(0), _price, _size, false);
        uint256 _usdcWithoutFee =
            uint256((uint32((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
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

    function testSellAndBuyEqualMatch(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        address _taker = _addBuyOrder(address(0), _price, _size, 1, false);
        uint256 _usdc = uint256(uint32((_price * _size) / SIZE_PRECISION)) * 10 ** usdc.decimals() / PRICE_PRECISION;
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

    function testCancelBuyOrder(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addBuyOrder(address(0), _price, _size, 0, false);

        uint40[] memory _cancelId = new uint40[](1);
        _cancelId[0] = 1;
        vm.startPrank(_maker);
        orderBook.batchCancelOrders(_cancelId);
        vm.stopPrank();
        uint256 _amount = (uint256(uint32((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        assertEq(marginAccount.getBalance(_maker, address(usdc)), _amount);
        vm.prank(_maker);
        marginAccount.withdraw(_amount, address(usdc));
        assertEq(usdc.balanceOf(_maker), _amount);
    }

    function testCancelSellOrder(uint32 _price, uint96 _size) public {
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

    function testMarketBuy(uint32 _priceA, uint96 _sizeA, uint32 _priceB, uint96 _sizeB) public {
        uint256 decimals = usdc.decimals();

        //Claming price and size of our two sell orders
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);

        address _makerA = _addSellOrder(address(0), _priceA, _sizeA, false);
        address _makerB = _addSellOrder(address(0), _priceB, _sizeB, false);

        //Expected quote tokens to be supplied for filling each sell order
        uint96 _amountA = mulDivUp(_priceA, _sizeA);
        uint96 _amountB = mulDivUp(_priceB, _sizeB);

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

        uint96 _totalAmount = _amountA + _amountB;

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

    function testMarketBuyMargin(uint32 _priceA, uint96 _sizeA, uint32 _priceB, uint96 _sizeB) public {
        uint256 decimals = usdc.decimals();

        //Claming price and size of our two sell orders
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);

        address _makerA = _addSellOrder(address(0), _priceA, _sizeA, false);
        address _makerB = _addSellOrder(address(0), _priceB, _sizeB, false);

        //Expected quote tokens to be supplied for filling each sell order
        uint96 _amountA = mulDivUp(_priceA, _sizeA);
        uint96 _amountB = mulDivUp(_priceB, _sizeB);

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

        uint96 _totalAmount = _amountA + _amountB;

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

    function testMarketBuyPartialFill(uint32 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        address _maker = _addSellOrder(address(0), _price, _size, false);
        uint96 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint96 _quoteExtra = _quoteTokens + 101; //Extra for partial fill
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

    function testMarketBuyRevertFillOrKill(uint32 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        _addSellOrder(address(0), _price, _size, false);
        uint96 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint96 _quoteExtra = _quoteTokens + 101; //Extra for partial fill

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        usdc.approve(address(orderBook), (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.expectRevert(OrderBookErrors.InsufficientLiquidity.selector);
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, 0, false, true);
        vm.stopPrank();
    }

    function testMarketBuyInsufficientAllowance(uint32 _price, uint96 _size) public {
        uint256 _decimals = usdc.decimals(); //caching to avoid startPrank glitch
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        _addSellOrder(address(0), _price, _size, false);
        uint96 _quoteTokens = mulDivUp(_price, _size); //Quote tokens needed to fill
        uint96 _quoteExtra = _quoteTokens + 101; //Extra for partial fill

        address _taker = genAddress();
        usdc.mint(_taker, (_quoteExtra * 10 ** _decimals) / PRICE_PRECISION);
        vm.startPrank(_taker);
        vm.expectRevert(OrderBookErrors.TransferFromFailed.selector);
        orderBook.placeAndExecuteMarketBuy(_quoteExtra, 0, false, false);
        vm.stopPrank();
    }

    function testMarketSell(uint32 _priceA, uint96 _sizeA, uint32 _priceB, uint96 _sizeB) public {
        uint256 _decimals = eth.decimals();
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);
        //Adding two buy orders which need to get filled
        address _makerA = _addBuyOrder(address(0), _priceA, _sizeA, 0, false);
        uint256 _expectedQuoteA = _amountPayableInQuote(_priceA, _sizeA);
        uint256 _expectedRebateA = (_expectedQuoteA * _makerFeeBps) / 10 ** 4;
        address _makerB = _addBuyOrder(address(0), _priceB, _sizeB, 0, false);
        uint256 _expectedQuoteB = _amountPayableInQuote(_priceB, _sizeB);

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

    function testMarketSellMargin(uint32 _priceA, uint96 _sizeA, uint32 _priceB, uint96 _sizeB) public {
        uint256 _decimals = eth.decimals();
        (_priceA, _sizeA) = _adjustPriceAndSize(_priceA, _sizeA);
        (_priceB, _sizeB) = _adjustPriceAndSize(_priceB, _sizeB);
        //Adding two buy orders which need to get filled
        address _makerA = _addBuyOrder(address(0), _priceA, _sizeA, 0, false);
        uint256 _expectedQuoteA = _amountPayableInQuote(_priceA, _sizeA);
        uint256 _expectedRebateA = (_expectedQuoteA * _makerFeeBps) / 10 ** 4;
        address _makerB = _addBuyOrder(address(0), _priceB, _sizeB, 0, false);
        uint256 _expectedQuoteB = _amountPayableInQuote(_priceB, _sizeB);

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
        assertGte(
            marginAccount.getBalance(_taker, address(usdc)), _expectedQuote - _quoteTolerance, "Too less quote credit"
        );
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

    function testMarketSellPartialFill(uint32 _price, uint96 _size) public {
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

    function testMarketSellRevertFillOrKill(uint32 _price, uint96 _size) public {
        uint256 _decimals = eth.decimals();
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _sizeForSale = ((_size + 10 ** 6) * 10 ** _decimals) / SIZE_PRECISION; //extra 10**6 size for partial fill

        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        eth.approve(address(orderBook), _sizeForSale);
        vm.expectRevert(OrderBookErrors.InsufficientLiquidity.selector);
        orderBook.placeAndExecuteMarketSell(_size + 10 ** 6, 0, false, true);
        vm.stopPrank();
    }

    function testMarketSellInsufficientAllowance(uint32 _price, uint96 _size) public {
        uint256 _decimals = eth.decimals();
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        _addBuyOrder(address(0), _price, _size, 0, false);

        uint256 _sizeForSale = ((_size + 10 ** 6) * 10 ** _decimals) / SIZE_PRECISION;

        address _taker = genAddress();
        eth.mint(_taker, _sizeForSale);
        vm.startPrank(_taker);
        vm.expectRevert(OrderBookErrors.TransferFromFailed.selector);
        orderBook.placeAndExecuteMarketSell(_size + 10 ** 6, 0, false, false);
        vm.stopPrank();
    }

    function testCancelFlipOrderCase1(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _isBuy) public {
        if (_isBuy) {
            vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            testAddBuyFlipOrder(_price, _flippedPrice, _size);
            (address _maker, uint96 _size,,,, uint32 _price,,) = orderBook.s_orders(1);
            uint256 _makerMarginBefore = marginAccount.getBalance(_maker, address(usdc));
            vm.startPrank(_maker);
            marginAccount.withdraw(_makerMarginBefore, address(usdc));
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelFlipOrders(_orders);
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            uint256 _makerMarginAfter = marginAccount.getBalance(_maker, address(usdc));
            uint256 _expectedMargin = (_price * _size / SIZE_PRECISION) * 10 ** usdc.decimals() / PRICE_PRECISION;
            assertEq(_makerMarginAfter, _expectedMargin);
            marginAccount.withdraw(_expectedMargin, address(usdc));
        } else {
            vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            vm.assume(_size > _minSize && _size < _maxSize);
            testAddSellFlipOrder(_price, _flippedPrice, _size);
            (address _maker, uint96 _size,,,,,,) = orderBook.s_orders(1);
            uint256 _makerMarginBefore = marginAccount.getBalance(_maker, address(eth));
            vm.startPrank(_maker);
            marginAccount.withdraw(_makerMarginBefore, address(eth));
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelFlipOrders(_orders);
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            uint256 _makerMarginAfter = marginAccount.getBalance(_maker, address(eth));
            uint256 _expectedMargin = _size * 10 ** eth.decimals() / SIZE_PRECISION;
            assertEq(_makerMarginAfter, _expectedMargin);
            marginAccount.withdraw(_expectedMargin, address(eth));
        }
    }

    function testCancelFlipOrderCase2(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _isBuy) public {
        if (_isBuy) {
            vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            testAddBuyFlipOrderPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelFlipOrders(_orders);
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        } else {
            vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            vm.assume(_size > _minSize && _size < _maxSize);
            testAddSellFlipOrderPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelFlipOrders(_orders);
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        }
    }

    function testCancelFlipOrderCase3(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _isBuy) public {
        if (_isBuy) {
            vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            testAddBuyFlipOrderFullFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        } else {
            vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            vm.assume(_size > _minSize && _size < _maxSize);
            testAddSellFlipOrderFullFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        }
    }

    function testCancelFlipOrderCase4(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _isBuy) public {
        if (_isBuy) {
            vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            testAddBuyFlipOrderFullFillAndPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 3;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        } else {
            vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            vm.assume(_size > _minSize && _size < _maxSize);
            testAddSellFlipOrderFullFillAndPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 3;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        }
    }

    function testCancelFlipOrderCase5(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _isBuy) public {
        if (_isBuy) {
            vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            testAddBuyFlipOrderFullFillAndPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 3;
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        } else {
            vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            vm.assume(_size > _minSize && _size < _maxSize);
            testAddSellFlipOrderFullFillAndPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 3;
            orderBook.batchCancelFlipOrders(_orders);
            _orders[0] = 2;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
        }
    }

    function testCancelFlipOrderCase6(uint32 _price, uint32 _flippedPrice, uint96 _size, bool _isBuy, bool _interChange)
        public
    {
        if (_isBuy) {
            vm.assume(_flippedPrice > _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_price > _tickSize && _flippedPrice > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            testAddBuyFlipOrderFullFillAndPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](2);
            _orders[0] = _interChange ? 2 : 3;
            _orders[1] = _interChange ? 3 : 2;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        } else {
            vm.assume(_flippedPrice < _price && _price != 0 && _flippedPrice != 0);
            vm.assume(_flippedPrice > _tickSize && _price > 2 * _tickSize);
            vm.assume(_price < _maxPrice && _flippedPrice < _maxPrice);
            vm.assume(_size > _minSize && _size < _maxSize);
            testAddSellFlipOrderFullFillAndPartialFill(_price, _flippedPrice, _size);
            (address _maker,,,,,,,) = orderBook.s_orders(1);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](2);
            _orders[0] = _interChange ? 2 : 3;
            _orders[1] = _interChange ? 3 : 2;
            vm.expectRevert(OrderBookErrors.OrderAlreadyFilledOrCancelled.selector);
            orderBook.batchCancelFlipOrders(_orders);
            vm.stopPrank();
        }
    }

    function testCancelOrder(uint32 _price, uint96 _size, bool _isBuy) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);

        if (_isBuy) {
            address _maker = _addBuyOrder(address(0), _price, _size, 0, false);
            vm.startPrank(_maker);
            uint40[] memory _orders = new uint40[](1);
            _orders[0] = 1;
            orderBook.batchCancelOrders(_orders);
            vm.stopPrank();
            uint256 _quoteBalance =
                (uint256(uint32((_price * _size) / SIZE_PRECISION)) * 10 ** usdc.decimals()) / PRICE_PRECISION;
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

    function testAddBuyOrderMinSizeError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _minSize - 1;

        address _maker = genAddress();
        uint256 _amount = (uint256(uint32((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(OrderBookErrors.SizeError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderMaxSizeError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _maxSize + 1;

        address _maker = genAddress();
        uint256 _amount = (uint256(uint32((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(OrderBookErrors.SizeError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderTickSizeError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price -= 1; //wrong tick size

        address _maker = genAddress();
        uint256 _amount = (uint256(uint32((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(OrderBookErrors.TickSizeError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderZeroPriceError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = 0;

        address _maker = genAddress();
        uint256 _amount = (uint256(uint32((_price * _size) / SIZE_PRECISION))) * 10 ** usdc.decimals() / PRICE_PRECISION;
        usdc.mint(_maker, _amount);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(usdc), _amount);
        vm.expectRevert(OrderBookErrors.PriceError.selector);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testSellOrderMinSizeError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _minSize - 1;

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(OrderBookErrors.SizeError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testSellOrderMaxSizeError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _size = _maxSize + 1;

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(OrderBookErrors.SizeError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddSellOrderTickSizeError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price -= 1; //wrong tick size

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(OrderBookErrors.TickSizeError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testAddSellOrderZeroPriceError(uint32 _price, uint96 _size) public {
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = 0;

        address _maker = genAddress();

        uint256 _amount = _size * 10 ** eth.decimals() / SIZE_PRECISION;
        eth.mint(_maker, _amount);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _amount);
        marginAccount.deposit(_maker, address(eth), _amount);
        vm.expectRevert(OrderBookErrors.PriceError.selector);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function testKuruVaultInitLiquidityAddition(uint32 _price, uint96 _size) public {
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
        (, uint256 _vaultBestBid,, uint256 _vaultBestAsk,,,,) = orderBook.getVaultParams();
        console.log((_vaultBestAsk * 10000000 / _vaultBestBid));
        vm.stopPrank();
    }

    function testKuruVaultMarketSell(uint32 _price, uint96 _size) public {
        //TODO: VAULT MAY NOT HAVE ADJUSTED PRICE. TRY NOT CONFORMING TO TICK SIZE
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = uint32(clampBetween(_price, 10000, _maxPrice));
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
        (,,, uint256 _askPrice,,,,) = orderBook.getVaultParams();
        console.log((_vaultUsdcBalance * PRICE_PRECISION) / _vaultEthBalance);
        console.log(_askPrice * PRICE_PRECISION / 10 ** 18);
    }

    function testKuruVaultMarketBuy(uint32 _price, uint96 _size) public {
        //TODO: VAULT MAY NOT HAVE ADJUSTED PRICE. TRY NOT CONFORMING TO TICK SIZE
        (_price, _size) = _adjustPriceAndSize(_price, _size);
        _price = uint32(clampBetween(_price, 10000, _maxPrice));
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
        orderBook.placeAndExecuteMarketBuy(uint32(((_amountQuote / 10) * PRICE_PRECISION) / 10 ** 18), 0, false, false);
        vm.stopPrank();
        uint256 _vaultEthBalance = marginAccount.getBalance(address(vault), address(eth));
        console.log("Vault ETH:", _vaultEthBalance);
        uint256 _vaultUsdcBalance = marginAccount.getBalance(address(vault), address(usdc));
        console.log("Vault USDC:", _vaultUsdcBalance);
        (,,, uint256 _askPrice,,,,) = orderBook.getVaultParams();
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
        (,,, uint256 _askPrice,,,,) = orderBook.getVaultParams();
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
        (,,, uint256 _askPrice,,,,) = orderBook.getVaultParams();
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
        (,,, uint256 _vaultBestAsk,, uint96 _vaultBidOrderSize, uint96 _vaultAskOrderSize,) = orderBook.getVaultParams();
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
        orderBook.placeAndExecuteMarketBuy(uint32((_quoteForFillingAsk * PRICE_PRECISION) / 10 ** 18), 0, false, true);
        (,,, uint256 _vaultBestAskNew,,,,) = orderBook.getVaultParams();
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
        vm.expectRevert(KuruAMMVaultErrors.InsufficientQuoteToken.selector);
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
        vm.expectRevert(KuruAMMVaultErrors.InsufficientLiquidityMinted.selector);
        vault.deposit(0, 0, _vaultMaker);
        vm.stopPrank();
    }

    function testKuruVaultNoRevertPartialFilledSizeExceedsNewSize(uint256 _targetVaultPrice, uint96 _targetVaultSize)
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
        (,,,,, uint96 _vaultBidOrderSize,,) = orderBook.getVaultParams();
        uint256 _bidTakerBaseAmount = (_vaultBidOrderSize * 10 ** eth.decimals()) / (2 * SIZE_PRECISION); //half of bid order size
        address _partialBidTaker = genAddress();
        eth.mint(_partialBidTaker, _bidTakerBaseAmount);
        vm.startPrank(_partialBidTaker);
        eth.approve(address(orderBook), _bidTakerBaseAmount);
        orderBook.placeAndExecuteMarketSell(_vaultBidOrderSize / 2, 0, false, true);
        vm.stopPrank();
        (,, uint96 _partiallyFilledBid,, uint96 _partiallyFilledAsk,,,) = orderBook.getVaultParams();
        assert(_partiallyFilledBid != 0);
        vm.startPrank(_vaultMaker);
        vault.withdraw(_shares, _vaultMaker, _vaultMaker);
        vm.stopPrank();
        (,, _partiallyFilledBid,, _partiallyFilledAsk,,,) = orderBook.getVaultParams();
        assert(_partiallyFilledBid == 0 && _partiallyFilledAsk == 0);
    }

    function testV3PositionNormal() public {
        uint256 points = 7;
        uint96 size = 50 * SIZE_PRECISION;
        uint32[] memory prices = new uint32[](points);
        uint32[] memory flipPrices = new uint32[](points);
        uint96[] memory sizes = new uint96[](points);
        bool[] memory isBuy = new bool[](points);
        uint256 baseAssetToDeposit;
        uint256 quoteAssetToDeposit;
        for (uint256 i = 0; i < points; i++) {
            prices[i] = uint32((100 + i) * PRICE_PRECISION);
            sizes[i] = size;
            if (i < points / 2) {
                isBuy[i] = true;
                flipPrices[i] = uint32((100 + i + 1) * PRICE_PRECISION);
                quoteAssetToDeposit += mulDivUp(prices[i], sizes[i]) * 10 ** usdc.decimals() / PRICE_PRECISION;
            } else {
                isBuy[i] = false;
                flipPrices[i] = uint32((100 + i - 1) * PRICE_PRECISION);
                baseAssetToDeposit += size * 10 ** eth.decimals() / SIZE_PRECISION;
            }
        }
        address _maker = genAddress();
        eth.mint(_maker, baseAssetToDeposit);
        usdc.mint(_maker, quoteAssetToDeposit);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), baseAssetToDeposit);
        usdc.approve(address(marginAccount), quoteAssetToDeposit);
        marginAccount.deposit(_maker, address(eth), baseAssetToDeposit);
        marginAccount.deposit(_maker, address(usdc), quoteAssetToDeposit);
        orderBook.batchProvisionLiquidity(prices, flipPrices, sizes, isBuy, true);
        vm.stopPrank();
    }

    function testV3PositionProvisionErrorCase1() public {
        //matches against a normal sell order, must revert
        uint32 price = 100 * PRICE_PRECISION;
        uint96 size = 50 * SIZE_PRECISION;
        _addSellOrder(address(0), price, size, true);
        uint256 points = 7;
        uint32[] memory prices = new uint32[](points);
        uint32[] memory flipPrices = new uint32[](points);
        uint96[] memory sizes = new uint96[](points);
        bool[] memory isBuy = new bool[](points);
        uint256 baseAssetToDeposit;
        uint256 quoteAssetToDeposit;
        for (uint256 i = 0; i < points; i++) {
            prices[i] = uint32((100 + i) * PRICE_PRECISION);
            sizes[i] = size;
            if (i < points / 2) {
                isBuy[i] = true;
                flipPrices[i] = uint32((100 + i + 1) * PRICE_PRECISION);
                quoteAssetToDeposit += mulDivUp(prices[i], sizes[i]) * 10 ** usdc.decimals() / PRICE_PRECISION;
            } else {
                isBuy[i] = false;
                flipPrices[i] = uint32((100 + i - 1) * PRICE_PRECISION);
                baseAssetToDeposit += size * 10 ** eth.decimals() / SIZE_PRECISION;
            }
        }
        address _maker2 = genAddress();
        eth.mint(_maker2, baseAssetToDeposit);
        usdc.mint(_maker2, quoteAssetToDeposit);
        vm.startPrank(_maker2);
        eth.approve(address(marginAccount), baseAssetToDeposit);
        usdc.approve(address(marginAccount), quoteAssetToDeposit);
        marginAccount.deposit(_maker2, address(eth), baseAssetToDeposit);
        marginAccount.deposit(_maker2, address(usdc), quoteAssetToDeposit);
        vm.expectRevert(OrderBookErrors.ProvisionError.selector);
        orderBook.batchProvisionLiquidity(prices, flipPrices, sizes, isBuy, true);
        vm.stopPrank();
    }

    function testV3PositionProvisionErrorCase2() public {
        //matches against a normal buy order, must revert
        uint256 points = 7;
        uint32 price = uint32((100 + points) * PRICE_PRECISION);
        uint96 size = 50 * SIZE_PRECISION;
        _addBuyOrder(address(0), price, size, 0, true);
        uint32[] memory prices = new uint32[](points);
        uint32[] memory flipPrices = new uint32[](points);
        uint96[] memory sizes = new uint96[](points);
        bool[] memory isBuy = new bool[](points);
        uint256 baseAssetToDeposit;
        uint256 quoteAssetToDeposit;
        for (uint256 i = 0; i < points; i++) {
            prices[i] = uint32((100 + i) * PRICE_PRECISION);
            sizes[i] = size;
            if (i < points / 2) {
                isBuy[i] = true;
                flipPrices[i] = uint32((100 + i + 1) * PRICE_PRECISION);
                quoteAssetToDeposit += mulDivUp(prices[i], sizes[i]) * 10 ** usdc.decimals() / PRICE_PRECISION;
            } else {
                isBuy[i] = false;
                flipPrices[i] = uint32((100 + i - 1) * PRICE_PRECISION);
                baseAssetToDeposit += size * 10 ** eth.decimals() / SIZE_PRECISION;
            }
        }
        address _maker2 = genAddress();
        eth.mint(_maker2, baseAssetToDeposit);
        usdc.mint(_maker2, quoteAssetToDeposit);
        vm.startPrank(_maker2);
        eth.approve(address(marginAccount), baseAssetToDeposit);
        usdc.approve(address(marginAccount), quoteAssetToDeposit);
        marginAccount.deposit(_maker2, address(eth), baseAssetToDeposit);
        marginAccount.deposit(_maker2, address(usdc), quoteAssetToDeposit);
        vm.expectRevert(OrderBookErrors.ProvisionError.selector);
        orderBook.batchProvisionLiquidity(prices, flipPrices, sizes, isBuy, true);
        vm.stopPrank();
    }

    function mulDivUp(uint32 _price, uint96 _size) internal pure returns (uint96) {
        uint256 _result = FixedPointMathLib.mulDivUp(_price, _size, SIZE_PRECISION);
        if (_result >= type(uint96).max) {
            revert("OrderBook: Too much size being filled");
        }
        return uint96(_result);
    }
}
