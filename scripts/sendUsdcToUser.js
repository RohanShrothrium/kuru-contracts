const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: ["0x62383739D68Dd0F844103Db8dFb05a7EdED5BBE6"],
    });

    const signer = await hre.ethers.getSigner("0x62383739D68Dd0F844103Db8dFb05a7EdED5BBE6");

    const usdcContract = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.usdcAddress, signer);

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
