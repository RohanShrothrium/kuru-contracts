const hre = require("hardhat");
const config = require("../config.json");

async function main() {
    const [owner] = await hre.ethers.getSigners();

    await owner.sendTransaction({
        to: "0x59a661f1c909ca13ba3e9114bfdd81e5a420705d",
        value: ethers.utils.parseEther("1.0"), // Sends exactly 1.0 ether
    });

    // const vaibizz = await hre.ethers.getSigner("0x31FA9CCb91e7f475F1f8Ae3B5CD98B40aA5310ba")
    // await vaibizz.getBalance()
    const bal = await hre.ethers.provider.getBalance("0x59a661f1c909ca13ba3e9114bfdd81e5a420705d");
    console.log(bal)
}


main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
