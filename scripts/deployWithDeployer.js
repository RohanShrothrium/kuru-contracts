const hre = require("hardhat");
const fs = require('fs');

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("http://localhost:8545");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    const userAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
    const takerAddress = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    const ERC20 = await hre.ethers.getContractFactory("MintableERC20", deployer);
    const wbtc = await ERC20.deploy("Wrapped Bitcoin", "WBTC");
    await wbtc.deployed();
    console.log("WBTC deployed to:", wbtc.address);

    const usdc = await ERC20.deploy("USD Coin", "USDC");
    await usdc.deployed();
    console.log("USDC deployed to:", usdc.address);

    // Fund the shark account with a substantial amount of tokens
    await (await wbtc.mint(takerAddress, hre.ethers.utils.parseEther("1000000"))).wait();
    console.log("Shark WBTC balance:", (await wbtc.balanceOf(takerAddress)).toString());

    await (await usdc.mint(userAddress, hre.ethers.utils.parseEther("1000000"))).wait();
    console.log("Shark USDC balance:", (await usdc.balanceOf(userAddress)).toString());

    // Your existing deployment logic here, modified to use the deployed token addresses
    // Replace wbtcAddress and usdcAddress with the addresses of the deployed contracts
    const wbtcAddress = wbtc.address;
    const usdcAddress = usdc.address;

    // deploy Router Contract
    const Router = await hre.ethers.getContractFactory("Router", deployer);
    const router = await Router.deploy();
    await router.deployed();

    const routerAddress = router.address;
    console.log("Router deployed to:", routerAddress);

    // initialize router contract
    const routerInitTx = await router.initialize(userAddress);
    await routerInitTx.wait();
    console.log("Router Initialized with owner:", userAddress);

    // deploy Margin Account Contract
    const MarginAccount = await hre.ethers.getContractFactory("MarginAccount", deployer);
    const marginAccount = await MarginAccount.deploy(routerAddress);
    await marginAccount.deployed();

    const marginAccountAddress = marginAccount.address;
    console.log("MarginAccountAddress deployed to:", marginAccountAddress);

    // set margin account address for router
    const setMarginTx = await router.setMarginAccount(marginAccountAddress);
    await setMarginTx.wait();
    console.log("Router set with margin account address:", marginAccountAddress);

    const config = {
        "usdcAddress": usdcAddress,
        "wbtcAddress": wbtcAddress,
        "routerAddress": routerAddress,
        "marginAccountAddress": marginAccountAddress,
    }
    fs.writeFileSync("config.json", JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});