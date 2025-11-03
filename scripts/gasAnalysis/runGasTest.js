const hre = require("hardhat");
const fs = require("fs");

// ===== Access List helpers (EIP-2930) =====
const ORDER_SLOT = 50; // mapping(uint40 => Order) s_orders at slot 50
const BUY_PP_SLOT = 51; // mapping(uint256 => PricePoint) s_buyPricePoints at slot 51
const SELL_PP_SLOT = 52; // mapping(uint256 => PricePoint) s_sellPricePoints at slot 52
const MARGIN_BALANCES_SLOT = 1; // mapping(bytes32 => uint256) balances at slot 1 in MarginAccount
const BUY_TREE_BASE_SLOT = 53; // TreeMath.TreeUint32 s_buyTree base slot (level0)
const SELL_TREE_BASE_SLOT = 57; // TreeMath.TreeUint32 s_sellTree base slot (level0)
const VERIFIED_MARKET_SLOT = 2; // mapping(address => bool) verifiedMarket at slot 1 in MarginAccount
function _keccakMappingSlot(key, slotIndex) {
    const { defaultAbiCoder, keccak256 } = hre.ethers.utils;
    const encoded = defaultAbiCoder.encode(["uint256", "uint256"], [key, slotIndex]);
    return hre.ethers.BigNumber.from(keccak256(encoded));
}

function _keccakMappingSlotBytes32(keyBytes32, slotIndex) {
    const { defaultAbiCoder, keccak256 } = hre.ethers.utils;
    const encoded = defaultAbiCoder.encode(["bytes32", "uint256"], [keyBytes32, slotIndex]);
    return hre.ethers.BigNumber.from(keccak256(encoded));
}

function _keccakMappingSlotAddress(addr, slotIndex) {
    const { defaultAbiCoder, keccak256 } = hre.ethers.utils;
    const encoded = defaultAbiCoder.encode(["address", "uint256"], [addr, slotIndex]);
    return hre.ethers.BigNumber.from(keccak256(encoded));
  }

function _hex32(bn) {
    return hre.ethers.utils.hexZeroPad(bn.toHexString(), 32);
}

function _addOrderSlotsToSet(set, startOrderIdBn, count) {
    for (let i = 0; i < count; i++) {
        const orderId = startOrderIdBn.add(i);
        const base = _keccakMappingSlot(orderId, ORDER_SLOT);
        set.add(_hex32(base));
        set.add(_hex32(base.add(1))); // second slot of Order struct
    }
}

function _addPricePointSlotsToSet(set, prices, isBuySide) {
    const slotIndex = isBuySide ? BUY_PP_SLOT : SELL_PP_SLOT;
    for (const p of prices) {
        const priceBn = hre.ethers.BigNumber.from(p);
        const pp = _keccakMappingSlot(priceBn, slotIndex);
        set.add(_hex32(pp));
    }
}

function _accountKey(userAddress, tokenAddress) {
    const { solidityPack, keccak256 } = hre.ethers.utils;
    const packed = solidityPack(["address", "address"], [userAddress, tokenAddress]);
    return keccak256(packed);
}

function _addMarginBalanceSlotsToSet(set, userAddress, tokenAddresses) {
    for (const token of tokenAddresses) {
        const key = _accountKey(userAddress, token);
        const slot = _keccakMappingSlotBytes32(key, MARGIN_BALANCES_SLOT);
        set.add(_hex32(slot));
    }
}

function _addVerifiedMarketSlot(set, orderBookProxyAddress) {
    const slot = _keccakMappingSlotAddress(orderBookProxyAddress, VERIFIED_MARKET_SLOT);
    set.add(_hex32(slot));
  }

function _hexBytes32FromBnShiftRight(bn, bits) {
    return hre.ethers.utils.hexZeroPad(bn.shr(bits).toHexString(), 32);
}

function _addTreeSlotsForPrices(set, prices, isBuySide) {
    if (prices.length === 0) return;
    const baseSlot = isBuySide ? BUY_TREE_BASE_SLOT : SELL_TREE_BASE_SLOT;
    const level1Slot = baseSlot + 1; // mapping(bytes32 => bytes32) level1
    const level2Slot = baseSlot + 2; // mapping(bytes32 => bytes32) level2
    const level3Slot = baseSlot + 3; // mapping(bytes32 => bytes32) level3

    // Include level0 slot directly (bytes32 variable)
    set.add(_hex32(hre.ethers.BigNumber.from(baseSlot)));

    for (const p of prices) {
        const priceBn = hre.ethers.BigNumber.from(p);
        const key3 = _hexBytes32FromBnShiftRight(priceBn, 8);
        const key2 = _hexBytes32FromBnShiftRight(priceBn, 16);
        const key1 = _hexBytes32FromBnShiftRight(priceBn, 24);

        const slotL3 = _keccakMappingSlotBytes32(key3, level3Slot);
        const slotL2 = _keccakMappingSlotBytes32(key2, level2Slot);
        const slotL1 = _keccakMappingSlotBytes32(key1, level1Slot);

        set.add(_hex32(slotL3));
        set.add(_hex32(slotL2));
        set.add(_hex32(slotL1));
    }
}

// small sleep helper
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function buildAccessListForPlacement(orderBook, buyPrices, sellPrices, marginAccountAddress, userAddress, quoteTokenAddress, baseTokenAddress) {
    const nextId = await orderBook.s_orderIdCounter();
    const nextIdBn = hre.ethers.BigNumber.from(nextId).add(1);
    const totalNew = buyPrices.length + sellPrices.length;
    const keySet = new Set();
    _addOrderSlotsToSet(keySet, nextIdBn, totalNew);
    _addPricePointSlotsToSet(keySet, buyPrices, true);
    _addPricePointSlotsToSet(keySet, sellPrices, false);
    _addTreeSlotsForPrices(keySet, buyPrices, true);
    _addTreeSlotsForPrices(keySet, sellPrices, false);

    const marginKeySet = new Set();
    if (buyPrices.length > 0) {
        _addMarginBalanceSlotsToSet(marginKeySet, userAddress, [quoteTokenAddress]);
    }
    if (sellPrices.length > 0) {
        _addMarginBalanceSlotsToSet(marginKeySet, userAddress, [baseTokenAddress]);
    }

    const accessList = [
        { address: orderBook.address, storageKeys: Array.from(keySet) },
        { address: marginAccountAddress, storageKeys: Array.from(marginKeySet) },
    ];
    return accessList;
}

async function buildAccessListForCancelAndPlace(orderBook, orderIdsToCancel, buyPrices, sellPrices, marginAccountAddress, userAddress, quoteTokenAddress, baseTokenAddress,
orderBookImpl, marginAccountImpl) {
    const keySet = new Set();
    const marginKeySet = new Set();
    const EIP1967_IMPL_SLOT ="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    // Include slots for orders being canceled and their price points
    const orders = await Promise.all(orderIdsToCancel.map((id) => orderBook.s_orders(id)));
    let hasBuyCancel = false;
    let hasSellCancel = false;
    const canceledBuyPrices = [];
    const canceledSellPrices = [];
    for (let i = 0; i < orderIdsToCancel.length; i++) {
        const id = orderIdsToCancel[i];
        const idBn = hre.ethers.BigNumber.from(id);
        const base = _keccakMappingSlot(idBn, ORDER_SLOT);
        keySet.add(_hex32(base));
        keySet.add(_hex32(base.add(1)));
        const ord = orders[i];
        const price = (ord.price !== undefined) ? ord.price : ord[5];
        const isBuy = (ord.isBuy !== undefined) ? ord.isBuy : ord[7];
        const priceBn = hre.ethers.BigNumber.from(price);
        const pp = _keccakMappingSlot(priceBn, isBuy ? BUY_PP_SLOT : SELL_PP_SLOT);
        keySet.add(_hex32(pp));
        if (isBuy) {
            hasBuyCancel = true;
            canceledBuyPrices.push(priceBn);
        } else {
            hasSellCancel = true;
            canceledSellPrices.push(priceBn);
        }
    }
    _addTreeSlotsForPrices(keySet, canceledBuyPrices, true);
    _addTreeSlotsForPrices(keySet, canceledSellPrices, false);

    // Include slots for orders being placed and their price points
    const nextId = await orderBook.s_orderIdCounter();
    const nextIdBn = hre.ethers.BigNumber.from(nextId).add(1);
    const totalNew = buyPrices.length + sellPrices.length;
    _addOrderSlotsToSet(keySet, nextIdBn, totalNew);
    _addPricePointSlotsToSet(keySet, buyPrices, true);
    _addPricePointSlotsToSet(keySet, sellPrices, false);
    _addTreeSlotsForPrices(keySet, buyPrices, true);
    _addTreeSlotsForPrices(keySet, sellPrices, false);

    // Margin keys needed for cancels (credits) and placements (debits)
    if (hasBuyCancel || buyPrices.length > 0) {
        _addMarginBalanceSlotsToSet(marginKeySet, userAddress, [quoteTokenAddress]);
    }
    if (hasSellCancel || sellPrices.length > 0) {
        _addMarginBalanceSlotsToSet(marginKeySet, userAddress, [baseTokenAddress]);
    }

    // fixed slots for orderbook 
    
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000000"); // VaultBestBid
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000002"); // vaultBestAsk
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000003"); // askPartiallyFilledSize
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000004"); // vaultBidOrderSize
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000031"); // _trustedForwarder
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000035"); // s_buyTree
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000039"); // s_sellTree
    keySet.add("0x000000000000000000000000000000000000000000000000000000000000003d"); // sizePrecision, and price precision
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000041"); // baseDecimalMultiplier
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000043"); // quoteDecimalMultiplier
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000044"); // baseAsset
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000045"); // qouteAsset
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000046"); // maxsize
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000049"); // Marginaccount
    keySet.add(EIP1967_IMPL_SLOT);
    marginKeySet.add(EIP1967_IMPL_SLOT);


    // fixed slots for margin account
    keySet.add("0x0000000000000000000000000000000000000000000000000000000000000000"); // protocolPaused
    _addVerifiedMarketSlot(keySet, orderBook.address);


    const accessList = [
        { address: orderBook.address, storageKeys: Array.from(keySet) },
        { address: marginAccountAddress, storageKeys: Array.from(marginKeySet) },
        { address: orderBookImpl},
        { address: marginAccountImpl},
    ];
    return accessList;
}

async function buildAccessListForCancelOnly(orderBook, orderIdsToCancel, marginAccountAddress, userAddress, quoteTokenAddress, baseTokenAddress) {
    const keySet = new Set();
    const marginKeySet = new Set();
    const orders = await Promise.all(orderIdsToCancel.map((id) => orderBook.s_orders(id)));
    let hasBuyCancel = false;
    let hasSellCancel = false;
    const canceledBuyPrices = [];
    const canceledSellPrices = [];
    for (let i = 0; i < orderIdsToCancel.length; i++) {
        const id = orderIdsToCancel[i];
        const idBn = hre.ethers.BigNumber.from(id);
        const base = _keccakMappingSlot(idBn, ORDER_SLOT);
        keySet.add(_hex32(base));
        keySet.add(_hex32(base.add(1)));
        const ord = orders[i];
        const price = (ord.price !== undefined) ? ord.price : ord[5];
        const isBuy = (ord.isBuy !== undefined) ? ord.isBuy : ord[7];
        const priceBn = hre.ethers.BigNumber.from(price);
        const pp = _keccakMappingSlot(priceBn, isBuy ? BUY_PP_SLOT : SELL_PP_SLOT);
        keySet.add(_hex32(pp));
        if (isBuy) {
            hasBuyCancel = true;
            canceledBuyPrices.push(priceBn);
        } else {
            hasSellCancel = true;
            canceledSellPrices.push(priceBn);
        }
    }
    _addTreeSlotsForPrices(keySet, canceledBuyPrices, true);
    _addTreeSlotsForPrices(keySet, canceledSellPrices, false);
    if (hasBuyCancel) {
        _addMarginBalanceSlotsToSet(marginKeySet, userAddress, [quoteTokenAddress]);
    }
    if (hasSellCancel) {
        _addMarginBalanceSlotsToSet(marginKeySet, userAddress, [baseTokenAddress]);
    }
    const accessList = [
        { address: orderBook.address, storageKeys: Array.from(keySet) },
        { address: marginAccountAddress, storageKeys: Array.from(marginKeySet) },
    ];
    return accessList;
}

async function main() {

    // const [user, taker] = await hre.ethers.getSigners();
    const configJson = JSON.parse(fs.readFileSync('./scripts/gasAnalysis/config.json', 'utf8'));
    
    const marketaddress = configJson.marketAddress;
    const wethaddress = configJson.wethAddress;
    const usdcaddress = configJson.usdcAddress;
    const marginaccountaddress = configJson.marginAccount;
    const orderBookImpl = configJson.orderBookImpl;
    const marginAccountImpl = configJson.marginAccountImpl;
    
    const currentProvider = new hre.ethers.providers.JsonRpcProvider(configJson.rpcUrl);
    const deployerPvtKey = configJson.deployerPrivateKey;
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    // Setup USDC approval and deposit for margin account
    const usdcContract = await hre.ethers.getContractAt("IERC20Metadata", usdcaddress, deployer);
    var tx = await usdcContract.approve(
        marginaccountaddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    const marginAccount = await hre.ethers.getContractAt("MarginAccount", marginaccountaddress, deployer);
    var tx = await marginAccount.deposit(
        deployer.address,
        usdcaddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    // Setup WBTC approval and deposit for margin account
    const wbtcContract = await hre.ethers.getContractAt("IERC20Metadata", wethaddress, deployer);
    var tx = await wbtcContract.approve(
        marginaccountaddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    var tx = await marginAccount.deposit(
        deployer.address,
        wethaddress,
        hre.ethers.utils.parseEther("100000"),
    );
    await tx.wait();

    // Get OrderBook contract instance
    const orderBook = await hre.ethers.getContractAt("OrderBook", marketaddress, deployer);

    // Store all gas costs with descriptive labels
    const gasCosts = {
        metadata: {
            description: "Gas cost benchmark for batch order operations",
            timestamp: new Date().toISOString(),
            test_scenarios: {
                "initial_placement": "Cost to place N buy orders + N sell orders on empty orderbook",
                "replace_at_new_prices": "Cost to cancel N+N orders and place N+N orders at different price levels",
                "replace_at_existing_prices": "Cost to cancel N+N orders and place N+N orders at price levels that already have orders",
                "cancel_all_orders": "Cost to cancel all N+N orders (cleanup)"
            }
        },
        results: {}
    };

    // Test different values of n
    const nValues = [3, 5, 10, 20];
    var prevBalance = await deployer.getBalance();
    console.log("Before placing orders: ", prevBalance);
    for (const n of nValues) {
        var prevBalance = await deployer.getBalance();
        console.log(`Before placing orders: ${n} : ${prevBalance}`);
        console.log(`\n=============================================`)
        console.log(`                  n = ${n}                   `)
        console.log(`=============================================`)

        // Initialize results for this n value
        gasCosts.results[`n_${n}`] = {
            order_count: 2 * n,
            buy_orders: n,
            sell_orders: n
        };

        // 1. Initial cost for placing 2n orders (n buy, n sell)
        console.log(`\n1. Initial cost for placing ${2*n} orders (${n} buy, ${n} sell)`)
        const orderIds = [];
        
        // Place n buy and n sell orders using batchUpdate
        const initialBuyPrices = Array.from({length: n}, (_, i) => 200000 - ((i + 1) * 100));
        const initialSellPrices = Array.from({length: n}, (_, i) => 200000 + ((i + 1) * 100));
        
        let accessList = await buildAccessListForPlacement(
            orderBook,
            initialBuyPrices,
            initialSellPrices,
            marginaccountaddress,
            deployer.address,
            usdcaddress,
            wethaddress
        );
        var tx = await orderBook.populateTransaction.batchUpdate(
            initialBuyPrices,
            Array(n).fill(10**8),
            initialSellPrices,
            Array(n).fill(10**8),
            [], // No orders to cancel
            true
        );
        // Capture order ids using counter before and after
        const counterBefore1 = await orderBook.s_orderIdCounter();
        tx = await deployer.sendTransaction({ ...tx, accessList });
        const txReceipt = await tx.wait();
        await sleep(3000);
        const counterAfter1 = await orderBook.s_orderIdCounter();
        {
            const start = hre.ethers.BigNumber.from(counterBefore1).add(1);
            const end = hre.ethers.BigNumber.from(counterAfter1);
            for (let id = start; id.lte(end); id = id.add(1)) {
                orderIds.push(id);
            }
        }
        var currBalance = await deployer.getBalance();
        console.log(`After placing orders: ${n} : ${currBalance}`);
        var effectiveGasUsed = prevBalance.sub(currBalance).div(hre.ethers.utils.parseUnits("100", "gwei")); // need to check this
        console.log(`Placed ${2*n} orders: Gas used: ${effectiveGasUsed}`);
        
        gasCosts.results[`n_${n}`].initial_placement = {
            gas_used: effectiveGasUsed.toString(),
            description: `Place ${2*n} orders (${n} buy + ${n} sell) on empty orderbook`
        };
        prevBalance = currBalance;
        // 3. Cost of replacing 2n orders at 2n price points
        console.log(`\n2. Cost of replacing ${2*n} orders at ${2*n} price points`)
        const diffBuyPrices = Array.from({length: n}, (_, i) => 230000 - ((i + 1) * 100));
        const diffSellPrices = Array.from({length: n}, (_, i) => 230000 + ((i + 1) * 100));
        accessList = await buildAccessListForCancelAndPlace(
            orderBook,
            orderIds,
            diffBuyPrices,
            diffSellPrices,
            marginaccountaddress,
            deployer.address,
            usdcaddress,
            wethaddress,
            orderBookImpl,
            marginAccountImpl
        );
        tx = await orderBook.populateTransaction.batchUpdate(
            diffBuyPrices,
            Array(n).fill(10**8),
            diffSellPrices,
            Array(n).fill(10**8),
            orderIds,
            true // postOnly = true
        );
        const counterBefore2 = await orderBook.s_orderIdCounter();
        tx = await deployer.sendTransaction({ ...tx, accessList });
        await tx.wait();
        await sleep(3000);
        const counterAfter2 = await orderBook.s_orderIdCounter();
        var currBalance = await deployer.getBalance();
        console.log(`After replacing orders: ${n} : ${currBalance}`);
        var effectiveGasUsed = prevBalance.sub(currBalance).div(hre.ethers.utils.parseUnits("101", "gwei"));
        console.log(`Replaced ${2*n} orders at different price points: Gas used: ${effectiveGasUsed}`);
        prevBalance = currBalance;
        gasCosts.results[`n_${n}`].replace_at_new_prices = {
            gas_used: effectiveGasUsed.toString(),
            description: `Cancel ${2*n} orders and place ${2*n} new orders at different price levels`
        };

        // Update orderIds using counter delta
        {
            const newIds = [];
            const start = hre.ethers.BigNumber.from(counterBefore2).add(1);
            const end = hre.ethers.BigNumber.from(counterAfter2);
            for (let id = start; id.lte(end); id = id.add(1)) {
                newIds.push(id);
            }
            orderIds.splice(0, 2*n, ...newIds);
        }

        const secondBuyPrices = Array.from({length: n}, (_, i) => 230000 - ((i + 1) * 100));
        const secondSellPrices = Array.from({length: n}, (_, i) => 230000 + ((i + 1) * 100));
        accessList = await buildAccessListForPlacement(
            orderBook,
            secondBuyPrices,
            secondSellPrices,
            marginaccountaddress,
            deployer.address,
            usdcaddress,
            wethaddress
        );
        tx = await orderBook.populateTransaction.batchUpdate(
            secondBuyPrices,
            Array(n).fill(10**8),
            secondSellPrices,
            Array(n).fill(10**8),
            [],
            false
        );
        const counterBefore3 = await orderBook.s_orderIdCounter();
        tx = await deployer.sendTransaction({ ...tx, accessList });
        await tx.wait();
        await sleep(3000);
        const counterAfter3 = await orderBook.s_orderIdCounter();
        const secondSetIds = [];
        {
            const start = hre.ethers.BigNumber.from(counterBefore3).add(1);
            const end = hre.ethers.BigNumber.from(counterAfter3);
            for (let id = start; id.lte(end); id = id.add(1)) {
                secondSetIds.push(id);
            }
        }
        currBalance = await deployer.getBalance();
        prevBalance = currBalance;
        console.log("\n3. Cost of replacing 2n orders at price points with existing orders")

        // Now replace the second set: cancel those 2n and place another 2n
        const replaceBuyPrices = Array.from({length: n}, (_, i) => 230000 - ((i + 1) * 100));
        const replaceSellPrices = Array.from({length: n}, (_, i) => 230000 + ((i + 1) * 100));
        accessList = await buildAccessListForCancelAndPlace(
            orderBook,
            secondSetIds,
            replaceBuyPrices,
            replaceSellPrices,
            marginaccountaddress,
            deployer.address,
            usdcaddress,
            wethaddress,
            orderBookImpl,
            marginAccountImpl
        );
        tx = await orderBook.populateTransaction.batchUpdate(
            replaceBuyPrices,
            Array(n).fill(10**8),
            replaceSellPrices,
            Array(n).fill(10**8),
            secondSetIds,
            false
        );
        const counterBefore4 = await orderBook.s_orderIdCounter();
        tx = await deployer.sendTransaction({ ...tx, accessList });
        await tx.wait();
        await sleep(3000);
        const counterAfter4 = await orderBook.s_orderIdCounter();
        currBalance = await deployer.getBalance();
        effectiveGasUsed = prevBalance.sub(currBalance).div(hre.ethers.utils.parseUnits("101", "gwei"));
        prevBalance = currBalance;
        gasCosts.results[`n_${n}`].replace_at_existing_prices = {
            gas_used: effectiveGasUsed.toString(),
            description: `Cancel ${2*n} orders and place ${2*n} new orders at price levels that already have existing orders`
        };
        console.log(`Replace ${2*n} orders with existing orders: Gas used: ${effectiveGasUsed}`);

        // Wipe orderbook before proceeding: cancel pre-existing and newly placed replacement orders
        const replacedSecondIds = [];
        {
            const start = hre.ethers.BigNumber.from(counterBefore4).add(1);
            const end = hre.ethers.BigNumber.from(counterAfter4);
            for (let id = start; id.lte(end); id = id.add(1)) {
                replacedSecondIds.push(id);
            }
        }
        const wipeIds = orderIds.concat(replacedSecondIds);
        accessList = await buildAccessListForCancelOnly(
            orderBook,
            wipeIds,
            marginaccountaddress,
            deployer.address,
            usdcaddress,
            wethaddress
        );
        tx = await orderBook.populateTransaction.batchUpdate(
            [],
            [],
            [],
            [],
            wipeIds,
            false
        );
        tx = await deployer.sendTransaction({ ...tx, accessList });
        await tx.wait();
        currBalance = await deployer.getBalance();
        effectiveGasUsed = prevBalance.sub(currBalance).div(hre.ethers.utils.parseUnits("101", "gwei"));
        console.log(`Wiped ${2*n} orders: Gas used: ${effectiveGasUsed}`);
        gasCosts.results[`n_${n}`].cancel_all_orders = {
            gas_used: effectiveGasUsed.toString(),
            description: `Cancel all ${wipeIds.length} orders (cleanup)`
        };
        prevBalance = currBalance;
    }

    // Save results to file
    fs.writeFileSync("./scripts/gasAnalysis/gasTestResults.json", JSON.stringify(gasCosts, null, 2));
    console.log("\nBenchmark results saved to gasTestResults.json");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});