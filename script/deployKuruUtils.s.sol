//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {KuruUtils} from "../contracts/periphery/KuruUtils.sol";

contract DeployKuruUtils is Script {
    function run() external {
        // Monad chain ID is 1024
        uint256 chainId = vm.envOr("CHAIN_ID", uint256(10143));
        console.log("Deploying KuruUtils on chain ID:", chainId);

        // Get deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // Start broadcasting
        vm.startBroadcast(deployerPrivateKey);

        // Deploy KuruUtils
        KuruUtils kuruUtils = new KuruUtils();
        console.log("KuruUtils deployed at:", address(kuruUtils));

        vm.stopBroadcast();
    }
}
