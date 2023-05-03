/** @type import('hardhat/config').HardhatUserConfig */

require("@nomiclabs/hardhat-ethers");

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.17",
      },
      {
        version: "0.6.12",
      },
    ],
  },
  defaultNetwork: "localhost",
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545/"
    },
  }
};
