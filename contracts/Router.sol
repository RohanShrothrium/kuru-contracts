// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Internal Interface Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

// ============ Internal Library Imports ============
import {IERC20} from "./libraries/IERC20.sol";

// ============ Internal Contract Imports ============
import {KuruAMMVault} from "./KuruAMMVault.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

contract Router is IRouter, Ownable, Initializable, UUPSUpgradeable {
    using SafeTransferLib for address;
    // Mapping of hash of token pairs to their market contract addresses

    mapping(address => MarketParams) public verifiedMarket;

    // used to create base/native and native/quote markets
    address private constant NATIVE = 0x0000000000000000000000000000000000000000;

    address orderBookImplementation;
    address marginAccountAddress;

    // Event for market registration
    event MarketRegistered(
        address baseAsset,
        address quoteAsset,
        address market,
        address vaultAddress,
        uint24 pricePrecision,
        uint96 sizePrecision,
        uint24 tickSize,
        uint96 minSize,
        uint96 maxSize,
        uint256 takerFeeBps,
        uint256 makerFeeBps
    );

    constructor() {
        _disableInitializers();
    }

    /**
     * @param _owner The owner of the contract.
     */
    function initialize(address _owner, address _marginAccount, address _implementation) public initializer {
        _initializeOwner(_owner);
        marginAccountAddress = _marginAccount;
        orderBookImplementation = _implementation;
    }

    /**
     * @dev Deploys an OrderBook proxy for a set of given parameters
     * @param _type The type of OrderBook which can be NO_NATIVE, NATIVE_IN_BASE or NATIVE_IN_QUOTE
     * @param _baseAssetAddress The base asset address. Can be address 0 if _type is NATIVE_IN_BASE
     * @param _quoteAssetAddress The quote asset address. Can be address 0 if _type is NATIVE_IN_QUOTE
     * @param _sizePrecision The size precision of the asset pair
     * @param _pricePrecision The price precision of the asset pair
     * @param _tickSize The tick size of the price
     * @param _minSize The minimum size an order must have to be placed
     * @param _maxSize The maximum size an order can have to be placed
     * @param _takerFeeBps The taker fee in bips per second.
     * @param _makerFeeBps The maker fee in bips per second. The maker fee must be lower than the taker fee.
     */
    function deployProxy(
        IOrderBook.OrderBookType _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint24 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) public returns (address proxy) {
        require(_baseAssetAddress != _quoteAssetAddress, "Router: Base and quote assets are the same!");
        {
            bytes32 _salt = _getSalt(
                _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? NATIVE : _baseAssetAddress,
                _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? NATIVE : _quoteAssetAddress,
                _sizePrecision,
                _pricePrecision,
                _tickSize,
                _minSize,
                _maxSize,
                _takerFeeBps,
                _makerFeeBps
            );
            proxy = Create2.deploy(
                0,
                _salt,
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(orderBookImplementation, bytes("")))
            );
        }
        KuruAMMVault _kuruAmmVault = _deployKuruAMMVault(_baseAssetAddress, _quoteAssetAddress, proxy, _kuruAmmSpread);
        uint256 _baseAssetDecimals =
            _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? 18 : IERC20(_baseAssetAddress).decimals();
        uint256 _quoteAssetDecimals =
            _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? 18 : IERC20(_quoteAssetAddress).decimals();
        // @note native decimals hardcoded to 18
        {
            IOrderBook(proxy).initialize(
                owner(),
                _type,
                _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? NATIVE : _baseAssetAddress,
                _baseAssetDecimals,
                _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? NATIVE : _quoteAssetAddress,
                _quoteAssetDecimals,
                marginAccountAddress,
                _sizePrecision,
                _pricePrecision,
                _tickSize,
                _minSize,
                _maxSize,
                _takerFeeBps,
                _makerFeeBps,
                address(_kuruAmmVault),
                _kuruAmmSpread
            );
        }

        verifiedMarket[proxy] = MarketParams(
            _pricePrecision,
            _sizePrecision,
            _baseAssetAddress,
            _baseAssetDecimals,
            _quoteAssetAddress,
            _quoteAssetDecimals,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps
        );

        KuruAMMVault(_kuruAmmVault).setMarketParams();

        _registerMarket(_baseAssetAddress, _quoteAssetAddress, proxy, _type);

        emit MarketRegistered(
            _baseAssetAddress,
            _quoteAssetAddress,
            proxy,
            address(_kuruAmmVault),
            _pricePrecision,
            _sizePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps
        );

        return proxy;
    }

    function computeAddress(
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint24 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        address oldImplementation,
        bool old
    ) public view returns (address proxy) {
        bytes32 _salt = _getSalt(
            _baseAssetAddress,
            _quoteAssetAddress,
            _sizePrecision,
            _pricePrecision,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps
        );
        proxy = Create2.computeAddress(
            _salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(old ? oldImplementation : orderBookImplementation, bytes(""))
                )
            )
        );
    }

    /**
     * @dev Function to upgrade the orderbook implementation. Can only be called by owner
     * @param newImplementation The new deployed orderbook implementation
     */
    function upgradeImplementation(address newImplementation) external onlyOwner {
        require(newImplementation != orderBookImplementation);
        orderBookImplementation = newImplementation;
    }

    /**
     * @dev This function lets anyone batch upgrade orderbooks if a new implementation is available
     * @param proxies The proxies which are to be upgraded to the latest orderbook implementation
     */
    function upgradeMultipleProxies(address[] memory proxies) public {
        for (uint256 i = 0; i < proxies.length; i++) {
            (bool success,) = proxies[i].call(abi.encodeWithSelector(0x3659cfe6, orderBookImplementation));
            require(success, "Router: Upgrade Failed");
        }
    }

    // Register a market for a token pair
    function _registerMarket(
        address _baseAsset,
        address _quoteAsset,
        address _marketAddress,
        IOrderBook.OrderBookType _type
    ) internal {
        _type == IOrderBook.OrderBookType.NATIVE_IN_BASE
            ? true
            : IERC20(_baseAsset).approve(_marketAddress, type(uint256).max);
        _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE
            ? true
            : IERC20(_quoteAsset).approve(_marketAddress, type(uint256).max);

        IMarginAccount(marginAccountAddress).updateMarkets(_marketAddress);
    }

    //@note should change this to accomodate native
    // Perform an any-to-any swap
    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        bool[] calldata _nativeSend,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external payable returns (uint256 _amountOut) {
        require(_marketAddresses.length >= 1, "Router: No markets in input");
        require(_isBuy.length == _marketAddresses.length, "Router: Sizes length mismatch");
        require(_nativeSend.length == _marketAddresses.length, "Router: Sizes length mismatch");
        if (_nativeSend[0] == false) {
            _debitToken.safeTransferFrom(msg.sender, address(this), _amount);
        }
        // @note: We don't validate msg.value cause we do it in the market contract and we assume no funds ever stay on the router.

        // @audit: Do we check if we debit token against token from first market params? Do we check if we credit token against token from last market params?
        // If router has any balance, it can be drained.
        // Will the router ever have non zero balances? Idts.
        for (uint256 i = 0; i < _marketAddresses.length; i++) {
            address _currentMarket = _marketAddresses[i];
            MarketParams memory _marketParams = verifiedMarket[_currentMarket];
            require(_marketParams.pricePrecision > 0, "Router: Invalid market!");
            IOrderBook market = IOrderBook(_currentMarket);
            uint256 _value = _nativeSend[i] ? _amount : 0;
            _amountOut = _isBuy[i]
                ? (
                    market.placeAndExecuteMarketBuy{value: _value}(
                        uint24(
                            _amountToSize(
                                _amount,
                                true,
                                _marketParams.pricePrecision,
                                _marketParams.sizePrecision,
                                _marketParams.baseAssetDecimals,
                                _marketParams.quoteAssetDecimals
                            )
                        ),
                        true
                    )
                )
                : market.placeAndExecuteMarketSell{value: _value}(
                    _amountToSize(
                        _amount,
                        false,
                        _marketParams.pricePrecision,
                        _marketParams.sizePrecision,
                        _marketParams.baseAssetDecimals,
                        _marketParams.quoteAssetDecimals
                    ),
                    true
                );

            _amount = _amountOut;
        }
        require(_amountOut >= _minAmountOut, "Router: Slippage exceeds expected value!");
        if (_creditToken != address(0)) {
            _creditToken.safeTransfer(msg.sender, _amountOut);
        } else {
            (bool _success,) = (msg.sender).call{value: _amountOut}("");
            require(_success, "Router: Native fund transfer failed");
        }
    }

    /**
     * @dev Overrides the function in Ownable so that owner is initialized only once
     */
    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    /**
     * @dev Makes sure owner is the one upgrading contract
     */
    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    function _amountToSize(
        uint256 _amount,
        bool _isBuy,
        uint24 pricePrecision,
        uint96 sizePrecision,
        uint256 baseAssetDecimals,
        uint256 quoteAssetDecimals
    ) internal pure returns (uint96) {
        return _isBuy
            ? uint24((_amount * pricePrecision) / 10 ** quoteAssetDecimals)
            : uint96((_amount * sizePrecision) / 10 ** baseAssetDecimals);
    }

    function _getSalt(
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint24 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps
    ) internal pure returns (bytes32) {
        {
            (_baseAssetAddress, _quoteAssetAddress) = _reOrder(_baseAssetAddress, _quoteAssetAddress);
        }
        return keccak256(
            abi.encodePacked(
                _baseAssetAddress,
                _quoteAssetAddress,
                _sizePrecision,
                _pricePrecision,
                _tickSize,
                _minSize,
                _maxSize,
                _takerFeeBps,
                _makerFeeBps
            )
        );
    }

    function _reOrder(address _tokenA, address _tokenB)
        internal
        pure
        returns (address _baseAsset, address _quoteAsset)
    {
        (_baseAsset, _quoteAsset) = (_tokenA > _tokenB) ? (_tokenB, _tokenA) : (_tokenA, _tokenB);
    }

    function _deployKuruAMMVault(address _token1Address, address _token2Address, address _marketAddress, uint96 _spread)
        internal
        returns (KuruAMMVault)
    {
        KuruAMMVault _vault =
            new KuruAMMVault(_token1Address, _token2Address, marginAccountAddress, _marketAddress, _spread / 10, "", "");

        return _vault;
    }

    receive() external payable {}
}
