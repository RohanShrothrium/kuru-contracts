//SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.20;

// ============ External Imports ============
import {ECDSA} from "solady/src/utils/ECDSA.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// ============ Internal Interface Imports ============
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {KuruForwarderErrors} from "./libraries/Errors.sol";

contract KuruForwarder is EIP712, Initializable, Ownable, UUPSUpgradeable {
    using ECDSA for bytes32;

    error ExecutionFailed(bytes);
    error PriceDependentRequestFailed(uint256 _currentPrice, uint256 _breakpointPrice);
    error DeadlineExpired();

    mapping(bytes4 => bool) public allowedInterface;
    mapping(bytes32 => bool) public executedPriceDependentRequest;

    struct ForwardRequest {
        address from;
        address market;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
        bytes4 selector;
        bytes data;
    }

    struct PriceDependentRequest {
        address from;
        address market;
        uint256 price;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
        bool isBelowPrice;
        bytes4 selector;
        bytes data;
    }

    struct CancelPriceDependentRequest {
        address from;
        uint256 nonce;
        uint256 deadline;
    }

    struct MarginAccountRequest {
        address from;
        address marginAccount;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
        bytes4 selector;
        bytes data;
    }

    bytes32 private constant _FORWARD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address market,uint256 value,uint256 nonce,uint256 deadline,bytes4 selector,bytes data)"
    );

    bytes32 private constant _PRICE_DEPENDENT_TYPEHASH = keccak256(
        "PriceDependentRequest(address from,address market,uint256 price,uint256 value,uint256 nonce,uint256 deadline,bool isBelowPrice,bytes4 selector,bytes data)"
    );

    bytes32 private constant _CANCEL_PRICE_DEPENDENT_TYPEHASH =
        keccak256("CancelPriceDependentRequest(address from,uint256 nonce,uint256 deadline)");

    bytes32 private constant _MARGIN_ACCOUNT_REQUEST_TYPEHASH = keccak256(
        "MarginAccountRequest(address from,address marginAccount,uint256 value,uint256 nonce,uint256 deadline,bytes4 selector,bytes data)"
    );

    mapping(address => uint256) private _nonces;

    constructor() {
        _disableInitializers();
    }

    // ============ auth =================
    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    // ============ initializer =================

    function initialize(address _owner, bytes4[] memory _allowedInterfaces) public initializer {
        _initializeOwner(_owner);
        for (uint256 i = 0; i < _allowedInterfaces.length; i++) {
            allowedInterface[_allowedInterfaces[i]] = true;
        }
    }

    // ============ owner functions =============

    function setAllowedInterfaces(bytes4[] memory _allowedInterfaces) external onlyOwner {
        for (uint256 i = 0; i < _allowedInterfaces.length; i++) {
            allowedInterface[_allowedInterfaces[i]] = true;
        }
    }

    function removeAllowedInterfaces(bytes4[] memory _allowedInterfaces) external onlyOwner {
        for (uint256 i = 0; i < _allowedInterfaces.length; i++) {
            allowedInterface[_allowedInterfaces[i]] = false;
        }
    }

    function _domainNameAndVersionMayChange() internal pure override returns (bool result) {
        return true;
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "KuruForwarder";
        version = "1.0.0";
    }

    function getNonce(address from) public view returns (uint256) {
        return _nonces[from];
    }

    function verify(ForwardRequest calldata req, bytes calldata signature) public view returns (bool) {
        require(block.timestamp <= req.deadline, DeadlineExpired());
        address signer = _hashTypedData(
            keccak256(
                abi.encode(
                    _FORWARD_TYPEHASH,
                    req.from,
                    req.market,
                    req.value,
                    req.nonce,
                    req.deadline,
                    req.selector,
                    keccak256(req.data)
                )
            )
        ).recoverCalldata(signature);
        return req.nonce >= _nonces[req.from] && signer == req.from;
    }

    //Does not check nonce because price dependent transaction nonces are not iterative
    //executePriceDependent() has special checks for nonces
    function verifyPriceDependent(PriceDependentRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        require(block.timestamp <= req.deadline, DeadlineExpired());
        address signer = _hashTypedData(
            keccak256(
                abi.encode(
                    _PRICE_DEPENDENT_TYPEHASH,
                    req.from,
                    req.market,
                    req.price,
                    req.value,
                    req.nonce,
                    req.deadline,
                    req.isBelowPrice,
                    req.selector,
                    keccak256(req.data)
                )
            )
        ).recoverCalldata(signature);
        require(
            !executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))],
            KuruForwarderErrors.NonceAlreadyUsed()
        );
        return signer == req.from;
    }

    function verifyCancelPriceDependent(CancelPriceDependentRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        require(block.timestamp <= req.deadline, DeadlineExpired());
        address signer = _hashTypedData(
            keccak256(abi.encode(_CANCEL_PRICE_DEPENDENT_TYPEHASH, req.from, req.nonce, req.deadline))
        ).recoverCalldata(signature);
        require(
            !executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))],
            KuruForwarderErrors.NonceAlreadyUsed()
        );
        return signer == req.from;
    }

    function verifyMarginAccountRequest(MarginAccountRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        require(block.timestamp <= req.deadline, DeadlineExpired());
        address signer = _hashTypedData(
            keccak256(
                abi.encode(
                    _MARGIN_ACCOUNT_REQUEST_TYPEHASH,
                    req.from,
                    req.marginAccount,
                    req.value,
                    req.nonce,
                    req.deadline,
                    req.selector,
                    keccak256(req.data)
                )
            )
        ).recoverCalldata(signature);
        return req.nonce >= _nonces[req.from] && signer == req.from;
    }

    function executeMarginAccountRequest(MarginAccountRequest calldata req, bytes calldata signature)
        public
        payable
        returns (bytes memory)
    {
        require(verifyMarginAccountRequest(req, signature), KuruForwarderErrors.SignatureMismatch());
        require(msg.value >= req.value, KuruForwarderErrors.InsufficientValue());
        require(allowedInterface[req.selector], KuruForwarderErrors.InterfaceNotAllowed());

        _nonces[req.from] = req.nonce + 1;

        (bool success, bytes memory returndata) =
            req.marginAccount.call{value: req.value}(abi.encodePacked(req.selector, req.data, req.from));

        if (!success) {
            revert ExecutionFailed(returndata);
        }

        return returndata;
    }

    function execute(ForwardRequest calldata req, bytes calldata signature) public payable returns (bytes memory) {
        require(verify(req, signature), KuruForwarderErrors.SignatureMismatch());
        require(msg.value >= req.value, KuruForwarderErrors.InsufficientValue());
        require(allowedInterface[req.selector], KuruForwarderErrors.InterfaceNotAllowed());

        _nonces[req.from] = req.nonce + 1;

        (bool success, bytes memory returndata) =
            req.market.call{value: req.value}(abi.encodePacked(req.selector, req.data, req.from));

        if (!success) {
            revert ExecutionFailed(returndata);
        }

        return returndata;
    }

    function executePriceDependent(PriceDependentRequest calldata req, bytes calldata signature)
        public
        payable
        returns (bytes memory)
    {
        require(verifyPriceDependent(req, signature), KuruForwarderErrors.SignatureMismatch());
        require(msg.value >= req.value, KuruForwarderErrors.InsufficientValue());
        require(allowedInterface[req.selector], KuruForwarderErrors.InterfaceNotAllowed());
        executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))] = true;

        (uint256 _currentBidPrice,) = IOrderBook(req.market).bestBidAsk();
        require(
            (req.isBelowPrice && req.price < _currentBidPrice) || (!req.isBelowPrice && req.price > _currentBidPrice),
            PriceDependentRequestFailed(_currentBidPrice, req.price)
        );
        (bool success, bytes memory returndata) =
            req.market.call{value: req.value}(abi.encodePacked(req.selector, req.data, req.from));

        if (!success) {
            revert ExecutionFailed(returndata);
        }

        return returndata;
    }

    function cancelPriceDependent(CancelPriceDependentRequest calldata req, bytes calldata signature) public {
        require(verifyCancelPriceDependent(req, signature), KuruForwarderErrors.SignatureMismatch());

        executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))] = true;
    }
}
