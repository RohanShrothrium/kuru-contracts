const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: ["0x59a661f1c909ca13ba3e9114bfdd81e5a420705d"],
    });

    const signer = await hre.ethers.getSigner("0x59a661f1c909ca13ba3e9114bfdd81e5a420705d");

    const usdcContract = await hre.ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", signer);

    var receipt = await usdcContract.transfer(
        config.userAccount,
        1000000000,
    );

    const resp = await receipt.wait()

    console.log(resp);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
