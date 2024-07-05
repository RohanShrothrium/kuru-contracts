const hre = require("hardhat");
const fs = require('fs');

var configFileName = "devnet.config.json";

const args = process.argv.slice(2);
const devnetName = args[0];

if (devnetName !== "") {
    configFileName = `${devnetName}_${configFileName}`;
}

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("https://devnet1.monad.xyz/rpc/WbScX50z7Xsvsuk6UB1uMci8Ekee3PJqhBZ2RRx0xSjyqx9hjipbfMh60vr7a1gS");
    const deployerPvtKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    const userAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
    const takerAddress = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    const ERC20 = await hre.ethers.getContractFactory("MintableERC20", deployer);
    var tokenA = await ERC20.deploy("Token A", "TOKA");
    await tokenA.deployed();
    console.log("Token A deployed to:", tokenA.address);

    var tokenB = await ERC20.deploy("Token B", "TOKB");
    await tokenB.deployed();
    console.log("Token B deployed to:", tokenB.address);

    if(hre.ethers.BigNumber.from(tokenA.address).gt(hre.ethers.BigNumber.from(tokenB.address))) {
        const temp = tokenA;
        tokenA = tokenB;
        tokenB = temp;
    }

    // Fund the shark account with a substantial amount of tokens
    await (await tokenA.mint(userAddress, hre.ethers.utils.parseEther("1000000"))).wait();
    await (await tokenA.mint(takerAddress, hre.ethers.utils.parseEther("1000000"))).wait();
    console.log("Shark WBTC balance:", (await tokenA.balanceOf(takerAddress)).toString());

    await (await tokenB.mint(userAddress, hre.ethers.utils.parseEther("1000000"))).wait();
    await (await tokenB.mint(takerAddress, hre.ethers.utils.parseEther("1000000"))).wait();
    console.log("Shark USDC balance:", (await tokenB.balanceOf(userAddress)).toString());

    // Your existing deployment logic here, modified to use the deployed token addresses
    // Replace wbtcAddress and usdcAddress with the addresses of the deployed contracts
    var wbtcAddress = tokenA.address;
    var usdcAddress = tokenB.address;
    // deploy Router Contract
    const Router = await hre.ethers.getContractFactory("Router", deployer);
    const router = await Router.deploy();
    await router.deployed();

    const routerAddress = router.address;
    console.log("Router deployed to:", routerAddress);



    // deploy Margin Account Contract
    const MarginAccount = await hre.ethers.getContractFactory("MarginAccount", deployer);
    const marginAccount = await MarginAccount.deploy(routerAddress, userAddress);
    await marginAccount.deployed();

    const marginAccountAddress = marginAccount.address;
    console.log("MarginAccountAddress deployed to:", marginAccountAddress);

    //Deploy OrderBook implementation
    const OrderBook = await hre.ethers.getContractFactory("OrderBook", deployer);
    const implementation = await OrderBook.deploy();
    await implementation.deployed();
    console.log("Orderbook implementation deployed at: ", implementation.address);

    // initialize router contract
    const routerInitTx = await router.initialize(userAddress, marginAccountAddress, implementation.address);
    await routerInitTx.wait();
    console.log("Router Initialized with owner:", userAddress);

    const config = {
        "usdcAddress": usdcAddress,
        "wbtcAddress": wbtcAddress,
        "routerAddress": routerAddress,
        "marginAccountAddress": marginAccountAddress,
    }
    fs.writeFileSync(configFileName, JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});