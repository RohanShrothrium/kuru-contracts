// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CranklessOrderBook} from "../contracts/CranklessOrderBook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract OrderBookTest is Test {
    uint128 constant SIZE_PRECISION = 10**10;
    uint96 constant PRICE_PRECISION = 10**2;

    CranklessOrderBook orderBook;
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

        orderBook = new CranklessOrderBook(address(eth), 18, address(usdc), 18);

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
    }

    function testAddBuyOrder() public {
        uint96 price = 1800;
        uint128 size = 10;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();

        // Fetch the PricePoint from the contract
        (uint128 totalCompletedOrCanceledOrders, uint128 totalOrdersAtPrice) = orderBook.s_buyPricePoints(price*PRICE_PRECISION);

        assertEq(usdc.balanceOf(user2), initUsdc - (price*size)*10**18);
        assertEq(usdc.balanceOf(address(orderBook)), (price*size)*10**18);

        assertEq(totalOrdersAtPrice, size*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testAddBuyOrderInsufficientAllowanceFail() public {
        uint96 price = 1800;
        uint128 size = 10;

        vm.startPrank(user2);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testAddBuyOrderExceedsBalanceFail() public {
        uint96 price = 1800;
        uint128 size = 10;

        vm.startPrank(user3);
        usdc.approve(address(orderBook), initUsdc);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        orderBook.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testAddSellOrder() public {
        uint96 price = 1800;
        uint128 size = 10;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();

        // Fetch the PricePoint from the contract
        (uint128 totalCompletedOrCanceledOrders, uint128 totalOrdersAtPrice) = orderBook.s_sellPricePoints(price*PRICE_PRECISION);

        assertEq(eth.balanceOf(user1), initEth - size*10**18);
        assertEq(eth.balanceOf(address(orderBook)), (size)*10**18);

        assertEq(totalOrdersAtPrice, size*SIZE_PRECISION);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testAddSellOrderInsufficientAllowanceFail() public {
        uint96 price = 1800;
        uint128 size = 10;

        vm.startPrank(user1);
        vm.expectRevert("ERC20: insufficient allowance");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testAddSellOrderExceedsBalanceFail() public {
        uint96 price = 1800;
        uint128 size = 10;

        vm.startPrank(user3);
        eth.approve(address(orderBook), initEth);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        orderBook.addSellOrder(price*PRICE_PRECISION, size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testCancelOrder() public {
        testAddBuyOrder();

        uint256[] memory _orderIds = new uint256[](1);
        _orderIds[0] = 1;

        uint96 price = 1800*PRICE_PRECISION;
        uint128 size = 10*SIZE_PRECISION;

        vm.startPrank(user2);
        orderBook.batchCancelOrders(_orderIds);
        vm.stopPrank();

        (uint128 totalCompletedOrCanceledOrders, uint128 totalOrdersAtPrice) = orderBook.s_buyPricePoints(price);

        assertEq(usdc.balanceOf(user2), initUsdc);
        assertEq(usdc.balanceOf(address(orderBook)), 0);

        assertEq(totalOrdersAtPrice, size);
        assertEq(totalCompletedOrCanceledOrders, size);
    }

    function testCancelOrderOnlyOwnerFail() public {
        testAddBuyOrder();

        uint256[] memory _orderIds = new uint256[](1);
        _orderIds[0] = 1;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Only order owner can cancel order");
        orderBook.batchCancelOrders(_orderIds);
        vm.stopPrank();
    }

    function testAddMultipleBuyOrders() public {
        uint96[] memory prices = new uint96[](3);
        prices[0] = 1800*PRICE_PRECISION;
        prices[1] = 1801*PRICE_PRECISION;
        prices[2] = 1802*PRICE_PRECISION;

        uint128[] memory sizes = new uint128[](3);
        sizes[0] = 1*SIZE_PRECISION;
        sizes[1] = 2*SIZE_PRECISION;
        sizes[2] = 3*SIZE_PRECISION;

        vm.startPrank(user2);
        usdc.approve(address(orderBook), initUsdc);
        orderBook.placeMultipleBuyOrders(prices, sizes);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user2), initUsdc - (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);
        assertEq(usdc.balanceOf(address(orderBook)), (prices[0]*sizes[0] + prices[1]*sizes[1] + prices[2]*sizes[2])/PRICE_PRECISION/SIZE_PRECISION*10**18);

        (uint128 totalCompletedOrCanceledOrders, uint128 totalOrdersAtPrice) = orderBook.s_buyPricePoints(prices[0]);
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

        uint128[] memory sizes = new uint128[](3);
        sizes[0] = 1*SIZE_PRECISION;
        sizes[1] = 2*SIZE_PRECISION;
        sizes[2] = 3*SIZE_PRECISION;

        vm.startPrank(user1);
        eth.approve(address(orderBook), initEth);
        orderBook.placeMultipleSellOrders(prices, sizes);
        vm.stopPrank();

        assertEq(eth.balanceOf(user1), initEth - (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);
        assertEq(eth.balanceOf(address(orderBook)), (sizes[0] + sizes[1] + sizes[2])/SIZE_PRECISION*10**18);

        (uint128 totalCompletedOrCanceledOrders, uint128 totalOrdersAtPrice) = orderBook.s_sellPricePoints(prices[0]);
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
        testAddBuyOrder();

        uint96 oldPrice = 1800*PRICE_PRECISION;
        uint128 size = 10*SIZE_PRECISION;

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        uint96[] memory prices = new uint96[](1);
        prices[0] = 1801*PRICE_PRECISION;

        vm.startPrank(user2);
        orderBook.replaceOrders(orderIds, prices);
        vm.stopPrank();

        (uint128 totalCompletedOrCanceledOrders, uint128 totalOrdersAtPrice) = orderBook.s_buyPricePoints(oldPrice);
        assertEq(totalOrdersAtPrice, size);
        assertEq(totalCompletedOrCanceledOrders, size);

        (totalCompletedOrCanceledOrders, totalOrdersAtPrice) = orderBook.s_buyPricePoints(prices[0]);
        assertEq(totalOrdersAtPrice, size);
        assertEq(totalCompletedOrCanceledOrders, 0);
    }

    function testReplaceOrdersOnlyOwnerFail() public {
        testAddBuyOrder();

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        uint96[] memory prices = new uint96[](1);
        prices[0] = 1801*PRICE_PRECISION;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Only order owner can update order");
        orderBook.replaceOrders(orderIds, prices);
        vm.stopPrank();
    }

    function testPlaceMarketBuy() public {
        testAddSellOrder();

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 1;

        uint96[] memory prices = new uint96[](1);
        prices[0] = 1801*PRICE_PRECISION;

        vm.startPrank(user1);
        vm.expectRevert("OrderBook: Only order owner can update order");
        orderBook.replaceOrders(orderIds, prices);
        vm.stopPrank();
    }
}
