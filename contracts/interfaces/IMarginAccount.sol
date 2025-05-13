// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IMarginAccount {
    function updateMarkets(address _marketAddress) external;

    function deposit(address _user, address _token, uint256 _amount) external payable;

    function withdraw(uint256 _amount, address _token) external;

    function debitUser(address _user, address _token, uint256 _amount) external;

    function creditFee(address _assetA, uint256 _feeA, address _assetB, uint256 _feeB) external returns (bool);

    function creditUser(address _user, address _token, uint256 _amount, bool _useMargin) external returns (bool);

    function creditUsersEncoded(bytes calldata _encodedData) external returns (bool);

    function getBalance(address _user, address _token) external view returns (uint256);
}
