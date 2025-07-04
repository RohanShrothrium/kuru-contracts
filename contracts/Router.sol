// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============ Internal Interface Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

// ============ Internal Library Imports ============
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RouterErrors} from "./libraries/Errors.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";

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
    address public TRUSTED_FORWARDER;
    address public orderBookImplementation;
    address public marginAccountAddress;
    address public kuruAmmVaultImplementation;

    constructor() {
        _disableInitializers();
    }

    /**
     * @param _owner The owner of the contract.
     */
    function initialize(
        address _owner,
        address _marginAccount,
        address _orderbookImplementation,
        address _kuruAmmVaultImplementation,
        address _trustedForwarder
    ) public initializer {
        _initializeOwner(_owner);
        marginAccountAddress = _marginAccount;
        orderBookImplementation = _orderbookImplementation;
        kuruAmmVaultImplementation = _kuruAmmVaultImplementation;
        TRUSTED_FORWARDER = _trustedForwarder;
    }
    // @audit price precision, size precision must be power of 10
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
     * @param _kuruAmmSpread The spread in bps for the kuru amm vault
     */
    function deployProxy(
        IOrderBook.OrderBookType _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
    ) public returns (address proxy) {
        if (_type == IOrderBook.OrderBookType.NATIVE_IN_BASE) {
            require(_baseAssetAddress == address(0), RouterErrors.MarketTypeMismatch());
            require(_quoteAssetAddress != address(0), RouterErrors.MarketTypeMismatch());
        } else if (_type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE) {
            require(_baseAssetAddress != address(0), RouterErrors.MarketTypeMismatch());
            require(_quoteAssetAddress == address(0), RouterErrors.MarketTypeMismatch());
        } else {
            require(_baseAssetAddress != address(0), RouterErrors.MarketTypeMismatch());
            require(_quoteAssetAddress != address(0), RouterErrors.MarketTypeMismatch());
            require(_baseAssetAddress != _quoteAssetAddress, RouterErrors.BaseAndQuoteAssetSame());
        }
        uint256 _baseAssetDecimals =
            _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? 18 : IERC20Metadata(_baseAssetAddress).decimals();
        uint256 _quoteAssetDecimals =
            _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? 18 : IERC20Metadata(_quoteAssetAddress).decimals();
        {
            bytes32 _salt = _getSalt(
                _baseAssetAddress,
                _quoteAssetAddress,
                _sizePrecision,
                _pricePrecision,
                _tickSize,
                _minSize,
                _maxSize,
                _takerFeeBps,
                _makerFeeBps,
                _kuruAmmSpread
            );
            proxy = Create2.deploy(
                0,
                _salt,
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(orderBookImplementation, bytes("")))
            );
        }
        IKuruAMMVault _kuruAmmVault = IKuruAMMVault(
            Create2.deploy(
                0,
                keccak256(abi.encode(proxy)),
                abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(kuruAmmVaultImplementation, bytes("")))
            )
        );
        // @note native decimals hardcoded to 18
        {
            IOrderBook(proxy).initialize(
                address(this),
                _type,
                _baseAssetAddress,
                _baseAssetDecimals,
                _quoteAssetAddress,
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
                _kuruAmmSpread,
                TRUSTED_FORWARDER
            );
        }
        _kuruAmmVault.initialize(
            address(this), _baseAssetAddress, _quoteAssetAddress, marginAccountAddress, proxy, _kuruAmmSpread, "", ""
        );
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

        _kuruAmmVault.setMarketParams();

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
            _makerFeeBps,
            _kuruAmmSpread
        );

        return proxy;
    }

    function computeAddress(
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread,
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
            _makerFeeBps,
            _kuruAmmSpread
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

    function computeVaultAddress(address _marketAddress, address oldImplementation, bool old)
        public
        view
        returns (address)
    {
        bytes32 _salt = keccak256(abi.encode(_marketAddress));
        return Create2.computeAddress(
            _salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(old ? oldImplementation : kuruAmmVaultImplementation, bytes(""))
                )
            )
        );
    }

    /**
     * @dev Function to upgrade the orderbook implementation. Can only be called by owner
     * @param newImplementation The new deployed orderbook implementation
     */
    function upgradeOrderBookImplementation(address newImplementation) external onlyOwner {
        require(newImplementation != orderBookImplementation);
        emit OBImplementationUpdated(orderBookImplementation, newImplementation);
        orderBookImplementation = newImplementation;
    }

    /**
     * @dev Function to upgrade the kuru amm vault implementation. Can only be called by owner
     * @param newImplementation The new deployed kuru amm vault implementation
     */
    function upgradeVaultImplementation(address newImplementation) external onlyOwner {
        require(newImplementation != kuruAmmVaultImplementation);
        emit VaultImplementationUpdated(kuruAmmVaultImplementation, newImplementation);
        kuruAmmVaultImplementation = newImplementation;
    }

    /**
     * @dev Function to toggle the market state for pausing or resuming markets. Can only be called by owner
     * @param markets The markets to toggle the state of
     * @param state The state to set the market to
     */
    function toggleMarkets(address[] memory markets, IOrderBook.MarketState state) external onlyOwner {
        for (uint256 i = 0; i < markets.length; i++) {
            IOrderBook(markets[i]).toggleMarket(state);
        }
    }

    /**
     * @dev This function lets anyone batch upgrade orderbooks if a new implementation is available
     * @param proxies The proxies which are to be upgraded to the latest orderbook implementation
     */
    function upgradeMultipleOrderBookProxies(address[] memory proxies, bytes[] memory data) public onlyOwner {
        for (uint256 i = 0; i < proxies.length; i++) {
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(orderBookImplementation, data[i]);
        }
    }

    function upgradeMultipleVaultProxies(address[] memory proxies, bytes[] memory data) public onlyOwner {
        for (uint256 i = 0; i < proxies.length; i++) {
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(kuruAmmVaultImplementation, data[i]);
        }
    }

    // Register a market for a token pair
    function _registerMarket(
        address _baseAsset,
        address _quoteAsset,
        address _marketAddress,
        IOrderBook.OrderBookType _type
    ) internal {
        if (_type == IOrderBook.OrderBookType.NATIVE_IN_BASE) {
            _quoteAsset.safeApprove(_marketAddress, type(uint256).max);
        } else if (_type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE) {
            _baseAsset.safeApprove(_marketAddress, type(uint256).max);
        } else {
            _baseAsset.safeApprove(_marketAddress, type(uint256).max);
            _quoteAsset.safeApprove(_marketAddress, type(uint256).max);
        }

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
        require(_marketAddresses.length >= 1, RouterErrors.NoMarketsPassed());
        require(_isBuy.length == _marketAddresses.length, RouterErrors.LengthMismatch());
        require(_nativeSend.length == _marketAddresses.length, RouterErrors.LengthMismatch());
        if (_nativeSend[0] == false) {
            _debitToken.safeTransferFrom(msg.sender, address(this), _amount);
        }
        uint256 _cachedAmountIn = _amount;
        // @note: We don't validate msg.value cause we do it in the market contract and we assume no funds ever stay on the router.

        // @audit: Do we check if we debit token against token from first market params? Do we check if we credit token against token from last market params?
        // If router has any balance, it can be drained.
        // Will the router ever have non zero balances? Idts.
        for (uint256 i = 0; i < _marketAddresses.length; i++) {
            address _currentMarket = _marketAddresses[i];
            MarketParams memory _marketParams = verifiedMarket[_currentMarket];
            require(_marketParams.pricePrecision > 0, RouterErrors.InvalidMarket());
            IOrderBook market = IOrderBook(_currentMarket);
            uint256 _value = _nativeSend[i] ? _amount : 0;
            _amountOut = _isBuy[i]
                ? (
                    market.placeAndExecuteMarketBuy{value: _value}(
                        (
                            _amountToSize(
                                _amount,
                                true,
                                _marketParams.pricePrecision,
                                _marketParams.sizePrecision,
                                _marketParams.baseAssetDecimals,
                                _marketParams.quoteAssetDecimals
                            )
                        ),
                        0,
                        false,
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
                    0,
                    false,
                    true
                );

            _amount = _amountOut;
        }
        require(_amountOut >= _minAmountOut, RouterErrors.SlippageExceeded());
        emit KuruRouterSwap(msg.sender, _debitToken, _creditToken, _cachedAmountIn, _amountOut);
        if (_creditToken != address(0)) {
            _creditToken.safeTransfer(msg.sender, _amountOut);
        } else {
            (bool _success,) = (msg.sender).call{value: _amountOut}("");
            require(_success, RouterErrors.NativeAssetTransferFail());
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
        uint32 pricePrecision,
        uint96 sizePrecision,
        uint256 baseAssetDecimals,
        uint256 quoteAssetDecimals
    ) internal pure returns (uint96) {
        return _isBuy
            ? toU96((_amount * pricePrecision) / 10 ** quoteAssetDecimals)
            : toU96((_amount * sizePrecision) / 10 ** baseAssetDecimals);
    }

    function _getSalt(
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint32 _pricePrecision,
        uint32 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
        uint256 _makerFeeBps,
        uint96 _kuruAmmSpread
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
                _makerFeeBps,
                _kuruAmmSpread
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

    function toU96(uint256 _from) internal pure returns (uint96 _to) {
        require((_to = uint96(_from)) == _from, RouterErrors.Uint96Overflow());
    }

    receive() external payable {}
}
