//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {OrderBook} from "../../contracts/OrderBook.sol";
import {KuruAMMVault} from "../../contracts/KuruAMMVault.sol";
import {MintableERC20} from "../lib/MintableERC20.sol";
import {Router} from "../../contracts/Router.sol";
import {MarginAccount} from "../../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Gas} from "./gas_helpers/Gas.sol";
import "forge-std/Test.sol";

contract BenchMarkTest is Test, Gas {
    OrderBook orderBook;
    MintableERC20 usdc;
    MintableERC20 eth;
    Router router;
    MarginAccount marginAccount;
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint32 constant PRICE_PRECISION = 10 ** 2;

    address deployer;
    uint256 initEth = 1000 * 10 ** 18;
    uint256 initUsdc = 1000000 * 10 ** 18;
    address lastGenAddress;
    uint256 SEED = 2;
    uint96 SPREAD = 30;
    address trustedForwarder;

    function setUp() public {
        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USDC", "USDC");
        uint32 _tickSize = PRICE_PRECISION / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 12;
        uint256 _takerFeeBps = 0;
        uint256 _makerFeeBps = 0;
        Router routerImplementation = new Router();
        address routerProxy = Create2.deploy(
            0,
            bytes32(keccak256("")),
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(routerImplementation, bytes("")))
        );
        router = Router(payable(routerProxy));
        marginAccount = new MarginAccount();
        trustedForwarder = address(0x123);
        marginAccount = MarginAccount(payable(address(new ERC1967Proxy(address(marginAccount), ""))));
        marginAccount.initialize(address(this), address(router), address(router), trustedForwarder);

        OrderBook implementation = new OrderBook();
        KuruAMMVault kuruAmmVaultImplementation = new KuruAMMVault();
        router.initialize(address(this), address(marginAccount), address(implementation), address(kuruAmmVaultImplementation), trustedForwarder);
        OrderBook.OrderBookType _type;
        address proxy = router.deployProxy(
            _type,
            address(eth),
            address(usdc),
            SIZE_PRECISION,
            PRICE_PRECISION,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps,
            SPREAD
        );

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

    function _addCustomBuyOrder(address _user, uint32 _price, uint96 _size) internal {
        vm.startPrank(_user);
        orderBook.addBuyOrder(_price, _size, false);
        vm.stopPrank();
    }

    function _addCustomSellOrderOnlyPriceSize(uint32 _price, uint96 _size) internal {
        address _maker = genAddress();
        eth.mint(_maker, _size * 10 ** 18);
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _size * 10 ** 18);
        marginAccount.deposit(_maker, address(eth), _size * 10 ** 18);
        orderBook.addSellOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function _addCustomSellOrder(address _user, uint32 _price, uint96 _size) internal {
        vm.startPrank(_user);
        orderBook.addSellOrder(_price, _size, false);
        vm.stopPrank();
    }

    function _addCustomBuyOrderOnlyPriceSize(uint32 _price, uint96 _size) internal {
        address _maker = genAddress();
        uint256 _usdcForEachOrder = _price * _size * 10 ** usdc.decimals();
        usdc.mint(_maker, _usdcForEachOrder);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _usdcForEachOrder);
        marginAccount.deposit(_maker, address(usdc), _usdcForEachOrder);
        orderBook.addBuyOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
        vm.stopPrank();
    }

    function testBenchmarkBuySingleMultiplePriceDifferentUser() public {
        uint96 _size = 10;
        console.log("LIMIT BUY ORDER DIFFERENT PRICE DIFFERENT USER : ");
        for (uint32 i; i < 10; i++) {
            address _user = genAddress();
            uint32 _price = 3600 + 100 * i;
            uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10 ** usdc.decimals());
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(marginAccount), _consumableFunds);
            marginAccount.deposit(_user, address(usdc), _consumableFunds);
            startMeasuringGas("");
            orderBook.addBuyOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkBuySingleSamePriceDifferentUser() public {
        uint96 _size = 10;
        uint32 _price = 3600;
        console.log("LIMIT BUY ORDERS SAME PRICE DIFFERENT USER : ");
        for (uint32 i; i < 10; i++) {
            address _user = genAddress();
            uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10 ** usdc.decimals());
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(marginAccount), _consumableFunds);
            marginAccount.deposit(_user, address(usdc), _consumableFunds);
            startMeasuringGas("");
            orderBook.addBuyOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkSellSingleSamePriceSameUser() public {
        console.log("LIMIT SELL ORDER 1PP: ");
        address _user = genAddress();
        uint32 _price = 3600;
        uint96 _size = 10;
        uint256 _iterations = 10;
        eth.mint(_user, _iterations * _size * 10 ** eth.decimals());
        vm.startPrank(_user);
        eth.approve(address(marginAccount), _iterations * _size * 10 ** 18);
        marginAccount.deposit(_user, address(eth), _iterations * _size * 10 ** 18);
        for (uint32 i; i < _iterations; i++) {
            startMeasuringGas("");
            orderBook.addSellOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, "GAS USED: ", gasVar);
        }
        vm.stopPrank();
    }

    function testBenchmarkSellSingleDifferentPriceSameUser() public {
        console.log("LIMIT SELL ORDER DIFFERENT PP: ");
        address _user = genAddress();
        uint32 _startingPrice = 3600;
        uint96 _size = 10;
        uint256 _iterations = 10;
        eth.mint(_user, _iterations * _size * 10 ** eth.decimals());
        vm.startPrank(_user);
        eth.approve(address(marginAccount), _iterations * _size * 10 ** eth.decimals());
        marginAccount.deposit(_user, address(eth), _iterations * _size * 10 ** eth.decimals());
        for (uint32 i; i < _iterations; i++) {
            startMeasuringGas("");
            orderBook.addSellOrder((_startingPrice + i) * PRICE_PRECISION, _size * SIZE_PRECISION, false);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, "GAS USED: ", gasVar);
        }
        vm.stopPrank();
    }

    function testBenchmarkMarketBuySamePriceIterative3LO() public {
        uint32 _price = 3600;
        uint96 _size = 12;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10 ** usdc.decimals());
        //place 3 orders, same price, same size, from 3 different makers
        for (uint32 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_price, _size / 3);
        }
        console.log("MARKET BUY 1PP 3LO :");
        for (uint32 i = 0; i < 10; i++) {
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint96(_consumableFunds * PRICE_PRECISION / (10 ** 18)), 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketBuySamePriceIterative2LO() public {
        uint32 _price = 3600;
        uint96 _size = 12;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10 ** usdc.decimals());
        //place 3 orders, same price, same size, from 3 different makers
        for (uint32 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_price, _size / 2);
        }
        console.log("MARKET BUY 1PP 2LO :");
        for (uint32 i = 0; i < 10; i++) {
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint96(_consumableFunds * PRICE_PRECISION / (10 ** 18)), 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketBuySamePriceIterative1LO() public {
        uint32 _price = 3600;
        uint96 _size = 12;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10 ** usdc.decimals());
        //place 3 orders, same price, same size, from 3 different makers
        for (uint32 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_price, _size);
        }
        console.log("MARKET BUY 1PP 1LO :");
        for (uint32 i = 0; i < 10; i++) {
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint96(_consumableFunds * PRICE_PRECISION / (10 ** 18)), 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketBuyDifferentPriceIterative() public {
        //Concept is to place equal size orders over a long price range
        //so that each market buy is matched with 3 orders, each of different price point
        console.log("MARKET BUY 3PP 1LO:");
        uint32 _startingPrice = 3600;
        uint96 _sellSize = 4;
        for (uint32 i = 0; i < 30; i++) {
            _addCustomSellOrderOnlyPriceSize(_startingPrice + i, _sellSize);
        }
        //10 market buy orders
        for (uint32 i = 0; i < 10; i++) {
            //Each market order should match against 12 ETH
            //Total consumable funds = 4*(3600 + 3600 + 3600 + 3*i + 3*i + 1 + 3*i + 2)*10**decimals = 4*(3600*3 + 9*i + 3)*10**decimals
            uint256 _consumableFunds = 4 * (3600 * 3 + 9 * uint256(i) + 3) * 10 ** 18;
            address _user = genAddress();
            usdc.mint(_user, _consumableFunds);
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _consumableFunds);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketBuy(uint96(_consumableFunds * PRICE_PRECISION / 10 ** 18), 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellSamePriceIterative3LO() public {
        uint32 _startingPrice = 3600;
        uint96 _size = 12;
        //sell 10 eth
        uint96 _sellSizeEth = 12 * 10 ** 18;
        //place 3 orders, same price, same size, from 3 different makers
        //each order to be filling 4 eth
        console.log("MARKET SELL 1PP 3LO: ");
        for (uint32 i = 0; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice, 4);
        }

        for (uint32 i = 0; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, uint256(_sellSizeEth));
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSizeEth);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_size * SIZE_PRECISION, 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellSamePriceIterative2LO() public {
        uint32 _startingPrice = 3600;
        uint96 _size = 12;
        //sell 10 eth
        uint96 _sellSizeEth = 12 * 10 ** 18;
        //place 3 orders, same price, same size, from 3 different makers
        //each order to be filling 4 eth
        console.log("MARKET SELL 1PP 2LO: ");
        for (uint32 i = 0; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice, 6);
        }

        for (uint32 i = 0; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, uint256(_sellSizeEth));
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSizeEth);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_size * SIZE_PRECISION, 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellSamePriceIterative1LO() public {
        uint32 _startingPrice = 3600;
        uint96 _size = 12;
        //sell 10 eth
        uint96 _sellSizeEth = 12 * 10 ** 18;
        //place 3 orders, same price, same size, from 3 different makers
        //each order to be filling 4 eth
        console.log("MARKET SELL 1PP 1LO: ");
        for (uint32 i = 0; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice, 12);
        }

        for (uint32 i = 0; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, uint256(_sellSizeEth));
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSizeEth);
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_size * SIZE_PRECISION, 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED: ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkMarketSellDifferentPriceIterative() public {
        //Concept : Place same size orders over a price range, equally spaced
        //Must match with 3 PP
        console.log("MARKET BUY 3PP 1LO : ");
        uint32 _startingPrice = 3600;
        uint96 _buySize = 4;
        uint96 _sellSize = 12;
        for (uint32 i; i < 30; i++) {
            _addCustomBuyOrderOnlyPriceSize(_startingPrice + i, _buySize);
        }
        for (uint32 i; i < 10; i++) {
            address _user = genAddress();
            eth.mint(_user, _sellSize * 10 ** eth.decimals());
            vm.startPrank(_user);
            eth.approve(address(orderBook), _sellSize * 10 ** eth.decimals());
            startMeasuringGas("");
            orderBook.placeAndExecuteMarketSell(_sellSize * SIZE_PRECISION, 0, false, true);
            uint256 gasVar = stopMeasuringGas();
            console.log("ITERATION ", i + 1, " GAS USED : ", gasVar);
            vm.stopPrank();
        }
    }

    function testBenchmarkCancelBuyOrders() public {
        console.log("CANCEL BUY ORDERS 1LO : ");
        uint32 _price = 3600;
        uint96 _size = 4;
        uint256 _iterations = 10;
        address _maker = genAddress();
        uint256 _usdcForEachOrder = uint256(_price) * uint256(_size) * 10 ** usdc.decimals();
        usdc.mint(_maker, _iterations * _usdcForEachOrder);
        vm.startPrank(_maker);
        usdc.approve(address(marginAccount), _iterations * _usdcForEachOrder);
        marginAccount.deposit(_maker, address(usdc), _iterations * _usdcForEachOrder);
        for (uint32 i = 0; i < _iterations; i++) {
            orderBook.addBuyOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
        }
        vm.stopPrank();
        for (uint32 i = 0; i < _iterations; i++) {
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
        uint32 _price = 2600;
        uint96 _size = 4;
        uint256 _iterations = 10;
        address _maker = genAddress();
        eth.mint(_maker, _iterations * _size * 10 ** eth.decimals());
        vm.startPrank(_maker);
        eth.approve(address(marginAccount), _iterations * _size * 10 ** eth.decimals());
        marginAccount.deposit(_maker, address(eth), _iterations * _size * 10 ** eth.decimals());
        for (uint32 i; i < _iterations; i++) {
            orderBook.addSellOrder(_price * PRICE_PRECISION, _size * SIZE_PRECISION, false);
        }
        vm.stopPrank();
        for (uint32 i = 0; i < _iterations; i++) {
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
