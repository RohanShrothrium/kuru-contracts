const { ethers } = require("hardhat");
const config = require("../config.json");

async function main() {
	const orderBook = await ethers.getContractAt(
		"OrderBook",
		config.cranklessOrderBookAddress
	);
	const userAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";

	// Call the function
	const data = await orderBook.getActiveOrdersForAddress(userAddress);

	// Decode the data
	let offset = 66;
	const blockNumber = parseInt("0x" + data.slice(2, 66), 16);
	let orderIds = [];
	while (offset < data.length) {
		const orderId = parseInt("0x" + data.slice(offset, offset + 64), 16);
		offset += 64; // Each uint24 is padded to 64 bytes
		orderIds.push(orderId);
	}

    console.log({blockNumber, orderIds});
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
