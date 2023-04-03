const hre = require("hardhat");
const config = require("../../config.json");

exports.CreateSmartWallet = async (isLong) => {
    try {
        // create abstract position for user
        const factoryContract = await hre.ethers.getContractAt("FactoryContract", config.factoryContractAddress);
        var receipt = await factoryContract.createAbstractPosition();
        await receipt.wait();

        return {
            success: true,
        }
    } catch (error) {
        return { success: false, error };
    }
};
