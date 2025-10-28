const fs = require('fs');
const zlib = require('zlib');

/**
 * Extract a specific contract's data from a large Anvil dump state file
 * 
 * Usage:
 *   node extractContract.js <dumpFile> <contractAddress> [outputFile]
 * 
 * Examples:
 *   node extractContract.js dump/dumpStateBefore.json 0x7028AAEFfB76603716c6DD5859e1f6Fd5613Cd5E
 *   node extractContract.js dump/dumpStateAfter.json 0x7028AAEFfB76603716c6DD5859e1f6Fd5613Cd5E dump/contract_data.json
 */

function parseContractFromDumpFile(dumpFile, contractAddress) {
    console.log(`Loading dump file: ${dumpFile}`);
    
    const normalizedAddress = contractAddress.toLowerCase();
    const fileSize = fs.statSync(dumpFile).size;
    console.log(`File size: ${(fileSize / 1024 / 1024).toFixed(2)} MB`);
    
    // Read just the first 200 bytes to check format
    const fd = fs.openSync(dumpFile, 'r');
    const headerBuffer = Buffer.alloc(200);
    fs.readSync(fd, headerBuffer, 0, 200, 0);
    const header = headerBuffer.toString('utf8');
    
    if (header.includes('"jsonrpc"') || header.includes('"result"')) {
        // It's a JSON-RPC response (compressed), need to decompress first
        console.log('Detected compressed JSON-RPC format, decompressing...');
        fs.closeSync(fd);
        
        const content = fs.readFileSync(dumpFile, 'utf8');
        const parsed = JSON.parse(content);
        const hexData = parsed.result.slice(2);
        const compressedBuffer = Buffer.from(hexData, 'hex');
        const decompressedBuffer = zlib.gunzipSync(compressedBuffer);
        
        console.log(`Decompressed size: ${(decompressedBuffer.length / 1024 / 1024).toFixed(2)} MB`);
        
        // Search in decompressed buffer in chunks
        const searchStr = `"${normalizedAddress}"`;
        const CHUNK_SIZE = 10 * 1024 * 1024;
        let position = 0;
        
        while (position < decompressedBuffer.length) {
            const chunkSize = Math.min(CHUNK_SIZE, decompressedBuffer.length - position);
            const chunk = decompressedBuffer.toString('utf8', position, position + chunkSize);
            const index = chunk.indexOf(searchStr);
            
            if (index !== -1) {
                console.log(`Found contract at position ${position + index}`);
                
                const extractStart = Math.max(0, position + index - 1000);
                const extractEnd = Math.min(decompressedBuffer.length, position + index + 50 * 1024 * 1024);
                const extractedText = decompressedBuffer.toString('utf8', extractStart, extractEnd);
                
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
                
                return JSON.parse(extractedText.substring(objectStart, objectEnd));
            }
            
            position += chunkSize - 10000;
            if (chunkSize < CHUNK_SIZE) break;
        }
        
        throw new Error(`Contract ${contractAddress} not found in dump`);
    }
    
    // For raw decompressed JSON files (very large), read in chunks
    console.log('Parsing large decompressed JSON file in chunks...');
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
            console.log(`Found contract at position ${position + index}`);
            
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

function main() {
    console.log('='.repeat(60));
    console.log('EXTRACT CONTRACT FROM ANVIL DUMP STATE');
    console.log('='.repeat(60));
    
    const args = process.argv.slice(2);
    
    if (args.length < 2) {
        console.log('\n❌ Usage: node extractContract.js <dumpFile> <contractAddress> [outputFile]');
        console.log('\nExamples:');
        console.log('  node extractContract.js dump/dumpStateBefore.json 0x7028AAEFfB76603716c6DD5859e1f6Fd5613Cd5E');
        console.log('  node extractContract.js dump/dumpStateAfter.json 0x1234...5678 dump/my_contract.json');
        console.log('\nThe extracted contract data will be saved to a JSON file.');
        process.exit(1);
    }
    
    const dumpFile = args[0];
    const contractAddress = args[1];
    const outputFile = args[2] || `contract_${contractAddress.slice(0, 10)}_extracted.json`;
    
    console.log(`\nDump file:        ${dumpFile}`);
    console.log(`Contract address: ${contractAddress}`);
    console.log(`Output file:      ${outputFile}`);
    console.log('='.repeat(60) + '\n');
    
    // Check if dump file exists
    if (!fs.existsSync(dumpFile)) {
        console.error(`❌ Error: Dump file '${dumpFile}' not found`);
        process.exit(1);
    }
    
    try {
        // Extract contract data
        const contractData = parseContractFromDumpFile(dumpFile, contractAddress);
        
        console.log('\n✅ Contract found!');
        console.log('\n' + '='.repeat(60));
        console.log('CONTRACT DATA SUMMARY');
        console.log('='.repeat(60));
        
        if (contractData.balance !== undefined) {
            console.log(`Balance: ${contractData.balance}`);
        }
        
        if (contractData.nonce !== undefined) {
            console.log(`Nonce: ${contractData.nonce}`);
        }
        
        if (contractData.code !== undefined) {
            const codeLength = contractData.code.length;
            const codeBytes = Math.floor((codeLength - 2) / 2);
            console.log(`Code: ${codeBytes} bytes`);
        }
        
        if (contractData.storage) {
            const totalSlots = Object.keys(contractData.storage).length;
            
            // Count non-zero slots
            let nonZeroSlots = 0;
            for (const [slot, value] of Object.entries(contractData.storage)) {
                const isZero = value === "0x0" || 
                               value === "0x0000000000000000000000000000000000000000000000000000000000000000" ||
                               BigInt(value) === 0n;
                if (!isZero) nonZeroSlots++;
            }
            
            console.log(`Storage slots (total): ${totalSlots.toLocaleString()}`);
            console.log(`Storage slots (non-zero): ${nonZeroSlots.toLocaleString()}`);
            console.log(`Storage size: ${(totalSlots * 32 / 1024).toFixed(2)} KB`);
        }
        
        // Save to file
        console.log('\n' + '='.repeat(60));
        console.log(`Saving to ${outputFile}...`);
        
        const output = {
            contractAddress: contractAddress,
            extractedAt: new Date().toISOString(),
            sourceDumpFile: dumpFile,
            data: contractData
        };
        
        fs.writeFileSync(outputFile, JSON.stringify(output, null, 2));
        const fileSize = fs.statSync(outputFile).size;
        
        console.log(`✅ Successfully saved!`);
        console.log(`File size: ${(fileSize / 1024).toFixed(2)} KB`);
        console.log('='.repeat(60));
        
    } catch (error) {
        console.error(`\n❌ Error: ${error.message}`);
        process.exit(1);
    }
}

if (require.main === module) {
    main();
}

module.exports = { parseContractFromDumpFile };

