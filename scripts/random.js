const { ethers } = require("hardhat");
const config = require("../config.json");

async function main() {
	const orderbook = await ethers.getContractAt(
		"OrderBook",
		config.cranklessOrderBookAddress
	);
	console.log(await orderbook.bestBidAsk());
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
