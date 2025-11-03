# Gas Analysis Scripts

This directory contains scripts for analyzing gas usage of the Kuru protocol contracts.

## Setup Instructions

1. **Configure connection details**: Fill in the `rpcUrl` and `deployerPrivateKey` fields in `config.json` with your network RPC URL and private key.

2. **Compile contracts**: Run the following command to compile all contracts:
   ```bash
   npx hardhat compile --force
   ```

3. **Deploy contracts**: Execute the deployment script:
   ```bash
   node deployContractsSet.js
   ```

4. **Deploy test tokens and create market**: Deploy ETH and USDC tokens and create a trading market:
   ```bash
   node deployEthUsdc.js
   ```

5. **Run gas analysis**: Execute the gas test script:
   ```bash
   node runGasTest.js
   ```

## Files

- `config.json` - Configuration file containing contract addresses and connection details
- `deployContractsSet.js` - Script to deploy the core Kuru protocol contracts (Router, MarginAccount, OrderBook, etc.)
- `deployEthUsdc.js` - Script to deploy test WETH and USDC tokens and create a trading market
- `runGasTest.js` - Main gas analysis script that measures gas usage for batch order operations with different order counts

