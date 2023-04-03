const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);
    const position = await lendingContract.takeLoanOnPosition(
        config.wethAddress,
        true,
        "9000000000000000000",
    );
    hre.ethers.BigNumber

    ans = await position.wait();

    console.log(JSON.stringify(ans))
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
