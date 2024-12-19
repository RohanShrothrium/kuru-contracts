// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {KuruForwarder} from "../contracts/KuruForwarder.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MonadDeployer} from "../contracts/periphery/MonadDeployer.sol";
import {IRouter} from "../contracts/interfaces/IRouter.sol";

contract Deployer is Script {
    using stdJson for string;

    error InvalidInitialization();

    struct ChainConfig {
        string name;
        uint256 chainId;
        string rpcUrl;
    }

    struct ChainList {
        ChainConfig[] chains;
    }

    function setUp() public {}

    function run() public {
        address deployerAdmin = vm.rememberKey(vm.envUint(string("DEPLOYER_PRIVATE_KEY")));

        console.log("Deployer address:", deployerAdmin);
        string memory chains = vm.readFile("script/config/chains.json");
        string memory deployChain = vm.envString("DEPLOY_CHAIN");

        bytes memory encodedChain = chains.parseRaw(string(abi.encodePacked(".", deployChain)));
        ChainConfig memory chainConfig = abi.decode(encodedChain, (ChainConfig));
        console.log("Deploying on chain:", chainConfig.name);

        vm.createSelectFork(chainConfig.rpcUrl);
        bytes4[] memory allowedInterfaces = new bytes4[](6);
        allowedInterfaces[0] = OrderBook.addBuyOrder.selector;
        allowedInterfaces[1] = OrderBook.addSellOrder.selector;
        allowedInterfaces[2] = OrderBook.placeAndExecuteMarketBuy.selector;
        allowedInterfaces[3] = OrderBook.placeAndExecuteMarketSell.selector;
        allowedInterfaces[4] = MarginAccount.deposit.selector;
        allowedInterfaces[5] = MarginAccount.withdraw.selector;
        vm.broadcast(deployerAdmin);
        KuruForwarder kuruForwarder = new KuruForwarder(allowedInterfaces);
        console.log("KuruForwarder deployed to:", address(kuruForwarder));
        vm.broadcast(deployerAdmin);
        Router routerImpl = new Router();
        console.log("Router implementation deployed to:", address(routerImpl));
        vm.broadcast(deployerAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(routerImpl), "");
        console.log("Router proxy deployed to:", address(proxy));
        Router router = Router(payable(address(proxy)));

        vm.broadcast(deployerAdmin);
        MarginAccount marginAccount = new MarginAccount(address(router), deployerAdmin, address(kuruForwarder));
        console.log("MarginAccount deployed to:", address(marginAccount));
        vm.broadcast(deployerAdmin);
        OrderBook OBImpl = new OrderBook();
        console.log("OrderBook implementation deployed to:", address(OBImpl));
        vm.startBroadcast(deployerAdmin);
        router.initialize(deployerAdmin, address(marginAccount), address(OBImpl), address(kuruForwarder));
        vm.stopBroadcast();
        vm.expectRevert(InvalidInitialization.selector);
        router.initialize(deployerAdmin, address(marginAccount), address(OBImpl), address(kuruForwarder));
        assert(router.owner() == deployerAdmin);
        vm.startBroadcast(deployerAdmin);
        MonadDeployer monadDeployer = new MonadDeployer(
            IRouter(address(router)), address(marginAccount), address(kuruForwarder), 100, 10 * 10 ** 18
        );
        console.log("MonadDeployer deployed to:", address(monadDeployer));
        // assert(marginAccount.feeCollector() == deployerAdmin);
    }
}
