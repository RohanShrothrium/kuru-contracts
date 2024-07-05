const hre = require("hardhat");
const fs = require('fs');

var configFileName = "devnet.config.json";

const args = process.argv.slice(2);
const devnetName = args[0];

if (devnetName !== "") {
    configFileName = `${devnetName}_${configFileName}`;
}

const config = require(`../${configFileName}`);

function Enum(...options) {
    return Object.fromEntries(options.map((key, i) => [key, hre.ethers.BigNumber.from(i)]));
}

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("https://devnet1.monad.xyz/rpc/WbScX50z7Xsvsuk6UB1uMci8Ekee3PJqhBZ2RRx0xSjyqx9hjipbfMh60vr7a1gS");

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
    const _makerFeeBps = 0;

    const router = await hre.ethers.getContractAt("Router", config.routerAddress, deployer);
    const cranklessOrderBookAddress = await router.callStatic.deployProxy(Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE, wbtcAddress, usdcAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps, _makerFeeBps);
    const deployProxyTx = await router.deployProxy(Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE, wbtcAddress, usdcAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps, _makerFeeBps);
    await deployProxyTx.wait();

    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);




    config.cranklessOrderBookAddress = cranklessOrderBookAddress;
    fs.writeFileSync(configFileName, JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});