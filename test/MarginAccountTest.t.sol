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
    uint96 constant PRICE_PRECISION = 10 ** 2;

    OrderBook eth_usdc;
    OrderBook mon_usdc;
    Router router;
    MintableERC20 eth;
    MintableERC20 usdc;
    MintableERC20 mon;
    MarginAccount marginAccount;

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

        marginAccount = new MarginAccount(address(this));

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
        mon.mint(user3, initMon);
    }

    function testRevertUnauthorizedVerifyMarket() public {
        vm.startPrank(address(12345));
        vm.expectRevert("MarginAccount: Only router can update markets");
        marginAccount.updateMarkets(address(80085));
        vm.stopPrank();
    }

    function testDepositAndWithdraw() public {
        vm.startPrank(user1);
        eth.approve(address(marginAccount), initEth);
        marginAccount.deposit(user1, address(eth), initEth);
        assert(marginAccount.getBalance(user1, address(eth)) == initEth);
        marginAccount.withdraw(initEth, address(eth));
        assert(eth.balanceOf(user1) == initEth);
        vm.stopPrank();
    }

    function testNativeDepositWithdraw() public {
        address _native = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        address _userAddress = address(123);
        vm.deal(_userAddress, 100 ether);
        vm.startPrank(_userAddress);
        marginAccount.deposit{value: 1 ether}(_userAddress, _native, 1 ether);
        assert(marginAccount.getBalance(_userAddress, _native) == 1 ether);
        assert(_userAddress.balance == 99 ether);
        marginAccount.withdraw(1 ether, _native);
        assert(_userAddress.balance == 100 ether);
        vm.stopPrank();
    }


    function _createOrderbook(MintableERC20 _baseAsset, MintableERC20 _quoteAsset, uint96 _sizePrecision, uint24 _pricePrecision) internal returns (OrderBook) {
        uint96 _tickSize = _pricePrecision / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 15;
        uint256 _takerFeeBps = 0;
        OrderBook.OrderBookType _type;
        address proxy = router.deployProxy(
            _type,
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
}
