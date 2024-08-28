const hre = require("hardhat");

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("https://eth-sepolia.api.onfinality.io/public");

    const deployerPvtKey = "e33eae6a73c0c8bb2be71c86d72dc35b6b573468592165cbb24cc66f961c1c2e";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    const args = process.argv.slice(2);
    const tokenName = args[0];
    const tokenSymbol = args[1];
    const userAddress = args[2];
    const totalSupplyArg = args[3];

    // Deploy the ERC20 token
    const ERC20 = await hre.ethers.getContractFactory("KuruERC20", deployer);
    const totalSupply = hre.ethers.utils.parseEther(totalSupplyArg);

    const token = await ERC20.deploy(tokenName, tokenSymbol, totalSupply, userAddress);
    await token.deployed();

    console.log(`${tokenName} (${tokenSymbol}) deployed to:`, token.address);
    console.log(`Total Supply:`, totalSupply.toString());
    console.log(`Tokens minted to:`, userAddress);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
