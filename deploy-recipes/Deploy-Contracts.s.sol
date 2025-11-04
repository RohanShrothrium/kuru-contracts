// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Config} from "./config/Config.s.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {KuruForwarder} from "../contracts/KuruForwarder.sol";
import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MonadDeployer} from "../contracts/periphery/MonadDeployer.sol";
import {IRouter} from "../contracts/interfaces/IRouter.sol";
import {KuruUtils} from "../contracts/periphery/KuruUtils.sol";

contract Deployer is Script, Config {

    Config public config;
    address public deployerAddress;
    Router public router;
    Router public routerImpl;
    MarginAccount public marginAccount;
    MarginAccount public marginAccountImpl;
    KuruForwarder public kuruForwarder;
    KuruForwarder public kuruForwarderImpl;
    OrderBook public orderBookImpl;
    KuruAMMVault public kuruAMMVaultImpl;
    MonadDeployer public monadDeployer;
    KuruUtils public kuruUtils;
    
    function setUp() public {
    }

    function run() public {
        vm.createSelectFork(getRpcUrl());

        executeDeployments();
        executeOwnershipTransfers();
        verifyDeployments();
        writeDeploymentsToFile();
    }

    function executeDeployments() public {
        deployerAddress = getDeployer();

        bytes4[] memory allowedInterfaces = new bytes4[](7);
        allowedInterfaces = getKuruForwarderAllowedInterfaces();
        console.log("executing deployments time");
        vm.startBroadcast(deployerAddress);
        // deploy kuru forwarder implementation and proxy
        kuruForwarderImpl = new KuruForwarder();
        console.log("KuruForwarder Implementation deployed to:", address(kuruForwarderImpl));
        ERC1967Proxy kuruForwarderProxy = new ERC1967Proxy(address(kuruForwarderImpl), "");
        kuruForwarder = KuruForwarder(payable(address(kuruForwarderProxy)));
        kuruForwarder.initialize(deployerAddress, allowedInterfaces);
        console.log("KuruForwarder initialized and deployed to:", address(kuruForwarder));
        vm.stopBroadcast();

        vm.startBroadcast(deployerAddress);
        routerImpl = new Router();
        console.log("Router implementation deployed to:", address(routerImpl));
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), "");
        router = Router(payable(address(routerProxy)));
        console.log("Uninitialized Router deployed to:", address(router));
        vm.stopBroadcast();

        vm.startBroadcast(deployerAddress);
        marginAccountImpl = new MarginAccount();
        console.log("MarginAccount implementation deployed to:", address(marginAccountImpl));
        ERC1967Proxy marginAccountProxy = new ERC1967Proxy(address(marginAccountImpl), "");
        marginAccount = MarginAccount(payable(address(marginAccountProxy)));
        address protocolFeeCollector = getProtocolFeeCollector();
        marginAccount.initialize(deployerAddress, address(router), protocolFeeCollector, address(kuruForwarder));
        console.log("MarginAccount deployed and initialized to:", address(marginAccount));
        vm.stopBroadcast();

        vm.startBroadcast(deployerAddress);
        orderBookImpl = new OrderBook();
        console.log("OrderBook implementation deployed to:", address(orderBookImpl));
        kuruAMMVaultImpl = new KuruAMMVault();
        console.log("KuruAMMVault implementation deployed to:", address(kuruAMMVaultImpl));
        router.initialize(
            deployerAddress, address(marginAccount), address(orderBookImpl), address(kuruAMMVaultImpl), address(kuruForwarder)
        );
        vm.stopBroadcast();

        vm.startBroadcast(deployerAddress);
        monadDeployer =
            new MonadDeployer(IRouter(address(router)), deployerAddress, address(marginAccount), address(protocolFeeCollector), 100, 0);
        console.log("MonadDeployer deployed to:", address(monadDeployer));
        vm.stopBroadcast();

        vm.startBroadcast(deployerAddress);
        kuruUtils = new KuruUtils();
        console.log("KuruUtils deployed to:", address(kuruUtils));
        vm.stopBroadcast();
    }

    function executeOwnershipTransfers() public {
        vm.startBroadcast(deployerAddress);
        address protocolAdmin = getProtocolMultiSig();
        marginAccount.transferOwnership(protocolAdmin);
        router.transferOwnership(protocolAdmin);
        kuruForwarder.transferOwnership(protocolAdmin);
        monadDeployer.transferOwnership(protocolAdmin);
        vm.stopBroadcast();
    }
    
    function verifyDeployments() public {
        address protocolAdmin = getProtocolMultiSig();
        assert(protocolAdmin != address(0));
        assert(marginAccount.owner() == protocolAdmin);
        assert(router.owner() == protocolAdmin);
        assert(monadDeployer.owner() == protocolAdmin);
        assert(kuruForwarder.owner() == protocolAdmin);
    }

    function writeDeploymentsToFile() internal {
        string memory path = "deploy-recipes/deployments.json";
        string memory objectKey = "deployments";
        console.log("Writing deployments to file");
        vm.serializeAddress(objectKey, "Router", address(router));
        vm.serializeAddress(objectKey, "RouterImpl", address(routerImpl));
        vm.serializeAddress(objectKey, "MarginAccount", address(marginAccount));
        vm.serializeAddress(objectKey, "MarginAccountImpl", address(marginAccountImpl));
        vm.serializeAddress(objectKey, "KuruForwarder", address(kuruForwarder));
        vm.serializeAddress(objectKey, "KuruForwarderImpl", address(kuruForwarderImpl));
        vm.serializeAddress(objectKey, "OrderBookImpl", address(orderBookImpl));
        vm.serializeAddress(objectKey, "KuruAMMVaultImpl", address(kuruAMMVaultImpl));
        vm.serializeAddress(objectKey, "MonadDeployer", address(monadDeployer));
        string memory finalJson = vm.serializeAddress(objectKey, "KuruUtils", address(kuruUtils));
        console.log("Finished writing deployments to file");        
        vm.writeJson(finalJson, path);
    }

}
