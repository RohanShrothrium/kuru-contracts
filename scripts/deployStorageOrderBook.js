const hre = require("hardhat");
const { ethers, upgrades } = require("hardhat");
const fs = require('fs');

function Enum(...options) {
    return Object.fromEntries(options.map((key, i) => [key, hre.ethers.BigNumber.from(i)]));
}

async function main() {
    // contract addresses
    const wbtcDecimals = 18;
    const usdcDecimals = 18;

    const _sizePrecision = 10**10;
    const _pricePrecision = 100;
    const _tickSize = 1;
    const _spread = 100;
    const _minSize = 10**2;
    const _maxSize = 10**12;
    const _takerFeeBps = 25;
    const _makerFeeBps = 20;
    const [deployer, taker] = await hre.ethers.getSigners();
    const userAddress = deployer.address;
    const takerAddress = taker.address;

    const ERC20 = await hre.ethers.getContractFactory("KuruERC20");
    const wbtc = await ERC20.deploy("Wrapped Bitcoin", "WBTC", hre.ethers.utils.parseEther("20000000"), userAddress);
    await wbtc.deployed();
    console.log("WBTC deployed to:", wbtc.address);

    const usdc = await ERC20.deploy("USD Coin", "USDC", hre.ethers.utils.parseEther("20000000"), userAddress);
    await usdc.deployed();
    console.log("USDC deployed to:", usdc.address);

    // Transfer tokens to fund the taker account
    await wbtc.transfer(takerAddress, hre.ethers.utils.parseEther("10000000"));
    await usdc.transfer(takerAddress, hre.ethers.utils.parseEther("10000000"));
    console.log("Taker WBTC balance:", (await wbtc.balanceOf(takerAddress)).toString());
    console.log("Taker USDC balance:", (await usdc.balanceOf(takerAddress)).toString());
    console.log("User WBTC balance:", (await wbtc.balanceOf(userAddress)).toString());
    console.log("User USDC balance:", (await usdc.balanceOf(userAddress)).toString());

    // Your existing deployment logic here, modified to use the deployed token addresses
    // Replace wbtcAddress and usdcAddress with the addresses of the deployed contracts
    var wbtcAddress = wbtc.address;
    var usdcAddress = usdc.address;

    // deploy KuruForwarder Contract
    const MarginAccount = await hre.ethers.getContractFactory("MarginAccount");
    const KuruForwarder = await hre.ethers.getContractFactory("KuruForwarder");
    const Proxy = await hre.ethers.getContractFactory("ERC1967Proxy");
    const Router = await hre.ethers.getContractFactory("Router");
    const CranklessOrderBook = await hre.ethers.getContractFactory("OrderBook");
    const KuruAMMVault = await hre.ethers.getContractFactory("KuruAMMVault");
    const allowedInterfaces = [
        CranklessOrderBook.interface.getSighash('addBuyOrder'),
        CranklessOrderBook.interface.getSighash('addSellOrder'),
        CranklessOrderBook.interface.getSighash('placeAndExecuteMarketBuy'),
        CranklessOrderBook.interface.getSighash('placeAndExecuteMarketSell'),
        MarginAccount.interface.getSighash('deposit'),
        MarginAccount.interface.getSighash('withdraw'),
    ];
    const kuruForwarderImpl = await KuruForwarder.deploy();
    await kuruForwarderImpl.deployed();
    const kuruForwarderProxy = await Proxy.deploy(kuruForwarderImpl.address, "0x");
    await kuruForwarderProxy.deployed();
    const kuruForwarder = await hre.ethers.getContractAt("KuruForwarder", kuruForwarderProxy.address, deployer);
    const initializeKuruForwarderTx = await kuruForwarder.initialize(userAddress, allowedInterfaces);
    await initializeKuruForwarderTx.wait();
    console.log("KuruForwarder deployed to:", kuruForwarder.address);

    // deploy Router Contract
    const routerImpl = await Router.deploy();
    await routerImpl.deployed();
    const proxy = await Proxy.deploy(routerImpl.address, "0x");
    await proxy.deployed();

    const router = await hre.ethers.getContractAt("Router", proxy.address, deployer);

    const routerAddress = proxy.address;
    console.log("Router deployed to:", routerAddress);

    // deploy Margin Account Contract
    const marginAccountImpl = await MarginAccount.deploy();
    await marginAccountImpl.deployed();
    const marginAccountProxy = await Proxy.deploy(marginAccountImpl.address, "0x");
    await marginAccountProxy.deployed();
    const marginAccount = await hre.ethers.getContractAt("MarginAccount", marginAccountProxy.address, deployer);
    const initializeMarginAccountTx = await marginAccount.initialize(userAddress, routerAddress, userAddress, kuruForwarder.address);
    await initializeMarginAccountTx.wait();
    const marginAccountAddress = marginAccountProxy.address;
    console.log("MarginAccountAddress deployed to:", marginAccountAddress);

    if(hre.ethers.BigNumber.from(wbtcAddress).gt(hre.ethers.BigNumber.from(usdcAddress))) {
        const temp = wbtcAddress;
        wbtcAddress = usdcAddress;
        usdcAddress = temp;
    }
    // deploy CranklessOrderBook contract
    const implementation = await CranklessOrderBook.deploy();
    await implementation.deployed();
    const kuruAmmVaultImpl = await KuruAMMVault.deploy();
    await kuruAmmVaultImpl.deployed();
    // Initialize Router
    const initializeRouterTx = await router.initialize(userAddress, marginAccountAddress, implementation.address, kuruAmmVaultImpl.address, kuruForwarder.address);    
    await initializeRouterTx.wait();
    console.log("Router initialized with \n Admin :", userAddress, "\nMargin Account: ", marginAccountAddress, "\nImplementation:", implementation.address, "\nKuruForwarder:", kuruForwarder.address);
    
    const cranklessOrderBookAddress = await router.callStatic.deployProxy(Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE, wbtcAddress, usdcAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps, _makerFeeBps, _spread);
    const deployProxyTx = await router.deployProxy(Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE, wbtcAddress, usdcAddress, _sizePrecision, _pricePrecision, _tickSize, _minSize, _maxSize, _takerFeeBps, _makerFeeBps, _spread);
    await deployProxyTx.wait();

    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);

    const market = await hre.ethers.getContractAt(
		"OrderBook",
		cranklessOrderBookAddress
	);

    const vaultParamsData = await market.getVaultParams();
    const kuruAmmVaultAddress = vaultParamsData[0];
    console.log("KuruAMMVault deployed to:", kuruAmmVaultAddress);

    var tx = await wbtc.approve(
        kuruAmmVaultAddress,
        hre.ethers.utils.parseEther("10000000"),
    );
    await tx.wait();

    var tx = await usdc.approve(
        kuruAmmVaultAddress,
        hre.ethers.utils.parseEther("10000000"),
    );
    await tx.wait();

    const kuruAmmVault = await hre.ethers.getContractAt(
		"KuruAMMVault",
		kuruAmmVaultAddress
	);

    // TODO: Uncomment if you want an AMM
    // const vaultDepositTx = await kuruAmmVaultContract.deposit(hre.ethers.utils.parseEther("206900"), hre.ethers.utils.parseEther("79"), userAddress);
    // await vaultDepositTx.wait();

    const config = {
        "usdcAddress": usdcAddress,
        "wbtcAddress": wbtcAddress,
        "routerAddress": routerAddress,
        "marginAccountAddress": marginAccountAddress,
        "cranklessOrderBookAddress": cranklessOrderBookAddress,
        "kuruAmmVaultAddress": kuruAmmVaultAddress,
        "kuruForwarderAddress": kuruForwarder.address,
    }
    fs.writeFileSync("config.json", JSON.stringify(config));
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});