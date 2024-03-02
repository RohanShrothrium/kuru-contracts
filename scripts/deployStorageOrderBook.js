const hre = require("hardhat");
const fs = require('fs');

async function main() {
    // contract addresses
    const wbtcAddress = "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f";
    const wbtcDecimals = 8;
    const wbtcShark = "0x4bb7f4c3d47c4b431cb0658f44287d52006fb506";

    const usdcAddress = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
    const usdcDecimals = 6;
    const usdcShark = "0x3dd1d15b3c78d6acfd75a254e857cbe5b9ff0af2";

    const _sizePrecision = 10**10;
    const _pricePrecision = 10**2;
    const _tickSize = _pricePrecision/2;
    const _minSize = 10**5;
    const _maxSize = 10**12;
    const _takerFeeBps = 0;

    const [deployer] = await hre.ethers.getSigners();
    const userAddress = deployer.address;

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

    // imporsonate sharkAddress for wbtc
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [wbtcShark],
    });

    const wbtcSigner = await hre.ethers.getSigner(wbtcShark);

    const wbtcContractShark = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", wbtcAddress, wbtcSigner);

    var receipt = await wbtcContractShark.transfer(
        userAddress,
        17*10**9,
    );

    console.log("wbtc balance: ", (await wbtcContractShark.balanceOf(userAddress)).toString())

    // imporsonate sharkAddress for usdc
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [usdcShark],
    });

    const usdcSigner = await hre.ethers.getSigner(usdcShark);

    const usdcContractShark = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress, usdcSigner);

    var receipt = await usdcContractShark.transfer(
        userAddress,
        2*10**10,
    );

    await receipt.wait();

    console.log("usdc balance: ", (await usdcContractShark.balanceOf(userAddress)).toString())

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