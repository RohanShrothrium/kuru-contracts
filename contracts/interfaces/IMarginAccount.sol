// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.20;

interface IMarginAccount {
    event ProtocolStateUpdated(bool newState);

    event FeeCollectorUpdated(address newFeeCollector);

    event Deposit(address owner, address token, uint256 amount);

    event Withdrawal(address owner, address token, uint256 amount);

    function updateMarkets(address _marketAddress) external;

    function deposit(address _user, address _token, uint256 _amount) external payable;

    function withdraw(uint256 _amount, address _token) external;

    function debitUser(address _user, address _token, uint256 _amount) external;

    function creditFee(address _assetA, uint256 _feeA, address _assetB, uint256 _feeB) external;

    function creditUser(address _user, address _token, uint256 _amount, bool _useMargin) external;

    function creditUsersEncoded(bytes calldata _encodedData) external;

    function getBalance(address _user, address _token) external view returns (uint256);
}
