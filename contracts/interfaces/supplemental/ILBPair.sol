// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

interface ILBPair {

    function getFactory() external view returns (address factory);

    function getTokenX() external view returns (address tokenX);

    function getTokenY() external view returns (address tokenY);

    function getBinStep() external view returns (uint16 binStep);
}