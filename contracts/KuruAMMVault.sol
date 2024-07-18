// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

/**
 * @dev Implementation of the ERC4626 "Tokenized Vault Standard" as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[EIP-4626].
 *
 * This extension allows the minting and burning of "shares" (represented using the ERC20 inheritance) in exchange for
 * underlying "assets" through standardized {deposit}, {mint}, {redeem}, and {burn} workflows. This contract extends
 * the ERC20 standard.
 */
contract KuruAMMVault is ERC20 {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    address private immutable token1;
    uint256 private immutable token1Decimals;
    uint256 private immutable token2Decimals;
    address private immutable token2;
    IMarginAccount private immutable marginAccount;
    IOrderBook private immutable market;

    MarketParams private marketParams;

    event Deposit(address indexed from, address indexed to, uint256 amount1, uint256 amount2, uint256 shares);
    event Withdraw(address indexed from, address indexed to, address indexed owner, uint256 amount1, uint256 amount2, uint256 shares);

    struct MarketParams {
        uint24 pricePrecision;
        uint96 sizePrecision;
        address baseAssetAddress;
        uint256 baseAssetDecimals;
        address quoteAssetAddress;
        uint256 quoteAssetDecimals;
        uint24 tickSize;
        uint96 minSize;
        uint96 maxSize;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
    }

    constructor(
        address token1_,
        address token2_,
        address _marginAccount,
        address _market,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        token1 = token1_;
        token1Decimals = token1_ != address(0) ? ERC20(token1_).decimals() : 18;
        token2 = token2_;
        token2Decimals = token2_ != address(0) ? ERC20(token2_).decimals() : 18;
        marginAccount = IMarginAccount(_marginAccount);
        market = IOrderBook(_market);

        (
            uint24 _pricePrecision,
            uint96 _sizePrecision,
            address _baseAssetAddress,
            uint256 _baseAssetDecimals,
            address _quoteAssetAddress,
            uint256 _quoteAssetDecimals,
            uint24 _tickSize,
            uint96 _minSize,
            uint96 _maxSize,
            uint256 _takerFeeBps,
            uint256 _makerFeeBps
        ) = market.getMarketParams();

        marketParams = MarketParams(
            _pricePrecision,
            _sizePrecision,
            _baseAssetAddress,
            _baseAssetDecimals,
            _quoteAssetAddress,
            _quoteAssetDecimals,
            _tickSize,
            _minSize,
            _maxSize,
            _takerFeeBps,
            _makerFeeBps
        );
    }

    function deposit(
        uint256 amount1,
        uint256 amount2,
        address receiver
    ) public payable returns (uint256) {
        if (token1 == address(0)) {
            require(msg.value == amount1, "KuruAMMVault: incorrect amount1");
        } else if (token2 == address(0)) {
            require(msg.value == amount2, "KuruAMMVault: incorrect amount2");
        } else {
            require(msg.value == 0, "KuruAMMVault: msg.value should be 0");
        }

        uint256 shares = _deposit(amount1, amount2, receiver);
        return shares;
    }

    function _deposit(
        uint256 amount1,
        uint256 amount2,
        address receiver
    ) internal returns (uint256) {
        uint256 balance1Before = marginAccount.getBalance(address(this), token1);
        uint256 balance2Before = marginAccount.getBalance(address(this), token2);

        if (token1 == address(0)) {
            marginAccount.deposit{value: amount1}(address(this), token1, amount1);
        } else {
            ERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
            marginAccount.deposit(address(this), token1, amount1);
        }

        if (token2 == address(0)) {
            marginAccount.deposit{value: amount2}(address(this), token2, amount2);
        } else {
            ERC20(token2).safeTransferFrom(msg.sender, address(this), amount2);
            marginAccount.deposit(address(this), token2, amount2);
        }

        uint256 balance1After = marginAccount.getBalance(address(this), token1);
        uint256 balance2After = marginAccount.getBalance(address(this), token2);

        market.updateVaultOrdSz(
            (uint96(
                (balance1After * marketParams.pricePrecision) /
                    10 ** marketParams.baseAssetDecimals
            ) * 3) / 2003
        );

        uint256 actualAmount1 = balance1After - balance1Before;
        uint256 actualAmount2 = balance2After - balance2Before;

        uint256 totalSupply = totalSupply();
        uint256 shares;

        if (totalSupply == 0) {
            shares = Math.sqrt(actualAmount1 * actualAmount2);
        } else {
            shares = Math.min(
                (actualAmount1 * totalSupply) / balance1Before,
                (actualAmount2 * totalSupply) / balance2Before
            );
        }

        require(shares > 0, "KuruAMMVault: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, actualAmount1, actualAmount2, shares);

        return shares;
    }

    function withdraw(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256, uint256) {
        require(shares <= balanceOf(owner), "KuruAMMVault: withdraw more than balance");

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 totalSupply = totalSupply();
        uint256 amount1 = (shares * marginAccount.getBalance(address(this), token1)) / totalSupply;
        uint256 amount2 = (shares * marginAccount.getBalance(address(this), token2)) / totalSupply;

        _burn(owner, shares);

        marginAccount.withdraw(amount1, token1);
        marginAccount.withdraw(amount2, token2);

        if (token1 == address(0)) {
            (bool success1, ) = receiver.call{value: amount1}("");
            require(success1, "KuruAMMVault: failed to transfer token1");
        } else {
            ERC20(token1).safeTransfer(receiver, amount1);
        }

        if (token2 == address(0)) {
            (bool success2, ) = receiver.call{value: amount2}("");
            require(success2, "KuruAMMVault: failed to transfer token2");
        } else {
            ERC20(token2).safeTransfer(receiver, amount2);
        }

        uint256 balance1After = marginAccount.getBalance(address(this), token1);
        market.updateVaultOrdSz(
            (uint96(
                (balance1After * marketParams.pricePrecision) /
                    10 ** marketParams.baseAssetDecimals
            ) * 3) / 2003
        );

        emit Withdraw(msg.sender, receiver, owner, amount1, amount2, shares);

        return (amount1, amount2);
    }

    function totalAssets() public view returns (uint256) {
        return marginAccount.getBalance(address(this), token1) + marginAccount.getBalance(address(this), token2);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** decimals(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** decimals(), rounding);
    }

    receive() external payable {}
}
