const hre = require("hardhat");
const { ethers, upgrades } = require("hardhat");
const fs = require('fs');

var configFileName = "devnet.config.json";

const args = process.argv.slice(2);
const devnetName = args[0];

if (devnetName !== "") {
    configFileName = `${devnetName}_${configFileName}`;
}

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("https://devnet1.monad.xyz/rpc/WbScX50z7Xsvsuk6UB1uMci8Ekee3PJqhBZ2RRx0xSjyqx9hjipbfMh60vr7a1gS");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    const userAddress = "0xf109c592d2c9EA712A01c6fCE8f149c5AF0b6672";

    // deploy Router Contract
    const Router = await hre.ethers.getContractFactory("Router");
    const routerImpl = await Router.deploy();
    await routerImpl.deployed();
    const Proxy = await hre.ethers.getContractFactory("ERC1967Proxy");
    const proxy = await Proxy.deploy(routerImpl.address, "0x");
    await proxy.deployed();

    const router = await hre.ethers.getContractAt("Router", proxy.address, deployer);
    const routerAddress = proxy.address;
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