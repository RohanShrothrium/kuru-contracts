const hre = require("hardhat");
const config = require("../config.json");
const fs = require("fs");

async function main() {
    const [user, taker] = await hre.ethers.getSigners();

    // Setup USDC approval and deposit
    const usdcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.usdcAddress);
    var tx = await usdcContract.approve(
        config.marginAccountAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    const marginAccount = await hre.ethers.getContractAt("MarginAccount", config.marginAccountAddress);
    var tx = await marginAccount.deposit(
        user.address,
        config.usdcAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    // Setup WBTC approval
    const wbtcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.wbtcAddress, taker);
    var tx = await wbtcContract.approve(
        config.cranklessOrderBookAddress,
        hre.ethers.utils.parseEther("10000"),
    );
    await tx.wait();

    // Setup OrderBook instances
    const orderBookMaker = await hre.ethers.getContractAt("OrderBook", config.cranklessOrderBookAddress);
    const orderBookTaker = await hre.ethers.getContractAt("OrderBook", config.cranklessOrderBookAddress, taker);

    // Benchmark 100 flip limit orders
    console.log("=============================================")
    console.log("                FLIP LIMIT                   ")
    console.log("=============================================")
    const placeFlipLimitGas = {};
    for (let i = 0; i < 100; i++) {
        var tx = await orderBookMaker.addFlipBuyOrder(
            180000 - (i * 100),
            180000 + ((i+1) * 100),
            10**8,
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeFlipLimitGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // Cancel last 10 orders
    console.log("=============================================")
    console.log("                   CANCEL                    ")
    console.log("=============================================")
    const cancelFlipLimitGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBookMaker.batchCancelOrders(
            [i+1],
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        cancelFlipLimitGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // Place 10 flip orders at existing price points
    console.log("=============================================")
    console.log("              EXISTING FLIP                  ")
    console.log("=============================================")
    const placeFlipExistingGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBookMaker.addFlipBuyOrder(
            180000,
            180001,
            10**8,
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeFlipExistingGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // Place 10 market orders that takes from a single price point
    console.log("=============================================")
    console.log("             No New Order / NewOrder         ")
    console.log("=============================================")
    const placeFlipMarketSingleGas = {};
    for (let i = 0; i < 10; i++) {
        var tx = await orderBookTaker.placeAndExecuteMarketSell(
            10**8/4,
            0,
            false,
            false
        );
        const receipt = await tx.wait();

        console.log("Gas used: " + receipt.cumulativeGasUsed);
        placeFlipMarketSingleGas[i] = receipt.cumulativeGasUsed.toString();
    }

    // Write results to file
    fs.writeFileSync("cranklessStorageOrderBookFlip.json", JSON.stringify({
        placeFlipLimitGas,
        cancelFlipLimitGas,
        placeFlipExistingGas,
        placeFlipMarketSingleGas
    }));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
