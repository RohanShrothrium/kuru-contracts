// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface IKuruAMMVault {
    struct MarketParams {
        uint32 pricePrecision;
        uint96 sizePrecision;
        address baseAssetAddress;
        uint256 baseAssetDecimals;
        address quoteAssetAddress;
        uint256 quoteAssetDecimals;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    event KuruVaultDeposit(uint256 amount1, uint256 amount2, uint256 shares, address userAddress);

    event KuruVaultWithdraw(uint256 amount1, uint256 amount2, uint256 shares, address userAddress);

    function initialize(
        address _owner,
        address token1_,
        address token2_,
        address _marginAccount,
        address _market,
        uint96 _spread
    ) external;

    function setMarketParams() external;

    function deposit(uint256 amount1, uint256 amount2, address receiver) external payable returns (uint256);
}
