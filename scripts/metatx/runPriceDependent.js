const { ethers } = require("hardhat");
const config = require("../../config.json");

async function main() {
  const [signer] = await ethers.getSigners();

  // Get command line arguments
  const kuruForwarderAddress = process.argv[2];
  const orderBookAddress = process.argv[3];

  if (!kuruForwarderAddress || !orderBookAddress) {
    console.error("Please provide KuruForwarder and OrderBook addresses as command line arguments");
    process.exit(1);
  }

  // Connect to the token contracts
  const wbtc = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.wbtcAddress);
  const usdc = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", config.usdcAddress);

  // Approve unlimited amounts for both tokens
  const maxUint256 = ethers.constants.MaxUint256;
  await wbtc.approve(orderBookAddress, maxUint256);
  await usdc.approve(orderBookAddress, maxUint256);

  console.log("Unlimited approval granted for WBTC and USDC to OrderBook");

  // Connect to the KuruForwarder contract
  const kuruForwarder = await ethers.getContractAt("KuruForwarder", kuruForwarderAddress);

  // Connect to the OrderBook contract
  const orderBook = await ethers.getContractAt("OrderBook", orderBookAddress);

  // Prepare the function call data for placeAndExecuteMarketBuy
  const functionSignature = "placeAndExecuteMarketBuy(uint24,uint256,bool,bool) payable";

  // Prepare the domain for EIP-712 signing
  const domain = {
    name: "KuruForwarder",
    version: "1.0.0",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: kuruForwarderAddress,
  };

  const types = {
    PriceDependentRequest: [
      { name: "from", type: "address" },
      { name: "market", type: "address" },
      { name: "price", type: "uint256" },
      { name: "value", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "isBelowPrice", type: "bool" },
      { name: "data", type: "bytes" },
    ],
  };

  const params = [
    ethers.utils.parseUnits("1000", 0), // size: 1000
    ethers.BigNumber.from("0"), // minAmountOut: 0
    false, // isMargin: false
    true // isFillOrKill: true
  ];
  const data = orderBook.interface.encodeFunctionData(functionSignature, params);

  // Prepare the price dependent request
  const nonce = await kuruForwarder.getNonce(signer.address);

  const priceDependentRequest = {
    from: signer.address,
    market: orderBookAddress,
    price: ethers.BigNumber.from("378046504505452"),
    value: 0,
    nonce: 2,
    isBelowPrice: false,
    data: data,
  };

  // Sign the price dependent request using EIP-712
  const signature = await signer._signTypedData(domain, types, priceDependentRequest);

  // Execute the price dependent meta-transaction
  const tx = await kuruForwarder.executePriceDependent(priceDependentRequest, signature);
  const receipt = await tx.wait();

  console.log(`Price dependent meta-transaction executed. Transaction hash:`, receipt.transactionHash);
  console.log(`Gas used: ${receipt.gasUsed.toString()}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
