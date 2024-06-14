const { ethers } = require("hardhat");
const config = require("../config.json");

async function main() {
    const orderBook = await ethers.getContractAt("OrderBook", config.cranklessOrderBookAddress);

  // Call the function
  const data = await orderBook.getL2Book();

  // Decode the data
  let offset = 66;
  const blockNumber = parseInt('0x' + data.slice(2, 66), 16);
  let bids = {};
  while (offset < data.length) {
    const price = parseInt('0x' + data.slice(offset, offset + 64), 16);
    offset += 64;  // Each uint24 is padded to 64 bytes
    if (price == 0) {
        break
    }
    const size = parseInt('0x' + data.slice(offset, offset + 64), 16);
    offset += 64; // Each uint96 is padded to 64 bytes
    bids[price.toString()] = size.toString();
  }

  let asks = {};

  while (offset < data.length) {
    const price = parseInt('0x' + data.slice(offset, offset + 64), 16);
    offset += 64;  // Each uint24 is padded to 64 bytes
    const size = parseInt('0x' + data.slice(offset, offset + 64), 16);
    offset += 64; // Each uint96 is padded to 64 bytes
    asks[price.toString()] = size.toString();
  }

  const result = {bids, asks, blockNumber}

  // Log the JSON object
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
