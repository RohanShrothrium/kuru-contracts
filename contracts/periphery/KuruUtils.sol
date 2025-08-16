//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMarginAccount} from "../interfaces/IMarginAccount.sol";

/// @title A periphery contract for Kuru
contract KuruUtils {
    struct TokenInfo {
        string name;
        string symbol;
        uint256 balance;
        uint8 decimals;
        uint256 totalSupply;
    }

    function calculatePriceOverRoute(address[] memory route, bool[] memory isBuy) external view returns (uint256) {
        uint256 price = 10 ** 18;
        for (uint256 i = 0; i < route.length; i++) {
            if (isBuy[i]) {
                (, uint256 _bestAsk) = IOrderBook(route[i]).bestBidAsk();
                price = (price * _bestAsk) / 10 ** 18;
            } else {
                (uint256 _bestBid,) = IOrderBook(route[i]).bestBidAsk();
                price = (price * 10 ** 18) / _bestBid;
            }
        }
        return price;
    }

    function getMarginBalances(address marginAccountAddress, address[] calldata users, address[] calldata tokens)
        public
        view
        returns (uint256[] memory)
    {
        IMarginAccount marginAccount = IMarginAccount(marginAccountAddress);
        uint256[] memory balances = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            balances[i] = marginAccount.getBalance(users[i], tokens[i]);
        }
        return balances;
    }

    function getTokensInfo(address[] memory tokens, address holder) public view returns (TokenInfo[] memory) {
        TokenInfo[] memory info = new TokenInfo[](tokens.length);

        for (uint256 i; i < tokens.length; i++) {
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
}
