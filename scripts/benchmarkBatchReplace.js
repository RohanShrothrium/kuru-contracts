const hre = require("hardhat");
const config = require("../config.json");
const fs = require("fs");

async function main() {
    const [user, taker] = await hre.ethers.getSigners();

    // Setup USDC approval and deposit for margin account
    const usdcContract = await hre.ethers.getContractAt("IERC20Metadata", config.usdcAddress);
    var tx = await usdcContract.approve(
        config.marginAccountAddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    const marginAccount = await hre.ethers.getContractAt("MarginAccount", config.marginAccountAddress);
    var tx = await marginAccount.deposit(
        user.address,
        config.usdcAddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    // Setup WBTC approval and deposit for margin account
    const wbtcContract = await hre.ethers.getContractAt("IERC20Metadata", config.wbtcAddress);
    var tx = await wbtcContract.approve(
        config.marginAccountAddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    var tx = await marginAccount.deposit(
        user.address,
        config.wbtcAddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    // Get OrderBook contract instance
    const orderBook = await hre.ethers.getContractAt("OrderBook", config.cranklessOrderBookAddress);

    // Store all gas costs
    const gasCosts = {};

    // Test different values of n
    const nValues = [3, 5, 10, 20];

    for (const n of nValues) {
        console.log(`\n=============================================`)
        console.log(`                  n = ${n}                   `)
        console.log(`=============================================`)

        // 1. Initial cost for placing 2n orders (n buy, n sell)
        console.log(`\n1. Initial cost for placing ${2*n} orders (${n} buy, ${n} sell)`)
        const orderIds = [];
        
        // Place n buy and n sell orders using batchUpdate
        const initialBuyPrices = Array.from({length: n}, (_, i) => 200000 - ((i + 1) * 100));
        const initialSellPrices = Array.from({length: n}, (_, i) => 200000 + ((i + 1) * 100));
        
        var tx = await orderBook.batchUpdate(
            initialBuyPrices,
            Array(n).fill(10**8),
            initialSellPrices,
            Array(n).fill(10**8),
            [], // No orders to cancel
            true
        );
        const receipt = await tx.wait();
        
        // Extract order IDs from events
        const orderEvents = receipt.events.filter(e => e.event === 'OrderCreated');
        orderEvents.forEach(event => {
            orderIds.push(event.args.orderId);
        });
        
        console.log(`Placed ${2*n} orders: Gas used: ${receipt.cumulativeGasUsed}`);
        
        gasCosts[`${n}_initial_placement`] = receipt.cumulativeGasUsed.toString();

        // 3. Cost of replacing 2n orders at 2n price points
        console.log(`\n2. Cost of replacing ${2*n} orders at ${2*n} price points`)
        const diffBuyPrices = Array.from({length: n}, (_, i) => 230000 - ((i + 1) * 100));
        const diffSellPrices = Array.from({length: n}, (_, i) => 230000 + ((i + 1) * 100));
        var tx = await orderBook.batchUpdate(
            diffBuyPrices,
            Array(n).fill(10**8),
            diffSellPrices,
            Array(n).fill(10**8),
            orderIds,
            true // postOnly = true
        );
        const receipt3 = await tx.wait();
        gasCosts[`${n}_replace_2n_different_prices`] = receipt3.cumulativeGasUsed.toString();
        console.log(`Replace ${2*n} orders at ${2*n} prices: Gas used: ${receipt3.cumulativeGasUsed}`);

        // Update orderIds
        const newOrderIds3 = receipt3.events.filter(e => e.event === 'OrderCreated').map(e => e.args.orderId);
        orderIds.splice(0, 2*n, ...newOrderIds3);

        const secondBuyPrices = Array.from({length: n}, (_, i) => 230000 - ((i + 1) * 100));
        const secondSellPrices = Array.from({length: n}, (_, i) => 230000 + ((i + 1) * 100));
        tx = await orderBook.batchUpdate(
            secondBuyPrices,
            Array(n).fill(10**8),
            secondSellPrices,
            Array(n).fill(10**8),
            [],
            false
        );
        const secondSetReceipt = await tx.wait();
        const secondSetIds = secondSetReceipt.events.filter(e => e.event === 'OrderCreated').map(e => e.args.orderId);

        console.log("\n3. Cost of replacing 2n orders at price points with existing orders")

        // Now replace the second set: cancel those 2n and place another 2n
        const replaceBuyPrices = Array.from({length: n}, (_, i) => 230000 - ((i + 1) * 100));
        const replaceSellPrices = Array.from({length: n}, (_, i) => 230000 + ((i + 1) * 100));
        tx = await orderBook.batchUpdate(
            replaceBuyPrices,
            Array(n).fill(10**8),
            replaceSellPrices,
            Array(n).fill(10**8),
            secondSetIds,
            false
        );
        const receipt4 = await tx.wait();
        gasCosts[`${n}_replace_2n_different_prices_with_existing`] = receipt4.cumulativeGasUsed.toString();
        console.log(`Replace ${2*n} orders with existing: Gas used: ${receipt4.cumulativeGasUsed}`);

        // Wipe orderbook before proceeding: cancel pre-existing and newly placed replacement orders
        const replacedSecondIds = receipt4.events.filter(e => e.event === 'OrderCreated').map(e => e.args.orderId);
        const wipeIds = orderIds.concat(replacedSecondIds);
        tx = await orderBook.batchUpdate(
            [],
            [],
            [],
            [],
            wipeIds,
            false
        );
        await tx.wait();
    }

    // Save results to file
    fs.writeFileSync("benchmarkBatchReplace.json", JSON.stringify(gasCosts, null, 2));
    console.log("\nBenchmark results saved to benchmarkBatchReplace.json");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
