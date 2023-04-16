const hre = require("hardhat");
const config = require("../config.json")

async function main() {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [config.abstractPositionAddress],
    });

    const signer = await hre.ethers.getSigner(config.abstractPositionAddress);

    const positionRouterContract = await hre.ethers.getContractAt("PositionRouter", config.positionRouterAddress, signer);
    const positionKey = await positionRouterContract.getRequestKey(
        config.abstractPositionAddress,
        3
    );
    console.log(positionKey);

    var receipt = await positionRouterContract.executeIncreasePosition(
        positionKey,
        config.abstractPositionAddress,
    );

    const resp = await receipt.wait();

    console.log(JSON.stringify(resp.events));
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
