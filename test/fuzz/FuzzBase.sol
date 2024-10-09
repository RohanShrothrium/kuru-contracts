// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OrderBook} from "../../contracts/OrderBook.sol";
import {Router} from "../../contracts/Router.sol";
import {MarginAccount} from "../../contracts/MarginAccount.sol";
import {ERC20} from "node_modules/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MintableERC20} from "../lib/MintableERC20.sol";
import {IHevm} from "./IHevm.sol";

abstract contract FuzzBase {
    struct ExpectedAmounts {
        address owner;
        uint256 amount;
    }

    address clearOut;
    ExpectedAmounts[] makerBuyOrders;
    ExpectedAmounts[] makerSellOrders;
    uint256 sizeToSellCurrent;
    IHevm vm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint256 SEED = 2;
    address lastGenAddress;
    OrderBook implementation;
    Router router;
    MarginAccount marginAccount;
    OrderBook orderBook;
    MintableERC20 base;
    MintableERC20 quote;
    uint96 constant SIZE_PRECISION = 10 ** 10;
    uint32 constant PRICE_PRECISION = 10 ** 2;

    function genAddress() internal returns (address) {
        uint256 _seed = SEED;
        uint256 privateKeyGen = uint256(keccak256(abi.encodePacked(bytes32(_seed))));
        address derived = vm.addr(privateKeyGen);
        ++SEED;
        lastGenAddress = derived;
        return derived;
    }
}
