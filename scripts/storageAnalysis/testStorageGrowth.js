const hre = require("hardhat");
const fs = require("fs");
const zlib = require("zlib");
const path = require("path");

// Small sleep helper
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Directory for all dump and output files
const DUMP_DIR = path.join(__dirname, 'dump');

// Ensure dump directory exists
if (!fs.existsSync(DUMP_DIR)) {
    fs.mkdirSync(DUMP_DIR, { recursive: true });
}

/**
 * Parse contract data from a saved anvil dump state file
 * Handles large files by parsing in chunks to extract only the contract we need
 * @param {string} dumpFile - Path to the dump file
 * @param {string} contractAddress - The contract address to extract
 * @returns {Object} - The contract's storage data
 */
function parseContractFromDumpFile(dumpFile, contractAddress) {
    console.log(`  Loading dump file: ${dumpFile}`);
    
    const normalizedAddress = contractAddress.toLowerCase();
    const fileSize = fs.statSync(dumpFile).size;
    console.log(`  File size: ${(fileSize / 1024 / 1024).toFixed(2)} MB`);
    
    // Read just the first 200 bytes to check format
    const fd = fs.openSync(dumpFile, 'r');
    const headerBuffer = Buffer.alloc(200);
    fs.readSync(fd, headerBuffer, 0, 200, 0);
    const header = headerBuffer.toString('utf8');
    
    if (header.includes('"jsonrpc"') || header.includes('"result"')) {
        // It's a JSON-RPC response (compressed), need to decompress first
        console.log(`  Error: File appears to be in compressed JSON-RPC format.`);
        console.log(`  This should have been decompressed already. Something went wrong.`);
        fs.closeSync(fd);
        throw new Error('File is in compressed format, expected decompressed JSON');
    }
    
    // For raw decompressed JSON files (very large), read in chunks
    console.log(`  Parsing large decompressed JSON file in chunks...`);
    const CHUNK_SIZE = 10 * 1024 * 1024; // 10MB chunks
    const searchStr = `"${normalizedAddress}"`;
    let position = 0;
    let buffer = Buffer.alloc(CHUNK_SIZE + 100000); // Extra for overlap
    
    while (position < fileSize) {
        const bytesRead = fs.readSync(fd, buffer, 0, CHUNK_SIZE, position);
        if (bytesRead === 0) break;
        
        const chunk = buffer.toString('utf8', 0, bytesRead);
        const index = chunk.indexOf(searchStr);
        
        if (index !== -1) {
            console.log(`  Found contract at position ${position + index}`);
            
            // Read a larger section around the match
            const extractStart = Math.max(0, position + index - 1000);
            const extractSize = 50 * 1024 * 1024; // 50MB
            const extractBuffer = Buffer.alloc(extractSize);
            const extracted = fs.readSync(fd, extractBuffer, 0, extractSize, extractStart);
            const extractedText = extractBuffer.toString('utf8', 0, extracted);
            
            // Find the contract object
            const relativeIndex = extractedText.indexOf(searchStr);
            const objectStart = extractedText.indexOf('{', relativeIndex);
            
            let depth = 0;
            let objectEnd = objectStart;
            for (let i = objectStart; i < extractedText.length; i++) {
                if (extractedText[i] === '{') depth++;
                else if (extractedText[i] === '}') {
                    depth--;
                    if (depth === 0) {
                        objectEnd = i + 1;
                        break;
                    }
                }
            }
            
            fs.closeSync(fd);
            return JSON.parse(extractedText.substring(objectStart, objectEnd));
        }
        
        position += bytesRead - 10000; // Overlap
        if (bytesRead < CHUNK_SIZE) break;
    }
    
    fs.closeSync(fd);
    throw new Error(`Contract ${contractAddress} not found in dump file`);
}

/**
 * Get all non-zero storage slots for a contract from a state object
 * @param {Object} state - The decompressed state object (or null to fetch from provider)
 * @param {string} contractAddress - The contract address
 * @param {Object} provider - Optional: The ethers provider (for live query if state is null)
 * @param {string} dumpFile - Optional: path to saved dump file instead of live query
 * @returns {Object} - Map of storage slots to their values (only non-zero values)
 */
async function getContractStorage(state, contractAddress, provider = null, dumpFile = null) {
    console.log(`Extracting storage for ${contractAddress}...`);
    
    try {
        let accountData = null;
        
        // If dumpFile provided, parse contract data directly from file (memory efficient)
        if (dumpFile) {
            console.log(`  Reading from dump file...`);
            accountData = parseContractFromDumpFile(dumpFile, contractAddress);
        }
        // If state object provided, extract from it
        else if (state) {
            const normalizedAddress = contractAddress.toLowerCase();
            if (state.accounts && state.accounts[normalizedAddress]) {
                accountData = state.accounts[normalizedAddress];
            }
        }
        // Otherwise fetch live from provider
        else if (provider) {
            console.log(`  Calling anvil_dumpState RPC...`);
            const compressed = await provider.send("anvil_dumpState", []);
            const hexData = compressed.startsWith('0x') ? compressed.slice(2) : compressed;
            const compressedBuffer = Buffer.from(hexData, 'hex');
            const decompressedBuffer = zlib.gunzipSync(compressedBuffer);
            
            // Search in chunks to avoid string length limits
            const normalizedAddress = contractAddress.toLowerCase();
            const searchStr = `"${normalizedAddress}"`;
            const CHUNK_SIZE = 10 * 1024 * 1024; // 10MB chunks
            let position = 0;
            let found = false;
            
            while (position < decompressedBuffer.length) {
                const chunkSize = Math.min(CHUNK_SIZE, decompressedBuffer.length - position);
                const chunk = decompressedBuffer.toString('utf8', position, position + chunkSize);
                const index = chunk.indexOf(searchStr);
                
                if (index !== -1) {
                    console.log(`  Found contract at position ${position + index}`);
                    
                    // Extract a large section around the match
                    const extractStart = Math.max(0, position + index - 1000);
                    const extractEnd = Math.min(decompressedBuffer.length, position + index + 50 * 1024 * 1024);
                    const extractedText = decompressedBuffer.toString('utf8', extractStart, extractEnd);
                    
                    // Find the contract object
                    const relativeIndex = extractedText.indexOf(searchStr);
                    const objectStart = extractedText.indexOf('{', relativeIndex);
                    
                    let depth = 0;
                    let objectEnd = objectStart;
                    for (let i = objectStart; i < extractedText.length; i++) {
                        if (extractedText[i] === '{') depth++;
                        else if (extractedText[i] === '}') {
                            depth--;
                            if (depth === 0) {
                                objectEnd = i + 1;
                                break;
                            }
                        }
                    }
                    
                    accountData = JSON.parse(extractedText.substring(objectStart, objectEnd));
                    found = true;
                    break;
                }
                
                position += chunkSize - 10000; // Overlap to catch patterns at chunk boundaries
                if (chunkSize < CHUNK_SIZE) break;
            }
            
            if (!found) {
                console.log(`  Contract ${contractAddress} not found in state dump`);
            }
        }
        
        // Extract storage and filter out zero values
        const contractStorage = {};
        
        if (accountData && accountData.storage) {
            for (const [slot, value] of Object.entries(accountData.storage)) {
                // Check if value is non-zero
                const isZero = value === "0x0" || 
                               value === "0x0000000000000000000000000000000000000000000000000000000000000000" ||
                               BigInt(value) === 0n;
                
                if (!isZero) {
                    contractStorage[slot] = value;
                }
            }
            
            console.log(`  Found ${Object.keys(contractStorage).length} non-zero storage slots\n`);
        } else {
            console.log(`  No storage found for contract ${contractAddress}\n`);
        }
        
        return contractStorage;
    } catch (error) {
        console.error(`Error extracting storage:`, error.message);
        throw error;
    }
}

/**
 * Compare two storage snapshots and report differences
 */
function compareStorage(beforeStorage, afterStorage) {
    const beforeKeys = Object.keys(beforeStorage);
    const afterKeys = Object.keys(afterStorage);
    
    const newSlots = afterKeys.filter(k => !beforeKeys.includes(k));
    const removedSlots = beforeKeys.filter(k => !afterKeys.includes(k));
    const changedSlots = afterKeys.filter(k => 
        beforeKeys.includes(k) && beforeStorage[k] !== afterStorage[k]
    );
    
    console.log("\n" + "=".repeat(60));
    console.log("STORAGE COMPARISON RESULTS");
    console.log("=".repeat(60));
    console.log(`Storage slots BEFORE: ${beforeKeys.length}`);
    console.log(`Storage slots AFTER:  ${afterKeys.length}`);
    console.log(`Net change:           ${afterKeys.length - beforeKeys.length}`);
    console.log(`New slots added:      ${newSlots.length}`);
    console.log(`Slots removed:        ${removedSlots.length}`);
    console.log(`Slots changed:        ${changedSlots.length}`);
    console.log("=".repeat(60) + "\n");
    
    return {
        beforeCount: beforeKeys.length,
        afterCount: afterKeys.length,
        netChange: afterKeys.length - beforeKeys.length,
        newSlots: newSlots.length,
        removedSlots: removedSlots.length,
        changedSlots: changedSlots.length,
        newSlotsDetails: newSlots.slice(0, 10), // First 10 for inspection
        removedSlotsDetails: removedSlots.slice(0, 10)
    };
}

async function main() {
    // Configuration - FILL IN YOUR VALUES
    // Read configuration from config.json
    const config = JSON.parse(fs.readFileSync('./scripts/storageAnalysis/config.json', 'utf8'));
    const marketAddress = config.OrderBook; // OrderBook proxy address
    const wethAddress = config.BaseToken; // Base token address
    const usdcAddress = config.QuoteToken; // Quote token address
    const marginAccountAddress = config.MarginAccount; // MarginAccount address
    const rpcUrl = 'http://127.0.0.1:8545'; // YOUR RPC ENDPOINT HERE
    
    // Validate configuration
    if (!rpcUrl || !marketAddress || !wethAddress || !usdcAddress || !marginAccountAddress) {
        console.error("\n❌ ERROR: Please fill in all configuration values at the top of the script:");
        console.error("  - rpcUrl");
        console.error("  - marketAddress");
        console.error("  - wethAddress");
        console.error("  - usdcAddress");
        console.error("  - marginAccountAddress\n");
        process.exit(1);
    }
    
    const currentProvider = new hre.ethers.providers.JsonRpcProvider(rpcUrl);
    
    // Create 4 maker accounts
    const makers = [];
    const makerPrivateKeys = [
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // Maker 1
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // Maker 2  
        "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // Maker 3
        "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // Maker 4
    ];
    
    for (let i = 0; i < 4; i++) {
        makers.push(new hre.ethers.Wallet(makerPrivateKeys[i], currentProvider));
    }
    
    console.log("=".repeat(60));
    console.log("STORAGE GROWTH TEST: 100K ORDERS");
    console.log("=".repeat(60));
    console.log(`Makers: ${makers.length}`);
    console.log(`Target orders: ~100,000 (${Math.floor(100000 / makers.length)} per maker)`);
    console.log(`Batch size: 100 orders (50 buy + 50 sell)`);
    console.log("=".repeat(60) + "\n");
    
    // Get contract instances
    const orderBook = await hre.ethers.getContractAt("OrderBook", marketAddress, makers[0]);
    const marginAccount = await hre.ethers.getContractAt("MarginAccount", marginAccountAddress, makers[0]);
    const usdcContract = await hre.ethers.getContractAt("IERC20Metadata", usdcAddress, makers[0]);
    const wethContract = await hre.ethers.getContractAt("IERC20Metadata", wethAddress, makers[0]);
    
    // Fund and setup all makers
    console.log("\n📝 Setting up makers with token approvals and deposits...");
    const depositAmount = hre.ethers.utils.parseEther("1000000"); // Large amount for many orders
    
    for (let i = 0; i < makers.length; i++) {
        const maker = makers[i];
        console.log(`\nMaker ${i + 1} (${maker.address}):`);
        
        // Approve and deposit USDC
        console.log("  - Approving USDC...");
        let tx = await usdcContract.connect(maker).approve(marginAccountAddress, depositAmount);
        await tx.wait();
        
        console.log("  - Depositing USDC...");
        tx = await marginAccount.connect(maker).deposit(maker.address, usdcAddress, depositAmount);
        await tx.wait();
        
        // Approve and deposit WETH
        console.log("  - Approving WETH...");
        tx = await wethContract.connect(maker).approve(marginAccountAddress, depositAmount);
        await tx.wait();
        
        console.log("  - Depositing WETH...");
        tx = await marginAccount.connect(maker).deposit(maker.address, wethAddress, depositAmount);
        await tx.wait();
        
        console.log("  ✅ Maker setup complete");
    }
    
    // Capture storage BEFORE placing orders
    console.log("\n📸 Capturing storage state BEFORE placing orders...");
    const blockBefore = await currentProvider.getBlock("latest");
    
    // Dump and save full decompressed state to file
    console.log("  Calling anvil_dumpState...");
    const compressedStateBefore = await currentProvider.send("anvil_dumpState", []);
    
    console.log("  Decompressing state...");
    const hexData = compressedStateBefore.startsWith('0x') ? compressedStateBefore.slice(2) : compressedStateBefore;
    const compressedBuffer = Buffer.from(hexData, 'hex');
    const decompressedBuffer = zlib.gunzipSync(compressedBuffer);
    
    const dumpBeforeFile = path.join(DUMP_DIR, "dumpStateBefore.json");
    console.log(`  Writing decompressed state to ${dumpBeforeFile}...`);
    console.log(`  Decompressed size: ${(decompressedBuffer.length / 1024 / 1024).toFixed(2)} MB`);
    fs.writeFileSync(dumpBeforeFile, decompressedBuffer);
    console.log("  ✅ Decompressed dump state saved");
    
    // Extract contract storage (filtering non-zero values) from the saved file
    const storageBefore = await getContractStorage(null, marketAddress, null, dumpBeforeFile);
    
    // Save initial storage to file
    const storageBeforeFile = path.join(DUMP_DIR, "storage_before.json");
    fs.writeFileSync(storageBeforeFile, JSON.stringify({
        block: blockBefore.number,
        slotCount: Object.keys(storageBefore).length,
        storage: storageBefore
    }, null, 2));
    console.log(`✅ Initial storage saved to ${storageBeforeFile}`);
    
    // Place orders from all makers
    const ordersPerMaker = 25000; // 25k orders per maker = 100k total
    const batchSize = 50; // 10 buy + 10 sell = 20 orders per batch
    const batchesPerMaker = Math.ceil(ordersPerMaker / (batchSize * 2));
    const midPrice = 200000;
    
    console.log("\n" + "=".repeat(60));
    console.log("PLACING ORDERS");
    console.log("=".repeat(60));
    
    const allOrderIds = {}; // Track order IDs per maker
    
    for (let makerIdx = 0; makerIdx < makers.length; makerIdx++) {
        const maker = makers[makerIdx];
        allOrderIds[makerIdx] = [];
        
        console.log(`\n🔨 Maker ${makerIdx + 1} placing ${ordersPerMaker} orders in ${batchesPerMaker} batches...`);
        
        for (let batchIdx = 0; batchIdx < batchesPerMaker; batchIdx++) {
            // Generate unique prices for this batch to avoid matching
            // Each maker gets a different price range
            const makerOffset = makerIdx * 10000;
            const batchOffset = batchIdx * 100;
            
            const buyPrices = Array.from({length: batchSize}, (_, i) => 
                midPrice - makerOffset - batchOffset - ((i + 1) * 10)
            );
            const sellPrices = Array.from({length: batchSize}, (_, i) => 
                midPrice + makerOffset + batchOffset + ((i + 1) * 10)
            );
            const sizes = Array(batchSize).fill(10**8);
            
            try {
                // Capture counter before
                const counterBefore = await orderBook.s_orderIdCounter();
                
                // Place orders
                const tx = await orderBook.connect(maker).batchUpdate(
                    buyPrices,
                    sizes,
                    sellPrices,
                    sizes,
                    [], // No cancellations
                    true // postOnly
                );
                await tx.wait();
                
                // Capture counter after and track order IDs
                const counterAfter = await orderBook.s_orderIdCounter();
                const start = hre.ethers.BigNumber.from(counterBefore).add(1);
                const end = hre.ethers.BigNumber.from(counterAfter);
                for (let id = start; id.lte(end); id = id.add(1)) {
                    allOrderIds[makerIdx].push(id);
                }
                
                // Progress update every 100 batches
                if ((batchIdx + 1) % 100 === 0 || batchIdx === batchesPerMaker - 1) {
                    const progress = ((batchIdx + 1) / batchesPerMaker * 100).toFixed(1);
                    const ordersPlaced = allOrderIds[makerIdx].length;
                    console.log(`  Progress: ${progress}% (${ordersPlaced} orders placed)`);
                }
                
                // Small delay every 50 batches to avoid overwhelming the RPC
                if ((batchIdx + 1) % 50 === 0) {
                    await sleep(1000);
                }
            } catch (error) {
                console.error(`  ❌ Error at batch ${batchIdx + 1}:`, error.message);
                // Continue with next batch
            }
        }
        
        console.log(`  ✅ Maker ${makerIdx + 1} complete: ${allOrderIds[makerIdx].length} orders placed`);
    }
    
    // Calculate total orders placed
    const totalOrdersPlaced = Object.values(allOrderIds).reduce((sum, ids) => sum + ids.length, 0);
    console.log("\n" + "=".repeat(60));
    console.log(`✅ TOTAL ORDERS PLACED: ${totalOrdersPlaced}`);
    console.log("=".repeat(60));
    
    // Capture storage AFTER placing orders (optional - for reference)
    console.log("\n📸 Capturing storage state AFTER placing orders...");
    const blockAfterPlacement = await currentProvider.getBlock("latest");
    
    // Get state and extract contract storage (no need to save full dump for checkpoint)
    const storageAfterPlacement = await getContractStorage(null, marketAddress, currentProvider);
    
    const storageAfterPlacementFile = path.join(DUMP_DIR, "storage_after_placement.json");
    fs.writeFileSync(storageAfterPlacementFile, JSON.stringify({
        block: blockAfterPlacement.number,
        slotCount: Object.keys(storageAfterPlacement).length,
        storage: storageAfterPlacement
    }, null, 2));
    console.log(`✅ Post-placement storage saved to ${storageAfterPlacementFile}`);
    
    // Now cancel ALL orders
    console.log("\n" + "=".repeat(60));
    console.log("CANCELLING ALL ORDERS");
    console.log("=".repeat(60));
    
    const cancelBatchSize = 100; // Cancel 100 orders per transaction
    
    for (let makerIdx = 0; makerIdx < makers.length; makerIdx++) {
        const maker = makers[makerIdx];
        const orderIds = allOrderIds[makerIdx];
        const cancelBatches = Math.ceil(orderIds.length / cancelBatchSize);
        
        console.log(`\n🧹 Maker ${makerIdx + 1} cancelling ${orderIds.length} orders in ${cancelBatches} batches...`);
        
        for (let batchIdx = 0; batchIdx < cancelBatches; batchIdx++) {
            const start = batchIdx * cancelBatchSize;
            const end = Math.min(start + cancelBatchSize, orderIds.length);
            const batchOrderIds = orderIds.slice(start, end);
            
            try {
                const tx = await orderBook.connect(maker).batchUpdate(
                    [], // No buy orders
                    [], // No buy sizes
                    [], // No sell orders
                    [], // No sell sizes
                    batchOrderIds, // Cancel these orders
                    false
                );
                await tx.wait();
                
                // Progress update every 50 batches
                if ((batchIdx + 1) % 50 === 0 || batchIdx === cancelBatches - 1) {
                    const progress = ((batchIdx + 1) / cancelBatches * 100).toFixed(1);
                    const ordersCancelled = Math.min(end, orderIds.length);
                    console.log(`  Progress: ${progress}% (${ordersCancelled} orders cancelled)`);
                }
                
                // Small delay every 25 batches
                if ((batchIdx + 1) % 25 === 0) {
                    await sleep(1000);
                }
            } catch (error) {
                console.error(`  ❌ Error at cancel batch ${batchIdx + 1}:`, error.message);
                // Continue with next batch
            }
        }
        
        console.log(`  ✅ Maker ${makerIdx + 1} cancellations complete`);
    }
    
    console.log("\n" + "=".repeat(60));
    console.log("✅ ALL ORDERS CANCELLED");
    console.log("=".repeat(60));
    
    // Capture storage AFTER cancelling all orders
    console.log("\n📸 Capturing storage state AFTER cancelling all orders...");
    const blockAfter = await currentProvider.getBlock("latest");
    
    // Dump and save full decompressed state to file
    console.log("  Calling anvil_dumpState...");
    const compressedStateAfter = await currentProvider.send("anvil_dumpState", []);
    
    console.log("  Decompressing state...");
    const hexDataAfter = compressedStateAfter.startsWith('0x') ? compressedStateAfter.slice(2) : compressedStateAfter;
    const compressedBufferAfter = Buffer.from(hexDataAfter, 'hex');
    const decompressedBufferAfter = zlib.gunzipSync(compressedBufferAfter);
    
    const dumpAfterFile = path.join(DUMP_DIR, "dumpStateAfter.json");
    console.log(`  Writing decompressed state to ${dumpAfterFile}...`);
    console.log(`  Decompressed size: ${(decompressedBufferAfter.length / 1024 / 1024).toFixed(2)} MB`);
    fs.writeFileSync(dumpAfterFile, decompressedBufferAfter);
    console.log("  ✅ Decompressed dump state saved");
    
    // Extract contract storage (filtering non-zero values) from the saved file
    const storageAfter = await getContractStorage(null, marketAddress, null, dumpAfterFile);
    
    const storageAfterFile = path.join(DUMP_DIR, "storage_after.json");
    fs.writeFileSync(storageAfterFile, JSON.stringify({
        block: blockAfter.number,
        slotCount: Object.keys(storageAfter).length,
        storage: storageAfter
    }, null, 2));
    console.log(`✅ Final storage saved to ${storageAfterFile}`);
    
    // Compare storage
    const comparison = compareStorage(storageBefore, storageAfter);
    
    // Save comparison results
    const results = {
        testConfig: {
            totalMakers: makers.length,
            ordersPerMaker: ordersPerMaker,
            totalOrdersPlaced: totalOrdersPlaced,
            batchSize: batchSize * 2,
            cancelBatchSize: cancelBatchSize
        },
        blocks: {
            before: blockBefore.number,
            afterPlacement: blockAfterPlacement.number,
            afterCancellation: blockAfter.number
        },
        storageComparison: comparison,
        timestamp: new Date().toISOString()
    };
    
    const resultsFile = path.join(DUMP_DIR, "storage_growth_test_results.json");
    fs.writeFileSync(resultsFile, JSON.stringify(results, null, 2));
    
    console.log("\n✅ All results saved to scripts/storageAnalysis/dump/");
    console.log("   - dumpStateBefore.json (full decompressed Anvil state)");
    console.log("   - dumpStateAfter.json (full decompressed Anvil state)");
    console.log("   - storage_before.json (contract storage only)");
    console.log("   - storage_after_placement.json (contract storage only)");
    console.log("   - storage_after.json (contract storage only)");
    console.log("   - storage_growth_test_results.json");
    
    // Final summary
    console.log("\n" + "=".repeat(60));
    console.log("TEST SUMMARY");
    console.log("=".repeat(60));
    console.log(`Total orders placed and cancelled: ${totalOrdersPlaced}`);
    console.log(`Storage slots before:              ${comparison.beforeCount}`);
    console.log(`Storage slots after:               ${comparison.afterCount}`);
    console.log(`Net storage growth:                ${comparison.netChange}`);
    console.log(`Storage growth per order:          ${(comparison.netChange / totalOrdersPlaced).toFixed(6)}`);
    console.log("=".repeat(60));
    
    if (Math.abs(comparison.netChange) < 10) {
        console.log("\n✅ SUCCESS: Negligible storage growth demonstrated!");
        console.log("   The contract shows minimal state growth after placing and cancelling orders.");
    } else {
        console.log("\n⚠️  WARNING: Significant storage growth detected.");
        console.log(`   Net change: ${comparison.netChange} slots`);
    }
}

main().catch((error) => {
    console.error("\n❌ Fatal error:", error);
    process.exitCode = 1;
});

