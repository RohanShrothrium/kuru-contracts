// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestMarketBuy is Script {
    function run() external {
        // Get private key and derive address
        address user = vm.rememberKey(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        console.log("User address:", user);

        // Get addresses from environment
        address orderBookAddr = vm.envAddress("ORDERBOOK_ADDRESS");
        // address quoteTokenAddr = 0xC7143d5bA86553C06f5730c8dC9f8187a621A8D4;
        uint32 quoteSize = 10; // Size in quote precision
        OrderBook orderBook = OrderBook(orderBookAddr);

        // Get market params including quote token address
        (
            uint32 pricePrecision,
            ,
            address baseAsset,
            uint256 baseAssetDecimals,
            address quoteAsset,
            uint256 quoteAssetDecimals,
            ,
            ,
            ,
            ,
        ) = orderBook.getMarketParams();

        IERC20 quoteToken = IERC20(quoteAsset);

        // Approve quote tokens to OrderBook
        vm.startBroadcast(user);

        // Get quote token decimals and convert size
        uint256 quoteAmount = (uint256(quoteSize) * 10 ** quoteAssetDecimals) / pricePrecision;
        quoteToken.approve(address(orderBook), quoteAmount);

        // Execute market buy
        orderBook.placeAndExecuteMarketBuy(
            quoteSize, // Quote size in price precision
            0, // Min amount out (no slippage protection for test)
            false, // Not using margin
            false // Not fill-or-kill
        );

        vm.stopBroadcast();

        console.log("Market buy executed successfully");
    }
}
