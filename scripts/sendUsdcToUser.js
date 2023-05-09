const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: ["0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa"],
    });

    const signer = await hre.ethers.getSigner("0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa");

    const usdcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.usdcAddress, signer);

    var receipt = await usdcContract.transfer(
        config.userAccount,
        hre.ethers.utils.parseEther("1000"),
    );

    const resp = await receipt.wait()

    console.log(resp);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
