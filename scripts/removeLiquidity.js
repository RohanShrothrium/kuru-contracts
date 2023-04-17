const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    // const usdcContract = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.usdcAddress);

    // var receipt = await usdcContract.approve(
    //     config.klpManagerContractAddress,
    //     hre.ethers.BigNumber.from("100").mul(10**6),
    // );

    const klpManagerContract = await hre.ethers.getContractAt("KlpManager", config.klpManagerContractAddress);
    var receipt = await klpManagerContract.removeLiquidity(
        config.usdcAddress,
        hre.ethers.utils.parseEther("10").mul(10**12)
    );

    await receipt.wait();
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
