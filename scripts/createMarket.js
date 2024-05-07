const hre = require("hardhat");
const fs = require('fs');
const config = require("../config.json");

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("http://localhost:8545");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    // contract addresses
    const wbtcDecimals = 18;
    const usdcDecimals = 18;

    const _sizePrecision = 10**10;
    const _pricePrecision = 10**2;
    const _tickSize = _pricePrecision/2;
    const _minSize = 10**5;
    const _maxSize = 10**12;
    const _takerFeeBps = 0;

    // deploy CranklessOrderBook contract
    const CranklessOrderBook = await hre.ethers.getContractFactory("OrderBook", deployer);
    const cranklessOrderBook = await CranklessOrderBook.deploy(config.wbtcAddress, wbtcDecimals, config.usdcAddress, usdcDecimals, config.marginAccountAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);
    await cranklessOrderBook.deployed();

    const cranklessOrderBookAddress = cranklessOrderBook.address;
    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);

    const router = await hre.ethers.getContractAt("Router", config.routerAddress, deployer);

    // register wbtc-usdc market
    const marketRegisterTx = await router.registerMarket(config.wbtcAddress, config.usdcAddress, cranklessOrderBookAddress);
    await marketRegisterTx.wait();
    console.log("wbtc-usdc market registered");

    config.cranklessOrderBookAddress = cranklessOrderBookAddress;
    fs.writeFileSync("config.json", JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});