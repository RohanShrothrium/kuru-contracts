// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {KuruERC20} from "../test/ERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IKuruAMMVault} from "../interfaces/IKuruAMMVault.sol";
import {IMarginAccount} from "../interfaces/IMarginAccount.sol";

contract MonadDeployer {
    IRouter immutable router;
    uint96 immutable kuruAmmSpread;
    address kuruCollective;
    uint256 kuruCollectiveFee; //in native token amount
    IMarginAccount immutable marginAccount;

    struct TokenParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 initialSupply;
        address dev;
        uint256 supplyToDev; //in bps
    }

    struct MarketParams {
        uint256 nativeTokenAmount;
        uint96 sizePrecision;
        uint32 pricePrecision;
        uint32 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    event PumpingTime(address indexed token, string tokenURI, address dev, uint256 supplyToDev, address market);

    constructor(IRouter _router, address _kuruCollective, uint96 _kuruAmmSpread, uint256 _kuruCollectiveFee) {
        router = _router;
        kuruAmmSpread = _kuruAmmSpread;
        kuruCollective = _kuruCollective;
        kuruCollectiveFee = _kuruCollectiveFee;
    }

    function deployTokenAndMarket(TokenParams memory tokenParams, MarketParams memory marketParams) external payable {
        KuruERC20 token = new KuruERC20(tokenParams.name, tokenParams.symbol, tokenParams.initialSupply, address(this));
        address market = router.deployProxy(
            IOrderBook.OrderBookType.NATIVE_IN_BASE,
            address(token),
            address(0),
            marketParams.sizePrecision,
            marketParams.pricePrecision,
            marketParams.tickSize,
            marketParams.minSize,
            marketParams.maxSize,
            marketParams.takerFeeBps,
            marketParams.makerFeeBps,
            kuruAmmSpread
        );
        (address vault,,,,,,,) = IOrderBook(market).getVaultParams();
        uint256 _supplyToVault = tokenParams.initialSupply * (10 ** 4 - tokenParams.supplyToDev) / 10 ** 4;
        token.approve(vault, _supplyToVault);
        IKuruAMMVault(vault).deposit(_supplyToVault, marketParams.nativeTokenAmount, address(this));
        token.transfer(tokenParams.dev, tokenParams.initialSupply - _supplyToVault);
        marginAccount.deposit(kuruCollective, address(0), kuruCollectiveFee);
        emit PumpingTime(
            address(token), tokenParams.tokenURI, tokenParams.dev, tokenParams.initialSupply - _supplyToVault, market
        );
    }
}
