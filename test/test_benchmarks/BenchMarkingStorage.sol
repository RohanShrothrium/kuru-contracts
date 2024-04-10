//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {CranklessStorageOrderBook} from "../../contracts/CranklessStorageOrderBook.sol";
import {MintableERC20} from "../lib/MintableERC20.sol";
import {Router} from "../../contracts/Router.sol";
import {MarginAccount} from "../../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Gas} from "./gas_helpers/Gas.sol";
import "forge-std/Test.sol";


contract BenchMarkTest is Test, Gas {

    CranklessStorageOrderBook orderBook;
    MintableERC20 usdc;
    MintableERC20 eth;
    Router router;
    MarginAccount marginAccount;
    uint96 constant SIZE_PRECISION = 10**10;
    uint24 constant PRICE_PRECISION = 10**2;

    address deployer;
    address u1;
    address u2;
    address u3;
    uint256 initEth = 1000*10**18;
    uint256 initUsdc = 1000000*10**18;
    address lastGenAddress;
    uint256 SEED = 2;
    function setUp() public {

        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USDC", "USDC");
        uint96 _tickSize = PRICE_PRECISION/2;
        uint96 _minSize = 10**5;
        uint96 _maxSize = 10**12;
        uint256 _takerFeeBps = 0;

        router = new Router();
        router.initialize(address(this));
        u1 = genAddress();
        u2 = genAddress();
        u3 = genAddress();
        marginAccount = new MarginAccount(address(router));

        router.setMarginAccount(address(marginAccount));

        orderBook = new CranklessStorageOrderBook(address(eth), 18, address(usdc), 18, address(marginAccount), SIZE_PRECISION, PRICE_PRECISION, _tickSize, _minSize, _maxSize, _takerFeeBps);

        router.registerMarket(address(eth), address(usdc), address(orderBook));

        eth.mint(u1, initEth);
        usdc.mint(u2, initUsdc);


    }

    function genAddress() internal returns (address) {
        uint256 _seed = SEED;
        uint256 privateKeyGen = uint256(keccak256(abi.encodePacked(bytes32(_seed))));
        address derived = vm.addr(privateKeyGen);
        ++SEED;
        lastGenAddress = derived;
        return derived;
    }

    function _addCustomBuyOrder(address _user, uint24 _price, uint96 _size) internal {       
        vm.startPrank(_user);
        orderBook.addBuyOrder(_price, _size);
        vm.stopPrank();
    }

    function _addCustomSellOrderOnlyPriceSize(uint24 _price, uint96 _size) internal {
            address _maker = genAddress();
            eth.mint(_maker, _size*10**18);
            vm.startPrank(_maker);
            eth.approve(address(marginAccount), _size*10**18);
            marginAccount.deposit(_maker, address(eth), _size*10**18);
            orderBook.addSellOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
            vm.stopPrank();
    }


    function _addCustomSellOrder(address _user, uint24 _price, uint96 _size) internal {
        vm.startPrank(_user);
        orderBook.addSellOrder(_price, _size);
        vm.stopPrank();
    }


    function _addCustomBuyOrderOnlyPriceSize(uint24 _price, uint96 _size) internal {
        address _maker = genAddress();
        uint256 _usdcForEachOrder = _price * _size * 10 ** usdc.decimals();
        usdc.mint(_maker, _usdcForEachOrder);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _usdcForEachOrder);
        marginAccount.deposit(_maker, address(usdc), _usdcForEachOrder);
        orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testXBenchmarkBuySingleMultiplePriceSameUser() public {
        address _user = genAddress();
        uint96 _size = 10;
        console.log("LIMIT BUY ORDER DIFFERENT PRICE SAME USER : ");
        for(uint24 i; i < 10; i++) {   
            uint24 _price = 3600 + 100*i;
            uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(marginAccount), _consumableFunds);
            marginAccount.deposit(_user, address(usdc), _consumableFunds);
            startMeasuringGas("");
            orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i+1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkBuySingleMultiplePriceDifferentUser() public {
        uint96 _size = 10;
        console.log("LIMIT BUY ORDER DIFFERENT PRICE DIFFERENT USER : ");
        for(uint24 i; i < 10; i++) {   
            address _user = genAddress();
            uint24 _price = 3600 + 100*i;
            uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(marginAccount), _consumableFunds);
            marginAccount.deposit(_user, address(usdc), _consumableFunds);
            startMeasuringGas("");
            orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i+1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkBuySingleSamePriceDifferentUser() public {
        uint96 _size = 10;
        uint24 _price = 3600;
        console.log("LIMIT BUY ORDERS SAME PRICE DIFFERENT USER : ");
        for(uint24 i; i < 10; i++) {   
            address _user = genAddress();
            uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(marginAccount), _consumableFunds);
            marginAccount.deposit(_user, address(usdc), _consumableFunds);
            startMeasuringGas("");
            orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i+1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testXBenchmarkBuyAndMatchMultipleOrders() public {
        address _user = genAddress();
        uint24 _price = 3600;
        uint96 _size = 10;
        uint96 sellSizeEth = 4*10**18;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        usdc.mint(_user, _consumableFunds);
        for(uint i=0; i<3; i++) {
            address _maker = genAddress();
            eth.mint(_maker, sellSizeEth);
            vm.startPrank(_maker);
            eth.approve(address(marginAccount), sellSizeEth);
            marginAccount.deposit(_maker, address(eth), sellSizeEth);
            orderBook.addSellOrder(_price*PRICE_PRECISION, sellSizeEth*SIZE_PRECISION/10**18);
            vm.stopPrank();
        }
        vm.startPrank(_user);
        usdc.approve(address(marginAccount), _consumableFunds);
        usdc.balanceOf(_user);
        marginAccount.deposit(_user, address(usdc), _consumableFunds);
        assert(usdc.balanceOf(_user) == 0);
        orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        vm.stopPrank();
        assert(usdc.balanceOf(_user) == 0);
    }

    function testXBenchmarkBuyAndMatchMultipleOrdersMultiplePrice() public {
        address _user = genAddress();
        uint24 _price = 3600;
        uint96 _size = 10;
        uint96 sellSizeEth = 4*10**18;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        usdc.mint(_user, _consumableFunds);
        //place 3 sell orders at descending prices
        //begin with _price and dock 1% off the price for each iteration
        uint24 price_DEVIATION = _price/(10**2);
        for(uint24 i = 0; i < 3; i++) {
            address _maker = genAddress();
            eth.mint(_maker, sellSizeEth);
            vm.startPrank(_maker);
            eth.approve(address(marginAccount), sellSizeEth);
            marginAccount.deposit(_maker, address(eth), sellSizeEth);
            orderBook.addSellOrder((_price- i*price_DEVIATION)*PRICE_PRECISION, sellSizeEth*SIZE_PRECISION/10**18);
            vm.stopPrank();
        }
        vm.startPrank(_user);
        usdc.approve(address(marginAccount), _consumableFunds);
        marginAccount.deposit(_user, address(usdc), _consumableFunds);
        orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        vm.stopPrank();
        assert(usdc.balanceOf(_user)==0);
    }

    function testBenchmarkSellSingleSamePriceSameUser() public {
        console.log("LIMIT SELL ORDER 1PP: ");
        address _user = genAddress();
        uint24 _price = 3600;
        uint96 _size = 10;
        uint256 _iterations = 10;
        eth.mint(_user, _iterations * _size * 10 ** eth.decimals());
        vm.startPrank(_user);
        eth.approve(address(marginAccount), _iterations * _size *10 ** 18);
        marginAccount.deposit(_user, address(eth), _iterations * _size * 10 ** 18);
        for(uint24 i; i < _iterations; i++){
            startMeasuringGas("");
            orderBook.addSellOrder(_price*PRICE_PRECISION, _size * SIZE_PRECISION);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, "GAS USED: ", gasVar);
        }
        vm.stopPrank();
    }

    function testBenchmarkSellSingleDifferentPriceSameUser() public {
        console.log("LIMIT SELL ORDER DIFFERENT PP: ");
        address _user = genAddress();
        uint24 _startingPrice = 3600;
        uint96 _size = 10;
        uint256 _iterations = 10;
        eth.mint(_user, _iterations * _size * 10 ** eth.decimals());
        vm.startPrank(_user);
        eth.approve(address(marginAccount), _iterations * _size * 10 ** eth.decimals());
        marginAccount.deposit(_user, address(eth), _iterations * _size * 10 ** eth.decimals());
        for(uint24 i; i < _iterations; i++){
            startMeasuringGas("");
            orderBook.addSellOrder((_startingPrice + i) * PRICE_PRECISION, _size * SIZE_PRECISION);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, "GAS USED: ", gasVar);
        }
        vm.stopPrank();
    }

    function testBenchmarkMarketBuySamePriceIterative3LO() public {
        uint24 _price = 3600;
        uint96 _size = 12;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        //place 3 orders, same price, same size, from 3 different makers
        for(uint24 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_price, _size/3);
        }
        console.log("MARKET BUY 1PP 3LO :");
        for(uint24 i = 0; i < 10; i++) {
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint24(_consumableFunds*PRICE_PRECISION/(10**18)), true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketBuySamePriceIterative2LO() public {
        uint24 _price = 3600;
        uint96 _size = 12;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        //place 3 orders, same price, same size, from 3 different makers
        for(uint24 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_price, _size/2);
        }
        console.log("MARKET BUY 1PP 2LO :");
        for(uint24 i = 0; i < 10; i++) {
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint24(_consumableFunds*PRICE_PRECISION/(10**18)), true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketBuySamePriceIterative1LO() public {
        uint24 _price = 3600;
        uint96 _size = 12;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        //place 3 orders, same price, same size, from 3 different makers
        for(uint24 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_price, _size);
        }
        console.log("MARKET BUY 1PP 1LO :");
        for(uint24 i = 0; i < 10; i++) {
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint24(_consumableFunds*PRICE_PRECISION/(10**18)), true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketBuyDifferentPriceIterative() public {
        //Concept is to place equal size orders over a long price range
        //so that each market buy is matched with 3 orders, each of different price point
        console.log("MARKET BUY 3PP 1LO:");
        uint24 _startingPrice = 3600;
        uint96 _sellSize = 4;
        for(uint24 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_startingPrice + i, _sellSize);
        }
        //10 market buy orders
        for(uint24 i = 0; i < 10; i++) {
            //Each market order should match against 12 ETH
            //Total consumable funds = 4*(3600 + 3600 + 3600 + 3*i + 3*i + 1 + 3*i + 2)*10**decimals = 4*(3600*3 + 9*i + 3)*10**decimals
            uint256 _consumableFunds = 4*(3600*3 + 9*uint256(i) + 3)*10**18;
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint24(_consumableFunds*PRICE_PRECISION/10**18), true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellSamePriceIterative3LO() public {
        uint24 _startingPrice = 3600;
        uint96 _size = 12;
        //sell 10 eth
        uint96 _sellSizeEth = 12*10**18;
        //place 3 orders, same price, same size, from 3 different makers
        //each order to be filling 4 eth
        console.log("MARKET SELL 1PP 3LO: ");
        for(uint24 i = 0; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice, 4);
        }

        for(uint24 i = 0; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, uint256(_sellSizeEth));
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSizeEth);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_size * SIZE_PRECISION, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellSamePriceIterative2LO() public {
        uint24 _startingPrice = 3600;
        uint96 _size = 12;
        //sell 10 eth
        uint96 _sellSizeEth = 12*10**18;
        //place 3 orders, same price, same size, from 3 different makers
        //each order to be filling 4 eth
        console.log("MARKET SELL 1PP 2LO: ");
        for(uint24 i = 0; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice, 6);
        }

        for(uint24 i = 0; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, uint256(_sellSizeEth));
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSizeEth);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_size * SIZE_PRECISION, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellSamePriceIterative1LO() public {
        uint24 _startingPrice = 3600;
        uint96 _size = 12;
        //sell 10 eth
        uint96 _sellSizeEth = 12*10**18;
        //place 3 orders, same price, same size, from 3 different makers
        //each order to be filling 4 eth
        console.log("MARKET SELL 1PP 1LO: ");
        for(uint24 i = 0; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice, 12);
        }

        for(uint24 i = 0; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, uint256(_sellSizeEth));
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSizeEth);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_size * SIZE_PRECISION, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellDifferentPriceIterative() public {
        //Concept : Place same size orders over a price range, equally spaced
        //Must match with 3 PP
        console.log("MARKET BUY 3PP 1LO : ");
        uint24 _startingPrice = 3600;
        uint96 _buySize = 4;
        uint96 _sellSize = 12;
        for(uint24 i; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice + i, _buySize);
        }
        for(uint24 i; i < 10; i++)  {
            address _user = genAddress();
            eth.mint(_user, _sellSize * 10 ** eth.decimals());
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSize * 10 ** eth.decimals());
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_sellSize * SIZE_PRECISION, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED : ", gasVar);
            vm.stopPrank();
        }
    }

    function testXBenchmarkPlaceMultipleBuyDifferentPrices() public {
        //We construct 3 orders from price point 3600 onwards, with a price difference of 10
        //Size is kept constant
        uint24[] memory _prices = new uint24[](3);
        uint256 _totalUsdcToBeMinted;
        uint96 _size = 10;
        uint96[] memory _sizes = new uint96[](3);
        for(uint24 i; i < 3; i++) {
            _prices[i] = (3600 + i*10)*PRICE_PRECISION;
            _sizes[i] = _size*SIZE_PRECISION;
            _totalUsdcToBeMinted += _size*_prices[i]*10**18;
        }
        address _user = genAddress();
        usdc.mint(_user, _totalUsdcToBeMinted);
        vm.startPrank(_user);
        usdc.approve(address(marginAccount), _totalUsdcToBeMinted);
        marginAccount.deposit(_user, address(usdc), _totalUsdcToBeMinted);
        orderBook.placeMultipleBuyOrders(_prices, _sizes);
        vm.stopPrank();
    }

    function testXBenchmarkPlaceMultipleSellDifferentPrices() public {
        //We construct 3 orders from price point 3600 onwards, with a price difference of 10
        //Size is kept constant
        uint24[] memory _prices = new uint24[](3);
        uint96 _size = 10;
        uint96[] memory _sizes = new uint96[](3);
        for(uint24 i; i < 3; i++) {
            _prices[i] = (3600 + i*10)*PRICE_PRECISION;
            _sizes[i] = _size*SIZE_PRECISION;
        }
        address _user = genAddress();
        uint256 _totalEthToBeMinted = 3*_size*10**18;
        eth.mint(_user, _totalEthToBeMinted);
        vm.startPrank(_user);
        eth.approve(address(marginAccount), _totalEthToBeMinted);
        marginAccount.deposit(_user, address(eth), _totalEthToBeMinted);
        orderBook.placeMultipleSellOrders(_prices, _sizes);
        vm.stopPrank();
    }

    function testBenchmarkCancelBuyOrders() public {
        console.log("CANCEL BUY ORDERS 1LO : ");
        uint24 _price = 3600;
        uint96 _size = 4;
        uint256 _iterations = 10;
        address _maker = genAddress();
        uint256 _usdcForEachOrder = uint256(_price) * uint256(_size) * 10 ** usdc.decimals();
        usdc.mint(_maker, _iterations * _usdcForEachOrder);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _iterations * _usdcForEachOrder);
        marginAccount.deposit(_maker, address(usdc), _iterations * _usdcForEachOrder);
        for(uint24 i = 0; i < _iterations; i++) {
            orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        }
        vm.stopPrank();
        for(uint24 i = 0; i < _iterations; i++) {
            uint40[] memory _orderId = new uint40[](1);
            _orderId[0] = i + 1;
            vm.startPrank(_maker);
            startMeasuringGas("");
            orderBook.batchCancelOrders(_orderId);
            uint256 gasVar = stopMeasuringGas();
            vm.stopPrank();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
        }
    }

    function testBenchmarkCancelSellOrders() public {
        console.log("CANCEL SELL ORDERS 1LO :");
        uint24 _price = 2600;
        uint96 _size = 4;
        uint256 _iterations = 10;
        address _maker = genAddress();
        eth.mint(_maker, _iterations * _size * 10 ** eth.decimals());
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _iterations * _size * 10 ** eth.decimals());
        marginAccount.deposit(_maker, address(eth), _iterations * _size * 10 ** eth.decimals());
        for(uint24 i; i < _iterations; i++) {
            orderBook.addSellOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION);
        }
        vm.stopPrank();
        for(uint24 i = 0; i < _iterations; i++) {
            uint40[] memory _orderId = new uint40[](1);
            _orderId[0] = i + 1;
            vm.startPrank(_maker);
            startMeasuringGas("");
            orderBook.batchCancelOrders(_orderId);
            uint256 gasVar = stopMeasuringGas();
            vm.stopPrank();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
        }
    }

}