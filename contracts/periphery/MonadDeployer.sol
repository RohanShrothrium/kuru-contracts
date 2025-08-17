// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.20;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {KuruERC20} from "./ERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IKuruAMMVault} from "../interfaces/IKuruAMMVault.sol";
import {IMarginAccount} from "../interfaces/IMarginAccount.sol";

contract MonadDeployer is Ownable {
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

    //INTERNAL VARIABLES
    IRouter immutable router;
    uint96 public kuruAmmSpread;
    address public kuruCollective;
    uint256 public kuruCollectiveFee; //in native token amount
    IMarginAccount immutable marginAccount;

    //EVENTS
    event PumpingTime(
        address indexed token, string tokenURI, address dev, uint256 supplyToDev, address market, bytes metadata
    );
    //ERRORS

    error InsufficientAssets(uint256 expected, uint256 received);

    //CONSTRUCTOR
    constructor(
        IRouter _router,
        address _owner,
        address _marginAccount,
        address _kuruCollective,
        uint96 _kuruAmmSpread,
        uint256 _kuruCollectiveFee
    ) {
        _initializeOwner(_owner);
        router = _router;
        marginAccount = IMarginAccount(_marginAccount);
        kuruAmmSpread = _kuruAmmSpread;
        kuruCollective = _kuruCollective;
        kuruCollectiveFee = _kuruCollectiveFee;
    }

    function deployTokenAndMarket(
        TokenParams memory tokenParams,
        MarketParams memory marketParams,
        bytes calldata metadata
    ) external payable returns (address market) {
        KuruERC20 token = new KuruERC20(tokenParams.name, tokenParams.symbol, tokenParams.initialSupply, address(this));
        market = router.deployProxy(
            IOrderBook.OrderBookType.NATIVE_IN_QUOTE,
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
        if (msg.value != (marketParams.nativeTokenAmount + kuruCollectiveFee)) {
            revert InsufficientAssets(marketParams.nativeTokenAmount + kuruCollectiveFee, msg.value);
        }
        (address vault,,,,,,,) = IOrderBook(market).getVaultParams();
        uint256 _supplyToVault = tokenParams.initialSupply * (10 ** 4 - tokenParams.supplyToDev) / 10 ** 4;
        token.approve(vault, _supplyToVault);
        IKuruAMMVault(vault).deposit{value: marketParams.nativeTokenAmount}(
            _supplyToVault, marketParams.nativeTokenAmount, address(this)
        );
        token.transfer(tokenParams.dev, tokenParams.initialSupply - _supplyToVault);
        marginAccount.deposit{value: kuruCollectiveFee}(kuruCollective, address(0), kuruCollectiveFee);
        emit PumpingTime(
            address(token),
            tokenParams.tokenURI,
            tokenParams.dev,
            tokenParams.initialSupply - _supplyToVault,
            market,
            metadata
        );
    }

    function setKuruAmmSpread(uint96 _kuruAmmSpread) external onlyOwner {
        kuruAmmSpread = _kuruAmmSpread;
    }

    function setKuruCollective(address _kuruCollective) external onlyOwner {
        kuruCollective = _kuruCollective;
    }

    function setKuruCollectiveFee(uint256 _kuruCollectiveFee) external onlyOwner {
        kuruCollectiveFee = _kuruCollectiveFee;
    }
}