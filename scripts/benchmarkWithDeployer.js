const hre = require("hardhat");
const config = require("../config.json");
const fs = require("fs");

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("http://localhost:8545");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    const userAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    console.log("HERE")
    const usdcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.usdcAddress, deployer);
    console.log("HERE")
    var tx = await usdcContract.approve(
        config.marginAccountAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();
        console.log("HERE")
    var tx = await usdcContract.approve(
        config.cranklessOrderBookAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    const wbtcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.wbtcAddress, deployer);
    var tx = await wbtcContract.approve(
        config.marginAccountAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    var tx = await wbtcContract.approve(
        config.cranklessOrderBookAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    const marginAccount = await hre.ethers.getContractAt("MarginAccount", config.marginAccountAddress, deployer);
    var tx = await marginAccount.deposit(
        userAddress,
        config.usdcAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    var tx = await marginAccount.deposit(
        userAddress,
        config.wbtcAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    // create contract instance of OrderBook from config address
    const orderBook = await hre.ethers.getContractAt("OrderBook", config.cranklessOrderBookAddress, deployer);

    // loop over 100 and place limit orders
    // prices: 1800, 1801, 1802, ... ,1899
    // orderIds: 1, 2, 3, ..., 100
    console.log("=============================================")
    console.log("                   LIMIT                     ")
    console.log("=============================================")
    const placeLimitGas = {};
    for (let i = 0; i < 100; i++) {
        var tx = await orderBook.addBuyOrder(
            180000 + (i * 100),
            10**8
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeLimitGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // cancel last 10 orders
    // price points that exist: 1810, 1811, ... , 1899
    // orderIds: 11, 12, 13, ..., 100,
    console.log("=============================================")
    console.log("                   CANCEL                    ")
    console.log("=============================================")
    const cancelLimitGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBook.batchCancelOrders(
            [i+1],
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        cancelLimitGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 10 limit orders at a price point that already existis.
    // price points that exist: 1810, 1811, ... , 1899
    // orderIds: 11, 12, 13, ..., 100, ... , 110
    console.log("=============================================")
    console.log("               EXISTING LIMIT                ")
    console.log("=============================================")
    const placeLimitExistingGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBook.addBuyOrder(
            181100,
            10**8,
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeLimitExistingGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 10 market orders that iterates over a single price point.
    // orderIds: 11, 12, 13, ..., 90
    console.log("=============================================")
    console.log("              SINGLE LO MARKET               ")
    console.log("=============================================")
    const placeMarketSingleGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBook.placeAndExecuteMarketSell(
            10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketSingleGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 10 market orders that iterates over two price points.
    // orderIds: 11, 12, 13, ..., 70
    console.log("=============================================")
    console.log("                TWO LO MARKET                ")
    console.log("=============================================")
    const placeMarketTwoGas = {};
    for (let i = 0; i < 20; i = i + 2) {
        var tx = await orderBook.placeAndExecuteMarketSell(
            2*10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketTwoGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 10 market orders that iterates over three price points.
    // orderIds: 11, 12, 13, ..., 40
    console.log("=============================================")
    console.log("              THREE LO MARKET                ")
    console.log("=============================================")
    const placeMarketThreeGas = {};
    for (let i = 0; i < 30; i = i + 3) {
        var tx = await orderBook.placeAndExecuteMarketSell(
            3*10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketThreeGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 20 new limits at same price
    console.log("=============================================")
    console.log("               EXISTING LIMIT                ")
    console.log("=============================================")
    for (let i = 0; i < 60; i++) {
        var tx = await orderBook.addBuyOrder(
            190000,
            10**8,
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
    }

    // place 10 market orders that iterates over a single price point.
    // orderIds: 11, 12, 13, ..., 90
    console.log("=============================================")
    console.log("              1 LO 1 PP MARKET               ")
    console.log("=============================================")
    const placeMarketSingle1PPGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBook.placeAndExecuteMarketSell(
            10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketSingle1PPGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 10 market orders that iterates over two price points.
    // orderIds: 11, 12, 13, ..., 70
    console.log("=============================================")
    console.log("               2 LO 1 PP MARKET              ")
    console.log("=============================================")
    const placeMarketTwo1PPGas = {};
    for (let i = 0; i < 20; i = i + 2) {
        var tx = await orderBook.placeAndExecuteMarketSell(
            2*10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketTwo1PPGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // place 10 market orders that iterates over three price points.
    // orderIds: 11, 12, 13, ..., 40
    console.log("=============================================")
    console.log("              3 LO 1 PP MARKET               ")
    console.log("=============================================")
    const placeMarketThree1PPGas = {};
    for (let i = 0; i < 30; i = i + 3) {
        var tx = await orderBook.placeAndExecuteMarketSell(
            3*10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketThree1PPGas[i] = receipt.cumulativeGasUsed.toString();
    }


    fs.writeFileSync("cranklessStorageOrderBookMargin.json", JSON.stringify({
        placeLimitGas,
        cancelLimitGas,
        placeLimitExistingGas,
        placeMarketSingleGas,
        placeMarketTwoGas,
        placeMarketThreeGas,
        placeMarketSingle1PPGas,
        placeMarketTwo1PPGas,
        placeMarketThree1PPGas
    }));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
