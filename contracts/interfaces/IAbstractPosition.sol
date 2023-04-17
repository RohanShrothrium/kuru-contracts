// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface IAbstractPosition {
    function getPortfolioValue() external view returns (uint256);
}
