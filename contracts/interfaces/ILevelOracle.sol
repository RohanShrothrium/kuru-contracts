// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface ILevelOracle {
    function getPrice(address token, bool max) external view returns (uint256);
    function getMultiplePrices(address[] calldata tokens, bool max) external view returns (uint256[] memory);
}
