const hre = require("hardhat");
const config = require("../config.json");
const fs = require("fs");

async function main() {
    const usdcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.usdcAddress);
    var tx = await usdcContract.approve(
        config.cranklessOrderBookAddress,
        10**10,
    );
    await tx.wait();

    const wbtcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.wbtcAddress);
    var tx = await wbtcContract.approve(
        config.cranklessOrderBookAddress,
        10**10,
    );
    await tx.wait();

    // create contract instance of OrderBook from config address
    const orderBook = await hre.ethers.getContractAt("CranklessOrderBook", config.cranklessOrderBookAddress);

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
            10**8,
            false
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
            false
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
            false,
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
            [100 - i],
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
            [90 - i, 90 - (i+1)],
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
            [70 - i, 70 - (i+1), 70 - (i+2)],
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
            false,
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
            [111 + i],
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
            [121 + i, 121 + (i+1)],
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
            [141 + i, 141 + (i+1), 141 + (i+2)],
            3*10**8,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeMarketThree1PPGas[i] = receipt.cumulativeGasUsed.toString();
    }


    fs.writeFileSync("cranklessOrderBook.json", JSON.stringify({
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
