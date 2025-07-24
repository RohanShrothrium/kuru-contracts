//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {KuruUtils} from "../../contracts/periphery/KuruUtils.sol";

contract KuruUtilsForkTest is Test {
    KuruUtils public kuruUtils;
    
    // Test addresses with correct checksums
    address constant KURU_MARKET = 0x277bF4a0AAc16f19d7bf592FeFFc8D2d9a890508;
    address constant UNIV2_PAIR = 0xc0ce32EEe0eb8bF24FA2b00923a78abc5002f91e;
    address constant UNIV3_POOL = 0x01F4E5aeAe0Dd95048b526a11eB7e20F68802F2e;

    function setUp() public {
        // Fork from RPC_URL environment variable
        vm.createSelectFork(vm.envString("RPC_URL"));
        
        // Deploy KuruUtils contract
        kuruUtils = new KuruUtils();
    }

    function testGetKuruMarketInfo() public {
        console.log("Testing Kuru market:", KURU_MARKET);
        
        (
            KuruUtils.TokenInfo[] memory tokenInfo,
            KuruUtils.MarketInfo memory marketInfo,
            bool isValid
        ) = kuruUtils.getMarketInfo(
            KURU_MARKET, 
            KuruUtils.MarketType.KURU
        );

        // Assert that market info is populated
        assertTrue(marketInfo.baseAssetAddress != address(0), "Base asset should not be zero address");
        assertTrue(marketInfo.factoryAddress != address(0), "Factory address should not be zero address");
        assertTrue(isValid, "Kuru market should be valid");
        
        // Assert that we get token info for both tokens
        assertEq(tokenInfo.length, 2, "Should return info for 2 tokens");
        
        // Log market details
        console.log("Base Asset:", marketInfo.baseAssetAddress);
        console.log("Quote Asset:", marketInfo.quoteAssetAddress);
        console.log("Router:", marketInfo.factoryAddress);
        console.log("Taker Fee (bps):", marketInfo.fee);
        console.log("Is Valid:", isValid);
        
        // Log token info
        for (uint i = 0; i < tokenInfo.length; i++) {
            console.log("Token", i, "- Name:", tokenInfo[i].name);
            console.log("Token", i, "- Symbol:", tokenInfo[i].symbol);
            console.log("Token", i, "- Decimals:", tokenInfo[i].decimals);
            console.log("Token", i, "- Balance:", tokenInfo[i].balance);
            console.log("Token", i, "- Total Supply:", tokenInfo[i].totalSupply);
        }
    }

    function testGetUniswapV2MarketInfo() public {
        console.log("Testing Uniswap V2 pair:", UNIV2_PAIR);
        
        (
            KuruUtils.TokenInfo[] memory tokenInfo,
            KuruUtils.MarketInfo memory marketInfo,
            bool isValid
        ) = kuruUtils.getMarketInfo(
            UNIV2_PAIR, 
            KuruUtils.MarketType.UNISWAP_V2
        );

        // Assert that market info is populated
        assertTrue(marketInfo.baseAssetAddress != address(0), "Token0 should not be zero address");
        assertTrue(marketInfo.quoteAssetAddress != address(0), "Token1 should not be zero address");
        assertTrue(marketInfo.factoryAddress != address(0), "Factory address should not be zero address");
        assertEq(marketInfo.fee, 30, "UniV2 default fee should be 30 bps");
        assertTrue(isValid, "UniV2 pair should be valid");
        
        // Assert that we get token info for both tokens
        assertEq(tokenInfo.length, 2, "Should return info for 2 tokens");
        
        // Log market details
        console.log("Token0:", marketInfo.baseAssetAddress);
        console.log("Token1:", marketInfo.quoteAssetAddress);
        console.log("Factory:", marketInfo.factoryAddress);
        console.log("Fee (bps):", marketInfo.fee);
        console.log("Is Valid:", isValid);
        
        // Log token info
        for (uint i = 0; i < tokenInfo.length; i++) {
            console.log("Token", i, "- Name:", tokenInfo[i].name);
            console.log("Token", i, "- Symbol:", tokenInfo[i].symbol);
            console.log("Token", i, "- Decimals:", tokenInfo[i].decimals);
            console.log("Token", i, "- Balance:", tokenInfo[i].balance);
            console.log("Token", i, "- Total Supply:", tokenInfo[i].totalSupply);
        }
    }

    function testGetUniswapV3MarketInfo() public {
        console.log("Testing Uniswap V3 pool:", UNIV3_POOL);
        
        (
            KuruUtils.TokenInfo[] memory tokenInfo,
            KuruUtils.MarketInfo memory marketInfo,
            bool isValid
        ) = kuruUtils.getMarketInfo(
            UNIV3_POOL, 
            KuruUtils.MarketType.UNISWAP_V3
        );

        // Assert that market info is populated
        assertTrue(marketInfo.baseAssetAddress != address(0), "Token0 should not be zero address");
        assertTrue(marketInfo.quoteAssetAddress != address(0), "Token1 should not be zero address");
        assertTrue(marketInfo.factoryAddress != address(0), "Factory address should not be zero address");
        assertTrue(marketInfo.fee > 0, "UniV3 fee should be greater than 0");
        assertTrue(isValid, "UniV3 pool should be valid");
        
        // Assert that we get token info for both tokens
        assertEq(tokenInfo.length, 2, "Should return info for 2 tokens");
        
        // Log market details
        console.log("Token0:", marketInfo.baseAssetAddress);
        console.log("Token1:", marketInfo.quoteAssetAddress);
        console.log("Factory:", marketInfo.factoryAddress);
        console.log("Fee:", marketInfo.fee);
        console.log("Is Valid:", isValid);
        
        // Log token info
        for (uint i = 0; i < tokenInfo.length; i++) {
            console.log("Token", i, "- Name:", tokenInfo[i].name);
            console.log("Token", i, "- Symbol:", tokenInfo[i].symbol);
            console.log("Token", i, "- Decimals:", tokenInfo[i].decimals);
            console.log("Token", i, "- Balance:", tokenInfo[i].balance);
            console.log("Token", i, "- Total Supply:", tokenInfo[i].totalSupply);
        }
    }

    function testAllMarketsReturnValidInfo() public {
        console.log("Testing all markets for basic functionality...");
        
        // Test that all markets return data without reverting
        (
            KuruUtils.TokenInfo[] memory kuruTokens,
            KuruUtils.MarketInfo memory kuruInfo,
            bool kuruValid
        ) = kuruUtils.getMarketInfo(
            KURU_MARKET, 
            KuruUtils.MarketType.KURU
        );
        
        (
            KuruUtils.TokenInfo[] memory v2Tokens,
            KuruUtils.MarketInfo memory v2Info,
            bool v2Valid
        ) = kuruUtils.getMarketInfo(
            UNIV2_PAIR, 
            KuruUtils.MarketType.UNISWAP_V2
        );
        
        (
            KuruUtils.TokenInfo[] memory v3Tokens,
            KuruUtils.MarketInfo memory v3Info,
            bool v3Valid
        ) = kuruUtils.getMarketInfo(
            UNIV3_POOL, 
            KuruUtils.MarketType.UNISWAP_V3
        );

        // Assert all have valid addresses and validation status
        assertTrue(kuruInfo.baseAssetAddress != address(0), "Kuru base asset should not be zero");
        assertTrue(kuruInfo.factoryAddress != address(0), "Kuru factory should not be zero");
        assertEq(kuruTokens.length, 2, "Kuru should return 2 tokens");
        assertTrue(kuruValid, "Kuru market should be valid");
        
        assertTrue(v2Info.baseAssetAddress != address(0), "UniV2 token0 should not be zero");
        assertTrue(v2Info.quoteAssetAddress != address(0), "UniV2 token1 should not be zero");
        assertTrue(v2Info.factoryAddress != address(0), "UniV2 factory should not be zero");
        assertEq(v2Tokens.length, 2, "UniV2 should return 2 tokens");
        assertTrue(v2Valid, "UniV2 pair should be valid");
        
        assertTrue(v3Info.baseAssetAddress != address(0), "UniV3 token0 should not be zero");
        assertTrue(v3Info.quoteAssetAddress != address(0), "UniV3 token1 should not be zero");
        assertTrue(v3Info.factoryAddress != address(0), "UniV3 factory should not be zero");
        assertEq(v3Tokens.length, 2, "UniV3 should return 2 tokens");
        assertTrue(v3Valid, "UniV3 pool should be valid");
        
        // Log market types and basic info
        console.log("Kuru Market:");
        console.log("  Base:", kuruInfo.baseAssetAddress);
        console.log("  Quote:", kuruInfo.quoteAssetAddress);
        console.log("  Valid:", kuruValid);

        console.log("UniV2 Pair:");
        console.log("  Token0:", v2Info.baseAssetAddress);
        console.log("  Token1:", v2Info.quoteAssetAddress);
        console.log("  Valid:", v2Valid);

        console.log("UniV3 Pool:");
        console.log("  Token0:", v3Info.baseAssetAddress);
        console.log("  Token1:", v3Info.quoteAssetAddress);
        console.log("  Valid:", v3Valid);
    }

    function testMismatchedMarketTypesFail() public {
        console.log("Testing mismatched market types...");
        
        // Test UniV2 market with Kuru type
        (
            KuruUtils.TokenInfo[] memory tokens1,
            KuruUtils.MarketInfo memory info1,
            bool isValid1
        ) = kuruUtils.getMarketInfo(
            UNIV2_PAIR, 
            KuruUtils.MarketType.KURU
        );
        assertFalse(isValid1, "UniV2 pair should not validate as Kuru market");
        
        // Test Kuru market with UniV3 type
        (
            KuruUtils.TokenInfo[] memory tokens2,
            KuruUtils.MarketInfo memory info2,
            bool isValid2
        ) = kuruUtils.getMarketInfo(
            KURU_MARKET, 
            KuruUtils.MarketType.UNISWAP_V3
        );
        assertFalse(isValid2, "Kuru market should not validate as UniV3 pool");
        
        // Test UniV3 pool with UniV2 type
        (
            KuruUtils.TokenInfo[] memory tokens3,
            KuruUtils.MarketInfo memory info3,
            bool isValid3
        ) = kuruUtils.getMarketInfo(
            UNIV3_POOL, 
            KuruUtils.MarketType.UNISWAP_V2
        );
        assertFalse(isValid3, "UniV3 pool should not validate as UniV2 pair");
        
        // Log results for debugging
        console.log("UniV2 as Kuru valid:", isValid1);
        console.log("Kuru as UniV3 valid:", isValid2);
        console.log("UniV3 as UniV2 valid:", isValid3);
    }
}
