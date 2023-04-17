// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface IFactoryContract {
    function createAbstractPosition() external returns (address);
    function getContractForAccount(address account) external view returns (address);
}
