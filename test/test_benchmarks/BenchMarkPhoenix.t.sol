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
import {Test, console} from "forge-std/Test.sol";

contract BenchMarkTest is Test, Gas {
    OrderBook orderBook;
    MintableERC20 usdc;
    MintableERC20 eth;
    Router router;
    MarginAccount marginAccount;
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint32 constant PRICE_PRECISION = 10 ** 2;
    bool diffPricePoint = false;
    address deployer;
    address u1;
    address u2;
    address u3;
    uint256 initEth = 1000 * 10 ** 18;
    uint256 initUsdc = 1000000 * 10 ** 18;
    address lastGenAddress;
    uint256 SEED = 2;
    uint32 _initPrice = 1800;
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
        u1 = genAddress();
        u2 = genAddress();
        u3 = genAddress();
        trustedForwarder = address(0x123);
        marginAccount = new MarginAccount();
        marginAccount = MarginAccount(payable(address(new ERC1967Proxy(address(marginAccount), ""))));
        marginAccount.initialize(address(this), address(router), address(router), trustedForwarder);
        uint96 SPREAD = 30;
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

    function _addCustomBuyOrder(address _user, uint32 _price, uint96 _size) internal {
        vm.startPrank(_user);
        orderBook.addBuyOrder(_price, _size, false);
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

    /* Testing for :
     *1 Fill events: 573 transactions
     *2 Fill events: 265 transactions
     *3 Fill events: 89 transactions
     *4 Fill events: 32 transactions
     *5 Fill events: 18 transactions
     *6 Fill events: 10 transactions
     *7 Fill events: 2 transactions
     *8 Fill events: 4 transactions
     *9 Fill events: 1 transactions
     *12 Fill events: 3 transactions
     */

    function fillXforNtimes(uint256 _fills, uint256 _num, string memory _label) internal returns (uint256) {
        uint32 _step = PRICE_PRECISION / 2;
        uint96 _size = 5;
        uint32 _curPrice = _initPrice;
        uint256 _gasUse;
        for (uint256 i; i < _num; i++) {
            uint256 _usdcNeeded;
            for (uint256 j; j < _fills; j++) {
                _addCustomSellOrderOnlyPriceSize(_curPrice, _size);
                _usdcNeeded += (_curPrice) * _size * 10 ** usdc.decimals();
                if (diffPricePoint) {
                    _curPrice += _step;
                }
            }
            address _user = genAddress();
            usdc.mint(_user, _usdcNeeded);
            uint96 _input = uint96(_usdcNeeded * PRICE_PRECISION / (10 ** usdc.decimals()));
            vm.startPrank(_user);
            usdc.approve(address(orderBook), _usdcNeeded);
            startMeasuringGas(_label);
            orderBook.placeAndExecuteMarketBuy(_input, 0, false, true);
            uint256 _gas1 = stopMeasuringGas();
            vm.stopPrank();
            _gasUse += _gas1;
        }
        return _gasUse;
    }

    function testSpec() internal {
        uint256 fill_1 = 1;
        uint256 fill_2 = 1;
        uint256 fill_3 = 1;
        uint256 fill_4 = 1;
        uint256 fill_5 = 1;
        uint256 fill_6 = 1;
        uint256 fill_7 = 1;
        uint256 fill_8 = 1;
        uint256 fill_9 = 1;
        uint256 fill_12 = 1;
        uint256 _gasUsed;
        _gasUsed = fillXforNtimes(1, fill_1, string("1 FILLS"));
        console.log("1 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_1;
        console.log("Average 1 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(2, fill_2, string("2 FILLS"));
        console.log("2 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_2;
        console.log("Average 2 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(3, fill_3, string("3 FILLS"));
        console.log("3 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_3;
        console.log("Average 3 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(4, fill_4, string("4 FILLS"));
        console.log("4 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_4;
        console.log("Average 4 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(5, fill_5, string("5 FILLS"));
        console.log("5 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_5;
        console.log("Average 5 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(6, fill_6, string("6 FILLS"));
        console.log("6 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_6;
        console.log("Average 6 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(7, fill_7, string("7 FILLS"));
        console.log("7 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_7;
        console.log("Average 7 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(8, fill_8, string("8 FILLS"));
        console.log("8 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_8;
        console.log("Average 8 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(9, fill_9, string("9 FILLS"));
        console.log("9 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_9;
        console.log("Average 9 FILLS Gas = ", _gasUsed);

        _gasUsed = fillXforNtimes(12, fill_12, string("12 FILLS"));
        console.log("12 FILLS TOTAL = ", _gasUsed);
        _gasUsed /= fill_12;
        console.log("Average 12 FILLS Gas = ", _gasUsed);
    }

    function testSpecHandler() public {
        console.log("************* NO PRICE POINT CHANGE ****************");
        testSpec();
        console.log("************* PRICE POINT CHANGE *******************");
        diffPricePoint = true;
        testSpec();
    }
}
