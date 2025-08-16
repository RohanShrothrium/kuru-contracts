// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============ Internal Interface Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";

// ============ Internal Library Imports ============
import {RouterErrors} from "./libraries/Errors.sol";

// ============ External Imports ============
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

contract Router is IRouter, Ownable, Initializable, UUPSUpgradeable {
    using SafeTransferLib for address;

    mapping(address => MarketParams) public verifiedMarket;

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
     * @param _marginAccount The address of the margin account
     * @param _orderbookImplementation The address of the orderbook implementation
     * @param _kuruAmmVaultImplementation The address of the kuru amm vault implementation
     * @param _trustedForwarder The address of the trusted forwarder
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
     * @param _takerFeeBps The taker fee in basis points
     * @param _makerFeeBps The maker fee in basis points. The maker fee must be lower than the taker fee.
     * @param _kuruAmmSpread The spread in basis points for the kuru amm vault
     * @return proxy The address of the deployed proxy
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
        require(_tickSize > 0, RouterErrors.InvalidTickSize());
        require(10 ** Math.log10(_sizePrecision) == _sizePrecision, RouterErrors.InvalidSizePrecision());
        require(10 ** Math.log10(_pricePrecision) == _pricePrecision, RouterErrors.InvalidPricePrecision());
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
        IMarginAccount(marginAccountAddress).updateMarkets(proxy);
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
            address(this), _baseAssetAddress, _quoteAssetAddress, marginAccountAddress, proxy, _kuruAmmSpread
        );

        _setApprovalsForMarket(_baseAssetAddress, _quoteAssetAddress, proxy, _type);

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
     * @dev This function lets the owner batch upgrade orderbooks if a new implementation is available
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

    /**
     * @dev This function lets the owner batch transfer ownership of contracts to a new owner
     * @param contracts The contracts which are to be transferred to the new owner
     * @param _newOwner The new owner of the contracts
     */
    function transferOwnershipForContracts(address[] memory contracts, address _newOwner) external onlyOwner {
        for (uint256 i = 0; i < contracts.length; i++) {
            Ownable(contracts[i]).transferOwnership(_newOwner);
        }
    }

    function _setApprovalsForMarket(
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
    }

    /**
     * @dev This function lets the user swap any token to any token across multiple markets
     * @param _marketAddresses The markets to swap through
     * @param _isBuy Whether the user wants to buy from or sell to the i-th market
     * @param _nativeSend Whether the user is sending native tokens or not to the i-th market
     * @param _debitToken The token the user wants to send
     * @param _creditToken The token the user wants to receive
     * @param _amount The amount of the debit token the user wants to send
     * @param _minAmountOut The minimum amount of the credit token the user wants to receive
     * @return _amountOut The amount of the credit token the user received
     */
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

        for (uint256 i = 0; i < _marketAddresses.length; i++) {
            address _currentMarket = _marketAddresses[i];
            MarketParams memory _marketParams = verifiedMarket[_currentMarket];
            require(_marketParams.pricePrecision > 0, RouterErrors.InvalidMarket());
            IOrderBook market = IOrderBook(_currentMarket);
            uint256 _value = _nativeSend[i] ? _amount : 0;
            _amountOut = _isBuy[i]
                ? (
                    market.placeAndExecuteMarketBuy{value: _value}(
                        toU96(_amount * _marketParams.pricePrecision / 10 ** _marketParams.quoteAssetDecimals),
                        0,
                        false,
                        true
                    )
                )
                : market.placeAndExecuteMarketSell{value: _value}(
                    toU96(_amount * _marketParams.sizePrecision / 10 ** _marketParams.baseAssetDecimals), 0, false, true
                );

            _amount = _amountOut;
        }
        require(_amountOut >= _minAmountOut, RouterErrors.SlippageExceeded());
        emit KuruRouterSwap(msg.sender, _debitToken, _creditToken, _cachedAmountIn, _amountOut);
        if (_creditToken != address(0)) {
            _creditToken.safeTransfer(msg.sender, _amountOut);
        } else {
            msg.sender.safeTransferETH(_amountOut);
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

    function toU96(uint256 _from) internal pure returns (uint96 _to) {
        require((_to = uint96(_from)) == _from, RouterErrors.Uint96Overflow());
    }

    receive() external payable {}
}
