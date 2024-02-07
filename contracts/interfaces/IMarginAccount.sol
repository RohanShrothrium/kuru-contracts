// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMarginAccount {
    function updateMarkets(address _marketAddress) external;

    function deposit(
        address _user,
        address _token,
        uint256 _amount
    ) external payable;

    function withdraw(uint256 _amount, address _token) external;
}
