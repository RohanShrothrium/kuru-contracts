// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {KuruForwarder} from "../contracts/KuruForwarder.sol";
import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MonadDeployer} from "../contracts/periphery/MonadDeployer.sol";
import {IRouter} from "../contracts/interfaces/IRouter.sol";
import {KuruUtils} from "../contracts/periphery/KuruUtils.sol";

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
        KuruForwarder kuruForwarder = new KuruForwarder();
        console.log("KuruForwarder Implementation deployed to:", address(kuruForwarder));
        KuruForwarder kuruForwarderProxy = KuruForwarder((address(new ERC1967Proxy(address(kuruForwarder), ""))));
        kuruForwarderProxy.initialize(deployerAdmin, allowedInterfaces);
        console.log("KuruForwarder deployed to:", address(kuruForwarderProxy));
        vm.broadcast(deployerAdmin);
        Router routerImpl = new Router();
        console.log("Router implementation deployed to:", address(routerImpl));
        vm.broadcast(deployerAdmin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(routerImpl), "");
        console.log("Router proxy deployed to:", address(proxy));
        Router router = Router(payable(address(proxy)));

        vm.broadcast(deployerAdmin);
        MarginAccount marginAccount = new MarginAccount();
        marginAccount.initialize(deployerAdmin, address(router), address(router), address(kuruForwarder));
        console.log("MarginAccount deployed to:", address(marginAccount));
        vm.broadcast(deployerAdmin);
        OrderBook OBImpl = new OrderBook();
        console.log("OrderBook implementation deployed to:", address(OBImpl));
        vm.startBroadcast(deployerAdmin);
        KuruAMMVault kuruAmmVaultImpl = new KuruAMMVault();
        console.log("KuruAMMVault implementation deployed to:", address(kuruAmmVaultImpl));
        router.initialize(
            deployerAdmin, address(marginAccount), address(OBImpl), address(kuruAmmVaultImpl), address(kuruForwarder)
        );
        vm.stopBroadcast();
        vm.expectRevert(InvalidInitialization.selector);
        router.initialize(
            deployerAdmin, address(marginAccount), address(OBImpl), address(kuruAmmVaultImpl), address(kuruForwarder)
        );
        assert(router.owner() == deployerAdmin);
        vm.startBroadcast(deployerAdmin);
        MonadDeployer monadDeployer =
            new MonadDeployer(IRouter(address(proxy)), deployerAdmin, address(marginAccount), address(kuruForwarder), 100, 0);
        console.log("MonadDeployer deployed to:", address(monadDeployer));
        vm.stopBroadcast();
        vm.startBroadcast(deployerAdmin);
        KuruUtils kuruUtils = new KuruUtils();
        console.log("KuruUtils deployed to:", address(kuruUtils));
        vm.stopBroadcast();
        // assert(marginAccount.feeCollector() == deployerAdmin);
    }
}
