const hre = require("hardhat");
const config = require("../../config.json");

exports.GetReserve = async () => {
    try {
        const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);
        const balance = await lendingContract.getReserve();

        return {
            success: true,
            balance: `${balance}`
        }
    } catch (error) {
        return { success: false, error };
    }
};

exports.GetEthAcceptablePrice = async (isLong) => {
    try {
        const vaultContract = await hre.ethers.getContractAt("Vault", config.vaultAddress);
        if (isLong) {
            const maxPrice = await vaultContract.getMaxPrice(
                config.wethAddress
            );
            return {
                success: true,
                maxPrice: `${maxPrice}`
            }
        } else {
            const minPrice = await vaultContract.getMinPrice(
                config.wethAddress
            );
            return {
                success: true,
                minPrice: `${minPrice}`
            }
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetUSDCBalance = async () => {
    try {
        const usdcContract = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.usdcAddress);
        var balance = await usdcContract.balanceOf(config.userAccount);

        return {
            success: true,
            balance: `${balance.mul("1000000000000000000000000")}`
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.GetExistingLoan = async () => {
    try {
        const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);
        const existingLoan = await lendingContract.existingLoanOnPortfolio(config.userAccount);

        return {
            success: true,
            existingLoan: `${existingLoan}`
        }
    } catch (error) {
        return { success: false, error };
    }
}

exports.ProvideLiquidity = async (amount) => {
    try {
        const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);

        const receipt = await lendingContract.takeLoanOnPosition(amount);
        await receipt.wait();

        return { success: true };
    } catch (error) {
        return { success: false, error };
    }
};

exports.TakeLoanOnEthPosition = async (loanAmount) => {
    try {
        const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);

        const receipt = await lendingContract.takeLoanOnPosition(
            loanAmount,
        );
        await receipt.wait();

        return { success: true };
    } catch (error) {
        return { success: false, error };
    }
};

exports.PaybackLoanOnEthPosition = async (loanAmount) => {
    try {
        const usdcContract = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", config.usdcAddress);

        var receipt = await usdcContract.approve(
            config.lendingContractAddress,
            loanAmount,
        );

        await receipt.wait();

        const lendingContract = await hre.ethers.getContractAt("LendingContract", config.lendingContractAddress);

        receipt = await lendingContract.paybackLoan(
            loanAmount,
        );
        await receipt.wait();

        return { success: true };
    } catch (error) {
        return { success: false, error };
    }
};
