const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const wethAddress = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"

    const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);
    const loan = await lendingContract.existingLoanOnPosition(
        "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        wethAddress,
        true
    );

    console.log(`the loan on your position is: ${loan}`);

    const balance = await lendingContract.getReserve();

    console.log(`available liquidity: ${balance}`);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
