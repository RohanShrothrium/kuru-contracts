// Import the Hardhat runtime environment and assertion library
const { ethers, network } = require("hardhat");
const hre = require("hardhat");
const { expect, use } = require("chai");
const { solidity } = require("ethereum-waffle");

const userAccount = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const usdcSharkAccount = "0x62383739D68Dd0F844103Db8dFb05a7EdED5BBE6";
var executionPrice = 200000000000000;

// token addresses
const usdcAddress = "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8";
const wethAddress = "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1";
const wbtcAddress = "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f";
const zeroContract = "0x0000000000000000000000000000000000000000";
const referralCode = "0x0000000000000000000000000000000000000000000000000000000000000000";

// GMX contract addresses
const gmxAdmin = "0xb4d2603b2494103c90b2c607261dd85484b49ef0";
const positionRouterAddress = "0xb87a436B93fFE9D75c5cFA7bAcFff96430b09868";
const vaultAddress = "0x489ee077994B6658eAfA855C308275EAd8097C4A";
const routerAddress = "0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064";
const orderBookAddress = "0x09f77e8a13de9a35a7231028187e9fd5db8a2acb";

use(solidity);

describe("TEST: e2e workflow tests", async function () {
    var increaseRequests = 0;

    // variables to store contract addresses
    let lendingContractAddress, factoryContractAddress, abstractPositionAddress, klpManagerContractAddress, klpContractAddress;

    // variables to store contracts
    let lendingContract, factoryContract, abstractPositionContract, klpManagerContract, klpContract;
    
    // position router is used accross tests to execute increase position. In main net keepers will do this.
    before(async function () {
        // deploy lending contract
        const LendingContract = await ethers.getContractFactory("LendingContract");
        lendingContract = await LendingContract.deploy(usdcAddress);
        await lendingContract.deployed();

        lendingContractAddress = lendingContract.address;

        // deploy factory contract
        const FactoryContract = await ethers.getContractFactory("FactoryContract");
        factoryContract = await FactoryContract.deploy(lendingContractAddress, positionRouterAddress, routerAddress, orderBookAddress, vaultAddress);
        await factoryContract.deployed();

        factoryContractAddress = factoryContract.address;

        // set factory contract address on lending contract
        var receipt = await lendingContract.setFactoryaContractAddress(factoryContractAddress);
        await receipt.wait();

        // create abstract position for user
        var receipt = await factoryContract.createAbstractPosition();
        await receipt.wait();

        abstractPositionAddress = await factoryContract.getContractForAccount(userAccount);

        // deploy KLP token contract
        const KlpContract = await ethers.getContractFactory("KLP");
        klpContract = await KlpContract.deploy();
        await klpContract.deployed();

        klpContractAddress = klpContract.address;


        // deploy KLP Manager contract
        const KlpManagerContract = await ethers.getContractFactory("KlpManager");
        klpManagerContract = await KlpManagerContract.deploy(klpContractAddress, lendingContractAddress, usdcAddress);
        await klpManagerContract.deployed();

        klpManagerContractAddress = klpManagerContract.address;

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
        abstractPositionContract = await ethers.getContractAt("AbstractPosition", abstractPositionAddress);
        var receipt = await abstractPositionContract.deposit({ value: ethers.utils.parseEther("1") });
        await receipt.wait();

        // set min execution price on abstract position to create stop losses
        var receipt = await abstractPositionContract.setMinExecutionFee(executionPrice);
        await receipt.wait();

        var abstractPositionUser = await abstractPositionContract.ownerAddress();
        expect(abstractPositionUser).to.equal(userAccount);

        // set min delay as zero from gmx admin's account
        await network.provider.request({
            method: "hardhat_impersonateAccount",
            params: [gmxAdmin],
        });
        const gmxSigner = await ethers.getSigner(gmxAdmin);
        const positionRouterContractAsGmxAdmin = await ethers.getContractAt("PositionRouter", positionRouterAddress, gmxSigner);
        var receipt = await positionRouterContractAsGmxAdmin.setDelayValues(0, 0, 1800);
        await receipt.wait();

        // Transfer USDC to user account from shark account
        await network.provider.request({
            method: "hardhat_impersonateAccount",
            params: [usdcSharkAccount],
        });
    
        const signer = await ethers.getSigner(usdcSharkAccount);
        const usdcContractAsShark = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress, signer);

        var receipt = await usdcContractAsShark.transfer(
            userAccount,
            1000000000, // send $1000 to user account
        );
        await receipt.wait();
    });

    describe("TEST: create increase position", async function () {
        it("should create ETH long posiiton", async function () {
            var isLong = true;
            var leverage = 3;
            var collateral = 0.05;
    
            // get max/min price for eth from vault
            const vaultContract = await ethers.getContractAt("Vault", vaultAddress);
            const vaultMaxPrice = await vaultContract.getMaxPrice(
                wethAddress
            );
    
            var receipt = await abstractPositionContract.callCreateIncreasePositionETH(
                [wethAddress], // path: [collateral token is eth]
                wethAddress, // indexToken: eth
                0, // minOut: no swap required so set min out to 0
                vaultMaxPrice.mul(ethers.utils.parseEther(`${collateral}`)).mul(leverage).div(ethers.utils.parseEther("1")),
                isLong,
                vaultMaxPrice.mul(11).div(10), // 1.1x the max price as we want this request to get executed
                executionPrice,
                referralCode,
                zeroContract,
                { value: ethers.utils.parseEther(`${collateral}`) }
            );
            await receipt.wait();
    
            increaseRequests += 1;
    
            const positionRouterContract = await ethers.getContractAt("PositionRouter", positionRouterAddress);
            // get the key for the position to execute the position
            const positionKey = await positionRouterContract.getRequestKey(
                abstractPositionAddress,
                increaseRequests
            );
    
            // execute increase position as the abstract position contract (positions can be executeed by owners or keepers)
            await network.provider.request({
                method: "hardhat_impersonateAccount",
                params: [abstractPositionAddress],
            });
            const abstractPositionSigner = await ethers.getSigner(abstractPositionAddress);
            const positionRouterContractForAp = await ethers.getContractAt("PositionRouter", positionRouterAddress, abstractPositionSigner);
            var receipt = await positionRouterContractForAp.executeIncreasePosition(
                positionKey,
                abstractPositionAddress,
            );
            await receipt.wait();
        }).timeout(300000);
    
        it("should create BTC short posiiton", async function () {
            var isLong = false;
            var leverage = 2;
            var collateral = 100;
    
            // get max/min price for eth from vault
            const vaultContract = await ethers.getContractAt("Vault", vaultAddress);
            const vaultMinPrice = await vaultContract.getMinPrice(
                wbtcAddress
            );
    
            // approve collateral transfer from user to abstract position contract
            const usdcContract = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress);
            var receipt = await usdcContract.approve(
                abstractPositionAddress,
                collateral*10**6,
            );
            await receipt.wait();
    
            // create increase position request
            var receipt = await abstractPositionContract.callCreateIncreasePosition(
                [usdcAddress], // path: [collateral token is usdc for shorts]
                wbtcAddress, // indexToken: eth
                collateral*10**6, // amountIn: we are shorting btc with a collateral of $100
                0, // minOut: no swap required so set min out to 0
                ethers.utils.parseEther(`${collateral}`).mul(leverage).mul(10**12),
                isLong,
                vaultMinPrice.mul(9).div(10), // 0.9x the min price as we want this request to get executed
                executionPrice,
                referralCode,
                zeroContract,
                { value: executionPrice }
            );
            await receipt.wait();
            increaseRequests += 1;

            // expect $100 to be deducted
            var userUsdcBalance = await usdcContract.balanceOf(userAccount);
            expect(userUsdcBalance.toString()).to.equal((900*10**6).toString());
    
            // get the key for the position to execute the position
            const positionRouterContract = await ethers.getContractAt("PositionRouter", positionRouterAddress);
            const positionKey = await positionRouterContract.getRequestKey(
                abstractPositionAddress,
                increaseRequests
            );
    
            // execute increase position as the abstract position contract (positions can be executeed by owners or keepers)
            await network.provider.request({
                method: "hardhat_impersonateAccount",
                params: [abstractPositionAddress],
            });
            const abstractPositionSigner = await ethers.getSigner(abstractPositionAddress);
            const positionRouterContractForAp = await ethers.getContractAt("PositionRouter", positionRouterAddress, abstractPositionSigner);
            var receipt = await positionRouterContractForAp.executeIncreasePosition(
                positionKey,
                abstractPositionAddress,
            );
            await receipt.wait();
        }).timeout(300000);
    })

    describe("TEST: provide liquidity to pool", async function () {
        it("should provide liquidity to pool", async function () {
            const liquidityAmount = 100;

            // approve deposit amount for providing liquidity
            const usdcContract = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress);
            var receipt = await usdcContract.approve(
                klpManagerContractAddress,
                liquidityAmount*10**6,
            );
            await receipt.wait();

            // provide liquidity to the pool
            var receipt = await klpManagerContract.addLiquidity(
                usdcAddress,
                ethers.utils.parseEther("100").mul(10**12)
            );
            await receipt.wait();

            // expect $100 to be deducted
            const userUsdcBalance = await usdcContract.balanceOf(userAccount);
            expect(userUsdcBalance.toString()).to.equal((800*10**6).toString());

            // expect klp balance to be 100KLP
            const userKlpBalance = await klpContract.balanceOf(userAccount);
            expect(userKlpBalance.toString()).to.equal((100*10**18).toString());
        }).timeout(300000)

        it("should remove liquidity from pool", async function () {
            const liquidityAmount = 10;

            // approve klp amount that has to be withdrawn
            var receipt = await klpContract.approve(
                klpManagerContractAddress,
                ethers.utils.parseEther("10").mul(10**12),
            );
            await receipt.wait();

            // provide liquidity to the pool
            var receipt = await klpManagerContract.removeLiquidity(
                usdcAddress,
                ethers.utils.parseEther(liquidityAmount.toString()).mul(10**12)
            );
            await receipt.wait();

            // expect $10 to be added
            const usdcContract = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress);
            const userUsdcBalance = await usdcContract.balanceOf(userAccount);
            expect(userUsdcBalance.toString()).to.equal((810*10**6).toString());

            // expect klp balance to be 90KLP
            const userKlpBalance = await klpContract.balanceOf(userAccount);
            expect(userKlpBalance.toString()).to.equal((90*10**18).toString());
        }).timeout(300000)
    })

    describe("TEST: take loan on portfolio", async function () {
        it("should borrow on portfolio", async function () {
            const loanAmount = 20;

            // take loan on your portfolio
            var receipt = await lendingContract.takeLoanOnPosition(ethers.utils.parseEther(loanAmount.toString()).mul(10**12));
            await receipt.wait();
            
            // get usdc balance and expect it to increase by loan amount($20)
            const usdcContract = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress);
            const userUsdcBalance = await usdcContract.balanceOf(userAccount);
            expect(userUsdcBalance.toString()).to.equal((830*10**6).toString());

            // get loan amount from lending contract and expect it to be loan amoun
            const userLoan = await lendingContract.existingLoanOnPortfolio(userAccount);
            expect(userLoan.toString()).to.equal(ethers.utils.parseEther(loanAmount.toString()).mul(10**12).toString());
        }).timeout(300000)

        it("should repay loan", async function () {
            const repayAmount = 10;

            // approve the repay amount using the usdc smartcontract
            const usdcContract = await ethers.getContractAt("contracts/libraries/IERC20.sol:IERC20", usdcAddress);
            var receipt = await usdcContract.approve(lendingContractAddress, repayAmount*10**6)
            await receipt.wait();

            // pay back a part of the loan
            var receipt = await lendingContract.paybackLoan(ethers.utils.parseEther(repayAmount.toString()).mul(10**12));
            await receipt.wait();

            // validate that your usdc balance has gone down by the loan amount
            const userUsdcBalance = await usdcContract.balanceOf(userAccount);
            expect(userUsdcBalance.toString()).to.equal((820*10**6).toString());

            // expect the existing loan to have decreased but also account for the hourly iterest rate 0.001%APR
            const userLoan = await lendingContract.existingLoanOnPortfolio(userAccount);
            const interestAccumulated = ethers.utils.parseEther("20").mul(10**12).div(10000)
            expect(userLoan.toString()).to.equal((ethers.utils.parseEther(repayAmount.toString()).mul(10**12)).add(interestAccumulated).toString());
        }).timeout(300000)

        it("should throw error: loan amount too high", async function () {
            const loanAmount = 200;

            // take loan on your portfolio
            await expect(lendingContract.takeLoanOnPosition(ethers.utils.parseEther(loanAmount.toString()).mul(10**12)))
                .to.be.revertedWith("LTV does not support loan amount")
        }).timeout(300000)

        it("should throw error: smart wallet does not exist for user", async function () {
            const loanAmount = 200;
            [owner, user1] = await ethers.getSigners();

            // take loan on your portfolio
            await expect(lendingContract.connect(user1).takeLoanOnPosition(ethers.utils.parseEther(loanAmount.toString()).mul(10**12)))
                .to.be.revertedWith("acount does not have abstract contract")
        }).timeout(300000)

        it("should throw error: repay amount too high", async function () {
            const repayAmount = 100;

            // pay back a part of the loan
            await expect(lendingContract.paybackLoan(ethers.utils.parseEther(repayAmount.toString()).mul(10**12)))
                .to.be.revertedWith("loan taken lesser than paying amount")
        }).timeout(300000)
    })

    describe("TEST: factory contract tests", async function () {
        it("should create abstract position contract", async function () {
            [owner, user1] = await ethers.getSigners();
            var receipt = await factoryContract.connect(user1).createAbstractPosition();
            await receipt.wait();

            const user1AbstractAddress = await factoryContract.getContractForAccount(user1.address);

            expect(user1AbstractAddress).to.not.equal(zeroContract);
        })

        it("should throw error: wallet already exists", async function () {
            await expect(factoryContract.createAbstractPosition())
                .to.be.revertedWith("abstract position contract already exists for user")
        })
    })

    describe("TEST: Lending contract tests", async function () {
        it("should throw error: only gov can update factory contract address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(lendingContract.connect(user1).setFactoryaContractAddress(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("should throw error: only gov can update klp manager address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(lendingContract.connect(user1).setKlpManagerAddress(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("factory contract is correctly stored", async function () {
            const addr = await lendingContract.factoryContractAddress();

            expect(addr).to.equal(factoryContractAddress);
        })

        it("should throw error: only klp manager contract can call this", async function () {
            await expect(lendingContract.sendUsdcToLp(userAccount, 100*10**6))
                .to.be.revertedWith("only the klp manager can call this function");
        })
    })

    describe("TEST: abstract position contract", async function () {
        it("should throw error: only gov can update factory contract address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(abstractPositionContract.connect(user1).setLendingContractAddress(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("should throw error: only gov can update position router address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(abstractPositionContract.connect(user1).setPositionRouterAddress(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("should throw error: only gov can update router address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(abstractPositionContract.connect(user1).setRouterAddress(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("should throw error: only gov can update vault address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(abstractPositionContract.connect(user1).setVaultContractAddress(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("should throw error: only gov can update min execution fee address", async function () {
            const [owner, user1] = await ethers.getSigners();
            await expect(abstractPositionContract.connect(user1).setMinExecutionFee(user1.address))
                .to.be.revertedWith("only gov can call this function");
        })

        it("should throw error: only owner can create positions", async function () {
            var isLong = false;
            var leverage = 2;
            var collateral = 100;
    
            // get max/min price for eth from vault
            const vaultContract = await ethers.getContractAt("Vault", vaultAddress);
            const vaultMinPrice = await vaultContract.getMinPrice(
                wbtcAddress
            );

            const [owner, user1] = await ethers.getSigners();
            await expect(abstractPositionContract.connect(user1).callCreateIncreasePosition(
                [usdcAddress], // path: [collateral token is usdc for shorts]
                wbtcAddress, // indexToken: eth
                collateral*10**6, // amountIn: we are shorting btc with a collateral of $100
                0, // minOut: no swap required so set min out to 0
                ethers.utils.parseEther(`${collateral}`).mul(leverage).mul(10**12),
                isLong,
                vaultMinPrice.mul(9).div(10), // 0.9x the min price as we want this request to get executed
                executionPrice,
                referralCode,
                zeroContract,
                { value: executionPrice })
            ).to.be.revertedWith("only the owner can call this function");
        })
    })
});
