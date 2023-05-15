const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);

    var pk = await abstractPositionContract._getPositionKey(
        config.abstractPositionAddress,
        "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        0
    )

    console.log(pk)

    const poolC = await hre.ethers.getContractAt("IOrderManager", "0xf584A17dF21Afd9de84F47842ECEAF6042b1Bb5b");
    var position = await poolC.orders(
        62037
    )

    const bnbLevelContract = await hre.ethers.getContractAt("ILevelOracle", config.bnbLevelOracleAddress);
    var tokenPrice = await bnbLevelContract.getPrice(
        "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
        true
    );

    console.log(position)
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
