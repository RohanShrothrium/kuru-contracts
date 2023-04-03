// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./LendingContract.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPositionRouter.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IVault.sol";
import "./libraries/SafeMath.sol";

contract AbstractPosition {
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
        bool isLong;
    }

    uint256 public constant MIN_HEALTH_FACTOR = 10000;
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

    PositionData[] public existingPositions;

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

    // user calls this function when user wants to:
    // 1. opens a long or short position
    // 2. increase collateral for an existing position
    function callCreateIncreasePosition(
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

        existingPositions.push(PositionData(_indexToken, _isLong));

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

        // todo: if position is closed, delete position from here
        // todo: update condition

        // allow to decrease position of non loaned assets
        require(LendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress) == 0, "can't liquidateposition as there is an existing loan");

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

    // returns the value of the overall portfolio
    function getPortfolioValue() public view returns (uint256) {
        uint256 _positionValue = 0;
        for (uint256 i = 0; i < existingPositions.length; i++) {
            (
                uint256 positionSize,
                uint256 positionCollateral,
                uint256 positionAveragePrice,
                uint256 positionAastIncreasedTime
            ) = getPosition(existingPositions[i].indexToken, existingPositions[i].isLong);
            _positionValue += getPositionValue(positionCollateral, existingPositions[i].indexToken, positionSize, positionAveragePrice, existingPositions[i].isLong, positionAastIncreasedTime);
        }

        return _positionValue;
    }

    // gets absolute value of the position
    function getPositionValue(
        uint256 _positionCollateral,
        address _indexToken,
        uint256 _positionSize,
        uint256 _positionAveragePrice,
        bool _isLong,
        uint256 _positionLastIncreasedTime
    ) public view returns (uint256) {
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
        for (uint256 i = 0; i < existingPositions.length; i++) {
            (
                uint256 positionSize,
                uint256 positionCollateral,
                uint256 positionAveragePrice,
            ) = getPosition(existingPositions[i].indexToken, existingPositions[i].isLong);
            _portfolioValue += getPositionValueWithMargin(positionCollateral, existingPositions[i].indexToken, positionSize, positionAveragePrice, existingPositions[i].isLong);
            _portfolioSize += positionSize;
        }

        _portfolioValue = _portfolioValue.sub(_portfolioSize.mul(L2).div(BASIS_POINTS_DIVISOR));

        return _portfolioValue;
    }

    // gets position value and factors in L1 percent price drop
    function getPositionValueWithMargin(
        uint256 _positionCollateral,
        address _indexToken,
        uint256 _positionSize,
        uint256 _positionAveragePrice,
        bool _isLong
    ) public view returns (uint256) {
        (bool _hasProfit, uint256 delta) = getDeltaWithMargin(
            _indexToken,
            _positionSize,
            _positionAveragePrice,
            _isLong
        );

        if (_hasProfit) {
            return _positionCollateral.add(delta);
        } else {
            return _positionCollateral.sub(delta);
        }
    }

    // gets position for index token and side
    function getPosition(
        address _indexToken,
        bool _isLong
    ) public view returns (uint256, uint256, uint256, uint256) {
        Position memory position;
        (
            position.size,
            position.collateral,
            position.averagePrice,
            ,
            ,
            ,
            ,
            position.lastIncreasedTime
        ) = IVault(vaultContractAddress).getPosition(address(this), _indexToken, _indexToken, _isLong);


        return (
            position.size,
            position.collateral,
            position.averagePrice,
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
        uint256 _existingLoan = LendingContract(lendingContractAddress).existingLoanOnPortfolio(ownerAddress);
        uint256 _portfolioValue = getPortfolioValueWithMargin();
        _portfolioValue = _portfolioValue.sub(_existingLoan);

        if (_existingLoan == 0) {
            return 0;
        }

        return _portfolioValue.mul(MIN_HEALTH_FACTOR).div(_existingLoan);
    }

    function getPositios() public view returns (PositionData[] memory) {
        return existingPositions;
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
