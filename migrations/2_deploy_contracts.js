var LendingContract = artifacts.require("LendingContract");
var FactoryContract = artifacts.require("FactoryContract");
var KlpContract = artifacts.require("KLP");
var KlpManagerContract =  artifacts.require("KlpManager");
var TradeLensContract =  artifacts.require("TradeLens");

module.exports = function(deployer) {
    const usdtAddress = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";
    const lendingContractAddress = "0x8dEe6a66Ca0965E8Fd54eB688d09beE5bd3e7a69";

    const bnbOrderManagerAddress = "0xD78529f39d4d5b2B6d8187a26DB00269879e687b";
    const bnbPoolAddress = "0xf329aC496495CFD3C4EDf2B444Da0DD29ACB16eA";
    const bnbLevelOracleAddress = "0x0e429cef33e0bAf16caDa58ac496d2b0931FCF71";

    const factoryContractAddress = "0x3493e48b7e53181AaEF765AbDD50481b0481C8c0";

    const klpContractAddress = "0x238e3A9E9f7a8644b8a00631436a9508fcacF2fc";
    deployer.deploy(TradeLensContract);
};