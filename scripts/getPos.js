const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
    var posVal = await abstractPositionContract.getPosition(
        "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        0
    )

    console.log(posVal)

    var portValue = await abstractPositionContract.portfolioHealthFactor()

    console.log(portValue)
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
