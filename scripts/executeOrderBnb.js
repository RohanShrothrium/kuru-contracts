const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const [owner] = await hre.ethers.getSigners();

    // send eth to executor
    await owner.sendTransaction({
        to: "0x4d91cf959c86888df1ed20877b27fa0c7bc08147",
        value: ethers.utils.parseEther("1.0"), // Sends exactly 1.0 ether
    });

    const bal = await hre.ethers.provider.getBalance("0x4d91cf959c86888df1ed20877b27fa0c7bc08147");
    console.log(bal)

    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: ["0x4d91cf959c86888df1ed20877b27fa0c7bc08147"],
    });

    const signer = await hre.ethers.getSigner("0x4d91cf959c86888df1ed20877b27fa0c7bc08147");

    const priceReporterContract = await hre.ethers.getContractAt("IPriceReporter", "0xe423BB0a8b925EABF625A8f36B468ab009a854e7", signer);
    var receipt = await priceReporterContract.postPriceAndExecuteOrders(
        [],
        [],
        1
    );
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
