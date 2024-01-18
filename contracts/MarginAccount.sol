// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============ Internal Interface Imports ============
import {IRouter} from "./interfaces/IRouter.sol";

// ============ Internal Library Imports ============
import {IERC20} from "./libraries/IERC20.sol";

contract MarginAccount {
    // Mapping from user addresses to their ETH balance
    mapping(bytes32 => uint256) public balances;
    IRouter immutable routerContract;

    // Native token
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Event for deposit tracking
    event Deposited(address indexed user, address token, uint256 amount);

    // Event for withdrawal tracking
    event Withdrawn(address indexed user, address token, uint256 amount);

    constructor(address _router) {
        routerContract = IRouter(_router);
    }

    /**
     * @dev This function is only callable by a verified market. This is used as the margin account that stores all assets of the user.
     * @param _user Address of the user whose account should be credited. 
     * @param _token address of token to be credit.
     * @param _amount amount to credit. 
     * @param _marketBaseAsset Address of the first token used for trading
     * @param _marketQutoeAsset Address of the second token used for trading
     */
    function creditUser(
        address _user,
        address _token,
        uint256 _amount,
        address _marketBaseAsset,
        address _marketQutoeAsset
    ) external {
        _isVerifiedMarket(_marketBaseAsset, _marketQutoeAsset, msg.sender);

        balances[_accountKey(_user, _token)] += _amount;

        emit Deposited(_user, _token, _amount);
    }

    /**
     * @dev Function for EOAs to deposit tokens on behalf of a user.
     * @param _user Address of the user whose account should be credited.
     * @param _token address of token to be credit.
     * @param _amount amount to credit. 
     */
    function deposit(
        address _user,
        address _token,
        uint256 _amount
    ) external payable {
        if (_token == ETH) {
            require(msg.value == _amount, "MarginAccount: amount and value mismatch");
            balances[_accountKey(_user, ETH)] += _amount;
        } else {
            IERC20(_token).transferFrom(msg.sender, address(this), _amount);
            balances[_accountKey(_user, _token)] += _amount;
        }

        emit Deposited(_user, _token, _amount);
    }

    /**
     * @dev Function for users to withdraw their assets.
     * @param _amount amount to withdraw.
     * @param _token address of token to be withdrawn.
     */
    function withdraw(uint256 _amount, address _token) external {
        require(
            _amount <= balances[_accountKey(msg.sender, _token)],
            "Insufficient balance"
        );
        balances[_accountKey(msg.sender, _token)] -= _amount;
        payable(msg.sender).transfer(_amount);
        emit Withdrawn(msg.sender, _token, _amount);
    }

    /**
     * @dev Function to check balance of a user for a given token.
     * @param _user user addresss
     * @param _token tokenA addresss
     */
    function getBalance(
        address _user,
        address _token
    ) external view returns (uint256) {
        return balances[_accountKey(_user, _token)];
    }

    /**
     * Function to calculate key of balances.
     * @param _user user addresss
     * @param _token tokenA addresss
     */
    function _accountKey(
        address _user,
        address _token
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_user, _token));
    }

    /**
     * Internal view function to 
     * @param _baseAsset Address of the first token used for trading.
     * @param _qutoeAsset Address of the second token used for trading.
     * @param _callerContract Contract address to be verified.
     */
    function _isVerifiedMarket(
        address _baseAsset,
        address _qutoeAsset,
        address _callerContract
    ) internal view {
        require(
            routerContract.marketAddress(_baseAsset, _qutoeAsset) ==
                _callerContract,
            "MarginAccount: Margin can be credited only through verified contracts"
        );
    }
}
