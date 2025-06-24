// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MarginAccountErrors} from "../contracts/libraries/Errors.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
    uint96 SPREAD = 30;

    function setUp() public {
        mon = new MintableERC20("MON", "MON");
        eth = new MintableERC20("ETH", "ETH");
        usdc = new MintableERC20("USD", "USDC");

        marginAccount = new MarginAccount();
        marginAccount = MarginAccount(payable(address(new ERC1967Proxy(address(marginAccount), ""))));
        marginAccount.initialize(address(this), address(this), address(0), address(0));

        eth.mint(user1, initEth);
        usdc.mint(user2, initUsdc);
        mon.mint(user3, initMon);
    }

    function testRevertUnauthorizedVerifyMarket() public {
        vm.startPrank(address(12345));
        vm.expectRevert(MarginAccountErrors.OnlyRouterAllowed.selector);
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
        address _native = 0x0000000000000000000000000000000000000000;
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

    function testMaxWithdraw(uint256[] memory _amounts) public {
        vm.assume(_amounts.length > 0 && _amounts.length == 200);
        address[] memory _tokens = new address[](_amounts.length);
        uint256 privateKeyGen = uint256(keccak256(abi.encodePacked(bytes32("key"))));
        address derived = vm.addr(privateKeyGen);
        for (uint256 i = 0; i < _amounts.length; i++) {
            _tokens[i] = address(_createErc20AndMint(derived, _amounts[i]));
            vm.startPrank(derived);
            ERC20(_tokens[i]).approve(address(marginAccount), _amounts[i]);
            marginAccount.deposit(derived, _tokens[i], _amounts[i]);
            vm.stopPrank();
        }
        vm.prank(derived);
        marginAccount.batchWithdrawMaxTokens(_tokens);
        for (uint256 i = 0; i < _amounts.length; i++) {
            assert(ERC20(_tokens[i]).balanceOf(derived) == _amounts[i]);
            assert(marginAccount.getBalance(derived, _tokens[i]) == 0);
        }
    }

    function _createOrderbook(
        MintableERC20 _baseAsset,
        MintableERC20 _quoteAsset,
        uint96 _sizePrecision,
        uint32 _pricePrecision
    ) internal returns (OrderBook) {
        uint32 _tickSize = _pricePrecision / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 15;
        uint256 _takerFeeBps = 0;
        uint256 _makerFeeBps = 0;
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
            _takerFeeBps,
            _makerFeeBps,
            SPREAD
        );

        return OrderBook(proxy);
    }

    function _createErc20AndMint(address _user, uint256 _amount) internal returns (MintableERC20) {
        MintableERC20 _erc20 = new MintableERC20("TEST", "TEST");
        _erc20.mint(_user, _amount);
        return _erc20;
    }
}
