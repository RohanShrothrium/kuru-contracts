// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./interfaces/IAbstractPosition.sol";
import "./interfaces/ILendingContract.sol";

// GMX interfaces
import "./interfaces/IRouter.sol";
import "./interfaces/IPositionRouter.sol";
import "./interfaces/IVault.sol";

// Level interfaces
import "./interfaces/ILevelOracle.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IOrderManager.sol";

import "./libraries/SafeMath.sol";
import "./libraries/IERC20.sol";
import "./libraries/Types.sol";

/**
 * @title AbstractPosition
 * @dev This contract implements the basic functionality of managing long and short positions for an index token, using a lending contract to borrow funds.
 * It relies on external smart contracts to create a position.
 * This contract holds the collateral and index tokens for all existing positions, and calculates the margin, the health factor, and the unrealized and realized profits and losses of each position.
 * This contract is owned by an external account, which is responsible for calling its functions in order to open, increase, or close positions.
 */
contract AbstractPosition {
    using SafeMath for uint256;

    /**
     * @dev This struct represents a long or short position for an index token, along with some basic information about the position.
     * It contains the size, or the number of index tokens borrowed, the collateral, or the amount of collateral tokens held, the average entry price, the entry funding rate, the reserve amount, the realized P&L, the last time the position was increased, and the maximum loan amount.
     */
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        uint256 realisedPnl;
        uint256 lastIncreasedTime;
        uint256 maxLoanAmount;
    }

    /**
     * @dev This struct represents the data of a long or short position for an index token, such as the index token, the collateral token, and whether it is a long or short position.
     */
    struct PositionData {
        address indexToken;
        address collateralToken;
        bool isLong;
    }

    uint256 public constant MIN_HEALTH_FACTOR = 10000;
    uint256 public constant MIN_DECREASE_HEALTH_FACTOR = 11000;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant L1 = 100;
    uint256 public constant L2 = 100;
    uint256 public constant PRECISION = 10**10;
    address private constant BNB = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // addresses
    address public gov;
    address public wethAddress;
    address public lendingContractAddress;

    // bnb contracts
    address public orderManagerAddress;
    address public poolAddress;
    address public levelOracleAddress;

    address public ownerAddress;

    mapping (bytes32 => bool) positionExists;
    BnbPositionData[] public existingPositionsData;

    constructor(
        address _gov,
        address _wethAddress,
        address _lendingContractAddress,
        address _ownerAddress,
        address _orderManagerAddress,
        address _poolAddress,
        address _levelOracleAddress
    ) {
        // init state variables
        gov = _gov;
        ownerAddress = _ownerAddress;
        wethAddress = _wethAddress;
        lendingContractAddress = _lendingContractAddress;

        // initial level fi variables
        orderManagerAddress = _orderManagerAddress;
        poolAddress = _poolAddress;
        levelOracleAddress = _levelOracleAddress;
    }

    /**
     * @dev Updates the leding contract address.
     * @param _lendingContractAddress The new lending contract address.
     */
    function setLendingContractAddress(address _lendingContractAddress) public {
        _onlyGov();
        lendingContractAddress = _lendingContractAddress;
    }

    /**
     * @dev Updates the order manager address.
     * @param _orderManagerAddress The new order manager address.
     */
    function setOrderManagerAddress(address _orderManagerAddress) public {
        _onlyGov();
        orderManagerAddress = _orderManagerAddress;
    }

    /**
     * @dev Updates the level pool address.
     * @param _poolAddress The new level pool address.
     */
    function setLevelPoolAddress(address _poolAddress) public {
        _onlyGov();
        poolAddress = _poolAddress;
    }

    /**
     * @dev Updates the level oracle address.
     * @param _levelOracleAddress The new level oracle address.
     */
    function setLevelOracleAddress(address _levelOracleAddress) public {
        _onlyGov();
        levelOracleAddress = _levelOracleAddress;
    }

    /**
     * @dev Computes the unique key for a given position.
     * @param _indexToken The address of the index token in the position.
     * @param _collateralToken The address of the collateral token in the position.
     * @param _isLong Indicates whether the position is long or short.
     * @return The key of the position.
     */
    function getPositionKey(address _indexToken, address _collateralToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _collateralToken, _isLong));
    }

    /**
     * @dev Updates the list of all positions.
     * @param _collateralToken The path of tokens for the position.
     * @param _indexToken The index token for the position.
     * @param _side The position direction, long or short.
     */
    function updateExistingPositions(address _collateralToken, address _indexToken, Side _side) internal {
        if (!positionExists[getPositionKey(_indexToken, _collateralToken, _side == Side.LONG)]) {
            existingPositionsData.push(BnbPositionData(_indexToken, _collateralToken, _side));
            positionExists[getPositionKey(_indexToken, _collateralToken, _side == Side.LONG)] = true;
        }
    }

    /**
     * @dev Function used by liquidator nodes to liquidate the portfolio when the health factor goes below 1.
     */
    function liquidatePortfolio() public {
        uint256 _healthFactor = portfolioHealthFactor();
        require(_healthFactor < MIN_HEALTH_FACTOR && _healthFactor != 0, "health factor");

        for (uint256 i = 0; i < existingPositionsData.length; i++) {
            BnbPosition memory _position = getPosition(
                existingPositionsData[i].indexToken,
                existingPositionsData[i].collateralToken,
                existingPositionsData[i].side
            );

            uint256 _oraclePrice = ILevelOracle(levelOracleAddress).getPrice(existingPositionsData[i].indexToken, true);

            uint256 _price = existingPositionsData[i].side == Side.LONG ? 0 : _oraclePrice.mul(2);
            bytes memory _data = abi.encode(
                _price,
                existingPositionsData[i].collateralToken,
                _position.size,
                _position.collateralValue,
                bytes("")
            );

            _callDecreasePlaceOrder(
                existingPositionsData[i].side,
                existingPositionsData[i].indexToken,
                existingPositionsData[i].collateralToken,
                _data
            );
            
        }
    }

    /**
     * @dev Function to open or increase a long or short position with the specified parameters.
     *
     * @param _side The side of the order, either LONG or SHORT.
     * @param _indexToken The token that the position is in.
     * @param _collateralToken The token used as collateral for the position.
     * @param price The acceptable price for token.
     * @param payToken The token used to pay for the order.
     * @param purchaseAmount The amount of the payToken used to purchase the position.
     * @param sizeChange The amount by which to increase the position size.
     * @param _collateral The amount of collateral to use for the order.
     */
    function callIncreasePlaceOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        uint256 price,
        address payToken,
        uint256 purchaseAmount,
        uint256 sizeChange,
        uint256 _collateral
    ) public payable {
        require(msg.sender == ownerAddress, "only the owner can call this function");

        UpdatePositionType _updateType = UpdatePositionType.INCREASE;
        // todo: support limit orders
        OrderType _orderType = OrderType.MARKET;

        updateExistingPositions(_collateralToken, _indexToken, _side);

        if (payToken != BNB) {
            require(IERC20(payToken).transferFrom(msg.sender, address(this), purchaseAmount), "failed to transfer in collateral");
            require(IERC20(payToken).approve(orderManagerAddress, purchaseAmount), "failed to approve collateral transfer");
        }

        bytes memory _data = abi.encode(price, payToken, purchaseAmount, sizeChange, _collateral, bytes(""));

        IOrderManager(orderManagerAddress).placeOrder{value: msg.value}(
            _updateType,
            _side,
            _indexToken,
            _collateralToken,
            _orderType,
            _data
        );
    }

    /**
     * @dev Function to close or decrease a long or short position with the specified parameters.
     * @param _side The side of the order, either LONG or SHORT.
     * @param _indexToken The token that the position is in.
     * @param _collateralToken The token used as collateral for the position.
     * @param price The acceptable price for token.
     * @param payToken The token used to pay for the order.
     * @param sizeChange The amount by which to decrease the position size.
     * @param _collateral The amount of collateral to use for the order.
     */
    function callDecreasePlaceOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        uint256 price,
        address payToken,
        uint256 sizeChange,
        uint256 _collateral
    ) public payable {
        require(msg.sender == ownerAddress, "only the owner can call this function");

        require(validateDecreasePosition(_indexToken, _collateralToken, _side), "loan amount does not permit liquidation");

        bytes memory _data = abi.encode(price, payToken, sizeChange, _collateral, bytes(""));

        _callDecreasePlaceOrder(_side, _indexToken, _collateralToken, _data);
    }

    /**
     * @dev Function to close or decrease a long or short position with the specified parameters.
     * @param _side The side of the order, either LONG or SHORT.
     * @param _indexToken The token that the position is in.
     * @param _collateralToken The token used as collateral for the position.
     * @param _data encoded data for placing the order.
     */
    function _callDecreasePlaceOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        bytes memory _data
    ) internal {
        // todo: support limit orders
        IOrderManager(orderManagerAddress).placeOrder(
            UpdatePositionType.DECREASE, _side, _indexToken, _collateralToken, OrderType.MARKET, _data
        );
    }

    /**
    * @dev Validates whether a decrease in position can be made without breaching the minimum health factor requirement.
    * @param _indexToken The address of the index token in the position to be decreased.
    * @param _collateralToken The address of the collateral token in the position to be decreased.
    * @param _side The side of the order, either LONG or SHORT.
    * @return A boolean value indicating whether a decrease in position can be made without breaching the minimum health factor requirement.
    */
    function validateDecreasePosition(
        address _indexToken,
        address _collateralToken,
        Side _side
    ) public view returns (bool) {
        uint256 _existingLoan = ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);

        if (_existingLoan == 0) {
            return true;
        }

        uint256 _portfolioValue = getPortfolioValueWithMargin();

        uint256 _positionValue = getPositionValue(_indexToken, _collateralToken, _side);

        if (_portfolioValue < _positionValue) {
            return false;
        }

        uint256 _healthFactor = (_portfolioValue.sub(_positionValue)).mul(MIN_HEALTH_FACTOR).div(_existingLoan);

        return _healthFactor > MIN_DECREASE_HEALTH_FACTOR;
    }

    /**
     * @dev Gets position for index token and side.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the order, either LONG or SHORT.
     * @return The size, collateral, average price, entry funding rate, and last increased time of the position.
     */
    function getPosition(
        address _indexToken,
        address _collateralToken,
        Side _side
    ) public view returns (BnbPosition memory) {
        BnbPosition memory _position;
        (
            _position.size,
            _position.collateralValue,
            _position.reserveAmount,
            _position.entryPrice,
            _position.borrowIndex
        ) = IPool(poolAddress).positions(
            _getPositionKey(address(this), _indexToken, _collateralToken, _side)
        );

        return _position;
    }

    /**
     * @dev Gets the absolute value of a position.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the order, either LONG or SHORT.
     * @return _positionValue A uint256 value representing the absolute value of the position.
     */
    function getPositionValue(
        address _indexToken,
        address _collateralToken,
        Side _side
    ) public view returns (uint256 _positionValue) {
        BnbPosition memory _position = getPosition(_indexToken, _collateralToken, _side);

        (uint256 delta, bool hasProfit) = getDelta(_indexToken, _side, _position.size, _position.entryPrice);

        if (!hasProfit && delta > _position.collateralValue) {
            return 0;
        }

        hasProfit ? _positionValue = _position.collateralValue.add(delta) : _positionValue = _position.collateralValue.sub(delta);
    }

    /**
     * @dev Gets position value and factors in L1 percent price drop.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the order, either LONG or SHORT.
     * @return _positionValue The position value with margin.
     */
    function getPositionValueWithMargin(
        address _indexToken,
        address _collateralToken,
        Side _side
    ) public view returns (uint256 _positionValue) {
        BnbPosition memory _position = getPosition(_indexToken, _collateralToken, _side);

        uint256 _positionFee = _getPositionFee(_position, _indexToken, _position.size);

        (uint256 delta, bool hasProfit) = getDeltaWithMargin(_indexToken, _side, _position.size, _position.entryPrice);

        if (!hasProfit && delta.add(_positionFee) > _position.collateralValue) {
            return 0;
        }

        _positionValue = hasProfit ? _position.collateralValue.add(delta).sub(_positionFee) : _position.collateralValue.sub(delta).sub(_positionFee);
    }

    /**
     * @dev Returns the value of the overall portfolio.
     * @return A uint256 value representing the value of the overall portfolio.
     */
    function getPortfolioValue() public view returns (uint256) {
        uint256 _portfolioValue = 0;

        // iterate over all existing position
        for (uint256 i = 0; i < existingPositionsData.length; i++) {
            // get value of the position
            uint256 _positionValue = getPositionValueWithMargin(
                existingPositionsData[i].indexToken,
                existingPositionsData[i].collateralToken,
                existingPositionsData[i].side
            );
            
            // add the value to the overall portfolio value
            _portfolioValue = _portfolioValue.add(_positionValue);
        }

        return _portfolioValue;
    }

    /**
     * @dev Returns the value of the overall portfolio with L1 percent margin.
     * @return A uint256 value representing the value of the overall portfolio with L1 percent margin.
     */
    function getPortfolioValueWithMargin() public view returns (uint256) {
        uint256 _portfolioValue = 0;
        uint256 _portfolioSize = 0;
        for (uint256 i = 0; i < existingPositionsData.length; i++) {
            uint256 _positionValue = getPositionValue(
                existingPositionsData[i].indexToken,
                existingPositionsData[i].collateralToken,
                existingPositionsData[i].side
            );

            // add the value to the overall portfolio value
            _portfolioValue = _portfolioValue.add(_positionValue);

            BnbPosition memory _position = getPosition(
                existingPositionsData[i].indexToken,
                existingPositionsData[i].collateralToken,
                existingPositionsData[i].side
            );

            // add the position size to portfolio size
            _portfolioSize = _portfolioSize.add(_position.size);
        }

        uint256 _interestToCollect = ILendingContract(lendingContractAddress).interestToCollect(ownerAddress);

        _portfolioValue = _portfolioValue.sub(_portfolioSize.mul(L2).div(BASIS_POINTS_DIVISOR)).sub(_interestToCollect);

        return _portfolioValue;
    }

    /**
     * @dev Calculates the portfolio health factor which is used to validate liquidation.
     * @return The portfolio health factor.
     */
    function portfolioHealthFactor() public view returns (uint256) {
        uint256 _existingLoan = ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);
        if (_existingLoan == 0) {
            return 0;
        }

        uint256 _portfolioValue = getPortfolioValueWithMargin();

        return _portfolioValue.mul(MIN_HEALTH_FACTOR).div(_existingLoan);
    }

    /**
     * @dev Gets pnl for position.
     * @param _indexToken The address of the index token.
     * @param _side The side of the order, either LONG or SHORT.
     * @param _size The overall size of the position.
     * @param _averagePrice The average price of the position.
     * @return delta The absolute value of profit/loss.
     * @return hasProfit Bool representing the position has a profit.
     */
    function getDelta(
        address _indexToken,
        Side _side,
        uint256 _size,
        uint256 _averagePrice
    ) internal view returns (uint256 delta, bool hasProfit) {
        if (_size == 0 || _averagePrice == 0) {
            return (0, false);
        }

        uint256 _price = ILevelOracle(levelOracleAddress).getPrice(_indexToken, _side == Side.LONG);

        uint256 priceDelta = _averagePrice > _price ? _averagePrice.sub(_price) : _price.sub(_averagePrice);
        delta = _size.mul(priceDelta).div(_averagePrice);

        hasProfit;

       hasProfit = _side == Side.LONG ?  _price > _averagePrice : _averagePrice > _price;
    }

    /**
     * @dev Gets pnl for position with L1 percent drop margin.
     * @param _indexToken The address of the index token.
     * @param _side The side of the order, either LONG or SHORT.
     * @param _size The overall size of the position.
     * @param _averagePrice The average price of the position.
     * @return delta The absolute value of profit/loss.
     * @return hasProfit Bool representing the position has a profit.
     */
    function getDeltaWithMargin(
        address _indexToken,
        Side _side,
        uint256 _size,
        uint256 _averagePrice
    ) public view returns (uint256 delta, bool hasProfit) {
        require(_averagePrice > 0, "averge price of position has to be greater than 0");

        uint256 _price = _side == Side.LONG
            ? ILevelOracle(levelOracleAddress)
                .getPrice(_indexToken, false)
                .mul(BASIS_POINTS_DIVISOR.sub(L1))
                .div(BASIS_POINTS_DIVISOR)
            : ILevelOracle(levelOracleAddress)
                .getPrice(_indexToken, true)
                .mul(BASIS_POINTS_DIVISOR.add(L1))
                .div(BASIS_POINTS_DIVISOR);
        uint256 priceDelta = _averagePrice > _price ? _averagePrice.sub(_price) : _price.sub(_averagePrice);

        delta = _size.mul(priceDelta).div(_averagePrice);

        hasProfit = _side == Side.LONG ?  _price > _averagePrice : _averagePrice > _price;
    }

    /**
     * @dev Calculates the fee value for updating a BNB position with a changed size, denominated in the specified index token.
     * The fee value consists of two components: a borrow fee and a position fee. The borrow fee is based on the change in the borrow index
     * of the index token and the size of the position being updated. The position fee is based on the percentage change in size of the
     * position being updated and the position fee percentage defined in the pool's fee configuration.
     * @param _position The BNB position being updated.
     * @param _indexToken The address of the index token denominated in which the fee is calculated.
     * @param _sizeChanged The change in size of the position being updated.
     *
     * @return _feeValue The total fee value, in the specified index token.
     */
    function _getPositionFee(
        BnbPosition memory _position,
        address _indexToken,
        uint256 _sizeChanged
    ) public view returns (uint256 _feeValue) {
        // fetch fee data from level poool
        Fee memory _fee = IPool(poolAddress).fee();

        // fetch borrow index for index token from level pool
        uint256 _borrowIndex = IPool(poolAddress).poolTokens(_indexToken).borrowIndex;

        // calculate the borrow fee
        uint256 borrowFee = ((_borrowIndex.sub(_position.borrowIndex)).mul(_position.size)).div(PRECISION);

        // calculate the one time fee for updating possition
        uint256 positionFee = (_sizeChanged.mul(_fee.positionFee)).div(PRECISION);

        _feeValue = borrowFee + positionFee;
    }

    /**
     * @dev Retrieves an array of all the existing positions.
     * @return An array of `PositionData` structs.
     */
    function getPositions() public view returns (BnbPositionData[] memory) {
        return existingPositionsData;
    }

    function _getPositionKey(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

     /**
     * @dev Restricts function access to the governing body.
     */
    function _onlyGov() private view {
        require(msg.sender == gov, "only gov can call this function");
    }

    /**
     * @dev Deposits Ether into the contract.
     */
    function deposit() payable external {}
}
