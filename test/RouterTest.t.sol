// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {RouterErrors} from "../contracts/libraries/Errors.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {IOrderBook} from "../contracts/interfaces/IOrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";

contract OrderBookTest is Test {
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint32 constant PRICE_PRECISION = 10 ** 2;

    OrderBook eth_mon;
    OrderBook mon_usdc;
    OrderBook eth_usdc;
    OrderBook native_mon;
    OrderBook mon_native;
    Router router;
    MarginAccount marginAccount;
    MintableERC20 eth;
    MintableERC20 usdc;
    MintableERC20 mon;

    address user1 = address(1);
    address user2 = address(2);
    address user3 = address(3);

    uint256 initEth = 1000 * 10 ** 18;
    uint256 initUsdc = 1000000 * 10 ** 18;
    uint256 initMon = 1000000 * 10 ** 18;
    uint256 SEED = 2;
    address lastGenAddress;
    uint96 SPREAD = 30;
    address trustedForwarder;

    function setUp() public {
        eth = new MintableERC20("ETH", "ETH");
        mon = new MintableERC20("MON", "MON");
        usdc = new MintableERC20("USD", "USDC");

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

        OrderBook implementation = new OrderBook();
        KuruAMMVault kuruAmmVaultImplementation = new KuruAMMVault();
        trustedForwarder = address(0x123);
        router.initialize(address(this), address(marginAccount), address(implementation), address(kuruAmmVaultImplementation), trustedForwarder);
        OrderBook.OrderBookType _type;
        eth_mon = _createOrderbook(_type, address(eth), address(mon), SIZE_PRECISION, PRICE_PRECISION);
        mon_usdc = _createOrderbook(_type, address(mon), address(usdc), SIZE_PRECISION, PRICE_PRECISION);
        eth_usdc = _createOrderbook(_type, address(eth), address(usdc), SIZE_PRECISION, PRICE_PRECISION);
        native_mon = _createOrderbook(
            IOrderBook.OrderBookType.NATIVE_IN_BASE, address(0), address(mon), SIZE_PRECISION, PRICE_PRECISION
        );
        mon_native = _createOrderbook(
            IOrderBook.OrderBookType.NATIVE_IN_QUOTE, address(mon), address(0), SIZE_PRECISION, PRICE_PRECISION * 10
        );

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
        mon.mint(user3, initMon);
    }

    function genAddress() internal returns (address) {
        uint256 _seed = SEED;
        uint256 privateKeyGen = uint256(keccak256(abi.encodePacked(bytes32(_seed))));
        address derived = vm.addr(privateKeyGen);
        ++SEED;
        lastGenAddress = derived;
        return derived;
    }

    function _addCustomBuyOrderOnlyPriceSize(
        OrderBook orderBook,
        MintableERC20 token,
        address _maker,
        uint32 _price,
        uint96 _size
    ) internal {
        uint256 _tokenForEachOrder = _price * _size * 10 ** token.decimals();
        token.mint(_maker, _tokenForEachOrder);
        vm.startPrank(_maker);
        token.approve(address(marginAccount), _tokenForEachOrder);
        marginAccount.deposit(_maker, address(token), _tokenForEachOrder);
        (uint32 _pricePrecision, uint96 _sizePrecision,,,,,,,,,) = orderBook.getMarketParams();
        orderBook.addBuyOrder(_price * _pricePrecision, _size * _sizePrecision, false);
        vm.stopPrank();
    }

    function _addCustomSellOrderOnlyPriceSize(
        OrderBook orderBook,
        MintableERC20 token,
        address _maker,
        uint32 _price,
        uint96 _size
    ) internal {
        token.mint(_maker, _size * 10 ** token.decimals());
        vm.startPrank(_maker);
        token.approve(address(marginAccount), _size * 10 ** token.decimals());
        marginAccount.deposit(_maker, address(token), _size * 10 ** token.decimals());
        (uint32 _pricePrecision, uint96 _sizePrecision,,,,,,,,,) = orderBook.getMarketParams();
        orderBook.addSellOrder(_price * _pricePrecision, _size * _sizePrecision, false);
        vm.stopPrank();
    }

    function _addCustomBuyOrderOnlyPriceSizeNativeQuote(
        OrderBook orderBook,
        address _maker,
        uint32 _priceWithoutPrecision,
        uint96 _sizeWithoutPrecision
    ) internal {
        vm.startPrank(_maker);
        (uint32 _pricePrecision, uint96 _sizePrecision,,,,,,,,,) = orderBook.getMarketParams();
        uint256 depositAmount = _priceWithoutPrecision * _sizeWithoutPrecision * 10 ** 18;
        marginAccount.deposit{value: depositAmount}(_maker, address(0), depositAmount);
        orderBook.addBuyOrder(_priceWithoutPrecision * _pricePrecision, _sizeWithoutPrecision * _sizePrecision, false);
        vm.stopPrank();
    }

    function _addCustomSellOrderOnlyPriceSizeNativeBase(
        OrderBook orderBook,
        address _maker,
        uint32 _priceWithoutPrecision,
        uint96 _sizeWithoutPrecision
    ) internal {
        vm.startPrank(_maker);
        (uint32 _pricePrecision, uint96 _sizePrecision,,,,,,,,,) = orderBook.getMarketParams();
        uint256 depositAmount = _sizeWithoutPrecision * 10 ** 18;
        marginAccount.deposit{value: depositAmount}(_maker, address(0), depositAmount);
        orderBook.addSellOrder(_priceWithoutPrecision * _pricePrecision, _sizeWithoutPrecision * _sizePrecision, false);
        vm.stopPrank();
    }

    function testAnyToAnySwap() public {
        //COMBO 1 : SELL, SELL

        //Placing Buy Orders
        address sellerA = genAddress();
        _addCustomBuyOrderOnlyPriceSize(eth_mon, mon, sellerA, 600, 3);
        address sellerB = genAddress();
        _addCustomBuyOrderOnlyPriceSize(mon_usdc, usdc, sellerB, 3, 1800);

        address routerUser = genAddress();
        eth.mint(routerUser, 3 * 10 ** 18);
        uint256 _previousBalance = usdc.balanceOf(routerUser);
        vm.startPrank(routerUser);
        eth.approve(address(router), 3 * 10 ** 18);
        address[] memory markets = new address[](2);
        markets[0] = address(eth_mon);
        markets[1] = address(mon_usdc);
        bool[] memory isBuy = new bool[](2);
        isBuy[0] = false;
        isBuy[1] = false;
        bool[] memory isNativeSend = new bool[](2);
        isNativeSend[0] = false;
        isNativeSend[1] = false;
        router.anyToAnySwap(markets, isBuy, isNativeSend, address(eth), address(usdc), 3 * 10 ** 18, 5400 * 10 ** 18);
        vm.stopPrank();
        assertEq(usdc.balanceOf(routerUser) - _previousBalance, 5400 * 10 ** 18);

        //COMBO 2
        _previousBalance = eth.balanceOf(routerUser);
        _addCustomSellOrderOnlyPriceSize(mon_usdc, mon, sellerA, 2, 2500);
        _addCustomSellOrderOnlyPriceSize(eth_mon, eth, sellerB, 500, 5);
        vm.startPrank(routerUser);
        usdc.approve(address(router), 5400 * 10 ** 18);
        markets[0] = address(mon_usdc);
        markets[1] = address(eth_mon);
        isBuy[0] = true;
        isBuy[1] = true;
        router.anyToAnySwap(markets, isBuy, isNativeSend, address(usdc), address(eth), 5000 * 10 ** 18, 2 * 10 ** 18);
        vm.stopPrank();
        assertEq(eth.balanceOf(routerUser) - _previousBalance, 5 * 10 ** 18);
    }

    function testRevertSlippageExceeded() public {
        //Placing Buy Orders
        address sellerA = genAddress();
        _addCustomBuyOrderOnlyPriceSize(eth_mon, mon, sellerA, 600, 3);
        address sellerB = genAddress();
        _addCustomBuyOrderOnlyPriceSize(mon_usdc, usdc, sellerB, 3, 1800);

        address routerUser = genAddress();
        eth.mint(routerUser, 3 * 10 ** 18);

        vm.startPrank(routerUser);
        eth.approve(address(router), 3 * 10 ** 18);
        address[] memory markets = new address[](2);
        markets[0] = address(eth_mon);
        markets[1] = address(mon_usdc);
        bool[] memory isBuy = new bool[](2);
        isBuy[0] = false;
        isBuy[1] = false;
        bool[] memory isNativeSend = new bool[](2);
        isNativeSend[0] = false;
        isNativeSend[1] = false;
        vm.expectRevert(RouterErrors.SlippageExceeded.selector);
        router.anyToAnySwap(markets, isBuy, isNativeSend, address(eth), address(usdc), 3 * 10 ** 18, 5600 * 10 ** 18);
        vm.stopPrank();
    }

    function testRevertInvalidMarket() public {
        //Placing Buy Orders
        address sellerA = genAddress();
        _addCustomBuyOrderOnlyPriceSize(eth_mon, mon, sellerA, 600, 3);
        address sellerB = genAddress();
        _addCustomBuyOrderOnlyPriceSize(mon_usdc, usdc, sellerB, 3, 1800);

        address routerUser = genAddress();
        eth.mint(routerUser, 3 * 10 ** 18);

        vm.startPrank(routerUser);
        eth.approve(address(router), 3 * 10 ** 18);
        address[] memory markets = new address[](2);
        markets[0] = address(sellerA);
        markets[1] = address(mon_usdc);
        bool[] memory isBuy = new bool[](2);
        isBuy[0] = false;
        isBuy[1] = false;
        bool[] memory isNativeSend = new bool[](2);
        isNativeSend[0] = false;
        isNativeSend[1] = false;
        vm.expectRevert(RouterErrors.InvalidMarket.selector);
        router.anyToAnySwap(markets, isBuy, isNativeSend, address(eth), address(usdc), 3 * 10 ** 18, 5400 * 10 ** 18);
        vm.stopPrank();
    }

    function testRevertLengthMismatch() public {
        //Placing Buy Orders
        address sellerA = genAddress();
        _addCustomBuyOrderOnlyPriceSize(eth_mon, mon, sellerA, 600, 3);
        address sellerB = genAddress();
        _addCustomBuyOrderOnlyPriceSize(mon_usdc, usdc, sellerB, 3, 1800);

        address routerUser = genAddress();
        eth.mint(routerUser, 3 * 10 ** 18);

        vm.startPrank(routerUser);
        eth.approve(address(router), 3 * 10 ** 18);
        address[] memory markets = new address[](2);
        markets[0] = address(sellerA);
        markets[1] = address(mon_usdc);
        bool[] memory isBuy = new bool[](1);
        isBuy[0] = false;
        bool[] memory isNativeSend = new bool[](1);
        isNativeSend[0] = false;
        vm.expectRevert(RouterErrors.LengthMismatch.selector);
        router.anyToAnySwap(markets, isBuy, isNativeSend, address(eth), address(usdc), 3 * 10 ** 18, 5400 * 10 ** 18);
        vm.stopPrank();
    }

    function _createOrderbook(
        OrderBook.OrderBookType _type,
        address _baseAsset,
        address _quoteAsset,
        uint96 _sizePrecision,
        uint32 _pricePrecision
    ) internal returns (OrderBook) {
        uint32 _tickSize = _pricePrecision / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 15;
        uint256 _takerFeeBps = 0;
        uint256 _makerFeeBps = 0;
        address proxy = router.deployProxy(
            _type,
            _baseAsset,
            _quoteAsset,
            _sizePrecision,
            _pricePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps,
            SPREAD
        );

        return OrderBook(proxy);
    }

    function _swapTokens(MintableERC20 tokenA, MintableERC20 tokenB)
        internal
        pure
        returns (MintableERC20, MintableERC20)
    {
        MintableERC20 temp = tokenA;
        tokenA = tokenB;
        tokenB = temp;
        return (tokenA, tokenB);
    }

    function testNativeToTokenSwap() public {
        // Setup liquidity in native_mon market
        address nativeProvider = genAddress();
        vm.deal(nativeProvider, 10 ether);
        _addCustomBuyOrderOnlyPriceSize(native_mon, mon, nativeProvider, 100, 5); // 1 Native = 100 MON

        // Setup liquidity in mon_usdc market
        address monProvider = genAddress();
        _addCustomBuyOrderOnlyPriceSize(mon_usdc, usdc, monProvider, 2, 1000); // 1 MON = 2 USDC

        address swapper = genAddress();
        vm.deal(swapper, 1 ether);

        vm.startPrank(swapper);
        address[] memory markets = new address[](2);
        markets[0] = address(native_mon);
        markets[1] = address(mon_usdc);
        bool[] memory isBuy = new bool[](2);
        isBuy[0] = false;
        isBuy[1] = false;
        bool[] memory isNativeSend = new bool[](2);
        isNativeSend[0] = true;
        isNativeSend[1] = false;

        uint256 expectedUsdcOut = 200 * 10 ** 18; // 1 Native -> 100 MON -> 200 USDC
        router.anyToAnySwap{value: 1 ether}(
            markets, isBuy, isNativeSend, address(0), address(usdc), 1 ether, expectedUsdcOut
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(swapper), expectedUsdcOut);
    }

    function testMultiMarketNativeToTokenSwap() public {
        // Setup liquidity in native_mon market
        address nativeProvider = genAddress();
        vm.deal(nativeProvider, 10 ether);
        _addCustomBuyOrderOnlyPriceSize(native_mon, mon, nativeProvider, 100, 5); // 1 Native = 100 MON

        // Setup liquidity in mon_usdc market
        address monProvider = genAddress();
        _addCustomBuyOrderOnlyPriceSize(mon_usdc, usdc, monProvider, 2, 1000); // 1 MON = 2 USDC

        // Setup liquidity in usdc_eth market
        address usdcProvider = genAddress();
        _addCustomSellOrderOnlyPriceSize(eth_usdc, eth, usdcProvider, 2000, 10); // 1 ETH = 2000 USDC

        address swapper = genAddress();
        vm.deal(swapper, 1 ether);

        vm.startPrank(swapper);
        address[] memory markets = new address[](3);
        markets[0] = address(native_mon);
        markets[1] = address(mon_usdc);
        markets[2] = address(eth_usdc);
        bool[] memory isBuy = new bool[](3);
        isBuy[0] = false;
        isBuy[1] = false;
        isBuy[2] = true;
        bool[] memory isNativeSend = new bool[](3);
        isNativeSend[0] = true;
        isNativeSend[1] = false;
        isNativeSend[2] = false;

        uint256 expectedEthOut = 0.1 * 10 ** 18; // 1 Native -> 100 MON -> 200 USDC -> 0.1 ETH
        router.anyToAnySwap{value: 1 ether}(
            markets, isBuy, isNativeSend, address(0), address(eth), 1 ether, expectedEthOut
        );
        vm.stopPrank();

        assertEq(eth.balanceOf(swapper), expectedEthOut);
    }

    function testNativeBuyInMonNativeMarket() public {
        // Setup liquidity in mon_native market
        address monProvider = genAddress();
        _addCustomSellOrderOnlyPriceSize(mon_native, mon, monProvider, 1, 10); // 1 MON = 1 Native

        address buyer = genAddress();
        vm.deal(buyer, 1 ether);

        vm.startPrank(buyer);
        uint256 initialMonBalance = mon.balanceOf(buyer);
        address[] memory markets = new address[](1);
        markets[0] = address(mon_native);
        bool[] memory isBuy = new bool[](1);
        isBuy[0] = true;
        bool[] memory isNativeSend = new bool[](1);
        isNativeSend[0] = true;

        uint256 expectedMonOut = 0.1 * 10 ** 18; // 0.1 Native should buy 0.1 MON
        router.anyToAnySwap{value: 0.1 ether}(
            markets, isBuy, isNativeSend, address(0), address(mon), 0.1 ether, expectedMonOut
        );
        vm.stopPrank();

        assertEq(mon.balanceOf(buyer) - initialMonBalance, expectedMonOut);
    }

    function testMultiRouteSwapEndingInNative() public {
        // Setup liquidity in eth_mon market
        address ethProvider = genAddress();
        _addCustomBuyOrderOnlyPriceSize(eth_mon, mon, ethProvider, 2000, 10); // 1 ETH = 2000 MON

        // Setup liquidity in mon_native market
        address nativeProvider = genAddress();
        vm.deal(nativeProvider, 2000 ether);
        _addCustomBuyOrderOnlyPriceSizeNativeQuote(mon_native, nativeProvider, 1, 2000); // 1 MON = 1 Native

        address swapper = genAddress();
        eth.mint(swapper, 1 * 10 ** 18); // 1 ETH

        vm.startPrank(swapper);
        eth.approve(address(router), 1 * 10 ** 18);
        uint256 initialNativeBalance = address(swapper).balance;

        address[] memory markets = new address[](2);
        markets[0] = address(eth_mon);
        markets[1] = address(mon_native);
        bool[] memory isBuy = new bool[](2);
        isBuy[0] = false;
        isBuy[1] = false;
        bool[] memory isNativeSend = new bool[](2);
        isNativeSend[0] = false;
        isNativeSend[1] = false;

        uint256 expectedNativeOut = 2000 ether; // 1 ETH -> 2000 MON -> 2000 Native
        router.anyToAnySwap(markets, isBuy, isNativeSend, address(eth), address(0), 1 * 10 ** 18, expectedNativeOut);
        vm.stopPrank();

        assertEq(address(swapper).balance - initialNativeBalance, expectedNativeOut);
    }
}
