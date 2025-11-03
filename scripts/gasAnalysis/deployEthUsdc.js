const hre = require("hardhat");
const fs = require('fs');

async function main() {
    const configJson = JSON.parse(fs.readFileSync('./scripts/gasAnalysis/config.json', 'utf8'));
    const currentProvider = new hre.ethers.providers.JsonRpcProvider(configJson.rpcUrl);
    const deployerPvtKey = configJson.deployerPrivateKey;
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);
    
    // Deploy WETH ERC20 token
    const WETH = await hre.ethers.getContractFactory("KuruERC20", deployer);
    const eth = await WETH.deploy("Wrapped Ether", "WETH", hre.ethers.utils.parseEther("100000000000"), deployer.address);
    await eth.deployed();
    console.log("ETH deployed to:", eth.address);

    const USDC = await hre.ethers.getContractFactory("KuruERC20", deployer);
    const usdc = await USDC.deploy("USD Coin", "USDC", hre.ethers.utils.parseEther("100000000000000"), deployer.address);
    await usdc.deployed();
    console.log("USDC deployed to:", usdc.address);

    const market = await createMarket(eth.address, usdc.address, deployer);
    console.log("WETH-USDC market created at:", market);

    // Save market information to a file
    const marketInfo = {
        name: "WETH-USDC",
        address: market,
        baseToken: eth.address,
        quoteToken: usdc.address
    };
    try {
        // Update config.json with deployed addresses
        const config = JSON.parse(fs.readFileSync('./scripts/gasAnalysis/config.json', 'utf8'));
        config.marketAddress = market;
        config.wethAddress = eth.address;
        config.usdcAddress = usdc.address;
        
        fs.writeFileSync('./scripts/gasAnalysis/config.json', JSON.stringify(config, null, 4));
        console.log("Config.json updated with deployed addresses");
    } catch (error) {
        console.error("Error saving market information:", error);
    }
}

async function createMarket(baseAddress, quoteAddress, deployer) {
    const config = JSON.parse(fs.readFileSync('./scripts/gasAnalysis/config.json', 'utf8'));
    const router = await hre.ethers.getContractAt("Router", config.router, deployer);

    const _sizePrecision = 10 ** 10;
    const _pricePrecision = 10000;
    const _tickSize = 1;
    const _minSize = 10 ** 2;
    const _maxSize = 10 ** 15;
    const _takerFeeBps = 0;
    const _makerFeeBps = 0;
    const _spread = 10;

    const proxyType = 0; // STANDARD

    const cranklessOrderBookAddress = await router.callStatic.deployProxy(
        proxyType,
        baseAddress,
        quoteAddress,
        _sizePrecision,
        _pricePrecision,
        _tickSize,
        _minSize,
        _maxSize,
        _takerFeeBps,
        _makerFeeBps,
        _spread
    );

    const deployProxyTx = await router.deployProxy(
        proxyType,
        baseAddress,
        quoteAddress,
        _sizePrecision,
        _pricePrecision,
        _tickSize,
        _minSize,
        _maxSize,
        _takerFeeBps,
        _makerFeeBps,
        _spread
    );
    await deployProxyTx.wait();

    return cranklessOrderBookAddress;
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
