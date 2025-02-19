//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IReadERC20} from "../interfaces/IReadERC20.sol";

/// @title A periphery contract for Kuru
contract KuruUtils {
    struct TokenInfo {
        string name;
        string symbol;
        uint256 balance;
        uint8 decimals;
    }

    function calculatePriceOverRoute(address[] memory route, bool[] memory isBuy) public view returns (uint256) {
        uint256 price = 10**18;
        for(uint256 i = 0; i < route.length; i++) {
            if(isBuy[i]) {
                (, uint256 _bestAsk) = IOrderBook(route[i]).bestBidAsk();
                price = (price * _bestAsk) / 10**18;
            } else {
                (uint256 _bestBid,) = IOrderBook(route[i]).bestBidAsk();
                price = (price * 10**18) / _bestBid;
            }
        }
        return price;
    }

    function getTokensInfo(address[] memory tokens, address holder) public view returns (TokenInfo[] memory) {
        TokenInfo[] memory info = new TokenInfo[](tokens.length);
        
        for(uint256 i = 0; i < tokens.length; i++) {
            IReadERC20 token = IReadERC20(tokens[i]);
            info[i] = TokenInfo(
                token.name(),
                token.symbol(),
                token.balanceOf(holder),
                token.decimals()
            );
        }
        
        return info;
    }
}
