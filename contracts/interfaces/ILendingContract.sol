// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

interface ILendingContract {
    function totalLiquidityProvided() external view returns (uint256);
    function sendUsdcToLp(address _account, uint256 _amount) external;
    function existingLoanOnPortfolio (address _account) external view returns(uint256);
    function interestToCollect(address _account) external view returns (uint256);
}
