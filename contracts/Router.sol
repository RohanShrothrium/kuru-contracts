// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Internal Interface Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

// ============ Internal Library Imports ============
import {IERC20} from "./libraries/IERC20.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

contract Router is IRouter, OwnableUpgradeable {
    // Mapping of hash of token pairs to their market contract addresses
    mapping(address => bool) public verifiedMarket;

    // used to create base/native and native/quote markets
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address orderBookImplementation;
    address marginAccountAddress;


    // Event for market registration
    event MarketRegistered(
        address baseAsset,
        address quoteAsset,
        address market
    );

    // Event for market updation
    event MarketUpdated(address baseAsset, address quoteAsset, address market);

    /**
     * @param _owner The owner of the contract.
     */
    function initialize(address _owner, address _marginAccount, address _implementation) public initializer {
        __Ownable_init();
        _transferOwnership(_owner);
        marginAccountAddress = _marginAccount;
        orderBookImplementation = _implementation;
    }

    function deployProxy(
        IOrderBook.OrderBookType _type,
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint96 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps
    ) public returns (address proxy) {

        {
            bytes32 _salt = _getSalt(
                _baseAssetAddress,
                _quoteAssetAddress,
                _sizePrecision,
                _pricePrecision,
                _tickSize,
                _minSize,
                _maxSize,
                _takerFeeBps
            );
            proxy = Create2.deploy(
                0,
                _salt,
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(orderBookImplementation, bytes(""))
                )
            );
        }
        //@note native decimals hardcoded to 18
        {
            IOrderBook(proxy).initialize(
                address(this),
                _type,
                _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE : _baseAssetAddress,
                _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? 18 : IERC20(_baseAssetAddress).decimals(),
                _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE : _quoteAssetAddress,
                _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? 18 : IERC20(_quoteAssetAddress).decimals(),
                marginAccountAddress,
                _sizePrecision,
                _pricePrecision,
                _tickSize,
                _minSize,
                _maxSize,
                _takerFeeBps
        );
        }

        _registerMarket(_baseAssetAddress, _quoteAssetAddress, proxy, _type);

        return proxy;
    }

    function _reOrder(address _tokenA, address _tokenB) internal pure returns (address _baseAsset, address _quoteAsset) {
        (_baseAsset, _quoteAsset) = (_tokenA > _tokenB) ? (_tokenB, _tokenA) : (_tokenA, _tokenB);
    }

    function computeAddress(
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint96 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps,
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
            _takerFeeBps
        );
        proxy = Create2.computeAddress(
            _salt,
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        old ? oldImplementation : orderBookImplementation,
                        bytes("")
                    )
                )
            )
        );
    }

    function upgradeImplementation(
        address newImplementation
    ) external onlyOwner {
        require(newImplementation != orderBookImplementation);
        orderBookImplementation = newImplementation;
    }

    function upgradeMultipleProxies(address[] memory proxies) public {
        for (uint i = 0; i < proxies.length; i++) {
            (bool success, ) = proxies[i].call(abi.encodeWithSelector(0x3659cfe6, orderBookImplementation));
            require(success, "Router: Upgrade Failed");
        }
    }

    // Register a market for a token pair
    function _registerMarket(
        address _baseAsset,
        address _quoteAsset,
        address _marketAddress,
        OrderBook.OrderBookType _type
    ) internal {
        verifiedMarket[_marketAddress] = true;
        _type == IOrderBook.OrderBookType.NATIVE_IN_BASE ? true : IERC20(_baseAsset).approve(_marketAddress, type(uint256).max);
        _type == IOrderBook.OrderBookType.NATIVE_IN_QUOTE ? true : IERC20(_quoteAsset).approve(_marketAddress, type(uint256).max);

        IMarginAccount(marginAccountAddress).updateMarkets(_marketAddress);

        emit MarketRegistered(_baseAsset, _quoteAsset, _marketAddress);
    }

    //@note should change this to accomodate native
    // Perform an any-to-any swap
    function anyToAnySwap(
        address[] calldata _marketAddresses,
        bool[] calldata _isBuy,
        address _debitToken,
        address _creditToken,
        uint256 _amount,
        uint256 _minAmountOut
    ) external returns (uint256 _amountOut) {
        require(_marketAddresses.length >= 1, "Router: No markets in input");
        require(
            _isBuy.length == _marketAddresses.length,
            "Router: Sizes length mismatch"
        );

        IERC20(_debitToken).transferFrom(msg.sender, address(this), _amount);

        // TODO: This is wrong logic, this has to be fixed. Proceeds from one round should be used for the other.
        for (uint i = 0; i < _marketAddresses.length; i++) {
            address _currentMarket = _marketAddresses[i];
            require(verifiedMarket[_currentMarket], "Router: Invalid market!");
            IOrderBook market = IOrderBook(_currentMarket);
            _amountOut = _isBuy[i]
                ? market.placeAndExecuteMarketBuy(
                   uint24( _amountToSize(_amount, true, market)),
                    true
                )
                : market.placeAndExecuteMarketSell(
                    _amountToSize(_amount, false, market),
                    true
                );
        
            _amount = _amountOut;
        }
        require(
            _amountOut >= _minAmountOut,
            "Router: Slippage exceeds expected value!"
        );
        IERC20(_creditToken).transfer(msg.sender, _amountOut);
    }


    function _amountToSize(
        uint256 _amount,
        bool _isBuy,
        IOrderBook market
    ) internal view returns (uint96) {
        return
            _isBuy
                ? uint24(
                    (_amount * market.getPricePrecision()) /
                        10 ** market.getQuoteAssetDecimals()
                )
                : uint96(
                    (_amount * market.getSizePrecision()) /
                        10 ** market.getBaseAssetDecimals()
                );
    }

    function _getSalt(
        address _baseAssetAddress,
        address _quoteAssetAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        uint96 _tickSize,
        uint96 _minSize,
        uint96 _maxSize,
        uint256 _takerFeeBps
    ) internal pure returns (bytes32) {
        {
            (_baseAssetAddress, _quoteAssetAddress) = _reOrder(_baseAssetAddress, _quoteAssetAddress);
        }
        return
            keccak256(
                abi.encodePacked(
                    _baseAssetAddress,
                    _quoteAssetAddress,
                    _sizePrecision,
                    _pricePrecision,
                    _tickSize,
                    _minSize,
                    _maxSize,
                    _takerFeeBps
                )
            );
    }
}
