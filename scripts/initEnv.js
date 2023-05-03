const hre = require("hardhat");
const fs = require('fs');

async function main() {
    const userAccount = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    // token addresses
    const usdcAddress = "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8";
    const wethAddress = "0x2170Ed0880ac9A755fd29B2688956BD959F933F8";

    // Level Fi contract address
    const bnbOrderManagerAddress = "0xf584A17dF21Afd9de84F47842ECEAF6042b1Bb5b";
    const bnbPoolAddress = "0xA5aBFB56a78D2BD4689b25B8A77fd49Bb0675874";
    const bnbLevelOracleAddress = "0x04Db83667F5d59FF61fA6BbBD894824B233b3693";

    // gelatoAutomate
    const gellatoAutomateAddress = "0x527a819db1eb0e34426297b03bae11F2f8B3A19E";

    // level fi owner of executor contract
    const bnbExecutorAddress = "0x4d91cf959c86888df1ed20877b27fa0c7bc08147";

    // deploy lending contract
    const LendingContract = await hre.ethers.getContractFactory("LendingContract");
    const lendingContract = await LendingContract.deploy(usdcAddress);
    await lendingContract.deployed();

    const lendingContractAddress = lendingContract.address;
    console.log(`ledning contract deployed at: ${lendingContractAddress}`);

    // deploy factory contract
    const FactoryContract = await hre.ethers.getContractFactory("FactoryContract");
    const factoryContract = await FactoryContract.deploy(
        lendingContractAddress,
        bnbOrderManagerAddress,
        bnbPoolAddress,
        bnbLevelOracleAddress,
        gellatoAutomateAddress
    );
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

    // deploy KLP token contract
    const KlpContract = await hre.ethers.getContractFactory("KLP");
    const klpContract = await KlpContract.deploy();
    await klpContract.deployed();

    const klpContractAddress = klpContract.address;
    console.log(`KLP contract deployed at: ${klpContractAddress}`);


    // deploy KLP Manager contract
    const KlpManagerContract = await hre.ethers.getContractFactory("KlpManager");
    const klpManagerContract = await KlpManagerContract.deploy(klpContractAddress, lendingContractAddress, usdcAddress);
    await klpManagerContract.deployed();

    const klpManagerContractAddress = klpManagerContract.address;
    console.log(`KLP Manager contract deployed at: ${klpManagerContractAddress}`);

    // set the klp manager as a minter
    var receipt = await klpContract.setMinter(
        klpManagerContractAddress,
        true
    );

    await receipt.wait();

    // set klpmanager address variable in the lending contract (only klpmanager can call liquidity pool related functions)
    receipt = await lendingContract.setKlpManagerAddress(klpManagerContractAddress);

    await receipt.wait();

    // add funds to abstract position contract so it can call execute increase,
    // this function will be removed eventually and only facilitates testing
    const abstractPositionContract = await hre.ethers.getContractAt("AbstractPosition", abstractPositionAddress);
    var receipt = await abstractPositionContract.deposit({ value: hre.ethers.utils.parseEther("1") });
    await receipt.wait();

    // create json object for writing to config file
    const networkConfig = {
        userAccount,
        bnbExecutorAddress,
        wethAddress,
        bnbOrderManagerAddress,
        bnbPoolAddress,
        bnbLevelOracleAddress,
        klpContractAddress,
        lendingContractAddress,
        klpManagerContractAddress,
        factoryContractAddress,
        abstractPositionAddress,
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