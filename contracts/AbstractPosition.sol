// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./interfaces/IAbstractPosition.sol";
import "./interfaces/ILendingContract.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IPositionRouter.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IVault.sol";

import "./libraries/SafeMath.sol";

contract AbstractPosition is IAbstractPosition{
    using SafeMath for uint256;

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

    constructor(
        address _gov,
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
        lendingContractAddress = _lendingContractAddress;

        positionRouterAddress = _positionRouterAddress;
        routerAddress = _routerAddress;
        orderBookAddress = _orderBookAddress;
        vaultContractAddress = _vaultContractAddress;

        // approve position router address for router for smartcontract address
        IRouter router = IRouter(_routerAddress);
        router.approvePlugin(positionRouterAddress);
    }

    // update the positionRouter address, maybe GMX positionRouter address changes
    function setLendingContractAddress(address _lendingContractAddress) external {
        _onlyGov();
        lendingContractAddress = _lendingContractAddress;
    }

    // update the positionRouter address, maybe GMX positionRouter address changes
    function setPositionRouterAddress(address newAddress) external {
        _onlyGov();
        positionRouterAddress = newAddress;
    }

    // update the router address, maybe GMX router address changes
    function setRouterAddress(address newAddress) external {
        _onlyGov();
        routerAddress = newAddress;
    }

    // set min vault contract address
    function setVaultContractAddress(uint256 _minExecutionFee) public {
        _onlyGov();
        minExecutionFee = _minExecutionFee;
    }

    // set min execution fee for setting stop loss
    function setMinExecutionFee(uint256 _minExecutionFee) public {
        _onlyGov();
        minExecutionFee = _minExecutionFee;
    }

    // can be called only by an internal smartcontract function and is used to update the list of all positions
    function updateExistingPositions(address[] memory _path, address _indexToken, bool _isLong) internal {
        address _collateralToken = _path[_path.length.sub(1)];

        if (!positionExists[getPositioKey(_indexToken, _collateralToken, _isLong)]) {
            existingPositionsData.push(PositionData(_indexToken, _collateralToken, _isLong));
            positionExists[getPositioKey(_indexToken, _collateralToken, _isLong)] = true;
        }
    }

    // user calls this function when user wants to:
    // 1. opens a long or short position
    // 2. increase collateral for an existing position
    // 3. increase leverage for an existing
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

    // user calls this function when user wants to:
    // 1. opens a long or short position
    // 2. increase collateral for an existing position
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

    // user calls this function when user wants to:
    // 1. closes a long or short position
    // 2. decrease collateral for an existing position
    // 3. decrease size for an existing position
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
    ) external payable returns (bytes32) {
        // validate weather the function is called by the owner of this smart contract
        require(msg.sender == ownerAddress || msg.sender == lendingContractAddress, "only the owner or gov can call this function");
        require(msg.value == _executionFee, "fee");

        {require(validateDecreasePosition(_indexToken, _path, _isLong), "");}

        // allow to decrease position of non loaned assets
        {require(ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress) == 0, "can't liquidateposition as there is an existing loan");}

        // call GMX smart contract to create decrease position
        return
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
    }

    function validateDecreasePosition(
        address _indexToken,
        address[] memory _path,
        bool _isLong
    ) public view returns (bool) {
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

        uint256 _existingLoan = ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);

        uint256 _healthFactor = (_portfolioValue.sub(positionValue)).mul(MIN_HEALTH_FACTOR).div(_existingLoan);

        return _healthFactor > MIN_DECREASE_HEALTH_FACTOR;
    }

    // returns the value of the overall portfolio
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

    // gets absolute value of the position
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

    // returns the value of the overall portfolio with L1 percent margin
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

    // gets position value and factors in L1 percent price drop
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

    // gets position for index token and side
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

    // gets pnl for position with L1 percent drop margin
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

    // health factor is used to validate liquidation
    function portfolioHealthFactor() public view returns (uint256) {
        uint256 _existingLoan = ILendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);
        uint256 _portfolioValue = getPortfolioValueWithMargin();

        if (_existingLoan == 0) {
            return 0;
        }

        return _portfolioValue.mul(MIN_HEALTH_FACTOR).div(_existingLoan);
    }

    function getPositions() public view returns (PositionData[] memory) {
        return existingPositionsData;
    }

    function getPositioKey(address _indexToken, address _collateralToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_indexToken, _collateralToken, _isLong));
    }

    // allow only the governing body to run function
    function _onlyGov() private view {
        require(msg.sender == gov, "only gov can call this function");
    }

    // this function will be removed after testing.
    function deposit() payable external {
        // deposit sizes are restricted to 1 ether
        require(msg.value == 1 ether);
    }
}
