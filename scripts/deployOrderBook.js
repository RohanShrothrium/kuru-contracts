const hre = require("hardhat");
const fs = require('fs');

async function main() {
    // contract addresses
    const wbtcAddress = "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f";
    const wbtcDecimals = 8;
    const wbtcShark = "0x7546966122e636a601a3ea4497d3509f160771d8";

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

    // deploy OrderBook contract
    const OrderBook = await hre.ethers.getContractFactory("OrderBook");
    const orderBook = await OrderBook.deploy(wbtcAddress, wbtcDecimals, usdcAddress, usdcDecimals);
    await orderBook.deployed();

    const orderBookAddress = orderBook.address;
    console.log("OrderBook deployed to:", orderBookAddress);

    // deploy CranklessOrderBook contract
    const CranklessOrderBook = await hre.ethers.getContractFactory("CranklessOrderBook");
    const cranklessOrderBook = await CranklessOrderBook.deploy(wbtcAddress, wbtcDecimals, usdcAddress, usdcDecimals, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps);
    await cranklessOrderBook.deployed();

    const cranklessOrderBookAddress = cranklessOrderBook.address;
    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);

    // imporsonate sharkAddress for wbtc
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [wbtcShark],
    });

    const wbtcSigner = await hre.ethers.getSigner(wbtcShark);

    const wbtcContractShark = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", wbtcAddress, wbtcSigner);

    var receipt = await wbtcContractShark.transfer(
        userAddress,
        2*10**10,
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
        "orderBookAddress": orderBookAddress,
        "cranklessOrderBookAddress": cranklessOrderBookAddress
    }
    fs.writeFileSync("config.json", JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});