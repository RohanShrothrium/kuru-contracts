const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const bnbPoolContract = await hre.ethers.getContractAt("ILevelOracle", "0x04Db83667F5d59FF61fA6BbBD894824B233b3693");
    var tokenData = await bnbPoolContract.getPrice(
        "0x2170Ed0880ac9A755fd29B2688956BD959F933F8",
        true
    );

    console.log(tokenData)
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
