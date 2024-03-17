// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CranklessOrderBook} from "../contracts/CranklessOrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";

contract OrderBookTest is Test {
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint96 constant PRICE_PRECISION = 10 ** 2;

    CranklessOrderBook eth_usdc;
    CranklessOrderBook mon_usdc;
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

    function setUp() public {
        mon = new MintableERC20("MON", "MON");
        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USD", "USDC");

        router = new Router();

        router.initialize(address(this));

        marginAccount = new MarginAccount(address(router));

        router.setMarginAccount(address(marginAccount));

        eth_usdc = _createOrderbook(eth, usdc, marginAccount);
        mon_usdc = _createOrderbook(mon, usdc, marginAccount);

        router.registerMarket(address(eth), address(usdc), address(eth_usdc));
        router.registerMarket(address(mon), address(usdc), address(mon_usdc));

        assertEq(router.marketAddress(address(eth), address(usdc)), address(eth_usdc));
        assertEq(router.marketAddress(address(mon), address(usdc)), address(mon_usdc));

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
        mon.mint(user3, initMon);
    }

    // function testAnyToAnySwap() public {
    //     uint96 price = 1800;
    //     uint96 size = 10;

    //     vm.startPrank(user2);
    //     usdc.approve(address(eth_usdc), initUsdc);
    //     eth_usdc.addBuyOrder(price*PRICE_PRECISION, size*SIZE_PRECISION, false);
    //     vm.stopPrank();

    //     vm.startPrank(user3);
    //     mon.approve(address(mon_usdc), initMon);
    //     mon_usdc.addSellOrder(1*PRICE_PRECISION, 1800*SIZE_PRECISION, false);
    //     vm.stopPrank();

    //     address[] memory _route = new address[](3);
    //     _route[0] = address(eth);
    //     _route[1] = address(usdc);
    //     _route[2] = address(mon);

    //     bool[] memory _isBuy = new bool[](2);
    //     _isBuy[0] = false;
    //     _isBuy[1] = true;

    //     uint256[][] memory _orderIds = new uint256[][](2);
    //     _orderIds[0] = new uint256[](1);
    //     _orderIds[1] = new uint256[](1);

    //     _orderIds[0][0] = 1;
    //     _orderIds[1][0] = 1;

    //     vm.startPrank(user1);
    //     eth.approve(address(router), initEth);
    //     router.anyToAnySwap(_route, _isBuy, 10**18, _orderIds);
    //     vm.stopPrank();

    //     assertEq(mon.balanceOf(user1), 1800*10**18);
    // }

    function testRegisterMarketOwnerError() public {
        vm.startPrank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        router.registerMarket(address(eth), address(usdc), address(eth_usdc));
        vm.stopPrank();
    }

    function testUpdateMarket() public {
        router.updateMarket(address(eth), address(usdc), address(99));

        assertEq(router.marketAddress(address(eth), address(usdc)), address(99));
    }

    function testUpdateMarketOwnerError() public {
        vm.startPrank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        router.updateMarket(address(eth), address(usdc), address(eth_usdc));
        vm.stopPrank();
    }

    function _createOrderbook(MintableERC20 _baseAsset, MintableERC20 _quoteAsset, MarginAccount _marginAccount) internal returns (CranklessOrderBook) {
        uint96 _sizePrecision = 10 ** 10;
        uint96 _pricePrecision = 10 ** 2;
        uint96 _tickSize = _pricePrecision / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 15;
        uint256 _takerFeeBps = 0;

        return new CranklessOrderBook(
            address(_baseAsset),
            18,
            address(_quoteAsset),
            18,
            address(_marginAccount),
            _sizePrecision,
            _pricePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps
        );
    }
}
