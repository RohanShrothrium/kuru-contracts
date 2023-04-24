// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./interfaces/IAbstractPosition.sol";
import "./interfaces/ILendingContract.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPositionRouter.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IVault.sol";

import "./libraries/SafeMath.sol";
import "./libraries/IERC20.sol";

/**
 * @title AbstractPosition
 * @dev This contract implements the basic functionality of managing long and short positions for an index token, using a lending contract to borrow funds.
 * It relies on external smart contracts to create a position.
 * This contract holds the collateral and index tokens for all existing positions, and calculates the margin, the health factor, and the unrealized and realized profits and losses of each position.
 * This contract is owned by an external account, which is responsible for calling its functions in order to open, increase, or close positions.
 */
contract AbstractPosition is IAbstractPosition{
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

    // addresses
    address public gov;
    address public wethAddress;
    address public lendingContractAddress;

    // gmx contracts
    address public positionRouterAddress;
    address public routerAddress;
    address public orderBookAddress;
    address public vaultContractAddress;

    address public ownerAddress;

    uint256 public minExecutionFee;

    mapping (bytes32 => bool) positionExists;
    PositionData[] public existingPositionsData;

    uint256 decreasePositionRequests = 0;

    constructor(
        address _gov,
        address _wethAddress,
        address _lendingContractAddress,
        address _ownerAddress,
        address _positionRouterAddress,
        address _routerAddress,
        address _orderBookAddress,
        address _vaultContractAddress
    ) {
        // init state variables
        gov = _gov;
        ownerAddress = _ownerAddress;
        wethAddress = _wethAddress;
        lendingContractAddress = _lendingContractAddress;

        positionRouterAddress = _positionRouterAddress;
        routerAddress = _routerAddress;
        orderBookAddress = _orderBookAddress;
        vaultContractAddress = _vaultContractAddress;

        // approve position router address for router for smartcontract address
        IRouter router = IRouter(_routerAddress);
        router.approvePlugin(positionRouterAddress);
    }

    /**
     * @dev Updates the WETH address.
     * @param _wethAddress The new WETH address.
     */
    function setWethAddress(address _wethAddress) external {
        _onlyGov();
        wethAddress = _wethAddress;
    }

    /**
     * @dev Updates the lending contract address.
     * @param _lendingContractAddress The new lending contract address.
     */
    function setLendingContractAddress(address _lendingContractAddress) external {
        _onlyGov();
        lendingContractAddress = _lendingContractAddress;
    }

    /**
     * @dev Updates the position router address.
     * @param newAddress The new position router address.
     */
    function setPositionRouterAddress(address newAddress) external {
        _onlyGov();
        positionRouterAddress = newAddress;
    }

    /**
     * @dev Updates the router address.
     * @param newAddress The new router address.
     */
    function setRouterAddress(address newAddress) external {
        _onlyGov();
        routerAddress = newAddress;
    }

    /**
     * @dev Updates the vault contract address.
     * @param _vaultContractAddress The new minimum execution fee.
     */
    function setVaultContractAddress(address _vaultContractAddress) public {
        _onlyGov();
        vaultContractAddress = _vaultContractAddress;
    }

    /**
     * @dev Sets the minimum execution fee for orders.
     * @param _minExecutionFee The new minimum execution fee.
     */
    function setMinExecutionFee(uint256 _minExecutionFee) public {
        _onlyGov();
        minExecutionFee = _minExecutionFee;
    }

    /**
     * @dev Updates the list of all positions.
     * @param _path The path of tokens for the position.
     * @param _indexToken The index token for the position.
     * @param _isLong The position direction, long or short.
     */
    function updateExistingPositions(address[] memory _path, address _indexToken, bool _isLong) internal {
        address _collateralToken = _path[_path.length.sub(1)];

        if (!positionExists[getPositioKey(_indexToken, _collateralToken, _isLong)]) {
            existingPositionsData.push(PositionData(_indexToken, _collateralToken, _isLong));
            positionExists[getPositioKey(_indexToken, _collateralToken, _isLong)] = true;
        }
    }

     /**
     * @dev Function to open or increase a long or short position with the specified parameters.
     * @param _path An array of token addresses that form the path to the destination token.
     * @param _indexToken The address of the index token that the position is based on.
     * @param _amountIn The input amount of tokens.
     * @param _minOut The minimum acceptable amount of index tokens to receive as output from the trade.
     * @param _sizeDelta The amount to increase the position size by. If opening a new position, this value is the size of the position.
     * @param _isLong A boolean flag indicating if the position is long (true) or short (false).
     * @param _acceptablePrice The maximum price in basis points that the position can be opened or increased at.
     * @param _executionFee The fee to be paid for executing the trade.
     * @param _referralCode The referral code for the user.
     * @param _callbackTarget The address of the contract to be called on successful execution of the trade.
     * @return A bytes32 value representing the request ID for the trade.
     */
    function callCreateIncreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        bytes32 _referralCode,
        address _callbackTarget
    ) external payable returns (bytes32) {
        // validate weather the function is called by the owner of this smart contract
        require(msg.sender == ownerAddress, "only the owner can call this function");

        updateExistingPositions(_path, _indexToken, _isLong);

        IERC20(_path[0]).transferFrom(msg.sender, address(this), _amountIn);

        IERC20(_path[0]).approve(routerAddress, _amountIn);

        // call GMX smart contract to create increase position
        IPositionRouter positionRouter = IPositionRouter(positionRouterAddress);
        return
            positionRouter.createIncreasePosition{value: msg.value}(
                _path,
                _indexToken,
                _amountIn,
                _minOut,
                _sizeDelta,
                _isLong,
                _acceptablePrice,
                _executionFee,
                _referralCode,
                _callbackTarget
            );
    }

    /**
     * @dev Function to open or increase a long or short position with the specified parameters.
     * @param _path An array of token addresses that form the path to the destination token.
     * @param _indexToken The address of the index token that the position is based on.
     * @param _minOut The minimum acceptable amount of index tokens to receive as output from the trade.
     * @param _sizeDelta The amount to increase the position size by. If opening a new position, this value is the size of the position.
     * @param _isLong A boolean flag indicating if the position is long (true) or short (false).
     * @param _acceptablePrice The maximum price in basis points that the position can be opened or increased at.
     * @param _executionFee The fee to be paid for executing the trade.
     * @param _referralCode The referral code for the user.
     * @param _callbackTarget The address of the contract to be called on successful execution of the trade.
     * @return A bytes32 value representing the request ID for the trade.
     */
    function callCreateIncreasePositionETH(
        address[] memory _path,
        address _indexToken,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        bytes32 _referralCode,
        address _callbackTarget
    ) external payable returns (bytes32) {
        // validate weather the function is called by the owner of this smart contract
        require(msg.sender == ownerAddress, "only the owner can call this function");

        updateExistingPositions(_path, _indexToken, _isLong);

        // call GMX smart contract to create increase position
        IPositionRouter positionRouter = IPositionRouter(positionRouterAddress);
        return
            positionRouter.createIncreasePositionETH{value: msg.value}(
                _path,
                _indexToken,
                _minOut,
                _sizeDelta,
                _isLong,
                _acceptablePrice,
                _executionFee,
                _referralCode,
                _callbackTarget
            );
    }

    /**
     * @dev Internal helper function to decrease a position.
     * @param _path An array of token addresses that form the path to the index token.
     * @param _indexToken The address of the index token that the position is based on.
     * @param _collateralDelta The change in collateral size of the position.
     * @param _sizeDelta The change in position size.
     * @param _isLong A boolean flag indicating if the position is long (true) or short (false).
     * @param _receiver The address of the receiver of the decreased position.
     * @param _acceptablePrice The acceptable price for the trade.
     * @param _minOut The minimum output of the trade.
     * @param _executionFee The fee for executing the trade.
     * @param _withdrawETH A boolean flag to determine if ETH should be withdrawn.
     * @param _callbackTarget The address of the contract to be called on successful execution of the trade.
     * @return True if the decrease position was executed successfully.
     */
    function callCreateDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee,
        bool _withdrawETH,
        address _callbackTarget
    ) external payable returns (bool) {
        // validate weather the function is called by the owner of this smart contract
        require(msg.sender == ownerAddress || msg.sender == lendingContractAddress, "only the owner or gov can call this function");
        require(msg.value == _executionFee, "fee");

        require(validateDecreasePosition(_indexToken, _path, _isLong), "loan amount does not permit liquidation");

        // increment the decrease position requests by 1
        decreasePositionRequests = decreasePositionRequests.add(1);

        // call GMX smart contract to create decrease position
        _callCreateDecreasePosition(
            _path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _minOut,
            _executionFee,
            _withdrawETH,
            _callbackTarget
        );

        return executeDecreasePosition();
    }

    /**
     * @dev Internal helper function to decrease a position.
     * @param _path An array of token addresses that form the path to the destination token.
     * @param _indexToken The address of the index token that the position is based on.
     * @param _collateralDelta The change in collateral size of the position.
     * @param _sizeDelta The change in position size.
     * @param _isLong A boolean flag indicating if the position is long (true) or short (false).
     * @param _receiver The address of the receiver of the decreased position.
     * @param _acceptablePrice The acceptable price for the trade.
     * @param _minOut The minimum output of the trade.
     * @param _executionFee The fee for executing the trade.
     * @param _withdrawETH A boolean flag to determine if ETH should be withdrawn.
     * @param _callbackTarget The address of the contract to be called on successful execution of the trade.
     * @return True if the decrease position was executed successfully.
     */
    function _callCreateDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee,
        bool _withdrawETH,
        address _callbackTarget
    ) internal returns (bool) {
        IPositionRouter(positionRouterAddress).createDecreasePosition{value: msg.value}(
            _path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _minOut,
            _executionFee,
            _withdrawETH,
            _callbackTarget
        );

        return executeDecreasePosition();
    }

    /**
     * @dev Execute the decrease position at a particular index.
     * @return True if the decrease position was executed successfully.
     */
    function executeDecreasePosition() public returns (bool) {
        bytes32 _key = getRequestKey(address(this), decreasePositionRequests);

        return IPositionRouter(positionRouterAddress).executeDecreasePosition(_key, address(this));
    }

    /**
     * @dev Function used by liquidator nodes to liquidate the portfolio when the health factor goes below 1.
     */
    function liquidatePortfolio() public {
        uint256 _healthFactor = portfolioHealthFactor();
        require(_healthFactor < MIN_HEALTH_FACTOR, "health factor");

        for (uint256 i = 0; i < existingPositionsData.length; i++) {
            (
                uint256 _positionSize,
                uint256 _positionCollateral,
                uint256 _positionAveragePrice,
                uint256 _positionEntryFundingRate,
            ) = getPosition(existingPositionsData[i].indexToken, existingPositionsData[i].collateralToken, existingPositionsData[i].isLong);
            // if there is collateral for the position, liquidate it
            if (_positionCollateral > 0) {
                // get the portfolio value with margin: collateralDelta
                uint256 _positionValue = getPositionValueWithMargin(
                    existingPositionsData[i].indexToken,
                    existingPositionsData[i].collateralToken,
                    existingPositionsData[i].isLong,
                    _positionCollateral,
                    _positionSize,
                    _positionAveragePrice,
                    _positionEntryFundingRate
                );

                // acceptable price set to 0 if it is long and twice the vault price for longs
                uint256 _acceptablePrice = existingPositionsData[i].isLong ? 0 : IVault(vaultContractAddress).getMaxPrice(existingPositionsData[i].indexToken).mul(2);
                _liquidatePosition(
                    existingPositionsData[i].indexToken,
                    existingPositionsData[i].collateralToken,
                    existingPositionsData[i].isLong,
                    _positionSize,
                    _positionValue,
                    _acceptablePrice
                );
            }
        }
    }

    /**
     * @dev Internal helper function to liquidate each position.
     * @param _indexToken The address of the index token that the position is based on.
     * @param _collateralToken The collateral token for the position.
     * @param _isLong A boolean flag to determine if the position is long.
     * @param _positionSize The size of the position to liquidate.
     * @param _positionValue The value of the position to liquidate.
     * @param _acceptablePrice The acceptable price for the trade.
     */
    function _liquidatePosition(
        address _indexToken,
        address _collateralToken,
        bool _isLong,
        uint256 _positionSize,
        uint256 _positionValue,
        uint256 _acceptablePrice
    ) internal {
        // call decrease position and execute it
        _callCreateDecreasePosition(
            _pathFromCollateral(_collateralToken),
            _indexToken,
            _positionValue,
            _positionSize,
            _isLong,
            lendingContractAddress,
            _acceptablePrice,
            0,
            minExecutionFee,
            _isWeth(_collateralToken),
            address(0)
        );
    }

    /**
     * @dev Internal helper function to check if a token is WETH.
     * @param _tokenAddress The address of the token to check.
     * @return True if the token is WETH.
     */
    function _isWeth(address _tokenAddress) internal view returns (bool) {
        return _tokenAddress == wethAddress;
    }

    /**
     * @dev Internal helper function to get the path of tokens from collateral.
     * @param _tokenAddress The address of the collateral token.
     * @return The path of tokens from the collateral.
     */
    function _pathFromCollateral(address _tokenAddress) internal pure returns (address[] memory) {
        address[] memory  _path = new address[](1);
        _path[0] = _tokenAddress;

        return _path;
    }

    /**
    * @dev Validates whether a decrease in position can be made without breaching the minimum health factor requirement.
    * @param _indexToken The address of the index token in the position to be decreased.
    * @param _path The array of addresses representing the path from the index token to the collateral token.
    * @param _isLong The boolean value representing whether the position is long or short.
    * @return A boolean value indicating whether a decrease in position can be made without breaching the minimum health factor requirement.
    */
    function validateDecreasePosition(
        address _indexToken,
        address[] memory _path,
        bool _isLong
    ) public view returns (bool) {
        uint256 _existingLoan = ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);

        if (_existingLoan == 0) {
            return true;
        }

        (
            uint256 _positionSize,
            uint256 _positionCollateral,
            uint256 _positionAveragePrice,
            ,
            uint256 _positionLastIncreasedTime
        ) = getPosition(_indexToken, _path[_path.length.sub(1)], _isLong);

        uint256 _portfolioValue = getPortfolioValueWithMargin();

        uint256 positionValue = getPositionValue(
            _indexToken,
            _isLong,
            _positionCollateral,
            _positionSize,
            _positionAveragePrice,
            _positionLastIncreasedTime
        );

        if (_portfolioValue < positionValue) {
            return false;
        }

        uint256 _healthFactor = (_portfolioValue.sub(positionValue)).mul(MIN_HEALTH_FACTOR).div(_existingLoan);

        return _healthFactor > MIN_DECREASE_HEALTH_FACTOR;
    }

    /**
    * @dev Returns the value of the overall portfolio.
    * @return A uint256 value representing the value of the overall portfolio.
    */
    function getPortfolioValue() public override view returns (uint256) {
        uint256 _portfolioValue = 0;
        for (uint256 i = 0; i < existingPositionsData.length; i++) {
            (
                uint256 positionSize,
                uint256 positionCollateral,
                uint256 positionAveragePrice,
                ,
                uint256 positionLastIncreasedTime
            ) = getPosition(existingPositionsData[i].indexToken, existingPositionsData[i].collateralToken, existingPositionsData[i].isLong);
            if (positionCollateral > 0) {
                _portfolioValue += getPositionValue(existingPositionsData[i].indexToken, existingPositionsData[i].isLong, positionCollateral, positionSize, positionAveragePrice, positionLastIncreasedTime);
            }
        }

        return _portfolioValue;
    }

    /**
    * @dev Gets the absolute value of a position.
    * @param _indexToken The address of the index token in the position.
    * @param _isLong The boolean value representing whether the position is long or short.
    * @param _positionCollateral The amount of collateral in the position.
    * @param _positionSize The size of the position.
    * @param _positionAveragePrice The average price of the position.
    * @param _positionLastIncreasedTime The timestamp representing the last time the position was increased.
    * @return A uint256 value representing the absolute value of the position.
    */
    function getPositionValue(
        address _indexToken,
        bool _isLong,
        uint256 _positionCollateral,
        uint256 _positionSize,
        uint256 _positionAveragePrice,
        uint256 _positionLastIncreasedTime
    ) public view returns (uint256) {
        if (_positionCollateral == 0) {
            return 0;
        }
        (bool _hasProfit, uint256 delta) = IVault(vaultContractAddress).getDelta(
            _indexToken,
            _positionSize,
            _positionAveragePrice,
            _isLong,
            _positionLastIncreasedTime
        );

        if (_hasProfit) {
            return _positionCollateral.add(delta);
        } else {
            return _positionCollateral.sub(delta);
        }
    }

    /**
    * @dev Returns the value of the overall portfolio with L1 percent margin.
    * @return A uint256 value representing the value of the overall portfolio with L1 percent margin.
    */
    function getPortfolioValueWithMargin() public view returns (uint256) {
        uint256 _portfolioValue = 0;
        uint256 _portfolioSize = 0;
        for (uint256 i = 0; i < existingPositionsData.length; i++) {
            (
                uint256 _positionSize,
                uint256 _positionCollateral,
                uint256 _positionAveragePrice,
                uint256 _positionEntryFundingRate,
            ) = getPosition(existingPositionsData[i].indexToken, existingPositionsData[i].collateralToken, existingPositionsData[i].isLong);
            if (_positionCollateral > 0) {
                _portfolioValue += getPositionValueWithMargin(existingPositionsData[i].indexToken, existingPositionsData[i].collateralToken, existingPositionsData[i].isLong, _positionCollateral, _positionSize, _positionAveragePrice, _positionEntryFundingRate);
                _portfolioSize += _positionSize;
            }
        }

        uint256 _interestToCollect = ILendingContract(lendingContractAddress).interestToCollect(ownerAddress);

        _portfolioValue = _portfolioValue.sub(_portfolioSize.mul(L2).div(BASIS_POINTS_DIVISOR)).sub(_interestToCollect);

        return _portfolioValue;
    }

    /**
     * @dev Gets position value and factors in L1 percent price drop.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _isLong Whether the position is long.
     * @param _positionCollateral The amount of collateral held in the position.
     * @param _positionSize The size of the position.
     * @param _positionAveragePrice The average price of the position.
     * @param _positionEntryFundingRate The entry funding rate of the position.
     * @return The position value with margin.
     */
    function getPositionValueWithMargin(
        address _indexToken,
        address _collateralToken,
        bool _isLong,
        uint256 _positionCollateral,
        uint256 _positionSize,
        uint256 _positionAveragePrice,
        uint256 _positionEntryFundingRate
    ) public view returns (uint256) {
        (bool _hasProfit, uint256 delta) = getDeltaWithMargin(
            _indexToken,
            _positionSize,
            _positionAveragePrice,
            _isLong
        );

        uint256 _marginFees = IVault(vaultContractAddress).getFundingFee(_collateralToken, _positionSize, _positionEntryFundingRate);
        _marginFees += IVault(vaultContractAddress).getPositionFee(_positionSize);        

        if (_hasProfit) {
            return _positionCollateral.add(delta).sub(_marginFees);
        } else {
            return _positionCollateral.sub(delta).sub(_marginFees);
        }
    }

    
    /**
     * @dev Gets position for index token and side.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _isLong Whether the position is long.
     * @return The size, collateral, average price, entry funding rate, and last increased time of the position.
     */
    function getPosition(
        address _indexToken,
        address _collateralToken,
        bool _isLong
    ) public view returns (uint256, uint256, uint256, uint256, uint256) {
        Position memory position;
        (
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryFundingRate,
            ,
            ,
            ,
            position.lastIncreasedTime
        ) = IVault(vaultContractAddress).getPosition(address(this), _collateralToken, _indexToken, _isLong);


        return (
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryFundingRate,
            position.lastIncreasedTime
        );
    }

    /**
     * @dev Gets pnl for position with L1 percent drop margin.
     * @param _indexToken The address of the index token.
     * @param _size The size of the position.
     * @param _averagePrice The average price of the position.
     * @param _isLong Whether the position is long.
     * @return Whether the position has profit and the delta with margin.
     */
    function getDeltaWithMargin(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong) public view returns (bool, uint256) {
        require(_averagePrice > 0, "averge price of position has to be greater than 0");
        uint256 price = _isLong
            ? IVault(vaultContractAddress)
                .getMinPrice(_indexToken)
                .mul(BASIS_POINTS_DIVISOR.sub(L1))
                .div(BASIS_POINTS_DIVISOR)
            : IVault(vaultContractAddress)
                .getMaxPrice(_indexToken)
                .mul(BASIS_POINTS_DIVISOR.add(L1))
                .div(BASIS_POINTS_DIVISOR);
        uint256 priceDelta = _averagePrice > price ? _averagePrice.sub(price) : price.sub(_averagePrice);
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);

        bool hasProfit;

        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        return (hasProfit, delta);
    }

    /**
     * @dev Calculates the portfolio health factor which is used to validate liquidation.
     * @return The portfolio health factor.
     */
    function portfolioHealthFactor() public view returns (uint256) {
        uint256 _existingLoan = ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);
        uint256 _portfolioValue = getPortfolioValueWithMargin();

        if (_existingLoan == 0) {
            return 0;
        }

        return _portfolioValue.mul(MIN_HEALTH_FACTOR).div(_existingLoan);
    }

    /**
     * @dev Retrieves an array of all the existing positions.
     * @return An array of `PositionData` structs.
     */
    function getPositions() public view returns (PositionData[] memory) {
        return existingPositionsData;
    }

    /**
     * @dev Computes the unique key for a given position.
     * @param _indexToken The address of the index token in the position.
     * @param _collateralToken The address of the collateral token in the position.
     * @param _isLong Indicates whether the position is long or short.
     * @return The key of the position.
     */
    function getPositioKey(address _indexToken, address _collateralToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _collateralToken, _isLong));
    }

    /**
     * @dev Computes the unique key for a given request.
     * @param _account The address of the account that made the request.
     * @param _index The index of the request.
     * @return The key of the request.
     */
    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
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
