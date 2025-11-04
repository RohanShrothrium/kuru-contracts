//SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.20;
import {OrderBook} from "../../contracts/OrderBook.sol";
import {MarginAccount} from "../../contracts/MarginAccount.sol";

contract Config {

    string rpcUrl = "https://rpc.fullnode.kuru.io";

    function getKuruForwarderAllowedInterfaces() public returns (bytes4[] memory) {
        bytes4[] memory allowedInterfaces = new bytes4[](7);
        allowedInterfaces[0] = OrderBook.addBuyOrder.selector;
        allowedInterfaces[1] = OrderBook.addSellOrder.selector;
        allowedInterfaces[2] = OrderBook.placeAndExecuteMarketBuy.selector;
        allowedInterfaces[3] = OrderBook.placeAndExecuteMarketSell.selector;
        allowedInterfaces[4] = MarginAccount.deposit.selector;
        allowedInterfaces[5] = MarginAccount.withdraw.selector;
        allowedInterfaces[6] = OrderBook.batchUpdate.selector;
        return allowedInterfaces;
    }

    function getProtocolMultiSig() public returns (address) {
        return 0x31f4797779C4dAEF2eF136983746a3d6FE171a5D;
    }

    function getDeployer() public returns (address) {
        return address(0x04c9495D7fCb42557348Cd061590d99D8B8Ce04A);
    }

    function getProtocolFeeCollector() public returns (address) {
        return 0xa2374adE88cba41B830d21492F7E198AC967Ae4d;
    }

    function getRpcUrl() internal returns (string memory) {
        return rpcUrl;
    }

}