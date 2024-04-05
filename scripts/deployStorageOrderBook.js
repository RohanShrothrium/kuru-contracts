const hre = require("hardhat");
const fs = require('fs');

async function main() {
    // contract addresses
    const wbtcDecimals = 18;
    const usdcDecimals = 18;

    const _sizePrecision = 10**10;
    const _pricePrecision = 10**2;
    const _tickSize = _pricePrecision/2;
    const _minSize = 10**5;
    const _maxSize = 10**12;
    const _takerFeeBps = 0;

    const [deployer, taker] = await hre.ethers.getSigners();
    const userAddress = deployer.address;
    const takerAddress = taker.address;

    const ERC20 = await hre.ethers.getContractFactory("MintableERC20");
    const wbtc = await ERC20.deploy("Wrapped Bitcoin", "WBTC");
    await wbtc.deployed();
    console.log("WBTC deployed to:", wbtc.address);

    const usdc = await ERC20.deploy("USD Coin", "USDC");
    await usdc.deployed();
    console.log("USDC deployed to:", usdc.address);

    // Fund the shark account with a substantial amount of tokens
    await wbtc.mint(takerAddress, hre.ethers.utils.parseEther("1000000"));
    console.log("Shark WBTC balance:", (await wbtc.balanceOf(takerAddress)).toString());

    await usdc.mint(userAddress, hre.ethers.utils.parseEther("1000000"));
    console.log("Shark USDC balance:", (await usdc.balanceOf(userAddress)).toString());

    // Your existing deployment logic here, modified to use the deployed token addresses
    // Replace wbtcAddress and usdcAddress with the addresses of the deployed contracts
    const wbtcAddress = wbtc.address;
    const usdcAddress = usdc.address;

    // deploy Router Contract
    const Router = await hre.ethers.getContractFactory("Router");
    const router = await Router.deploy();
    await router.deployed();

    const routerAddress = router.address;
    console.log("Router deployed to:", routerAddress);

    // initialize router contract
    const routerInitTx = await router.initialize(userAddress);
    await routerInitTx.wait();
    console.log("Router Initialized with owner:", userAddress);

    // deploy Margin Account Contract
    const MarginAccount = await hre.ethers.getContractFactory("MarginAccount");
    const marginAccount = await MarginAccount.deploy(routerAddress);
    await marginAccount.deployed();

    const marginAccountAddress = marginAccount.address;
    console.log("MarginAccountAddress deployed to:", marginAccountAddress);

    // set margin account address for router
    const setMarginTx = await router.setMarginAccount(marginAccountAddress);
    await setMarginTx.wait();
    console.log("Router set with margin account address:", marginAccountAddress);

    // deploy CranklessOrderBook contract
    const CranklessOrderBook = await hre.ethers.getContractFactory("CranklessStorageOrderBook");
    const cranklessOrderBook = await CranklessOrderBook.deploy(wbtcAddress, wbtcDecimals, usdcAddress, usdcDecimals, marginAccountAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);
    await cranklessOrderBook.deployed();

    const cranklessOrderBookAddress = cranklessOrderBook.address;
    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);

    // register wbtc-usdc market
    const marketRegisterTx = await router.registerMarket(wbtcAddress, usdcAddress, cranklessOrderBookAddress);
    await marketRegisterTx.wait();
    console.log("wbtc-usdc market registered");

    const config = {
        "usdcAddress": usdcAddress,
        "wbtcAddress": wbtcAddress,
        "routerAddress": routerAddress,
        "marginAccountAddress": marginAccountAddress,
        "cranklessOrderBookAddress": cranklessOrderBookAddress
    }
    fs.writeFileSync("config.json", JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});