require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.26",
    settings: {
      evmVersion: "shanghai",
      optimizer: {
        enabled: true,
        runs: 100,
        details: {
          yul: true,
          cse: true,
          deduplicate: true,
        },
      },
      viaIR: true,
      evmVersion: "shanghai",
    },
  },
  defaultNetwork: "localhost",
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545/",
    },
  }
};
