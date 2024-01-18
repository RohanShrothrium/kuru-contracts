// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0; 

interface IRouter {
    function marketAddress(address _baseAsset, address _qutoeAsset) external view returns (address);
}
