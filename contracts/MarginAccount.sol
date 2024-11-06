// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Internal Library Imports ============
import {IERC20} from "./libraries/IERC20.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC2771Context} from "./libraries/ERC2771Context.sol";
import {MarginAccountErrors} from "./libraries/Errors.sol";

// ============ Internal Interface Imports ============
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";

contract MarginAccount is IMarginAccount, ERC2771Context {
    using SafeTransferLib for address;
    // Mapping from user addresses to their NATIVE balance

    address trustedForwarder;
    mapping(bytes32 => uint256) public balances;

    // Mapping of hash of token pairs to their market contract addresses
    mapping(address => bool) public verifiedMarket;

    address immutable routerContractAddress;
    address feeCollector;
    // Native token
    address private constant NATIVE = 0x0000000000000000000000000000000000000000;

    event Deposit(address owner, address token, uint256 amount);
    event Withdrawal(address owner, address token, uint256 amount);

    constructor(address _router, address _feeCollector, address _trustedForwarder) {
        routerContractAddress = _router;
        feeCollector = _feeCollector;
        trustedForwarder = _trustedForwarder;
    }

    modifier onlyRouter() {
        require(msg.sender == routerContractAddress, MarginAccountErrors.OnlyRouterAllowed());
        _;
    }

    function isTrustedForwarder(address forwarder) public view override returns (bool) {
        return forwarder == trustedForwarder;
    }

    function _msgSender() internal view virtual override returns (address) {
        uint256 calldataLength = msg.data.length;
        uint256 contextSuffixLength = _contextSuffixLength();
        if (isTrustedForwarder(msg.sender) && calldataLength >= contextSuffixLength) {
            return address(bytes20(msg.data[calldataLength - contextSuffixLength:]));
        } else {
            return msg.sender;
        }
    }

    /**
     * @dev This function allows the router to register an official verified market.
     * @param _marketAddress Address of the orderbook of the market.
     */
    function updateMarkets(address _marketAddress) external onlyRouter {
        verifiedMarket[_marketAddress] = true;
    }

    /**
     * @dev This function allows a verified market to register fee collected
     * @param _assetA Address of first asset
     * @param _feeA Fee amount of _assetA to be credited
     * @param _assetB Address of second asset
     * @param _feeB Fee amount of _assetB to be credited
     */
    function creditFee(address _assetA, uint256 _feeA, address _assetB, uint256 _feeB) external returns (bool) {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());

        balances[_accountKey(feeCollector, _assetA)] += _feeA;
        balances[_accountKey(feeCollector, _assetB)] += _feeB;

        return true;
    }

    /**
     * @dev This function is only callable by a verified market. Verified markets consume user balances.
     * @param _user Address of the user whose account should be debited.
     * @param _token address of token to be debited.
     * @param _amount amount to debit.
     */
    function debitUser(address _user, address _token, uint256 _amount) external {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());
        require(balances[_accountKey(_user, _token)] >= _amount, MarginAccountErrors.InsufficientBalance());

        balances[_accountKey(_user, _token)] -= _amount;
    }

    /**
     * @dev This function is only callable by a verified market. Verified markets credit user balances.
     * @param _user Address of the user whose account should be credited.
     * @param _token address of token to be credit.
     * @param _amount amount to credit.
     */
    function creditUser(address _user, address _token, uint256 _amount, bool _useMargin) external returns (bool) {
        require(verifiedMarket[msg.sender], MarginAccountErrors.OnlyVerifiedMarketsAllowed());

        if (_useMargin) {
            balances[_accountKey(_user, _token)] += _amount;
        } else {
            if (_token == NATIVE) {
                (bool success,) = _user.call{value: _amount}("");
                require(success, MarginAccountErrors.NativeAssetTransferFail());
            } else {
                _token.safeTransfer(_user, _amount);
            }
        }

        return true;
    }

    /**
     * @dev This function is only callable by a verified market. Verified markets credit a bunch of users the tokens.
     * @param _encodedData Address of the user whose account should be credited.
     */
    function creditUsersEncoded(bytes calldata _encodedData) external returns (bool) {
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
                    (bool success,) = _user.call{value: _amount}("");
                    require(success, MarginAccountErrors.NativeAssetTransferFail());
                }
            }
        }

        return true;
    }

    /**
     * @dev Function for EOAs to deposit tokens on behalf of a user.
     * @param _user Address of the user whose account should be credited.
     * @param _token address of token to be credit.
     * @param _amount amount to credit.
     */
    function deposit(address _user, address _token, uint256 _amount) external payable {
        require(_user != address(0), MarginAccountErrors.ZeroAddressNotAllowed());
        if (_token == NATIVE) {
            require(msg.value == _amount, MarginAccountErrors.NativeAssetMismatch());
            balances[_accountKey(_user, NATIVE)] += _amount;
        } else {
            require(msg.value == 0, MarginAccountErrors.NativeAssetMismatch());
            _token.safeTransferFrom(_msgSender(), address(this), _amount);
            balances[_accountKey(_user, _token)] += _amount;
        }

        emit Deposit(_user, _token, _amount);
    }

    /**
     * @dev Function for users to withdraw their assets.
     * @param _amount amount to withdraw.
     * @param _token address of token to be withdrawn.
     */
    function withdraw(uint256 _amount, address _token) external {
        require(_amount <= balances[_accountKey(_msgSender(), _token)], MarginAccountErrors.InsufficientBalance());
        balances[_accountKey(_msgSender(), _token)] -= _amount;
        if (_token == NATIVE) {
            (bool _success,) = (_msgSender()).call{value: _amount}("");
            require(_success, MarginAccountErrors.NativeAssetTransferFail());
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
