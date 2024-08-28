const hre = require("hardhat");
const fs = require('fs');

var configFileName = "devnet.config.json";

const args = process.argv.slice(2);
const devnetName = args[0];

if (devnetName !== "") {
    configFileName = `${devnetName}_${configFileName}`;
}

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("https://eth-sepolia.api.onfinality.io/public");
    const deployerPvtKey = "e33eae6a73c0c8bb2be71c86d72dc35b6b573468592165cbb24cc66f961c1c2e";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    const userAddress = "0xf109c592d2c9EA712A01c6fCE8f149c5AF0b6672";

    // deploy Router Contract
    const Router = await hre.ethers.getContractFactory("Router", deployer);
    const router = await Router.deploy();
    await router.deployed();

    const routerAddress = router.address;
    console.log("Router deployed to:", routerAddress);

    // deploy Margin Account Contract
    const MarginAccount = await hre.ethers.getContractFactory("MarginAccount", deployer);
    const marginAccount = await MarginAccount.deploy(routerAddress, userAddress);
    await marginAccount.deployed();

    const marginAccountAddress = marginAccount.address;
    console.log("MarginAccountAddress deployed to:", marginAccountAddress);

    //Deploy OrderBook implementation
    const OrderBook = await hre.ethers.getContractFactory("OrderBook", deployer);
    const implementation = await OrderBook.deploy();
    await implementation.deployed();
    console.log("Orderbook implementation deployed at: ", implementation.address);

    // initialize router contract
    const routerInitTx = await router.initialize(userAddress, marginAccountAddress, implementation.address);
    await routerInitTx.wait();
    console.log("Router Initialized with owner:", userAddress);

    const config = {
        "routerAddress": routerAddress,
        "marginAccountAddress": marginAccountAddress,
    }
    fs.writeFileSync(configFileName, JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});