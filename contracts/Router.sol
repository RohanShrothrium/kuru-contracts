// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Internal Interface Imports ============
import {ICranklessOrderBook} from "./interfaces/ICranklessOrderBook.sol";
import {IRouter} from "./interfaces/IRouter.sol";

// ============ Internal Library Imports ============
import {IERC20} from "./libraries/IERC20.sol";

// ============ External Imports ============
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Router is IRouter, OwnableUpgradeable {
    // Mapping of hash of token pairs to their market contract addresses
    mapping(bytes32 => address) public markets;

    // used to create base/native and native/quote markets
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Event for market registration
    event MarketRegistered(address baseAsset, address quoteAsset, address market);

    // Event for market updation
    event MarketUpdated(address baseAsset, address quoteAsset, address market);

    /**
     * @param _owner The owner of the contract.
     */
    function initialize(address _owner) public initializer {
        __Ownable_init();
        _transferOwnership(_owner);
    }

    // Register a market for a token pair
    function registerMarket(address _baseAsset, address _quoteAsset, address _marketAddress) onlyOwner external {
        bytes32 pairKey = _marketsKey(_baseAsset, _quoteAsset);
        require(markets[pairKey] == address(0), "Router: Market already exists");
        markets[pairKey] = _marketAddress;

        IERC20(_baseAsset).approve(_marketAddress, type(uint256).max);
        IERC20(_quoteAsset).approve(_marketAddress, type(uint256).max);

        emit MarketRegistered(_baseAsset, _quoteAsset, _marketAddress);
    }

    // Register a market for a token pair
    function updateMarket(address _baseAsset, address quoteAsset, address _marketAddress) onlyOwner external {
        bytes32 pairKey = _marketsKey(_baseAsset, quoteAsset);
        require(markets[pairKey] != address(0), "Router: Market does not exist");
        markets[pairKey] = _marketAddress;

        emit MarketUpdated(_baseAsset, quoteAsset, _marketAddress);
    }

    // Perform an any-to-any swap
    function anyToAnySwap(
        address[] calldata _route,
        bool[] calldata _isBuy,
        uint256 _amount,
        uint256[][] calldata _orderIds
    ) external {
        require(_route.length >= 2, "Router: Invalid _route length");
        require(_isBuy.length == _route.length - 1, "Router: Sizes length mismatch");
        require(_orderIds.length == _route.length - 1, "Router: OrderIds length mismatch");

        IERC20(_route[0]).transferFrom(msg.sender, address(this), _amount);

        address _creditToken;
        // TODO: This is wrong logic, this has to be fixed. Proceeds from one round should be used for the other.
        for (uint i = 0; i < _route.length - 1; i++) {
            _creditToken = _route[i+1];
            uint256 _initBalance = _getTokenBalance(_creditToken);
            address _marketAddress = _isBuy[i] ? marketAddress(_route[i+1], _route[i]) : marketAddress(_route[i], _route[i + 1]);
            require(_marketAddress != address(0), "Router: Market does not exist");

            ICranklessOrderBook market = ICranklessOrderBook(_marketAddress);
            _isBuy[i]
                ? market.placeAndExecuteMarketBuy(
                    _orderIds[i],
                    _amountToSize(_amount, _isBuy[i], market),
                    true
                )
                : market.placeAndExecuteMarketSell(
                    _orderIds[i],
                    _amountToSize(_amount, _isBuy[i], market),
                    true
                );

            _amount = _getTokenBalance(_creditToken) - _initBalance;
        }

        IERC20(_creditToken).transfer(msg.sender, _amount);
    }

    function marketAddress(address _baseAsset, address _qutoeAsset) public view returns (address) {
        return markets[_marketsKey(_baseAsset, _qutoeAsset)];
    }

    function _getTokenBalance(address _token) internal view returns (uint256) {
        if (_token == ETH) {
            return address(this).balance;
        }

        return IERC20(_token).balanceOf(address(this));
    }

    function _amountToSize(uint256 _amount, bool _isBuy, ICranklessOrderBook market) internal view returns (uint96) {
        return
            _isBuy
                ? uint96(
                    (_amount * market.getPricePrecision()) /
                        10 ** market.getQuoteAssetDecimals()
                )
                : uint96(
                    (_amount * market.getSizePrecision()) /
                        10 ** market.getBaseAssetDecimals()
                );
    }

    // Function to generate a hash for a token pair
    function _marketsKey(address _baseAsset, address _qutoeAsset) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_baseAsset, _qutoeAsset));
    }
}
