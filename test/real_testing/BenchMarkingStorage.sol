//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {CranklessStorageOrderBook} from "../../contracts/CranklessStorageOrderBook.sol";
import {MintableERC20} from "../lib/MintableERC20.sol";
import {Router} from "../../contracts/Router.sol";
import {MarginAccount} from "../../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";


contract BenchMarkTest is Test {

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
    uint256 SEED = 2;
    uint96 sellSizeEth;
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
        sellSizeEth = 4*10**18;


    }

    function genAddress() internal returns (address) {
        uint256 _seed = SEED;
        uint256 privateKeyGen = uint256(keccak256(abi.encodePacked(bytes32(_seed))));
        address derived = vm.addr(privateKeyGen);
        ++SEED;
        return derived;
    }

    function _addCustomBuyOrder(address _user, uint24 _price, uint96 _size) internal {       
        vm.startPrank(_user);
        orderBook.addBuyOrder(_price, _size);
        vm.stopPrank();
    }

    function _addCustomSellOrder(address _user, uint24 _price, uint96 _size) internal {
        vm.startPrank(_user);
        orderBook.addSellOrder(_price, _size);
        vm.stopPrank();
    }

    function testBenchMarkBuySingleNewPrice() public {
        address _user = genAddress();
        uint24 _price = 3600;
        uint96 _size = 10;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        usdc.mint(_user, _consumableFunds);
        vm.startPrank(_user);
        usdc.approve(address(marginAccount), _consumableFunds);
        marginAccount.deposit(_user, address(usdc), _consumableFunds);
        orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        vm.stopPrank();
    }

    function testBenchMarkBuyAndMatchMultipleOrders() public {
        address _user = genAddress();
        uint24 _price = 3600;
        uint96 _size = 10;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        usdc.mint(_user, _consumableFunds);
        uint ethDecimals = eth.decimals();
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
        assert(usdc.balanceOf(_user) ==0);
        orderBook.addBuyOrder(_price*PRICE_PRECISION, _size*SIZE_PRECISION);
        vm.stopPrank();
        assert(usdc.balanceOf(_user)==0);
    }

    function testBenchMarkBuyAndMatchMultipleOrdersMultiplePrice() public {
        address _user = genAddress();
        uint24 _price = 3600;
        uint96 _size = 10;
        uint256 _consumableFunds = (uint256(_price) * uint256(_size) * 10**usdc.decimals());
        usdc.mint(_user, _consumableFunds);
        uint ethDecimals = eth.decimals();
        uint24 price_DEVIATION = _price/(10**2);
        for(uint24 i=0; i<3; i++) {
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
        uint256 expectedBalance = _consumableFunds - (4*uint256((_price-price_DEVIATION))*10**18 + 4*uint256((3600- 2*price_DEVIATION))*10**18 + (2*(3600)*10**18));
        assert(marginAccount.getBalance(_user, address(usdc))==expectedBalance);
    }
}