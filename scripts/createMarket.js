const hre = require("hardhat");
const fs = require('fs');
const config = require("../config.json");

function Enum(...options) {
    return Object.fromEntries(options.map((key, i) => [key, hre.ethers.BigNumber.from(i)]));
}

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("http://localhost:8545");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    // contract addresses
    const wbtcDecimals = 18;
    const usdcDecimals = 18;
    const wbtcAddress = config.wbtcAddress;
    const usdcAddress = config.usdcAddress;
    const _sizePrecision = 10**10;
    const _pricePrecision = 10**2;
    const _tickSize = _pricePrecision/2;
    const _minSize = 10**5;
    const _maxSize = 10**12;
    const _takerFeeBps = 0;
    
    var largerFlag = hre.ethers.BigNumber.from(wbtcAddress).gt(hre.ethers.BigNumber.from(usdcAddress));

    const router = await hre.ethers.getContractAt("Router", config.routerAddress, deployer);
    const cranklessOrderBookAddress = await router.callStatic.deployProxy(Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE, largerFlag ? usdcAddress : wbtcAddress, largerFlag ? wbtcAddress : usdcAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);
    const deployProxyTx = await router.deployProxy(Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE, wbtcAddress, usdcAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);
    await deployProxyTx.wait();

    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);




    config.cranklessOrderBookAddress = cranklessOrderBookAddress;
    fs.writeFileSync("config.json", JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});