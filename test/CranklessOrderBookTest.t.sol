// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CranklessOrderBook} from "../contracts/CranklessOrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";

contract OrderBookTest is Test {
    uint96 constant SIZE_PRECISION = 10**10;
    uint96 constant PRICE_PRECISION = 10**2;

    CranklessOrderBook orderBook;
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
        uint96 _pricePrecision = 10**2;
        uint96 _tickSize = _pricePrecision/2;
        uint96 _minSize = 10**5;
        uint96 _maxSize = 10**12;
        uint256 _takerFeeBps = 0;

        router = new Router();

        router.initialize(address(this));

        marginAccount = new MarginAccount(address(router));

        orderBook = new CranklessOrderBook(address(eth), 18, address(usdc), 18, address(marginAccount), _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);

        router.registerMarket(address(eth), address(usdc), address(orderBook));

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
    }

    function _addBuyOrder() internal {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function _addSellOrder() internal {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testAddBuyOrder() public {
        _addBuyOrder();
        uint96 price = 1800;
        uint96 size = 10;

        // Fetch the PricePoint from the contract
        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_buyPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), (price*size)*10**18);

        assertEq(totalOrdersAtPrice, size*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testAddBuyOrderMinSizeError() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("OrderBook: Size too low");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size, false);
        vm.stopPrank();
    }

    function testAddBuyOrderMaxSizeError() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("OrderBook: Size too large");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*10**20, false);
        vm.stopPrank();
    }

    function testAddBuyOrderTickSizeError() public {
        uint96 price = 180040;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("OrderBook: Tick Size");
        orderBook.addBuyOrder(price, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testAddBuyOrderInsufficientAllowanceFail() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testAddBuyOrderExceedsBalanceFail() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user3);
        usdc.approve(address(orderBook), initUsdc);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testAddSellOrder() public {
        _addSellOrder();
        uint96 price = 1800;
        uint96 size = 10;

        // Fetch the PricePoint from the contract
        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_sellPricePoints(price*PRICE_PRECISION);

        assertEq(eth.balanceOf(user1), initEth - size*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), (size)*10**18);

        assertEq(totalOrdersAtPrice, size*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testAddSellOrderMinSizeError() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Size too low");
        orderBook.addSellOrder(price*PRICE_PRECISION, size, false);
        vm.stopPrank();
    }

    function testAddSellOrderMaxSizeError() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Size too large");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*10**20, false);
        vm.stopPrank();
    }

    function testAddSellOrderTickSizeError() public {
        uint96 price = 180040;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Tick Size");
        orderBook.addSellOrder(price, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testAddSellOrderInsufficientAllowanceFail() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testAddSellOrderExceedsBalanceFail() public {
        uint96 price = 1800;
        uint96 size = 10;

        vm.startPrank(user3);
        eth.approve(address(orderBook), initEth);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testCancelOrder() public {
        _addBuyOrder();

        uint256[] memory _orderIds = new uint256[](1);
        _orderIds[0] = 1;

        uint96 price = 1800*PRICE_PRECISION;
        uint96 size = 10*SIZE_PRECISION;

        vm.startPrank(user2);
        orderBook.batchCancelOrders(_orderIds, false);
        vm.stopPrank();

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_buyPricePoints(price);

        assertEq(usdc.balanceOf(user2), initUsdc);
        assertEq(usdc.balanceOf(address(marginAccount)), 0);

        assertEq(totalOrdersAtPrice, size);
        assertEq(totalCompletedOrCanceledOrders, size);
    }

    function testCancelOrderOnlyOwnerFail() public {
        _addBuyOrder();

        uint256[] memory _orderIds = new uint256[](1);
        _orderIds[0] = 1;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Only order owner can cancel order");
        orderBook.batchCancelOrders(_orderIds, false);
        vm.stopPrank();
    }

    function testAddMultipleBuyOrders() public {
        uint96[] memory prices = new uint96[](3);
        prices[0] = 1800*PRICE_PRECISION;
        prices[1] = 1801*PRICE_PRECISION;
        prices[2] = 1802*PRICE_PRECISION;

        uint96[] memory sizes = new uint96[](3);
        sizes[0] = 1*SIZE_PRECISION;
        sizes[1] = 2*SIZE_PRECISION;
        sizes[2] = 3*SIZE_PRECISION;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.placeMultipleBuyOrders(prices, sizes, false);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user2), initUsdc - (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_buyPricePoints(prices[0]);
        assertEq(totalOrdersAtPrice, sizes[0]);
        assertEq(totalCompletedOrCanceledOrders, 0);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_buyPricePoints(prices[1]);
        assertEq(totalOrdersAtPrice, sizes[1]);
        assertEq(totalCompletedOrCanceledOrders, 0);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_buyPricePoints(prices[2]);
        assertEq(totalOrdersAtPrice, sizes[2]);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testAddMultipleSellOrders() public {
        uint96[] memory prices = new uint96[](3);
        prices[0] = 1803*PRICE_PRECISION;
        prices[1] = 1804*PRICE_PRECISION;
        prices[2] = 1805*PRICE_PRECISION;

        uint96[] memory sizes = new uint96[](3);
        sizes[0] = 1*SIZE_PRECISION;
        sizes[1] = 2*SIZE_PRECISION;
        sizes[2] = 3*SIZE_PRECISION;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.placeMultipleSellOrders(prices, sizes, false);
        vm.stopPrank();

        assertEq(eth.balanceOf(user1), initEth - (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_sellPricePoints(prices[0]);
        assertEq(totalOrdersAtPrice, sizes[0]);
        assertEq(totalCompletedOrCanceledOrders, 0);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_sellPricePoints(prices[1]);
        assertEq(totalOrdersAtPrice, sizes[1]);
        assertEq(totalCompletedOrCanceledOrders, 0);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_sellPricePoints(prices[2]);
        assertEq(totalOrdersAtPrice, sizes[2]);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testReplaceOrders() public {
        _addBuyOrder();

        uint96 oldPrice = 1800*PRICE_PRECISION;
        uint96 size = 10*SIZE_PRECISION;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        uint96[] memory prices = new uint96[](1);
        prices[0] = 1801*PRICE_PRECISION;

        uint96[] memory sizes = new uint96[](1);
        sizes[0] = 9*SIZE_PRECISION;

        vm.startPrank(user2);
        orderBook.replaceOrders(orderIds, prices, sizes, false);
        vm.stopPrank();

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_buyPricePoints(oldPrice);
        assertEq(totalOrdersAtPrice, size);
        assertEq(totalCompletedOrCanceledOrders, size);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_buyPricePoints(prices[0]);
        assertEq(totalOrdersAtPrice, sizes[0]);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testReplaceOrdersOnlyOwnerFail() public {
        _addBuyOrder();

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        uint96[] memory prices = new uint96[](1);
        prices[0] = 1801*PRICE_PRECISION;

        uint96[] memory sizes = new uint96[](1);
        sizes[0] = 9*SIZE_PRECISION;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Only order owner can cancel order");
        orderBook.replaceOrders(orderIds, prices, sizes, false);
        vm.stopPrank();
    }

    function testMarketSell() public {
        _addBuyOrder();

        uint96 size = 10;
        uint96 price = 1800;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.placeAndExecuteMarketSell(orderIds, size*SIZE_PRECISION, false);
        vm.stopPrank();

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_buyPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), 0);
        assertEq(usdc.balanceOf(user1), (price*size)*10**18);
        assertEq(eth.balanceOf(user2), size*10**18);

        assertEq(totalOrdersAtPrice, size*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, size*SIZE_PRECISION);
    }

    function testMarketSellTimePriorityFail() public {
        _addBuyOrder();
        _addBuyOrder();

        uint96 size = 10;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 2;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        vm.expectRevert("OrderBook: order not executable");
        orderBook.placeAndExecuteMarketSell(orderIds, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testMarketSellWrongOrderTypeFail() public {
        _addSellOrder();

        uint96 size = 10;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        vm.expectRevert("OrderBook: executing against a sell order");
        orderBook.placeAndExecuteMarketSell(orderIds, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testMarketSellInsifficientAllowance() public {
        _addBuyOrder();

        uint96 size = 10;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        vm.startPrank(user1);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.placeAndExecuteMarketSell(orderIds, size*SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testMarketBuy() public {
        _addSellOrder();

        uint96 size = 10;
        uint96 price = 1800;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.placeAndExecuteMarketBuy(orderIds, size*price*PRICE_PRECISION, false);
        vm.stopPrank();

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_sellPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), 0);
        assertEq(usdc.balanceOf(user1), (price*size)*10**18);
        assertEq(eth.balanceOf(user2), size*10**18);

        assertEq(totalOrdersAtPrice, size*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, size*SIZE_PRECISION);
    }

    function testMarketBuyTimePriorityFail() public {
        _addSellOrder();
        _addSellOrder();

        uint96 size = 10;
        uint96 price = 1800;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 2;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        vm.expectRevert("OrderBook: order not executable");
        orderBook.placeAndExecuteMarketBuy(orderIds, size*price*PRICE_PRECISION, false);
        vm.stopPrank();
    }

    function testMarketBuyWrongOrderTypeFail() public {
        _addBuyOrder();

        uint96 size = 10;
        uint96 price = 1800;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        vm.expectRevert("OrderBook: executing against a buy order");
        orderBook.placeAndExecuteMarketBuy(orderIds, size*price*PRICE_PRECISION, false);
        vm.stopPrank();
    }

    function testMarketBuyInsifficientAllowance() public {
        _addSellOrder();

        uint96 size = 10;
        uint96 price = 1800;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        vm.startPrank(user2);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.placeAndExecuteMarketBuy(orderIds, size*price*PRICE_PRECISION, false);
        vm.stopPrank();
    }

    function testAggressiveLimitSell() public {
        _addBuyOrder();
        _addBuyOrder();

        uint96 size = 30;
        uint96 oldSize = 10;
        uint96 price = 1799;
        uint96 oldPrice = 1800;

        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = 1;
        orderIds[1] = 2;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.placeAggressivelimitSell(orderIds, size * SIZE_PRECISION, price * PRICE_PRECISION, false);
        vm.stopPrank();

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_buyPricePoints(oldPrice*PRICE_PRECISION);
        assertEq(totalOrdersAtPrice, (2*oldSize)*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, (2*oldSize)*SIZE_PRECISION);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_sellPricePoints(price*PRICE_PRECISION);
        assertEq(totalOrdersAtPrice, (size - 2*oldSize)*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, 0);

        assertEq(usdc.balanceOf(user2), initUsdc - 2*(oldPrice*oldSize)*10**18);
        assertEq(eth.balanceOf(address(marginAccount)), (size - 2*oldSize)*10**18);
        assertEq(usdc.balanceOf(user1), 2*(oldPrice*oldSize)*10**18);
        assertEq(eth.balanceOf(user2), 2*oldSize*10**18);
    }

    function testAggressiveLimitBuy() public {
        _addSellOrder();
        _addSellOrder();

        uint96 size = 30;
        uint96 oldSize = 10;
        uint96 price = 1801;
        uint96 oldPrice = 1800;

        uint256[] memory orderIds = new uint256[](2);
        orderIds[0] = 1;
        orderIds[1] = 2;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.placeAggressivelimitBuy(orderIds, (2*oldPrice*oldSize + price*oldSize) * PRICE_PRECISION, price * PRICE_PRECISION, false);
        vm.stopPrank();

        (uint96 totalCompletedOrCanceledOrders, uint96 totalOrdersAtPrice) = orderBook.s_sellPricePoints(oldPrice*PRICE_PRECISION);
        assertEq(totalOrdersAtPrice, (2*oldSize)*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, (2*oldSize)*SIZE_PRECISION);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_buyPricePoints(price*PRICE_PRECISION);
        assertEq(totalOrdersAtPrice, (size - 2*oldSize)*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, 0);

        assertEq(usdc.balanceOf(user2), initUsdc - (2*oldPrice*oldSize + price*oldSize)*10**18);
        assertEq(usdc.balanceOf(address(marginAccount)), (price*oldSize)*10**18);
        assertEq(usdc.balanceOf(user1), (2*oldPrice*oldSize)*10**18);
        assertEq(eth.balanceOf(user2), 2*oldSize*10**18);
    }
}
