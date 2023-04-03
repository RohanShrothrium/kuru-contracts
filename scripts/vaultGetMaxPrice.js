const hre = require("hardhat");

async function main() {
    const vaultContractAddress = "0x489ee077994B6658eAfA855C308275EAd8097C4A";
    const wethAddress = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"

    const vaultContract = await hre.ethers.getContractAt("Vault", vaultContractAddress);
    const maxPrice = await vaultContract.getMinPrice(
        wethAddress
    );

    console.log(maxPrice);
    console.log(maxPrice.mul(hre.ethers.utils.parseEther("1.8")).div(hre.ethers.utils.parseEther("1")))
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
