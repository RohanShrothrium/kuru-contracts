// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./interfaces/ILendingContract.sol";
import "./interfaces/IAbstractPosition.sol";
import "./interfaces/IFactoryContract.sol";

import "./interfaces/IVault.sol";

import "./libraries/IERC20.sol";
import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";
/**
 * @title LendingContract
 * @dev A smart contract that allows users to take loans on their abstract positions, which are managed by the FactoryContract.
 * Loans are granted in USDC and the contract collects interest from borrowers. The interest rate is updated periodically
 * and depends on the total amount of liquidity provided by lenders and the amount of loans currently taken.
 */
contract LendingContract is ILendingContract {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDC_DECIMALS_DIVISOR = 10**24; // usdc has a decimal precision of 10^6 but GMX uses 10^18 (wei)
    uint256 public constant LTV = 60;
    uint256 public constant BORROW_RATE_PRECISION = 1000000;

    address public gov;
    address public factoryContractAddress;
    address public klpManagerAddress;

    address public usdcAddress;

    // variables to track loans
    mapping (address => uint256) public entryBorrowRate;
    mapping (address => uint256) public amountLoanedByUser;
    uint256 public totalLoanedAmount = 0;

    // borrow rate variables
    uint256 public borrowInterval = 3600;
    uint256 public borrowRateFactor = 100;
    uint256 public cumulativeBorrowRate;
    uint256 public lastBorrowTimes;

    /**
     * @dev Creates a new instance of the LendingContract
     * @param _usdcAddress Address of the USDC token contract
     */
    constructor(address _usdcAddress) {
        gov = msg.sender;

        usdcAddress = _usdcAddress;
    }

    /**
     * @dev Sets the factory contract address. Only callable by the contract owner
     * @param newAddress Address of the new factory contract
     */
    function setFactoryaContractAddress(address newAddress) external {
        _onlyGov();
        factoryContractAddress = newAddress;
    }

    /**
     * @dev Sets the KLP manager address. Only callable by the contract owner
     * @param newAddress Address of the new KLP manager
     */
    function setKlpManagerAddress(address newAddress) external {
        _onlyGov();
        klpManagerAddress = newAddress;
    }

    /**
     * @dev Sends USDC tokens to a KLP account. Only callable by the KLP manager
     * @param _account Address of the account to send the tokens to
     * @param _amount Amount of USDC tokens to send
     */
    function sendUsdcToLp(address _account, uint256 _amount) external {
        require(msg.sender == klpManagerAddress, "only the klp manager can call this function");

        require(IERC20(usdcAddress).transfer(_account, _amount), "failed to transfer out");
    }

    /**
     * @dev Updates the cumulative borrow rate
     */
    function updateCumulativeBorrowRate() public {
        // first time the borrow rate is being set
        if (lastBorrowTimes == 0) {
            lastBorrowTimes = block.timestamp.div(borrowInterval).mul(borrowInterval);
            return;
        }

        // if the interval has not passed, do nothing
        if (lastBorrowTimes.add(borrowInterval) > block.timestamp) {
            return;
        }

        uint256 borrowRate = getNextBorrowRate();
        cumulativeBorrowRate = cumulativeBorrowRate.add(borrowRate);

        return;
    }


    /**
     * @dev Calculates the next borrow rate
     * @return The next borrow rate
     */
    function getNextBorrowRate() public view returns (uint256) {
        if (lastBorrowTimes.add(borrowInterval) > block.timestamp) {
            return 0;
        }

        uint256 intervals = block.timestamp.sub(lastBorrowTimes).div(borrowInterval);
        uint256 _liquidityProvided = totalLiquidityProvided();
        if (_liquidityProvided == 0) { return 0; }

        return borrowRateFactor.mul(totalLoanedAmount).mul(intervals).div(_liquidityProvided);
    }

    /**
     * @dev Calculates the total liquidity provided
     * @return The total liquidity provided
     */
    function totalLiquidityProvided() public view returns (uint256) {
        uint256 _liquidityBalance = IERC20(usdcAddress).balanceOf(address(this));
        return (_liquidityBalance.mul(USDC_DECIMALS_DIVISOR)).add(totalLoanedAmount);
    }

    /**
     * @dev Calculates the USDC reserves
     * @return The USDC reserves
     */
    function getReserve() public view returns (uint256) {
        return IERC20(usdcAddress).balanceOf(address(this)).mul(USDC_DECIMALS_DIVISOR);
    }

    /**
     * @dev Calculates the interest to collect for a user
     * @param _account The address of the user
     * @return The interest to collect
     */
    function interestToCollect(address _account) public override view returns (uint256) {
        if (amountLoanedByUser[_account] == 0) { return 0; }

        uint256 _baseInterest = amountLoanedByUser[_account].mul(borrowRateFactor).div(BORROW_RATE_PRECISION);
        uint256 _interestToCollect = amountLoanedByUser[_account].mul(cumulativeBorrowRate.sub(entryBorrowRate[_account])).div(BORROW_RATE_PRECISION);

        return _interestToCollect.add(_baseInterest);
    }

    /**
     * @dev Takes a loan on a position
     * @param _loanAmount The amount of the loan to take
     */
    function takeLoanOnPosition(
        uint256 _loanAmount
    ) external {
        // fetch abstract position address for msg.sender
        IFactoryContract factoryContract = IFactoryContract(factoryContractAddress);
        address abstractPositionAddress = factoryContract.getContractForAccount(msg.sender);
        require(abstractPositionAddress != address(0), "acount does not have abstract contract");

        // get portfolio value for the borrower against their abstract position address
        IAbstractPosition abstractPositionContract = IAbstractPosition(abstractPositionAddress);

        uint256 portfolioValue = abstractPositionContract.getPortfolioValue();
        require(amountLoanedByUser[msg.sender] < portfolioValue.mul(LTV).div(100), "existing loan amount exceeding LTV");
        require(amountLoanedByUser[msg.sender].add(_loanAmount) < portfolioValue.mul(LTV).div(100), "LTV does not support loan amount");

        // calculate interest on existing loan
        uint256 _interestToCollect = interestToCollect(msg.sender);

        // increase loan amount stored against a user and update totals
        amountLoanedByUser[msg.sender] = amountLoanedByUser[msg.sender].add(_loanAmount);
        totalLoanedAmount = totalLoanedAmount.add(_loanAmount);

        // collect exiting interest: this means give lesser amount of usdc than requested
        _loanAmount = _loanAmount.sub(_interestToCollect);
        // set entery boorow rate as the current rate
        entryBorrowRate[msg.sender] = cumulativeBorrowRate;

        require(IERC20(usdcAddress).transfer(msg.sender, _loanAmount.div(USDC_DECIMALS_DIVISOR)), "failed to transfer out");
    }

    /**
     * @dev Repay loan on portfolio
     * @param _repayLoanAmount The amount of the loan to take
     */
    function paybackLoan(
        uint256 _repayLoanAmount
    ) external {
        uint256 _interestToCollect = interestToCollect(msg.sender);
        uint256 _loanWithBorrowFee = amountLoanedByUser[msg.sender].add(_interestToCollect);
        require(_loanWithBorrowFee >= _repayLoanAmount, "loan taken lesser than paying amount");

        amountLoanedByUser[msg.sender] = _loanWithBorrowFee.sub(_repayLoanAmount);
        totalLoanedAmount = totalLoanedAmount.sub(_repayLoanAmount.sub(_interestToCollect));

        // set entery borrow rate as the current rate
        entryBorrowRate[msg.sender] = cumulativeBorrowRate;

        // transfer in usdc from the borrower
        require(IERC20(usdcAddress).transferFrom(msg.sender, address(this), _repayLoanAmount.div(USDC_DECIMALS_DIVISOR)), "failed to transfer in");

        return;
    }

    /**
     * @dev Returns the amount of loans existing on a given user's portfolio.
     * @param _account The user's address to check for loans.
     * @return The total amount of loans the user has.
     */
    function existingLoanOnPortfolio (address _account) public view override returns(uint256) {
        return amountLoanedByUser[_account];
    }

    /**
     * @dev Private function that only allows the governing body to call it.
     */
    function _onlyGov() private view {
        require(msg.sender == gov, "only gov can call this function");
    }
}
