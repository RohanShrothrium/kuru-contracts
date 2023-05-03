const hre = require("hardhat");
const config = require("../config.json")

async function main() {
    const bnbLevelContract = await hre.ethers.getContractAt("ILevelOracle", config.bnbLevelOracleAddress);
    var tokenPrice = await bnbLevelContract.getPrice(
        config.wethAddress,
        true
    );

    const bnbOrderManagerContract = await hre.ethers.getContractAt("IOrderManager", config.bnbOrderManagerAddress);
    const nextOrderId = await bnbOrderManagerContract.nextOrderId();

    console.log(nextOrderId.toString());

    const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
    var receipt = await abstractPositionContract.callIncreasePlaceOrder(
        0,
        config.wethAddress,
        config.wethAddress,
        tokenPrice.mul(2000).toString(),
        "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
        hre.ethers.utils.parseEther("1").toString(),
        tokenPrice.mul(hre.ethers.utils.parseEther("1")).toString(),
        hre.ethers.utils.parseEther("1").toString(),
        { value: hre.ethers.utils.parseEther(`1.01`) }
    );
    var resp = await receipt.wait();

    // create one more cause level weird af
    receipt = await abstractPositionContract.callIncreasePlaceOrder(
        0,
        config.wethAddress,
        config.wethAddress,
        tokenPrice.mul(2000).toString(),
        "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",
        hre.ethers.utils.parseEther("1").toString(),
        tokenPrice.mul(hre.ethers.utils.parseEther("1")).toString(),
        hre.ethers.utils.parseEther("1").toString(),
        { value: hre.ethers.utils.parseEther(`1.01`) }
    );
    resp = await receipt.wait();

    const [owner] = await hre.ethers.getSigners();

    // send eth to executor
    await owner.sendTransaction({
        to: config.bnbExecutorAddress,
        value: ethers.utils.parseEther("1.0"), // Sends exactly 1.0 ether
    });

    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [config.bnbExecutorAddress],
    });

    var signer = await hre.ethers.getSigner(config.bnbExecutorAddress);

    const priceReporterContract = await hre.ethers.getContractAt("IPriceReporter", "0xe423BB0a8b925EABF625A8f36B468ab009a854e7", signer);
    receipt = await priceReporterContract.postPriceAndExecuteOrders(
        [],
        [],
        [nextOrderId.toString(), nextOrderId.add(1).toString()]
    );

    resp = await receipt.wait();

    console.log(resp)
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
