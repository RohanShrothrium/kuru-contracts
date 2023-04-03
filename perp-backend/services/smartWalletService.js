const hre = require("hardhat");
const config = require("../../config.json");

const zeroContract = "0x0000000000000000000000000000000000000000"
const referralCode = "0x0000000000000000000000000000000000000000000000000000000000000000";

exports.GetPosition = async (indexToken, isLong) => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const position = await abstractPositionContract.getPosition(
            indexToken,
            isLong,
        );

        return {
            size: `${position[0]}`,
            collateral: `${position[1]}`,
            averagePrice: `${position[2]}`,
            maxLoan: `${position[3]}`,
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetPositions = async () => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const positions = await abstractPositionContract.getPositios();

        var positionsResp = [];
        for (let i = 0; i < positions.length; i++) {
            var position = await this.GetPosition(positions[i][0], positions[i][1]);
            position.indexToken = positions[i][0];
            position.isLong = positions[i][1];
            positionsResp.push(position)
        }

        return {
            success: true,
            positionsResp
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetPortfolioValue = async () => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const value = await abstractPositionContract.getPortfolioValue();

        return {
            success: true,
            value: `${value}`
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetPortfolioValueWithMargin = async () => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const value = await abstractPositionContract.getPortfolioValueWithMargin();

        return {
            success: true,
            value: `${value}`
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetHealthFactor = async () => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const value = await abstractPositionContract.portfolioHealthFactor();

        return {
            success: true,
            value: `${value}`
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.CreateIncreasePosition = async (collateral, leverage, ethAcceptablePrice, isLong) => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        var receipt = await abstractPositionContract.callCreateIncreasePosition(
            [config.wethAddress],
            config.wethAddress,
            0,
            hre.ethers.BigNumber.from(ethAcceptablePrice).mul(hre.ethers.utils.parseEther(`${collateral}`)).mul(leverage).div(hre.ethers.utils.parseEther("1")),
            isLong,
            ethAcceptablePrice,
            200000000000000,
            referralCode,
            zeroContract,
            { value: hre.ethers.utils.parseEther(`${collateral}`) }
        );
    
        var response = await receipt.wait();

        return {
            success: true,
            response
        }
    } catch (error) {
        return { success: false, error };
    }
};

exports.CreateDecreasePosition = async (collateralDelta, sizeDelta, ethAcceptablePrice, isLong) => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        var receipt = await abstractPositionContract.callCreateDecreasePosition(
            [config.wethAddress],
            config.wethAddress,
            collateralDelta,
            sizeDelta,
            isLong,
            config.userAccount,
            ethAcceptablePrice,
            0,
            200000000000000,
            true,
            zeroContract,
            { value: "200000000000000" }
        );
    
        var response = await receipt.wait();

        return {
            success: true,
            response
        }
    } catch (error) {
        return { success: false, error };
    }
};
