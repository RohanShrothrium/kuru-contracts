const hre = require("hardhat");
const { ethers } = hre;
const fs = require("fs");
const path = require("path");

async function main() {
    const configJson = JSON.parse(fs.readFileSync('./scripts/gasAnalysis/config.json', 'utf8'));
    // Inputs: RPC URL and Private Key
    const provider = new ethers.providers.JsonRpcProvider(configJson.rpcUrl);
    const deployer = new ethers.Wallet(configJson.deployerPrivateKey, provider);
    console.log("Deployer address:", deployer.address);

    // Factories (connected to external signer)
    const KuruForwarder = await ethers.getContractFactory("KuruForwarder", deployer);
    const Router = await ethers.getContractFactory("Router", deployer);
    const MarginAccount = await ethers.getContractFactory("MarginAccount", deployer);
    const OrderBook = await ethers.getContractFactory("OrderBook", deployer);
    const KuruAMMVault = await ethers.getContractFactory("KuruAMMVault", deployer);
    const ERC1967Proxy = await ethers.getContractFactory("ERC1967Proxy", deployer);
    const MonadDeployer = await ethers.getContractFactory("MonadDeployer", deployer);
    const KuruUtils = await ethers.getContractFactory("KuruUtils", deployer);

    // Allowed interfaces for KuruForwarder
    const allowedInterfaces = [
        OrderBook.interface.getSighash("addBuyOrder"),
        OrderBook.interface.getSighash("addSellOrder"),
        OrderBook.interface.getSighash("placeAndExecuteMarketBuy"),
        OrderBook.interface.getSighash("placeAndExecuteMarketSell"),
        MarginAccount.interface.getSighash("deposit"),
        MarginAccount.interface.getSighash("withdraw"),
    ];

    // Deploy KuruForwarder implementation
    const kuruForwarderImplTx = await KuruForwarder.deploy();
    const kuruForwarderImpl = await kuruForwarderImplTx.deployed();
    console.log("KuruForwarder Implementation deployed to:", kuruForwarderImpl.address);

    // Deploy KuruForwarder proxy
    const kuruForwarderProxyTx = await ERC1967Proxy.deploy(
        kuruForwarderImpl.address,
        "0x"
    );
    const kuruForwarderProxy = await kuruForwarderProxyTx.deployed();
    const kuruForwarder = await ethers.getContractAt("KuruForwarder", kuruForwarderProxy.address, deployer);

    console.log("KuruForwarder proxy deployed to:", kuruForwarder.address);

    // KuruForwarder initialize
    let tx = await kuruForwarder.initialize(deployer.address, allowedInterfaces);
    await tx.wait();
    console.log("KuruForwarder initialized.");

    // Deploy Router implementation
    const routerImplTx = await Router.deploy();
    const routerImpl = await routerImplTx.deployed();
    console.log("Router implementation deployed to:", routerImpl.address);

    // Deploy Router proxy
    const routerProxyTx = await ERC1967Proxy.deploy(routerImpl.address, "0x");
    const routerProxy = await routerProxyTx.deployed();
    const router = await ethers.getContractAt("Router", routerProxy.address, deployer);
    console.log("Router proxy deployed to:", router.address);

    // Deploy MarginAccount implementation
    const marginAccountImplTx = await MarginAccount.deploy();
    const marginAccountImpl = await marginAccountImplTx.deployed();
    console.log("MarginAccount implementation deployed to:", marginAccountImpl.address);

    // Deploy MarginAccount proxy
    const marginAccountProxyTx = await ERC1967Proxy.deploy(marginAccountImpl.address, "0x");
    const marginAccountProxy = await marginAccountProxyTx.deployed();
    const marginAccount = await ethers.getContractAt("MarginAccount", marginAccountProxy.address, deployer);
    console.log("MarginAccount proxy deployed to:", marginAccount.address);

    // MarginAccount initialize
    tx = await marginAccount.initialize(deployer.address, router.address, router.address, kuruForwarder.address);
    await tx.wait();
    console.log("MarginAccount initialized.");

    // Deploy OrderBook implementation
    const orderBookImplTx = await OrderBook.deploy();
    const orderBookImpl = await orderBookImplTx.deployed();
    console.log("OrderBook implementation deployed to:", orderBookImpl.address);

    // Deploy KuruAMMVault implementation
    const kuruAmmVaultImplTx = await KuruAMMVault.deploy();
    const kuruAmmVaultImpl = await kuruAmmVaultImplTx.deployed();
    console.log("KuruAMMVault implementation deployed to:", kuruAmmVaultImpl.address);

    // Router initialize
    tx = await router.initialize(
        deployer.address,
        marginAccount.address,
        orderBookImpl.address,
        kuruAmmVaultImpl.address,
        kuruForwarder.address
    );
    await tx.wait();
    console.log("Router initialized.");

    // Expect a revert on second initialize
    try {
        await router.initialize(
            deployer.address,
            marginAccount.address,
            orderBookImpl.address,
            kuruAmmVaultImpl.address,
            kuruForwarder.address
        );
        await router.initialize(
            deployer.address,
            marginAccount.address,
            orderBookImpl.address,
            kuruAmmVaultImpl.address,
            kuruForwarder.address
        );
        console.warn("WARNING: Router initialize did not revert on second call (expected revert).");
    } catch (e) {
        console.log("Router second initialize reverted as expected.");
    }

    // Ownership check
    const owner = await router.owner();
    if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
        throw new Error("Router owner mismatch after initialization");
    }
    console.log("Router owner verified:", owner);

    // Deploy MonadDeployer
    const monadDeployerTx = await MonadDeployer.deploy(
        router.address,
        deployer.address,
        marginAccount.address,
        deployer.address,
        100,
        0
    );
    const monadDeployer = await monadDeployerTx.deployed();
    console.log("MonadDeployer deployed to:", monadDeployer.address);

    // Deploy KuruUtils
    const kuruUtilsTx = await KuruUtils.deploy();
    const kuruUtils = await kuruUtilsTx.deployed();
    console.log("KuruUtils deployed to:", kuruUtils.address);

    // Save deployment addresses to config.json
    const config = {
        deployer: deployer.address,
        kuruForwarderImpl: kuruForwarderImpl.address,
        kuruForwarder: kuruForwarder.address,
        routerImpl: routerImpl.address,
        router: router.address,
        marginAccountImpl: marginAccountImpl.address,
        marginAccount: marginAccount.address,
        orderBookImpl: orderBookImpl.address,
        kuruAmmVaultImpl: kuruAmmVaultImpl.address,
        monadDeployer: monadDeployer.address,
        kuruUtils: kuruUtils.address,
    };
    
    const configPath = path.join(__dirname, "config.json");
    
    // Read existing config and only update keys that already exist
    const existingConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const updatedConfig = { ...existingConfig };
    
    // Only update keys that already exist in the config
    Object.keys(config).forEach(key => {
        if (existingConfig.hasOwnProperty(key)) {
            updatedConfig[key] = config[key];
        }
    });
    
    fs.writeFileSync(configPath, JSON.stringify(updatedConfig, null, 4));

    console.log("\nDeployment complete:");
    console.log(config);
    console.log(`\nConfiguration saved to: ${configPath}`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
