const hre = require("hardhat");
const config = require("../config.json")

async function main() {
    const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
    const position = await abstractPositionContract.getPortfolioValue();

    console.log(`${position}`)
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
