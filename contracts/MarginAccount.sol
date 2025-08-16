// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============ External Imports ============
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// ============ Internal Library Imports ============
import {ERC2771Context} from "./libraries/ERC2771Context.sol";
import {MarginAccountErrors} from "./libraries/Errors.sol";

// ============ Internal Interface Imports ============
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

contract MarginAccount is IMarginAccount, ERC2771Context, Ownable, Initializable, UUPSUpgradeable {
    using SafeTransferLib for address;

    address trustedForwarder;

    bool protocolPaused;

    mapping(bytes32 => uint256) public balances;

    mapping(address => bool) public verifiedMarket;

    address routerContractAddress;
    address feeCollector;

    address private constant NATIVE = 0x0000000000000000000000000000000000000000;

    constructor() {
        _disableInitializers();
    }

    // ============ admin ================
    function toggleProtocolState(bool _state) external onlyOwner {
        require(protocolPaused != _state, MarginAccountErrors.ProtocolStateNotChanged());
        protocolPaused = _state;
        emit ProtocolStateUpdated(_state);
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(feeCollector != _feeCollector, MarginAccountErrors.FeeCollectorNotChanged());
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(_feeCollector);
    }

    // ============ auth =================

    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    modifier onlyRouter() {
        require(msg.sender == routerContractAddress, MarginAccountErrors.OnlyRouterAllowed());
        _;
    }

    modifier protocolActive() {
        require(!protocolPaused, MarginAccountErrors.ProtocolPaused());
        _;
    }

    function isTrustedForwarder(address forwarder) public view override returns (bool) {
        return forwarder == trustedForwarder;
    }

    // ============ initializer =================

    function initialize(address _owner, address _router, address _feeCollector, address _trustedForwarder)
        public
        initializer
    {
        _initializeOwner(_owner);
        routerContractAddress = _router;
        feeCollector = _feeCollector;
        trustedForwarder = _trustedForwarder;
    }

    // ============ router functions=================

    /**
     * @dev This function allows the router to register an official verified market.
     * @param _marketAddress Address of the orderbook of the market.
     */
    function updateMarkets(address _marketAddress) external onlyRouter protocolActive {
        verifiedMarket[_marketAddress] = true;
    }

    // ============ market functions=================

    /**
     * @dev This function is only callable by a verified market. Verified markets consume user balances.
     * @param _user address of the user whose account should be debited.
     * @param _token address of token to be debited.
     * @param _amount amount to debit.
     */
    function debitUser(address _user, address _token, uint256 _amount) external protocolActive {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());
        require(balances[_accountKey(_user, _token)] >= _amount, MarginAccountErrors.InsufficientBalance());

        balances[_accountKey(_user, _token)] -= _amount;
    }

    /**
     * @dev This function is only callable by a verified market. Verified markets credit user balances.
     * @param _user address of the user whose account should be credited.
     * @param _token address of token to be credit.
     * @param _amount amount to credit.
     * @param _useMargin whether to use margin or not - if not, user will receive token through an erc20 transfer
     */
    function creditUser(address _user, address _token, uint256 _amount, bool _useMargin) external protocolActive {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());

        if (_useMargin) {
            balances[_accountKey(_user, _token)] += _amount;
        } else {
            if (_token != NATIVE) {
                _token.safeTransfer(_user, _amount);
            } else {
                _user.safeTransferETH(_amount);
            }
        }
    }

    /**
     * @dev This function is only callable by a verified market. Verified markets credit a bunch of users the tokens.
     * @param _encodedData Address of the user whose account should be credited.
     */
    function creditUsersEncoded(bytes calldata _encodedData) external protocolActive {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());

        uint256 offset = 0;
        while (offset < _encodedData.length) {
            (address _user, address _token, uint256 _amount, bool _useMargin) =
                abi.decode(_encodedData[offset:offset + 128], (address, address, uint256, bool));
            offset += 128;

            if (_useMargin) {
                balances[_accountKey(_user, _token)] += _amount;
            } else {
                if (_token != NATIVE) {
                    _token.safeTransfer(_user, _amount);
                } else {
                    _user.safeTransferETH(_amount);
                }
            }
        }
    }

    /**
     * @dev This function allows a verified market to register fee collected
     * @param _assetA Address of first asset
     * @param _feeA Fee amount of _assetA to be credited
     * @param _assetB Address of second asset
     * @param _feeB Fee amount of _assetB to be credited
     */
    function creditFee(address _assetA, uint256 _feeA, address _assetB, uint256 _feeB) external protocolActive {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());

        balances[_accountKey(feeCollector, _assetA)] += _feeA;
        balances[_accountKey(feeCollector, _assetB)] += _feeB;
    }

    // ============ user functions=================

    /**
     * @dev This function allows a user to claim all of their tokens from the margin account.
     * @param _tokens Array of tokens to claim.
     */
    function batchWithdrawMaxTokens(address[] calldata _tokens) external protocolActive {
        uint256 _balance;
        for (uint256 i = 0; i < _tokens.length; i++) {
            _balance = balances[_accountKey(_msgSender(), _tokens[i])];
            balances[_accountKey(_msgSender(), _tokens[i])] = 0;
            if (_balance > 0) {
                if (_tokens[i] == NATIVE) {
                    _msgSender().safeTransferETH(_balance);
                } else {
                    _tokens[i].safeTransfer(_msgSender(), _balance);
                }
            }
        }
    }

    /**
     * @dev Function for EOAs to deposit tokens on behalf of a user.
     * @param _user Address of the user whose account should be credited.
     * @param _token address of token to be credit.
     * @param _amount amount to credit.
     */
    function deposit(address _user, address _token, uint256 _amount) external payable protocolActive {
        require(_user != address(0), MarginAccountErrors.ZeroAddressNotAllowed());
        if (_token == NATIVE) {
            require(msg.value == _amount, MarginAccountErrors.NativeAssetMismatch());
            balances[_accountKey(_user, NATIVE)] += _amount;
        } else {
            require(msg.value == 0, MarginAccountErrors.NativeAssetMismatch());
            balances[_accountKey(_user, _token)] += _amount;
            _token.safeTransferFrom(_msgSender(), address(this), _amount);
        }

        emit Deposit(_user, _token, _amount);
    }

    /**
     * @dev Function for users to withdraw their assets.
     * @param _amount amount to withdraw.
     * @param _token address of token to be withdrawn.
     */
    function withdraw(uint256 _amount, address _token) external protocolActive {
        require(_amount <= balances[_accountKey(_msgSender(), _token)], MarginAccountErrors.InsufficientBalance());
        balances[_accountKey(_msgSender(), _token)] -= _amount;
        if (_token == NATIVE) {
            _msgSender().safeTransferETH(_amount);
        } else {
            _token.safeTransfer(_msgSender(), _amount);
        }

        emit Withdrawal(_msgSender(), _token, _amount);
    }

    /**
     * @dev Function to check balance of a user for a given token.
     * @param _user user addresss
     * @param _token tokenA addresss
     */
    function getBalance(address _user, address _token) external view returns (uint256) {
        return balances[_accountKey(_user, _token)];
    }

    /**
     * Function to calculate key of balances.
     * @param _user user addresss
     * @param _token tokenA addresss
     */
    function _accountKey(address _user, address _token) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_user, _token));
    }

    receive() external payable {}
}
