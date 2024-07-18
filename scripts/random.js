const { ethers } = require("hardhat");
const config = require("../config.json");

async function main() {
	const hlp2 = await ethers.getContractAt(
		"HyperliquidityStrategy",
		"0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e"
	);
	const tx = await hlp2.extend(20);
	await tx.wait();
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
