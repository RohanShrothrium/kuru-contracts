//SPDX-License-Identifier: BUSL-1.1

//   ░█████░     ░█████▓    ███                                                       
//   ███████    ▓███████▒   ███▒                                                      
//   ███████   █████████▒   ███▒                                                      
//   ███████  ██████████░   ███▒    ████  ████     ████  ▓████████ ░███░    ░███▓     
//     ░████▒██████▒░       ███▒   ████   ████     ████  ▓████████ ▒███▒    ░███▓     
//                          ███▒ ▒████    ████     ████  ▓████     ▒███░    ░███▓     
//     ▓████▒███████▓       █████████     ████     ████  ▓███░     ▒███░    ░███▓     
//   ███████  ██████████▒   █████████▒    ████     ████  ▓███      ░███▒    ░███▒     
//   ███████   █████████▒   ███▒  ████▓   ▓███▒   ░████  ▓███       ████    ████░     
//   ███████    ▓███████▒   ███▒   ▒████   ███████████   ▓███       ░██████████▒      
//    ▒▓▓▓▓       ▒▓▓▓▓▒    ▓██      ███▒    ░█████░      ██▓          ▒████▒           
                                                                                       
pragma solidity ^0.8.20;

import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IKuruRouter} from "../interfaces/supplemental/IKuruRouter.sol";
import {IKuruOrderBook} from "../interfaces/supplemental/IKuruOrderBook.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMarginAccount} from "../interfaces/IMarginAccount.sol";
import {IUniswapV2Pair} from "../interfaces/supplemental/IUniswapV2Pool.sol";
import {IUniswapV2Factory} from "../interfaces/supplemental/IUniswapV2Factory.sol";
import {IUniswapV3Factory} from "../interfaces/supplemental/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../interfaces/supplemental/IUniswapV3Pool.sol";
import {ILBPair} from "../interfaces/supplemental/ILBPair.sol";
import {ILBFactory} from "../interfaces/supplemental/ILBFactory.sol";

/// @title A periphery contract for Kuru
contract KuruUtils {
    enum MarketType {
        KURU,
        UNISWAP_V2,
        UNISWAP_V3,
        TRADERJOE
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
        uint32 pricePrecision;
        uint96 sizePrecision;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 makerFeeBps;
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
            IERC20Metadata token = IERC20Metadata(tokens[i]);

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
        } else if (marketType == MarketType.TRADERJOE) {
            return getTraderJoePoolDetailsAndValidateFactory(market);
        }
        revert("Invalid market type");
    }
    function getKuruMarketDetailsAndValidateRouter(
        address market
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        IOrderBook orderBook = IOrderBook(market);
        address router;
        uint32 pricePrecision;
        uint96 sizePrecision;
        address baseAsset;
        address quoteAsset;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
        
        try IKuruOrderBook(market).owner() returns (address _router) {
            router = _router;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try orderBook.getMarketParams() returns (
            uint32 _pricePrecision,
            uint96 _sizePrecision,
            address _baseAsset,
            uint256,  // baseAssetDecimals
            address _quoteAsset,
            uint256,  // quoteAssetDecimals
            uint32 _tickSize,
            uint96 _minSize,
            uint96 _maxSize,
            uint256 _takerFeeBps,
            uint256 _makerFeeBps
        ) {
            pricePrecision = _pricePrecision;
            sizePrecision = _sizePrecision;
            baseAsset = _baseAsset;
            quoteAsset = _quoteAsset;
            tickSize = _tickSize;
            minSize = _minSize;
            maxSize = _maxSize;
            takerFeeBps = _takerFeeBps;
            makerFeeBps = _makerFeeBps;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        address[] memory tokens = new address[](2);
        tokens[0] = baseAsset;
        tokens[1] = quoteAsset;
        TokenInfo[] memory info = getTokensInfo(tokens, market);
        MarketInfo memory marketInfo = MarketInfo(baseAsset, quoteAsset, router, takerFeeBps, pricePrecision, sizePrecision, tickSize, minSize, maxSize, makerFeeBps);
        
        bool isValid;
        try IKuruRouter(router).verifiedMarket(market) returns (IKuruRouter.MarketParams memory marketParams) {
            isValid = marketParams.pricePrecision != 0;
        } catch {
            isValid = false;
        }
        
        return (info, marketInfo, isValid);
    }

    function getUniswapV2PoolDetailsAndValidateFactory(
        address pool
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        IUniswapV2Pair pair = IUniswapV2Pair(pool);
        address token0;
        address token1;
        address factory;

        try pair.token0() returns (address _token0) {
            token0 = _token0;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.token1() returns (address _token1) {
            token1 = _token1;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.factory() returns (address _factory) {
            factory = _factory;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        TokenInfo[] memory info = getTokensInfo(tokens, pool);
        MarketInfo memory marketInfo = MarketInfo(token0, token1, factory, 30, 0, 0, 0, 0, 0, 0);

        bool isValid;
        try IUniswapV2Factory(factory).getPair(token0, token1) returns (address actualPair) {
            isValid = actualPair == pool;
        } catch {
            isValid = false;
        }
        
        return (info, marketInfo, isValid);
    }

    function getUniswapV3PoolDetailsAndValidateFactory(
        address pool
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        IUniswapV3Pool pair = IUniswapV3Pool(pool);
        address token0;
        address token1;
        address factory;
        uint24 fee;

        try pair.token0() returns (address _token0) {
            token0 = _token0;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.token1() returns (address _token1) {
            token1 = _token1;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.factory() returns (address _factory) {
            factory = _factory;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.fee() returns (uint24 _fee) {
            fee = _fee;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        TokenInfo[] memory info = getTokensInfo(tokens, pool);
        MarketInfo memory marketInfo = MarketInfo(token0, token1, factory, fee, 0, 0, 0, 0, 0, 0);

        bool isValid;
        try IUniswapV3Factory(factory).getPool(token0, token1, fee) returns (address actualPool) {
            isValid = actualPool == pool;
        } catch {
            isValid = false;
        }
        
        return (info, marketInfo, isValid);
    }

    function getTraderJoePoolDetailsAndValidateFactory(
        address pool
    ) public view returns (TokenInfo[] memory, MarketInfo memory, bool) {
        ILBPair pair = ILBPair(pool);
        address token0;
        address token1;
        uint16 binStep;
        address factory;

        try pair.getTokenX() returns (address _token0) {
            token0 = _token0;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.getTokenY() returns (address _token1) {
            token1 = _token1;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.getBinStep() returns (uint16 _binStep) {
            binStep = _binStep;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        try pair.getFactory() returns (address _factory) {
            factory = _factory;
        } catch {
            return (new TokenInfo[](0), MarketInfo(address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0), false);
        }

        bool isValid;
        try ILBFactory(factory).getLBPairInformation(token0, token1, binStep) returns (ILBFactory.LBPairInformation memory actualPool) {
            isValid = actualPool.LBPair == pool;
        } catch {
            isValid = false;
        }

        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        TokenInfo[] memory info = getTokensInfo(tokens, pool);
        MarketInfo memory marketInfo = MarketInfo(token0, token1, factory, 0, 0, 0, 0, 0, 0, 0);

        return (info, marketInfo, isValid);
    }

    // ===== UTILITY FUNCTIONS =====
    function verifyKuruMarket(address market, address router) public view returns (bool) {
        try IKuruRouter(router).verifiedMarket(market) returns (IKuruRouter.MarketParams memory marketParams) {
            return marketParams.pricePrecision != 0;
        } catch {
            return false;
        }
    }

    function verifyUniswapV2Pair(address factory, address tokenA, address tokenB, address claimedPair) public view returns (bool) {
        try IUniswapV2Factory(factory).getPair(tokenA, tokenB) returns (address actualPair) {
            return actualPair == claimedPair;
        } catch {
            return false;
        }
    }

    function verifyUniswapV3Pool(address factory, address tokenA, address tokenB, uint24 fee, address claimedPool) public view returns (bool) {
        try IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee) returns (address actualPool) {
            return actualPool == claimedPool;
        } catch {
            return false;
        }
    }

}
