const hre = require("hardhat");
const fs = require('fs');

async function main() {
    const userAccount = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    var isLong = true;
    var leverage = 3;
    var collateral = 0.05;

    // token addresses
    const usdcAddress = "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8";
    const wethAddress = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1";
    const zeroContract = "0x0000000000000000000000000000000000000000"
    const referralCode = "0x0000000000000000000000000000000000000000000000000000000000000000";


    // GMX contract addresses
    const gmxAdmin = "0xb4d2603b2494103c90b2c607261dd85484b49ef0";
    const positionRouterAddress = "0xb87a436B93fFE9D75c5cFA7bAcFff96430b09868";
    const vaultAddress = "0x489ee077994B6658eAfA855C308275EAd8097C4A";
    const routerAddress = "0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064";
    const orderBookAddress = "0x09f77e8a13de9a35a7231028187e9fd5db8a2acb";

    // deploy lending contract
    const LendingContract = await hre.ethers.getContractFactory("LendingContract");
    const lendingContract = await LendingContract.deploy(usdcAddress);
    await lendingContract.deployed();

    const lendingContractAddress = lendingContract.address;
    console.log(`ledning contract deployed at: ${lendingContractAddress}`);

    // deploy factory contract
    const FactoryContract = await hre.ethers.getContractFactory("FactoryContract");
    const factoryContract = await FactoryContract.deploy(lendingContractAddress, positionRouterAddress, routerAddress, orderBookAddress, vaultAddress);
    await factoryContract.deployed();

    const factoryContractAddress = factoryContract.address;
    console.log(`factory contract deployed at: ${factoryContractAddress}`);

    // set factory contract address on lending contract
    var receipt = await lendingContract.setFactoryaContractAddress(factoryContractAddress);
    await receipt.wait();

    // create abstract position for user
    var receipt = await factoryContract.createAbstractPosition();
    await receipt.wait();

    const abstractPositionAddress = await factoryContract.getContractForAccount(userAccount);
    console.log(`abstract position contract deployed at: ${abstractPositionAddress}`);

    // add funds to abstract position contract so it can call execute increase,
    // this function will be removed eventually and only facilitates testing
    const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", abstractPositionAddress);
    var receipt = await abstractPositionContract.deposit({ value: hre.ethers.utils.parseEther("1") });
    await receipt.wait();

    // set min execution price on abstract position to create stop losses
    var receipt = await abstractPositionContract.setMinExecutionFee(200000000000000);
    await receipt.wait();

    // get max/min price for eth from vault
    const vaultContract = await hre.ethers.getContractAt("Vault", vaultAddress);

    // ethPrice = maxEthePrice for longs and ethPrice = minEthePrice. Acceptable price has a buffer of 10%.
    var ethPrice;
    var ethAcceptablePrice;
    if (isLong) {
        ethPrice = await vaultContract.getMaxPrice(
            wethAddress
        );
        ethAcceptablePrice = ethPrice.mul(11).div(10);
    } else {
        ethPrice = await vaultContract.getMinPrice(
            wethAddress
        );
        ethAcceptablePrice = ethPrice.mul(9).div(10);
    }

    // create an increase position: lvg 20x
    var receipt = await abstractPositionContract.callCreateIncreasePosition(
        [wethAddress],
        wethAddress,
        0,
        ethPrice.mul(hre.ethers.utils.parseEther(`${collateral}`)).mul(leverage).div(hre.ethers.utils.parseEther("1")),
        true,
        ethAcceptablePrice,
        200000000000000,
        referralCode,
        zeroContract,
        { value: hre.ethers.utils.parseEther(`${collateral}`) }
    );

    await receipt.wait();

    // get the key for the position to execute the position
    const positionRouterContract = await hre.ethers.getContractAt("PositionRouter", positionRouterAddress);
    const positionKey = await positionRouterContract.getRequestKey(
        abstractPositionAddress,
        1
    );
    console.log(`position key: ${positionKey}`);

    // set min delay as zero from gmx admin's account
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [gmxAdmin],
    });
    const gmxSigner = await hre.ethers.getSigner(gmxAdmin);
    const positionRouterContractAsGmxAdmin = await hre.ethers.getContractAt("PositionRouter", positionRouterAddress, gmxSigner);
    var receipt = await positionRouterContractAsGmxAdmin.setDelayValues(0, 0, 1800);
    await receipt.wait();
    console.log(`successfully set delay to zero`);

    // execute increase position
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [abstractPositionAddress],
    });
    const abstractPositionSigner = await hre.ethers.getSigner(abstractPositionAddress);
    const positionRouterContractForAp = await hre.ethers.getContractAt("PositionRouter", positionRouterAddress, abstractPositionSigner);
    var receipt = await positionRouterContractForAp.executeIncreasePosition(
        positionKey,
        abstractPositionAddress,
    );
    await receipt.wait();
    console.log(`successfully executed position`);

    // create json object for writing to config file
    const networkConfig = {
        userAccount,
        gmxAdmin,
        wethAddress,
        usdcAddress,
        positionRouterAddress,
        vaultAddress,
        lendingContractAddress,
        factoryContractAddress,
        abstractPositionAddress,
        positionKey
    };

    const jsonString = JSON.stringify(networkConfig);

    fs.writeFile("config.json", jsonString, 'utf8', function (err) {
        if (err) {
            console.log("An error occured while writing config file");
            console.log(err);
        }
     
        console.log("JSON file has been saved.");
    });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});