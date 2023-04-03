const hre = require("hardhat");
const config = require("../config.json")

async function main() {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [config.gmxAdmin],
    });

    const gmxSigner = await hre.ethers.getSigner(config.gmxAdmin);

    const positionRouterContractForAdmin = await hre.ethers.getContractAt("PositionRouter", config.positionRouterAddress, gmxSigner);

    var receipt = await positionRouterContractForAdmin.setDelayValues(0, 0, 1800);

    await receipt.wait();

    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [config.abstractPositionAddress],
    });

    const signer = await hre.ethers.getSigner(config.abstractPositionAddress);

    const positionRouterContract = await hre.ethers.getContractAt("PositionRouter", config.positionRouterAddress, signer);
    var receipt = await positionRouterContract.executeIncreasePosition(
        config.positionKey,
        config.abstractPositionAddress,
    );

    const resp = await receipt.wait();

    console.log(JSON.stringify(resp.events));
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
