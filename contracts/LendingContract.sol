// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./interfaces/IVault.sol";
import "./AbstractPosition.sol";
import "./FactoryContract.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./libraries/SafeMath.sol";

contract LendingContract {
    using SafeMath for uint256;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDC_DECIMALS_DIVISOR = 10**24; // usdc has a decimal precision of 10^6 but GMX uses 10^18 (wei)
    uint256 public constant LTV = 60;

    address public gov;
    address public factoryContractAddress;

    address public usdcAddress;

    mapping (address => uint256) public amountLoanedByUser;
    uint256 public totalLoanedAmount = 0;

    constructor(address _usdcAddress) {
        gov = msg.sender;

        usdcAddress = _usdcAddress;
    }

    // set the factory contract address
    function setFactoryaContractAddress(address newAddress) external {
        _onlyGov();
        factoryContractAddress = newAddress;
    }

    // function for liquidity providers to add liquidity to the pool
    // we might have to create something like a router contract to handle this.
    function provideLiquidity(
        uint256 _amount
    ) external returns (uint256 availablePool) {
        ERC20(usdcAddress).transferFrom(msg.sender, address(this), _amount.div(USDC_DECIMALS_DIVISOR));

        // todo: transfer our native tokens as holding value of LP provider

        return ERC20(usdcAddress).balanceOf(address(this));
    }

    // returns the usdc reserves
    function getReserve() public view returns (uint256) {
        return IERC20(usdcAddress).balanceOf(address(this)).mul(USDC_DECIMALS_DIVISOR);
    }

    // function to take loan on position
    function takeLoanOnPosition(
        uint256 _loanAmount
    ) external {
        // fetch abstract position address for msg.sender
        FactoryContract factoryContract = FactoryContract(factoryContractAddress);
        address abstractPositionAddress = factoryContract.getContractForAccount(msg.sender);


        // get portfolio value for the borrower against their abstract position address
        AbstractPosition abstractPositionContract = AbstractPosition(abstractPositionAddress);

        uint256 portfolioValue = abstractPositionContract.getPortfolioValue();
        require(amountLoanedByUser[msg.sender] < portfolioValue.mul(LTV).div(100), "existing loan amount exceeding LTV");
        require(amountLoanedByUser[msg.sender] + _loanAmount < portfolioValue.mul(LTV).div(100), "LTV does not support loan amount");

        amountLoanedByUser[msg.sender] += _loanAmount;
        totalLoanedAmount += _loanAmount;

        ERC20(usdcAddress).transfer(msg.sender, _loanAmount.div(USDC_DECIMALS_DIVISOR));
    }

    function paybackLoan(
        uint256 _repayLoanAmount
    ) external {
        require(amountLoanedByUser[msg.sender] >= _repayLoanAmount, "loan taken lesser than paying amount");

        amountLoanedByUser[msg.sender] -= _repayLoanAmount;
        totalLoanedAmount -= _repayLoanAmount;

        ERC20(usdcAddress).transferFrom(msg.sender, address(this), _repayLoanAmount.div(USDC_DECIMALS_DIVISOR));

        return;
    }

    function existingLoanOnPortfolio (address _account) public view returns(uint256) {
        return amountLoanedByUser[_account];
    }

    // allow only the governing body to run function
    function _onlyGov() private view {
        require(msg.sender == gov, "only gov can call this function");
    }
}
