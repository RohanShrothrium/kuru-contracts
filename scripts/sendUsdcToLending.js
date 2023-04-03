const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: ["0xe21bea5aaa9c65e065de171440179f0a55b1a814"],
    });

    const signer = await hre.ethers.getSigner("0xe21bea5aaa9c65e065de171440179f0a55b1a814");

    const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress, signer);

    const usdcContract = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.usdcAddress, signer);

    var receipt = await usdcContract.transfer(
        config.lendingContractAddress,
        10000000,
    );

    const resp = await receipt.wait()

    console.log(resp);
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
