const hre = require("hardhat");
const fs = require('fs');

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("http://127.0.0.1:8545");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);
    const maker2 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
    const maker3 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";
    const maker4 = "0x90F79bf6EB2c4f870365E785982E1f101E93b906";
    
    // Deploy WETH ERC20 token
    const WETH = await hre.ethers.getContractFactory("KuruERC20", deployer);
    const eth = await WETH.deploy("Wrapped Ether", "WETH", hre.ethers.utils.parseEther("100000000000"), deployer.address);
    await eth.deployed();
    console.log("ETH deployed to:", eth.address);

    const USDC = await hre.ethers.getContractFactory("KuruERC20", deployer);
    const usdc = await USDC.deploy("USD Coin", "USDC", hre.ethers.utils.parseEther("100000000000000"), deployer.address);
    await usdc.deployed();
    console.log("USDC deployed to:", usdc.address);

    // Distribute tokens to makers (1/4 each)
    const ethQuarter = hre.ethers.utils.parseEther("25000000000"); // 100B / 4
    const usdcQuarter = hre.ethers.utils.parseEther("25000000000000"); // 100T / 4

    await eth.transfer(maker2, ethQuarter);
    await eth.transfer(maker3, ethQuarter);
    await eth.transfer(maker4, ethQuarter);
    console.log("ETH distributed to makers");

    await usdc.transfer(maker2, usdcQuarter);
    await usdc.transfer(maker3, usdcQuarter);
    await usdc.transfer(maker4, usdcQuarter);
    console.log("USDC distributed to makers");

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
        const config = JSON.parse(fs.readFileSync('./scripts/storageAnalysis/config.json', 'utf8'));
        config.OrderBook = market;
        config.BaseToken = eth.address;
        config.QuoteToken = usdc.address;
        
        fs.writeFileSync('./scripts/storageAnalysis/config.json', JSON.stringify(config, null, 4));
        console.log("Config.json updated with deployed addresses");
    } catch (error) {
        console.error("Error saving market information:", error);
    }
}

async function createMarket(baseAddress, quoteAddress, deployer) {
    const config = JSON.parse(fs.readFileSync('./scripts/storageAnalysis/config.json', 'utf8'));
    const router = await hre.ethers.getContractAt("Router", config.Router, deployer);

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
