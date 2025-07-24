//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IKuruRouter} from "../interfaces/IKuruRouter.sol";
import {IKuruOrderBook} from "../interfaces/IKuruOrderBook.sol";
import {IReadERC20} from "../interfaces/IReadERC20.sol";
import {IMarginAccount} from "../interfaces/IMarginAccount.sol";
import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pool.sol";
import {IUniswapV2Factory} from "../interfaces/IUniswapV2Factory.sol";
import {IUniswapV3Factory} from "../interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";

/// @title A periphery contract for Kuru
contract KuruUtils {
    enum MarketType {
        KURU,
        UNISWAP_V2,
        UNISWAP_V3
    }

    struct TokenInfo {
        string name;
        string symbol;
        uint256 balance;
        uint8 decimals;
        uint256 totalSupply;
    }

    struct MarketInfo {
        address baseAssetAddress;
        address quoteAssetAddress;
        address factoryAddress;
        uint256 fee;
    }

    function calculatePriceOverRoute(
        address[] memory route,
        bool[] memory isBuy
    ) external view returns (uint256) {
        uint256 price = 10 ** 18;
        for (uint256 i = 0; i < route.length; i++) {
            if (isBuy[i]) {
                (, uint256 _bestAsk) = IOrderBook(route[i]).bestBidAsk();
                price = (price * _bestAsk) / 10 ** 18;
            } else {
                (uint256 _bestBid, ) = IOrderBook(route[i]).bestBidAsk();
                price = (price * 10 ** 18) / _bestBid;
            }
        }
        return price;
    }

    function getMarginBalances(
        address marginAccountAddress,
        address[] calldata users,
        address[] calldata tokens
    ) public view returns (uint256[] memory) {
        IMarginAccount marginAccount = IMarginAccount(marginAccountAddress);
        uint256[] memory balances = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            balances[i] = marginAccount.getBalance(users[i], tokens[i]);
        }
        return balances;
    }

    function getTokensInfo(
        address[] memory tokens,
        address holder
    ) public view returns (TokenInfo[] memory) {
        TokenInfo[] memory info = new TokenInfo[](tokens.length);

        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] == address(0)) {
                info[i] = TokenInfo("Monad", "MON", 0, 18, 0);
                continue;
            }
            IReadERC20 token = IReadERC20(tokens[i]);

            // Default empty values
            string memory name = "";
            string memory symbol = "";
            uint256 balance;
            uint8 decimals;
            uint256 totalSupply;

            // Try to get name
            try token.name() returns (string memory _name) {
                name = _name;
            } catch {}

            // Try to get symbol
            try token.symbol() returns (string memory _symbol) {
                symbol = _symbol;
            } catch {}

            // Try to get balance
            try token.balanceOf(holder) returns (uint256 _balance) {
                balance = _balance;
            } catch {}

            // Try to get decimals
            try token.decimals() returns (uint8 _decimals) {
                decimals = _decimals;
            } catch {}

            // Try to get total supply
            try token.totalSupply() returns (uint256 _totalSupply) {
                totalSupply = _totalSupply;
            } catch {}

            info[i] = TokenInfo(name, symbol, balance, decimals, totalSupply);
        }

        return info;
    }

    function getMarketInfo(
        address market,
        MarketType marketType
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        if (marketType == MarketType.KURU) {
            return getKuruMarketDetailsAndValidateRouter(market);
        } else if (marketType == MarketType.UNISWAP_V2) {
            return getUniswapV2PoolDetailsAndValidateFactory(market);
        } else if (marketType == MarketType.UNISWAP_V3) {
            return getUniswapV3PoolDetailsAndValidateFactory(market);
        }
        revert("Invalid market type");
    }
    function getKuruMarketDetailsAndValidateRouter(
        address market
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        IOrderBook orderBook = IOrderBook(market);
        (, , address baseAsset, , address quoteAsset, , , , , uint256 takerFeeBps, ) = orderBook.getMarketParams();
        address router = IKuruOrderBook(market).owner();
        address[] memory tokens = new address[](2);
        tokens[0] = baseAsset;
        tokens[1] = quoteAsset;
        TokenInfo[] memory info = getTokensInfo(tokens, market);
        // TODO: check if factory is valid
        MarketInfo memory marketInfo = MarketInfo(baseAsset, quoteAsset, router, takerFeeBps);
        return (info, marketInfo, verifyKuruMarket(market, router));
    }

    function getUniswapV2PoolDetailsAndValidateFactory(
        address pool
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        IUniswapV2Pair pair = IUniswapV2Pair(pool);
        address token0 = pair.token0();
        address token1 = pair.token1();
        address factory = pair.factory();
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        TokenInfo[] memory info = getTokensInfo(tokens, pool);
        MarketInfo memory marketInfo = MarketInfo(token0, token1, factory, 30);
        return (info, marketInfo, verifyUniswapV2Pair(factory, token0, token1, pool));
    }

    function getUniswapV3PoolDetailsAndValidateFactory(
        address pool
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        IUniswapV3Pool pair = IUniswapV3Pool(pool);
        address token0 = pair.token0();
        address token1 = pair.token1();
        address factory = pair.factory();
        uint24 fee = pair.fee();
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        TokenInfo[] memory info = getTokensInfo(tokens, pool);
        MarketInfo memory marketInfo = MarketInfo(token0, token1, factory, fee);
        return (info, marketInfo, verifyUniswapV3Pool(factory, token0, token1, fee, pool));
    }

    // ===== UTILITY FUNCTIONS =====
    function verifyKuruMarket(address market, address router) public view returns (bool) {
        IKuruRouter.MarketParams memory marketParams = IKuruRouter(router).verifiedMarket(market);
        return marketParams.pricePrecision != 0;
    }

    function verifyUniswapV2Pair(address factory, address tokenA, address tokenB, address claimedPair) public view returns (bool) {
        return IUniswapV2Factory(factory).getPair(tokenA, tokenB) == claimedPair;
    }

    function verifyUniswapV3Pool(address factory, address tokenA, address tokenB, uint24 fee, address claimedPool) public view returns (bool) {
        return IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee) == claimedPool;
    }

}
