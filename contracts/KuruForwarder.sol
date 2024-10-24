//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ECDSA} from "solady/src/utils/ECDSA.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {KuruForwarderErrors} from "./libraries/Errors.sol";

contract KuruForwarder is EIP712 {
    using ECDSA for bytes32;

    error ExecutionFailed(bytes);
    error Price(uint256, uint256);

    mapping(bytes4 => bool) public allowedInterface;
    mapping(bytes32 => bool) public executedPriceDependentRequest;

    struct ForwardRequest {
        address from;
        address market;
        uint256 value;
        uint256 nonce;
        bytes data;
    }

    struct PriceDependentRequest {
        address from;
        address market;
        uint256 price;
        uint256 value;
        uint256 nonce;
        bool isBelowPrice;
        bytes data;
    }

    struct CancelPriceDependentRequest {
        address from;
        uint256 nonce;
    }

    struct MarginAccountRequest {
        address from;
        address marginAccount;
        uint256 value;
        uint256 nonce;
        bytes data;
    }

    bytes32 private constant _TYPEHASH =
        keccak256("ForwardRequest(address from,address market,uint256 value,uint256 nonce,bytes data)");

    bytes32 private constant _PRICE_DEPENDENT_TYPEHASH = keccak256(
        "PriceDependentRequest(address from,address market,uint256 price,uint256 value,uint256 nonce,bool isBelowPrice,bytes data)"
    );

    bytes32 private constant _CANCEL_PRICE_DEPENDENT_TYPEHASH =
        keccak256("CancelPriceDependentRequest(address from,uint256 nonce)");

    bytes32 private constant _MARGIN_ACCOUNT_REQUEST_TYPEHASH = 
        keccak256("MarginAccountRequest(address from,address marginAccount,uint256 value,uint256 nonce,bytes data)");

    mapping(address => uint256) private _nonces;

    constructor(bytes4[] memory allowedInterfaces) {
        for (uint256 i = 0; i < allowedInterfaces.length; i++) {
            allowedInterface[allowedInterfaces[i]] = true;
        }
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "KuruForwarder";
        version = "1.0.0";
    }

    function getNonce(address from) public view returns (uint256) {
        return _nonces[from];
    }

    function verify(ForwardRequest calldata req, bytes calldata signature) public view returns (bool) {
        address signer = _hashTypedData(
            keccak256(abi.encode(_TYPEHASH, req.from, req.market, req.value, req.nonce, keccak256(req.data)))
        ).recover(signature);
        return req.nonce >= _nonces[req.from] && signer == req.from;
    }

    //Does not check nonce because price dependent transaction nonces are not iterative
    //executePriceDependent() has special checks for nonces
    function verifyPriceDependent(PriceDependentRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        address signer = _hashTypedData(
            keccak256(
                abi.encode(
                    _PRICE_DEPENDENT_TYPEHASH,
                    req.from,
                    req.market,
                    req.price,
                    req.value,
                    req.nonce,
                    req.isBelowPrice,
                    keccak256(req.data)
                )
            )
        ).recover(signature);
        return signer == req.from;
    }

    function verifyCancelPriceDependent(CancelPriceDependentRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        address signer = _hashTypedData(keccak256(abi.encode(_CANCEL_PRICE_DEPENDENT_TYPEHASH, req.from, req.nonce)))
            .recover(signature);
        return signer == req.from;
    }

    function verifyMarginAccountRequest(MarginAccountRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        address signer = _hashTypedData(keccak256(abi.encode(_MARGIN_ACCOUNT_REQUEST_TYPEHASH, req.from, req.marginAccount, req.value, req.nonce, keccak256(req.data))))
            .recover(signature);
        return req.nonce >= _nonces[req.from] && signer == req.from;
    }

    function executeMarginAccountRequest(MarginAccountRequest calldata req, bytes calldata signature)
        public
        payable
        returns (bool, bytes memory)
    {
        require(verifyMarginAccountRequest(req, signature), KuruForwarderErrors.SignatureMismatch());
        
        bytes4 selector = bytes4(req.data[:4]);
        require(allowedInterface[selector], KuruForwarderErrors.InterfaceNotAllowed());

        _nonces[req.from] = req.nonce + 1;

        (bool success, bytes memory returndata) =
            req.marginAccount.call{gas: 63 * gasleft() / 64, value: req.value}(abi.encodePacked(req.data, req.from));

        if (!success) {
            revert ExecutionFailed(returndata);
        }

        return (success, returndata);
    }

    function execute(ForwardRequest calldata req, bytes calldata signature)
        public
        payable
        returns (bool, bytes memory)
    {
        require(verify(req, signature), KuruForwarderErrors.SignatureMismatch());

        bytes4 selector = bytes4(req.data[:4]);
        require(allowedInterface[selector], KuruForwarderErrors.InterfaceNotAllowed());

        _nonces[req.from] = req.nonce + 1;

        (bool success, bytes memory returndata) =
            req.market.call{gas: 63 * gasleft() / 64, value: req.value}(abi.encodePacked(req.data, req.from));

        if (!success) {
            revert ExecutionFailed(returndata);
        }

        return (success, returndata);
    }

    function executePriceDependent(PriceDependentRequest calldata req, bytes calldata signature)
        public
        payable
        returns (bool, bytes memory)
    {
        require(verifyPriceDependent(req, signature), KuruForwarderErrors.SignatureMismatch());

        bytes4 selector = bytes4(req.data[:4]);
        require(allowedInterface[selector], KuruForwarderErrors.InterfaceNotAllowed());
        require(
            !executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))],
            KuruForwarderErrors.NonceAlreadyUsed()
        );
        executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))] = true;

        (uint256 _currentBidPrice,) = IOrderBook(req.market).bestBidAsk();
        require(
            (req.isBelowPrice && req.price < _currentBidPrice) || (!req.isBelowPrice && req.price > _currentBidPrice),
            Price(_currentBidPrice, req.price)
        );
        (bool success, bytes memory returndata) =
            req.market.call{gas: 63 * gasleft() / 64, value: req.value}(abi.encodePacked(req.data, req.from));

        if (!success) {
            revert ExecutionFailed(returndata);
        }

        return (success, returndata);
    }

    function cancelPriceDependent(CancelPriceDependentRequest calldata req, bytes calldata signature) public {
        require(verifyCancelPriceDependent(req, signature), KuruForwarderErrors.SignatureMismatch());
        require(
            !executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))],
            KuruForwarderErrors.NonceAlreadyUsed()
        );
        executedPriceDependentRequest[keccak256(abi.encodePacked(req.from, req.nonce))] = true;
    }
}
