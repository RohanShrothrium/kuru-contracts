// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IOrderBook} from "../contracts/interfaces/IOrderBook.sol";
import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {Router} from "../contracts/Router.sol";

contract PrecisionToken is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract FlipAccountingRegressionTest is Test {
    struct MarketConfig {
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint96 sizePrecision;
        uint32 pricePrecision;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
    }

    struct Market {
        OrderBook orderBook;
        PrecisionToken base;
        PrecisionToken quote;
    }

    Router internal router;
    MarginAccount internal marginAccount;

    function setUp() public {
        address trustedForwarder = address(0x123);
        OrderBook orderBookImplementation = new OrderBook();
        KuruAMMVault vaultImplementation = new KuruAMMVault();
        Router routerImplementation = new Router();

        router = Router(payable(address(new ERC1967Proxy(address(routerImplementation), ""))));
        marginAccount = MarginAccount(payable(address(new ERC1967Proxy(address(new MarginAccount()), ""))));
        marginAccount.initialize(address(this), address(router), address(router), trustedForwarder);
        router.initialize(
            address(this),
            address(marginAccount),
            address(orderBookImplementation),
            address(vaultImplementation),
            trustedForwarder
        );
    }

    function testExploitConfigCannotCreateUnbackedQuote() public {
        MarketConfig memory config = MarketConfig({
            baseDecimals: 0,
            quoteDecimals: 6,
            sizePrecision: 1e9,
            pricePrecision: 1e9,
            tickSize: 1,
            minSize: 1e9,
            maxSize: 1e18
        });
        Market memory market = _deployMarket(config);
        address attacker = makeAddr("attacker");
        uint256 baseAmount = 367;
        uint256 quoteAmount = 367;

        _deposit(market.base, attacker, baseAmount);
        _deposit(market.quote, attacker, quoteAmount);

        // These are the deployed malicious market's exact decimal and precision
        // relationships. Under the vulnerable floor conversion, every 999-unit
        // internal quote debit became zero physical quote.
        assertEq(uint256(999) * 1e6 / 1e9, 0, "old per-fill debit must round to zero");

        vm.startPrank(attacker);
        market.orderBook.addFlipSellOrder(999, 998, uint96(baseAmount * 1e9), true);
        for (uint256 i; i < baseAmount; ++i) {
            market.orderBook.addBuyOrder(999, 1e9, false);
        }

        uint256 quoteReceived = market.orderBook.placeAndExecuteMarketSell(uint96(baseAmount * 1e9), 0, true, true);
        uint40[] memory orderIds = new uint40[](1);
        orderIds[0] = 2;
        market.orderBook.batchCancelFlipOrders(orderIds);
        vm.stopPrank();

        assertEq(quoteReceived, 366, "aggregated reverse fill should produce physical quote");
        assertEq(marginAccount.getBalance(attacker, address(market.base)), baseAmount, "base must be restored");
        assertEq(
            marginAccount.getBalance(attacker, address(market.quote)),
            quoteAmount - 1,
            "round-up debits must make the cycle cost quote rather than create it"
        );
        assertEq(market.quote.balanceOf(address(marginAccount)), quoteAmount, "physical quote backing must remain");
    }

    function testMonUsdcConfigCannotCreateUnbackedQuote() public {
        // Production market 0xCb4659FbE7f7718D4e2Ce9B91bbf0f04dE19249d.
        MarketConfig memory config = MarketConfig({
            baseDecimals: 18,
            quoteDecimals: 6,
            sizePrecision: 1e9,
            pricePrecision: 1e8,
            tickSize: 10,
            minSize: 1e9,
            maxSize: 1e17
        });

        (uint256 finalBase, uint256 finalQuote) = _runTwoFillRoundTrip(config, 90, 80);

        assertEq(finalBase, 2 ether, "MON must be restored");
        assertEq(finalQuote, 1, "the former one-raw-USDC gain must become a one-raw-USDC cost");
    }

    function testCbBTCUsdcConfigCannotIncreaseEitherAsset() public {
        // Production market 0x40c49f171202f91ff5d2fae34c22dd2bfdd22af0.
        MarketConfig memory config = MarketConfig({
            baseDecimals: 8,
            quoteDecimals: 6,
            sizePrecision: 1e8,
            pricePrecision: 1e4,
            tickSize: 100,
            minSize: 12_500,
            maxSize: 1e10
        });

        (uint256 finalBase, uint256 finalQuote) = _runTwoFillRoundTrip(config, 900, 800);

        assertEq(finalBase, 2e8, "cbBTC must be restored");
        assertEq(finalQuote, 180_000, "USDC must not increase");
    }

    function testXAUt0UsdcConfigCannotIncreaseEitherAsset() public {
        // Production market 0x851145eaefdc37956b08da829fa31722199f3f07.
        MarketConfig memory config = MarketConfig({
            baseDecimals: 6,
            quoteDecimals: 6,
            sizePrecision: 1e6,
            pricePrecision: 1e4,
            tickSize: 100,
            minSize: 2_000,
            maxSize: 1e8
        });

        (uint256 finalBase, uint256 finalQuote) = _runTwoFillRoundTrip(config, 900, 800);

        assertEq(finalBase, 2e6, "XAUt0 must be restored");
        assertEq(finalQuote, 180_000, "USDC must not increase");
    }

    function _runTwoFillRoundTrip(MarketConfig memory config, uint32 sellPrice, uint32 flipPrice)
        internal
        returns (uint256 finalBase, uint256 finalQuote)
    {
        Market memory market = _deployMarket(config);
        address trader = makeAddr(string.concat("trader-", vm.toString(config.sizePrecision)));
        uint256 baseAmount = 2 * 10 ** config.baseDecimals;
        uint256 quoteInPricePrecision = _mulDivUp(sellPrice, config.sizePrecision, config.sizePrecision);
        uint256 quotePerFill = _mulDivUp(quoteInPricePrecision, 10 ** config.quoteDecimals, config.pricePrecision);
        uint256 initialQuote = 2 * quotePerFill;

        _deposit(market.base, trader, baseAmount);
        _deposit(market.quote, trader, initialQuote);

        vm.startPrank(trader);
        market.orderBook.addFlipSellOrder(sellPrice, flipPrice, 2 * config.sizePrecision, true);
        market.orderBook.addBuyOrder(sellPrice, config.sizePrecision, false);
        market.orderBook.addBuyOrder(sellPrice, config.sizePrecision, false);
        market.orderBook.placeAndExecuteMarketSell(2 * config.sizePrecision, 0, true, true);

        uint40[] memory orderIds = new uint40[](1);
        orderIds[0] = 2;
        market.orderBook.batchCancelFlipOrders(orderIds);
        vm.stopPrank();

        finalBase = marginAccount.getBalance(trader, address(market.base));
        finalQuote = marginAccount.getBalance(trader, address(market.quote));
        assertLe(finalBase, baseAmount, "round trip created base");
        assertLe(finalQuote, initialQuote, "round trip created quote");
    }

    function _deployMarket(MarketConfig memory config) internal returns (Market memory market) {
        market.base = new PrecisionToken("Base", "BASE", config.baseDecimals);
        market.quote = new PrecisionToken("Quote", "QUOTE", config.quoteDecimals);
        address proxy = router.deployProxy(
            IOrderBook.OrderBookType.NO_NATIVE,
            address(market.base),
            address(market.quote),
            config.sizePrecision,
            config.pricePrecision,
            config.tickSize,
            config.minSize,
            config.maxSize,
            0,
            0,
            100
        );
        market.orderBook = OrderBook(proxy);
    }

    function _deposit(PrecisionToken token, address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(marginAccount), amount);
        marginAccount.deposit(user, address(token), amount);
        vm.stopPrank();
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }
}
