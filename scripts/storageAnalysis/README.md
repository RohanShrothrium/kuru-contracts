# Storage Analysis Scripts

Tools for analyzing storage growth in Kuru contracts using Anvil state dumps.

## Prerequisites

- A running Anvil node (required for state dumps)
- Foundry installed
- Node.js and npm/yarn installed

## Deployment & Setup

### Step 1: Configure Deployment Settings

Edit `deploy-recipes/config/Config.s.sol` to set the correct RPC URL and deployer address:

```solidity
string rpcUrl = "http://127.0.0.1:8545";  // Your Anvil node URL

function getDeployer() public returns (address) {
    return address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);  // Your deployer address
}
```

### Step 2: Deploy Core Contracts

Start your Anvil node in a separate terminal:
```bash
anvil
```

Deploy the core Kuru contracts using Foundry:
```bash
forge script deploy-recipes/Deploy-Contracts.s.sol \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  -vvvvvv \
  --broadcast
```

**Note:** The private key above is the default Anvil wallet (first account).

### Step 3: Update Configuration

After deployment, copy the `Router` and `MarginAccount` addresses from `deploy-recipes/deployments.json` into `scripts/storageAnalysis/config.json`:

```json
{
    "Router": "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
    "MarginAccount": "0x0165878A594ca255338adfa4d48449f69242Eb8F",
    "OrderBook": "",
    "BaseToken": "",
    "QuoteToken": ""
}
```

### Step 4: Deploy Test Market

Run the deployment script to create a test market with ETH/USDC tokens:
```bash
cd scripts/storageAnalysis
node deployEthUsdc.js
```

This script will:
- Deploy test WETH and USDC tokens
- Distribute tokens to test accounts
- Create an ETH-USDC market
- Automatically update `config.json` with the OrderBook, BaseToken, and QuoteToken addresses

### Step 5: Run Storage Analysis

Now you're ready to run the storage growth test:
```bash
node testStorageGrowth.js
```

## Scripts Reference

### 1. `testStorageGrowth.js` - Main Storage Growth Test

Tests storage growth by placing and canceling orders, capturing state before and after.

**Usage:**
```bash
cd scripts/storageAnalysis
node testStorageGrowth.js
```

**Prerequisites:**
- Complete deployment steps 1-4 above
- Anvil node must be running

**Output Files (all saved to `dump/` directory):**
- `dump/dumpStateBefore.json` - Full Anvil state before test (⚠️ 500+ MB, cannot open directly)
- `dump/dumpStateAfter.json` - Full Anvil state after test (⚠️ 500+ MB, cannot open directly)
- `dump/storage_before.json` - Contract storage only (✅ readable)
- `dump/storage_after.json` - Contract storage only (✅ readable)
- `dump/storage_after_placement.json` - Mid-test checkpoint (✅ readable)
- `dump/storage_growth_test_results.json` - Comparison summary (✅ readable)

### 2. `extractContract.js` - Extract Contract from Large Dumps

Extracts a specific contract's data from the large dump files.

**Usage:**
```bash
cd scripts/storageAnalysis
node extractContract.js <dumpFile> <contractAddress> [outputFile]
```

**Examples:**
```bash
# Extract to default filename
node extractContract.js dump/dumpStateBefore.json 0x7028AAEFfB76603716c6DD5859e1f6Fd5613Cd5E

# Extract to custom filename
node extractContract.js dump/dumpStateAfter.json 0x1234...5678 my_contract.json
```

**Output:**
Creates a small JSON file with just that contract's data (balance, nonce, code, storage).

### 3. `deployEthUsdc.js` - Deploy Test Tokens & Market

Deploys test ETH and USDC tokens and creates a market.

**Usage:**
```bash
cd scripts/storageAnalysis
node deployEthUsdc.js
```

**Prerequisites:**
- `config.json` must have valid `Router` and `MarginAccount` addresses

## Understanding Storage Analysis

### Non-Zero Storage Slots
The scripts count only **non-zero** storage slots because:
- Empty slots (value = 0x0) don't contribute to actual storage usage
- Only slots with data impact state growth
- This gives accurate measurement of storage bloat

### File Sizes
- **Full dumps** (500+ MB): Contain entire blockchain state (all accounts, all contracts)
  - Use `extractContract.js` to extract specific contracts
  - Cannot be opened in text editors (too large)
  
- **Contract-only** files (< 50 MB): Contain only your contract's storage
  - Can be opened and inspected directly
  - Good for manual review

## Quick Start (Complete Workflow)

1. **Start Anvil:**
   ```bash
   anvil
   ```

2. **Deploy contracts (in a new terminal):**
   ```bash
   forge script deploy-recipes/Deploy-Contracts.s.sol \
     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
     -vvvvvv --broadcast
   ```

3. **Update config with Router and MarginAccount addresses from `deployments.json`**

4. **Deploy test market:**
   ```bash
   cd scripts/storageAnalysis
   node deployEthUsdc.js
   ```

5. **Run storage analysis:**
   ```bash
   node testStorageGrowth.js
   ```

6. **Check the results:**
   ```bash
   cat dump/storage_growth_test_results.json
   ```

7. **Extract specific contract if needed:**
   ```bash
   node extractContract.js dump/dumpStateBefore.json 0xYourAddress
   ```

## Tips

- The `storage_growth_test_results.json` file contains the comparison summary - start here!
- Use `storage_before.json` and `storage_after.json` for manual inspection
- Only use `extractContract.js` if you need to analyze contracts not captured in the main test
- Large dump files are archival - they're there if you need to re-analyze later

