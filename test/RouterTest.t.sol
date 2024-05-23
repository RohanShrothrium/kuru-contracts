// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";

contract OrderBookTest is Test {
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint24 constant PRICE_PRECISION = 10 ** 2;

    OrderBook eth_mon;
    OrderBook mon_usdc;
    OrderBook eth_usdc;
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

    function setUp() public {
        eth = new MintableERC20("ETH", "ETH");
        mon = new MintableERC20("MON", "MON");
        usdc = new MintableERC20("USD", "USDC");

        router = new Router();

        marginAccount = new MarginAccount(address(router));

        OrderBook implementation = new OrderBook();

        router.initialize(address(this), address(marginAccount), address(implementation));

        eth_mon = _createOrderbook(eth, mon, SIZE_PRECISION, PRICE_PRECISION);
        mon_usdc = _createOrderbook(mon, usdc, SIZE_PRECISION, PRICE_PRECISION);
        eth_usdc = _createOrderbook(eth, usdc, SIZE_PRECISION, PRICE_PRECISION);

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
        mon.mint(user3, initMon);
    }
    
    function genAddress() internal returns (address) {
        uint256 _seed = SEED;
        uint256 privateKeyGen = uint256(
            keccak256(abi.encodePacked(bytes32(_seed)))
        );
        address derived = vm.addr(privateKeyGen);
        ++SEED;
        lastGenAddress = derived;
        return derived;
    }

    function _addCustomBuyOrderOnlyPriceSize(
        OrderBook orderBook,
        MintableERC20 token,
        address _maker,
        uint24 _price,
        uint96 _size
    ) internal {
        uint256 _tokenForEachOrder = _price * _size * 10 ** token.decimals();
        token.mint(_maker, _tokenForEachOrder);
        vm.startPrank(_maker);
        token.approve(address(marginAccount), _tokenForEachOrder);
        marginAccount.deposit(_maker, address(token), _tokenForEachOrder);
        uint24 _pricePrecision = orderBook.getPricePrecision();
        uint96 _sizePrecision = orderBook.getSizePrecision();
        orderBook.addBuyOrder(_price * _pricePrecision, _size * _sizePrecision, false);
        vm.stopPrank();
    }

    function _addCustomSellOrderOnlyPriceSize(
        OrderBook orderBook,
        MintableERC20 token,
        address _maker,
        uint24 _price,
        uint96 _size
    ) internal {
        token.mint(_maker, _size * 10 ** token.decimals());
        vm.startPrank(_maker);
        token.approve(address(marginAccount), _size * 10 ** token.decimals());
        marginAccount.deposit(_maker, address(token), _size * 10 ** token.decimals());
        uint24 _pricePrecision = orderBook.getPricePrecision();
        uint96 _sizePrecision = orderBook.getSizePrecision();
        orderBook.addSellOrder(
            _price * _pricePrecision,
            _size * _sizePrecision,
            false
        );
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
        router.anyToAnySwap(markets, isBuy, address(eth), address(usdc), 3 * 10 ** 18, 5400 * 10 ** 18);
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
        router.anyToAnySwap(markets, isBuy, address(usdc), address(eth), 5000 * 10 ** 18, 2 * 10 ** 18);
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
        vm.expectRevert("Router: Slippage exceeds expected value!");
        router.anyToAnySwap(markets, isBuy, address(eth), address(usdc), 3 * 10 ** 18, 5600 * 10 ** 18);
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
        vm.expectRevert("Router: Invalid market!");
        router.anyToAnySwap(markets, isBuy, address(eth), address(usdc), 3 * 10 ** 18, 5400 * 10 ** 18);
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
        vm.expectRevert("Router: Sizes length mismatch");
        router.anyToAnySwap(markets, isBuy, address(eth), address(usdc), 3 * 10 ** 18, 5400 * 10 ** 18);
        vm.stopPrank();
    }


    function _createOrderbook(MintableERC20 _baseAsset, MintableERC20 _quoteAsset, uint96 _sizePrecision, uint24 _pricePrecision) internal returns (OrderBook) {
        uint96 _tickSize = _pricePrecision / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 15;
        uint256 _takerFeeBps = 0;

        address proxy = router.deployProxy(
            address(_baseAsset),
            address(_quoteAsset),
            _sizePrecision,
            _pricePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps
        );

        return OrderBook(proxy);
    }

    function _swapTokens(MintableERC20 tokenA, MintableERC20 tokenB) internal returns (MintableERC20, MintableERC20) {
        MintableERC20 temp = tokenA;
        tokenA = tokenB;
        tokenB = temp;
        return (tokenA, tokenB);
    }
}
