//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract KuruForwarder is EIP712 {
    using ECDSA for bytes32;
    error CustomX(bytes);
    mapping(bytes4 => bool) public allowedInterface;
    mapping(bytes32 => bool) public executedStopLoss;
    mapping(bytes32 => bool) public executedTakeProfit;

    struct ForwardRequest {
        address from;
        address market;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }

    bytes32 private constant _TYPEHASH = keccak256("ForwardRequest(address from,address market,uint256 value,uint256 gas,uint256 nonce,bytes data)");

    mapping(address => uint256) private _nonces;

    constructor(bytes4[] memory allowedInterfaces) EIP712("KuruForwarder", "1.0.0") {
        for (uint256 i = 0; i < allowedInterfaces.length; i++) {
            allowedInterface[allowedInterfaces[i]] = true;
        }
    }

    function getNonce(address from) public view returns (uint256) {
        return _nonces[from];
    }

    function verify(ForwardRequest calldata req, bytes calldata signature) public view returns (bool) {
        address signer = _hashTypedDataV4(keccak256(abi.encode(_TYPEHASH, req.from, req.market, req.value, req.gas, req.nonce, keccak256(req.data)))).recover(signature);
        return _nonces[req.from] == req.nonce && signer == req.from;
    }

    function execute(ForwardRequest calldata req, bytes calldata signature) public payable returns (bool, bytes memory) {
        require(verify(req, signature), "KuruForwarder: signature does not match request");
        
        bytes4 selector = bytes4(req.data[:4]);
        require(allowedInterface[selector], "KuruForwarder: interface not allowed");
        
        _nonces[req.from] = req.nonce + 1;

        (bool success, bytes memory returndata) = req.market.call{gas: req.gas, value: req.value}(
            abi.encodePacked(req.data, req.from)
        );

        if(!success){
            revert CustomX(returndata);
        }

        if (gasleft() <= req.gas / 63) {
            assembly {
                revert(0, 0)
            }
        }

        return (success, returndata);
    }
}