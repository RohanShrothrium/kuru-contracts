require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.26",
    settings: {
      evmVersion: "shanghai",
      optimizer: {
        enabled: true,
        runs: 1000,
      },
      viaIR: true,
    },
  },
  defaultNetwork: "localhost",
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
    localhost: {
      allowUnlimitedContractSize: true,
      url: "http://127.0.0.1:8545/",
    },
  }
};