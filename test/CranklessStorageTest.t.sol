// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CranklessStorageOrderBook} from "../contracts/CranklessStorageOrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";

contract OrderBookTest is Test {
    uint96 constant SIZE_PRECISION = 10**10;
    uint24 constant PRICE_PRECISION = 10**2;

    CranklessStorageOrderBook orderBook;
    Router router;
    MarginAccount marginAccount;

    MintableERC20 eth;
    MintableERC20 usdc;

    address user1 = address(1);
    address user2 = address(2);
    address user3 = address(3);

    uint256 initEth = 1000*10**18;
    uint256 initUsdc = 1000000*10**18;

    function setUp() public {
        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USD", "USDC");

        uint96 _sizePrecision = 10**10;
        uint24 _pricePrecision = 10**2;
        uint96 _tickSize = _pricePrecision/2;
        uint96 _minSize = 10**5;
        uint96 _maxSize = 10**12;
        uint256 _takerFeeBps = 0;

        router = new Router();

        router.initialize(address(this));

        marginAccount = new MarginAccount(address(router));

        router.setMarginAccount(address(marginAccount));

        orderBook = new CranklessStorageOrderBook(address(eth), 18, address(usdc), 18, address(marginAccount), _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);

        router.registerMarket(address(eth), address(usdc), address(orderBook));

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
    }

    function _addBuyOrder() internal {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        usdc.approve(address(marginAccount), initUsdc);
        marginAccount.deposit(user2, address(usdc), (price*size)*10**18);
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function _addSellOrder() internal {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        eth.approve(address(marginAccount), initEth);
        marginAccount.deposit(user1, address(eth), size*10**18);
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testAddBuyOrder() public {
        _addBuyOrder();
        uint24 price = 1800;
        uint96 size = 10;

        // Fetch the PricePoint from the contract
        (uint256 head, uint256 tail) = orderBook.s_buyPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), (price*size)*10**18);

        assertEq(head, 1);
        assertEq(tail, 1);
    }

    function testAddBuyOrderMinSizeError() public {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("OrderBook: Size too low");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size);
        vm.stopPrank();
    }

    function testAddBuyOrderMaxSizeError() public {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("OrderBook: Size too large");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*10**20);
        vm.stopPrank();
    }

    function testAddBuyOrderTickSizeError() public {
        uint24 price = 180040;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("OrderBook: Tick Size");
        orderBook.addBuyOrder(price, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    // function testAddBuyOrderInsufficientAllowanceFail() public {
    //     uint24 price = 1800;
    //     uint96 size = 10;

    //     vm.startPrank(user2);
    //     vm.expectRevert("MarginAccoiunt: Insufficient Balance");
    //     orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
    //     vm.stopPrank();
    // }

    function testAddBuyOrderExceedsBalanceFail() public {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user3);
        usdc.approve(address(orderBook), initUsdc);
        vm.expectRevert("MarginAccoiunt: Insufficient Balance");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testAddSellOrder() public {
        _addSellOrder();
        uint24 price = 1800;
        uint96 size = 10;

        // Fetch the PricePoint from the contract
        (uint256 head, uint256 tail) = orderBook.s_sellPricePoints(price*PRICE_PRECISION);

        assertEq(eth.balanceOf(user1), initEth - size*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), (size)*10**18);

        assertEq(head, 1);
        assertEq(tail, 1);
    }

    function testAddSellOrderMinSizeError() public {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Size too low");
        orderBook.addSellOrder(price*PRICE_PRECISION, size);
        vm.stopPrank();
    }

    function testAddSellOrderMaxSizeError() public {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Size too large");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*10**20);
        vm.stopPrank();
    }

    function testAddSellOrderTickSizeError() public {
        uint24 price = 180040;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Tick Size");
        orderBook.addSellOrder(price, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    // function testAddSellOrderInsufficientAllowanceFail() public {
    //     uint24 price = 1800;
    //     uint96 size = 10;

    //     vm.startPrank(user1);
    //     vm.expectRevert("ERC20: insufficient allowance");
    //     orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
    //     vm.stopPrank();
    // }

    function testAddSellOrderExceedsBalanceFail() public {
        uint24 price = 1800;
        uint96 size = 10;

        vm.startPrank(user3);
        eth.approve(address(orderBook), initEth);
        vm.expectRevert("MarginAccoiunt: Insufficient Balance");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testCancelOrder() public {
        _addBuyOrder();

        uint40[] memory _orderIds = new uint40[](1);
        _orderIds[0] = 1;

        uint24 price = 1800*PRICE_PRECISION;
        vm.startPrank(user2);
        orderBook.batchCancelOrders(_orderIds);
        vm.stopPrank();

        (uint256 head, uint256 tail) = orderBook.s_buyPricePoints(price);

        assertEq(usdc.balanceOf(user2), initUsdc-1800*10*10**18);
        assertEq(marginAccount.balances(keccak256(abi.encodePacked(user2, address(usdc)))), 1800*10*10**18);

        assertEq(head, 0);
        assertEq(tail, 0);
    }

    function testCancelOrderMiddle() public {
        _addBuyOrder();
        _addBuyOrder();
        _addBuyOrder();

        uint40[] memory _orderIds = new uint40[](1);
        _orderIds[0] = 2;

        uint24 price = 1800*PRICE_PRECISION;
        vm.startPrank(user2);
        orderBook.batchCancelOrders(_orderIds);
        vm.stopPrank();

        (uint256 head, uint256 tail) = orderBook.s_buyPricePoints(price);

        assertEq(head, 1);
        assertEq(tail, 3);
    }

    function testCancelOrderOnlyOwnerFail() public {
        _addBuyOrder();

        uint40[] memory _orderIds = new uint40[](1);
        _orderIds[0] = 1;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Only order owner can cancel order");
        orderBook.batchCancelOrders(_orderIds);
        vm.stopPrank();
    }

    function testAddMultipleBuyOrders() public {
        uint24[] memory prices = new uint24[](3);
        prices[0] = 1800*PRICE_PRECISION;
        prices[1] = 1801*PRICE_PRECISION;
        prices[2] = 1802*PRICE_PRECISION;

        uint96[] memory sizes = new uint96[](3);
        sizes[0] = 1*SIZE_PRECISION;
        sizes[1] = 2*SIZE_PRECISION;
        sizes[2] = 3*SIZE_PRECISION;

        vm.startPrank(user2);
        usdc.approve(address(marginAccount), initUsdc);
        marginAccount.deposit(user2, address(usdc), (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);
        orderBook.placeMultipleBuyOrders(prices, sizes);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user2), initUsdc - (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);

        (uint256 head, uint256 tail) = orderBook.s_buyPricePoints(prices[0]);
        assertEq(head, 1);
        assertEq(tail, 1);

        (head, tail) = orderBook.s_buyPricePoints(prices[1]);
        assertEq(head, 2);
        assertEq(tail, 2);

        (head, tail) = orderBook.s_buyPricePoints(prices[2]);
        assertEq(head, 3);
        assertEq(tail, 3);
    }

    function testAddMultipleSellOrders() public {
        uint24[] memory prices = new uint24[](3);
        prices[0] = 1803*PRICE_PRECISION;
        prices[1] = 1804*PRICE_PRECISION;
        prices[2] = 1805*PRICE_PRECISION;

        uint96[] memory sizes = new uint96[](3);
        sizes[0] = 1*SIZE_PRECISION;
        sizes[1] = 2*SIZE_PRECISION;
        sizes[2] = 3*SIZE_PRECISION;

        vm.startPrank(user1);
        eth.approve(address(marginAccount), initEth);
        marginAccount.deposit(user1, address(eth), (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);
        orderBook.placeMultipleSellOrders(prices, sizes);
        vm.stopPrank();

        assertEq(eth.balanceOf(user1), initEth - (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);

        (uint256 head, uint256 tail) = orderBook.s_sellPricePoints(prices[0]);
        assertEq(head, 1);
        assertEq(tail, 1);

        (head, tail) = orderBook.s_sellPricePoints(prices[1]);
        assertEq(head, 2);
        assertEq(tail, 2);

        (head, tail) = orderBook.s_sellPricePoints(prices[2]);
        assertEq(head, 3);
        assertEq(tail, 3);
    }

    function testMarketSell() public {
        _addBuyOrder();

        uint24 size = 10;
        uint96 price = 1800;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.placeAndExecuteMarketSell(size*SIZE_PRECISION, false);
        vm.stopPrank();

        (uint40 head, uint40 tail) = orderBook.s_buyPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), 0);
        assertEq(usdc.balanceOf(user1), (price*size)*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), size*10**18);

        assertEq(head, 0);
        assertEq(tail, 0);
    }

    function testMarketSellInsifficientAllowance() public {
        _addBuyOrder();

        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.placeAndExecuteMarketSell(size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testMarketBuy() public {
        _addSellOrder();

        uint96 size = 10;
        uint24 price = 1800;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.placeAndExecuteMarketBuy(uint24(size*price*PRICE_PRECISION), false);
        vm.stopPrank();

        (uint256 head, uint256 tail) = orderBook.s_sellPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), 0);
        assertEq(usdc.balanceOf(address(marginAccount)), (price*size)*10**18);
        assertEq(eth.balanceOf(user2), size*10**18);

        assertEq(head, 0);
        assertEq(tail, 0);
    }

    function testAggressiveBuy() public {
        _addSellOrder();

        uint96 size = 10;
        uint24 price = 1801;

        vm.startPrank(user2);
        usdc.approve(address(marginAccount), initUsdc);
        marginAccount.deposit(user2, address(usdc), (price*size)*10**18);
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();

        (uint256 head, uint256 tail) = orderBook.s_sellPricePoints(1800*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        // assertEq(marginAccount.balances(keccak256(abi.encodePacked(user2, address(usdc)))), 10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), (1801*size)*10**18);
        assertEq(marginAccount.balances(keccak256(abi.encodePacked(user2, address(eth)))), size*10**18);

        assertEq(head, 0);
        assertEq(tail, 0);
    }

    function _addCustomSellOrder(uint24 _price, uint96 _size, address _user) internal {
        // vm.startPrank(deployer);
        eth.mint(_user, initEth);
        // vm.stopPrank();
        vm.startPrank(_user);
        eth.approve(address(marginAccount), initEth);
        marginAccount.deposit(_user, address(eth), _size*10**18);
        orderBook.addSellOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function test_brutalizedBuyOrderFill() public {
        // uint times = bound(_someValue, 1, 30);
        uint times = 5;
        // emit TImes(times);
        for(uint i; i<times; i++) {
            _addCustomSellOrder(1800, 10, address(uint160(i+50)));
        }
        address _filler = makeAddr("FILLER");
        // vm.startPrank(deployer);
        usdc.mint(_filler, initUsdc*times);
        // vm.stopPrank();
        vm.startPrank(_filler);
        usdc.approve(address(marginAccount), initUsdc*times);
        marginAccount.deposit(_filler, address(usdc), times*initUsdc);
        orderBook.addBuyOrder(1801*PRICE_PRECISION, 40*SIZE_PRECISION);
        vm.stopPrank();
    }
    function makeAddrAndKey(string memory name) internal virtual returns (address addr, uint256 privateKey) {
        privateKey = uint256(keccak256(abi.encodePacked(name)));
        addr = vm.addr(privateKey);
        vm.label(addr, name);
    }

    // creates a labeled address
    function makeAddr(string memory name) internal virtual returns (address addr) {
        (addr,) = makeAddrAndKey(name);
    }
}

