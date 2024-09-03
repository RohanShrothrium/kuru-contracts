const hre = require("hardhat");

var configFileName = "devnet.config.json";

const args = process.argv.slice(2);
const devnetName = args[0];
const baseAddress = args[1];  // Base asset address
const quoteAddress = args[2];  // Quote asset address
const baseDeposit = args[3];  // Quote asset address
const quoteDeposit = args[4];  // Quote asset address

if (devnetName !== "") {
    configFileName = `${devnetName}_${configFileName}`;
}

const config = require(`../${configFileName}`);

function Enum(...options) {
    return Object.fromEntries(options.map((key, i) => [key, hre.ethers.BigNumber.from(i)]));
}

async function main() {
    const currentProvider = new hre.ethers.providers.JsonRpcProvider("https://eth-sepolia.api.onfinality.io/public");

    const deployerPvtKey = "e33eae6a73c0c8bb2be71c86d72dc35b6b573468592165cbb24cc66f961c1c2e";
    const deployer = new hre.ethers.Wallet(deployerPvtKey, currentProvider);

    // contract parameters
    const _sizePrecision = 10 ** 10;
    const _pricePrecision = 100;
    const _tickSize = 1;
    const _minSize = 10 ** 2;
    const _maxSize = 10 ** 12;
    const _takerFeeBps = 30;
    const _makerFeeBps = 21;
    const _spread = 30;
    // Determine the proxy type based on the base and quote addresses
    let proxyType;
    if (baseAddress === hre.ethers.constants.AddressZero) {
        proxyType = Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NATIVE_IN_BASE;
    } else if (quoteAddress === hre.ethers.constants.AddressZero) {
        proxyType = Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NATIVE_IN_QUOTE;
    } else {
        proxyType = Enum('NO_NATIVE', 'NATIVE_IN_BASE', 'NATIVE_IN_QUOTE').NO_NATIVE;
    }

    const router = await hre.ethers.getContractAt("Router", config.routerAddress, deployer);
    const cranklessOrderBookAddress = await router.callStatic.deployProxy(
        proxyType,
        baseAddress,
        quoteAddress,
        _sizePrecision,
        _pricePrecision,
        _tickSize,
        _minSize,
        _maxSize,
        _takerFeeBps,
        _makerFeeBps,
        _spread
    );
    const deployProxyTx = await router.deployProxy(
        proxyType,
        baseAddress,
        quoteAddress,
        _sizePrecision,
        _pricePrecision,
        _tickSize,
        _minSize,
        _maxSize,
        _takerFeeBps,
        _makerFeeBps,
        _spread
    );
    await deployProxyTx.wait();

    console.log("CranklessOrderBook deployed to:", cranklessOrderBookAddress);

    const market = await hre.ethers.getContractAt(
        "OrderBook",
        cranklessOrderBookAddress,
        deployer
    );

    const vaultParamsData = await market.getVaultParams();
    const kuruAmmVaultAddress = vaultParamsData[0];
    console.log("KuruAMMVault deployed to:", kuruAmmVaultAddress);

    // Handle approval or sending ETH based on the address type
    if (baseAddress !== hre.ethers.constants.AddressZero) {
        const base = await hre.ethers.getContractAt("ERC20", baseAddress, deployer);
        var tx = await base.approve(
            kuruAmmVaultAddress,
            hre.ethers.utils.parseEther(baseDeposit),
        );
        await tx.wait();
        var tx = await base.approve(
            cranklessOrderBookAddress,
            hre.ethers.BigNumber.from("115792089237316195423570985008687907853269984665640564039457584007913129639935"),
        );
        await tx.wait();
        console.log("Successfully deposited base assets")
    }

    if (quoteAddress !== hre.ethers.constants.AddressZero) {
        const quote = await hre.ethers.getContractAt("ERC20", quoteAddress, deployer);
        var tx = await quote.approve(
            kuruAmmVaultAddress,
            hre.ethers.utils.parseEther(quoteDeposit),
        );
        await tx.wait();
        var tx = await quote.approve(
            cranklessOrderBookAddress,
            hre.ethers.BigNumber.from("115792089237316195423570985008687907853269984665640564039457584007913129639935"),
        );
        await tx.wait();

        console.log("Successfully deposited quote assets")
    }

    const kuruAmmVault = await hre.ethers.getContractAt(
        "KuruAMMVault",
        kuruAmmVaultAddress,
        deployer
    );

    // Deposit funds into the AMM vault
    const vaultDepositTx = await kuruAmmVault.deposit(
        hre.ethers.utils.parseEther(baseDeposit),
        hre.ethers.utils.parseEther(quoteDeposit),
        deployer.address,
        {
            value: baseAddress === hre.ethers.constants.AddressZero ? hre.ethers.utils.parseEther(baseDeposit) : (quoteAddress === hre.ethers.constants.AddressZero ? hre.ethers.utils.parseEther(quoteDeposit) : 0)
        }
    );
    await vaultDepositTx.wait();
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
