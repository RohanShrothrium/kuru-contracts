// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {CranklessStorageOrderBook} from "../contracts/CranklessStorageOrderBook.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "./lib/MintableERC20.sol";

contract OrderBookTest is Test {
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint96 constant PRICE_PRECISION = 10 ** 2;

    CranklessStorageOrderBook eth_usdc;
    CranklessStorageOrderBook mon_usdc;
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

    function _createOrderbook(MintableERC20 _baseAsset, MintableERC20 _quoteAsset, MarginAccount _marginAccount) internal returns (CranklessStorageOrderBook) {
        uint96 _sizePrecision = 10 ** 10;
        uint24 _pricePrecision = 10 ** 2;
        uint96 _tickSize = _pricePrecision / 2;
        uint96 _minSize = 10 ** 5;
        uint96 _maxSize = 10 ** 15;
        uint256 _takerFeeBps = 0;

        return new CranklessStorageOrderBook(
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
    // TODO: Write tests here lol
}
