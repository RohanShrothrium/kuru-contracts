//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FuzzBase} from "./FuzzBase.sol";
import {MintableERC20} from "../lib/MintableERC20.sol";
import {OrderBook} from "../../contracts/OrderBook.sol";
import {KuruAMMVault} from "../../contracts/KuruAMMVault.sol";
import {Router} from "../../contracts/Router.sol";
import {MarginAccount} from "../../contracts/MarginAccount.sol";
import {PropertiesAsserts} from "./PropertiesHelper.sol";
import {TreeMath} from "../../contracts/libraries/TreeMath.sol";

contract Fuzz_OrderBook is FuzzBase, PropertiesAsserts {
    enum Fuzz_Mode {
        POST_ORDER,
        CLEAR_OUT,
        WITHDRAW
    }
    enum Campaign_Mode {
        FIXED_PRICE,
        DIFF_PRICE
    }

    Campaign_Mode CAMPAIGN;
    Fuzz_Mode MODE;

    uint40 orders;
    uint32 MAX_AMOUNT = 16777205;

    bool buyFlag;
    bool sellFlag;

    uint96 _minSize = 10 ** 5;
    uint96 _maxSize = 10 ** 12;

    uint32 presetPrice;
    bool priceSet;
    uint96 SPREAD = 30;
    address trustedForwarder;

    constructor() {
        MintableERC20 tokenA = new MintableERC20("A", "A");
        MintableERC20 tokenB = new MintableERC20("B", "B");
        if (address(tokenA) > address(tokenB)) {
            quote = tokenA;
            base = tokenB;
        } else {
            quote = tokenB;
            base = tokenA;
        }

        uint32 _tickSize = PRICE_PRECISION / 2;

        uint256 _takerFeeBps = 0;
        uint256 _makerFeeBps = 0;
        router = new Router();
        trustedForwarder = address(0x123);
        marginAccount = new MarginAccount();
        marginAccount.initialize(address(this), address(router), address(router), trustedForwarder);
        implementation = new OrderBook();
        KuruAMMVault kuruAmmVaultImplementation = new KuruAMMVault();
        router.initialize(address(this), address(marginAccount), address(implementation), address(kuruAmmVaultImplementation), trustedForwarder);
        OrderBook.OrderBookType _type;
        address proxy = router.deployProxy(
            _type,
            address(base),
            address(quote),
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

    function makerSellOrder(uint32 _price, uint96 _size) internal {
        uint256 _quoteDecimals = quote.decimals();
        address _maker = genAddress();
        uint256 _sizeNeed = _size * 10 ** base.decimals() / SIZE_PRECISION;
        base.mint(_maker, _sizeNeed);
        vm.prank(_maker);
        base.approve(address(marginAccount), _sizeNeed);
        vm.prank(_maker);
        marginAccount.deposit(_maker, address(base), _sizeNeed);
        vm.prank(_maker);
        orderBook.addSellOrder(_price, _size, false);
        vm.prank(_maker);
        makerSellOrders.push(
            ExpectedAmounts(
                _maker, uint256(_size) * uint256(_price) * 10 ** _quoteDecimals / (SIZE_PRECISION * PRICE_PRECISION)
            )
        );
        orders = orders + 1;
    }

    function makerBuyOrder(uint32 _price, uint96 _size) internal {
        uint256 _quoteDecimals = quote.decimals();
        uint256 _baseDecimals = base.decimals();
        address _maker = genAddress();
        uint256 _quoteForEachOrder = _price * _size * 10 ** _quoteDecimals;
        quote.mint(_maker, _quoteForEachOrder);
        vm.prank(_maker);
        quote.approve(address(marginAccount), _quoteForEachOrder);
        vm.prank(_maker);
        marginAccount.deposit(_maker, address(quote), _quoteForEachOrder);
        vm.prank(_maker);
        orderBook.addBuyOrder(_price, _size, false);
        makerBuyOrders.push(ExpectedAmounts(_maker, _size * 10 ** _baseDecimals / SIZE_PRECISION));
        orders = orders + 1;
    }

    function fuzzHandler(uint32 _price, uint96 _size, uint32 _quoteAmount, bool isBuy) public {
        _size = uint96(clampBetween(_size, SIZE_PRECISION, _maxSize));
        _price = uint32(clampBetween(_price, PRICE_PRECISION, type(uint32).max / 100));
        _price = _price - _price % 50;
        _quoteAmount = uint32(clampBetween(_quoteAmount, MAX_AMOUNT / 1000, MAX_AMOUNT));
        if (orders < 50) {
            if (isBuy) {
                makerBuyOrder(_price, _size);
            } else {
                makerSellOrder(_price, _size);
            }
            if (orders == 50) {
                MODE = Fuzz_Mode.CLEAR_OUT;
            }
        } else if (MODE == Fuzz_Mode.CLEAR_OUT) {
            (uint256 _bastBid, uint256 _bastAsk) = orderBook.bestBidAsk();
            if (_bastBid == type(uint256).max && _bastAsk == 0) {
                MODE = Fuzz_Mode.WITHDRAW;
            } else {
                if (isBuy) {
                    clearOutSellOrders(_quoteAmount);
                } else {
                    clearOutBuyOrders(_size);
                }
            }
        } else if (MODE == Fuzz_Mode.WITHDRAW) {
            withdrawTen(isBuy);
        }
    }

    function withdrawTen(bool isBuy) internal {
        if (isBuy) {
            uint256 clear = 10;
            if (makerBuyOrders.length < 10) {
                clear = makerBuyOrders.length;
            }
            address _baseToken = address(base);
            for (uint256 i; i < clear; i++) {
                ExpectedAmounts memory _detail = makerBuyOrders[makerBuyOrders.length - 1];
                address _owner = _detail.owner;
                makerBuyOrders.pop();
                uint256 _balance = marginAccount.getBalance(_detail.owner, _baseToken);
                vm.prank(_owner);
                marginAccount.withdraw(_balance, _baseToken);
                if (base.balanceOf(_detail.owner) < _detail.amount) {
                    buyFlag = true;
                }
            }
        } else {
            uint256 clear = 10;
            if (makerSellOrders.length < 10) {
                clear = makerSellOrders.length;
            }
            address _quoteToken = address(quote);
            for (uint256 i; i < clear; i++) {
                ExpectedAmounts memory _detail = makerSellOrders[makerSellOrders.length - 1];
                address _owner = _detail.owner;
                makerSellOrders.pop();
                uint256 _balance = marginAccount.getBalance(_detail.owner, _quoteToken);
                vm.prank(_owner);
                marginAccount.withdraw(_balance, _quoteToken);
                if (quote.balanceOf(_detail.owner) < _detail.amount) {
                    sellFlag = true;
                }
            }
        }
    }

    function clearOutSellOrders(uint32 _quoteAmount) internal returns (bool) {
        uint256 tokensNeed = uint256(_quoteAmount) * 10 ** quote.decimals() / PRICE_PRECISION;
        clearOut = genAddress();
        quote.mint(clearOut, tokensNeed);
        vm.prank(clearOut);
        quote.approve(address(orderBook), tokensNeed);
        vm.prank(clearOut);
        orderBook.placeAndExecuteMarketBuy(_quoteAmount, 0, false, false);
        return true;
    }

    function clearOutBuyOrders(uint96 _size) internal {
        uint256 baseNeed = uint256(_size) * 10 ** base.decimals() / SIZE_PRECISION;
        clearOut = genAddress();
        base.mint(clearOut, baseNeed);
        vm.prank(clearOut);
        base.approve(address(orderBook), baseNeed);
        vm.prank(clearOut);
        orderBook.placeAndExecuteMarketSell(_size, 0, false, false);
    }

    function echidna_testBaseBalance() public view returns (bool) {
        if (buyFlag || sellFlag) {
            return false;
        }
        return true;
    }
}
