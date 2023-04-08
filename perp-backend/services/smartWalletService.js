const hre = require("hardhat");
const config = require("../../config.json");

const zeroContract = "0x0000000000000000000000000000000000000000"
const referralCode = "0x0000000000000000000000000000000000000000000000000000000000000000";

exports.GetPosition = async (indexToken, collateralToken, isLong) => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const position = await abstractPositionContract.getPosition(
            indexToken,
            collateralToken,
            isLong,
        );

        const [size, collateral, averagePrice, entryFundingRate, lastIncreasedTime] = position;

        console.log(size, collateral, averagePrice, lastIncreasedTime);
        var positionValue;
        if (collateral == 0) {
            positionValue = 0;
        } else {
            positionValue = await abstractPositionContract.getPositionValue(
                indexToken,
                isLong,
                `${collateral}`,
                `${size}`,
                `${averagePrice}`,
                `${lastIncreasedTime}`
            );
        }

        return {
            size,
            collateral,
            averagePrice,
            positionValue,
            entryFundingRate,
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetPositions = async () => {
    try {
        const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", config.abstractPositionAddress);
        const positions = await abstractPositionContract.getPositions();
        console.log(positions)

        var positionsResp = [];
        for (let i = 0; i < positions.length; i++) {
            const [indexToken, collateralToken, isLong] = positions[i];
            var position = await this.GetPosition(indexToken, collateralToken, isLong);
            position.indexToken = indexToken;
            position.isLong = isLong;
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
