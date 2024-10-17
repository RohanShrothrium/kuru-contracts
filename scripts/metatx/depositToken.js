const { ethers } = require("hardhat");
const config = require("../../config.json");

async function main() {
  const [signer] = await ethers.getSigners();

  // Get command line arguments
  const size = process.argv[2];

  if (!size) {
    console.error("Please provide size as a command line argument");
    process.exit(1);
  }

  // Use addresses from config.json
  const kuruForwarderAddress = config.kuruForwarderAddress;
  const marginAccountAddress = config.marginAccountAddress;
  const tokenAddress = config.wbtcAddress; // Using WBTC as an example, change if needed

  // Connect to the KuruForwarder contract
  const kuruForwarder = await ethers.getContractAt("KuruForwarder", kuruForwarderAddress);

  // Connect to the MarginAccount contract
  const marginAccount = await ethers.getContractAt("MarginAccount", marginAccountAddress);

  // Connect to the token contract
  const token = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", tokenAddress);
  
  // Get token decimals
  const tokenDecimals = 18;

  // Calculate amount
  const amount = ethers.utils.parseUnits(size, tokenDecimals);

  // Approve the MarginAccount to spend tokens
  await token.approve(marginAccountAddress, ethers.constants.MaxUint256);
  console.log("Approved MarginAccount to spend tokens");

  // Prepare the function call data for deposit
  const functionSignature = "deposit(address,address,uint256)";

  // Prepare the domain for EIP-712 signing
  const domain = {
    name: "KuruForwarder",
    version: "1.0.0",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: kuruForwarderAddress,
  };

  const types = {
    MarginAccountRequest: [
      { name: "from", type: "address" },
      { name: "marginAccount", type: "address" },
      { name: "value", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "data", type: "bytes" },
    ],
  };

  const params = [
    signer.address,
    tokenAddress,
    amount
  ];
  const data = marginAccount.interface.encodeFunctionData(functionSignature, params);

  // Prepare the deposit request
  const nonce = await kuruForwarder.getNonce(signer.address);

  const marginAccountRequest = {
    from: signer.address,
    marginAccount: marginAccountAddress,
    value: "0", // Since we're using a token, not native currency
    nonce: nonce.toString(),
    data: data,
  };

  // Sign the deposit request using EIP-712
  const signature = await signer._signTypedData(domain, types, marginAccountRequest);

  // Execute the meta-transaction
  const tx = await kuruForwarder.executeMarginAccountRequest(marginAccountRequest, signature);
  const receipt = await tx.wait();

  console.log("Meta-transaction executed. Transaction hash:", receipt.transactionHash);
  console.log(`Gas used: ${receipt.gasUsed.toString()}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
