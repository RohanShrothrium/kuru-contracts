// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";

import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

contract KuruAMMVault is ERC20, IKuruAMMVault {
    using SafeTransferLib for ERC20;
    using Math for uint256;

    address private immutable token1;
    uint256 private immutable token1Decimals;

    event testEvent(uint256, uint256);

    address private immutable token2;
    uint256 private immutable token2Decimals;

    IMarginAccount private immutable marginAccount;
    IOrderBook private immutable market;

    MarketParams private marketParams;

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

        if (token1_ != address(0)) {
            ERC20(token1_).approve(_marginAccount, type(uint256).max);
        }
        if (token2_ != address(0)) {
            ERC20(token2_).approve(_marginAccount, type(uint256).max);
        }
    }

    /** @dev Fetches and stores the market params from the market contract. */
    function setMarketParams() external {
        (
            marketParams.pricePrecision,
            marketParams.sizePrecision,
            marketParams.baseAssetAddress,
            marketParams.baseAssetDecimals,
            marketParams.quoteAssetAddress,
            marketParams.quoteAssetDecimals,
            marketParams.tickSize,
            marketParams.minSize,
            marketParams.maxSize,
            marketParams.takerFeeBps,
            marketParams.makerFeeBps
        ) = market.getMarketParams();
    }

    /** @dev Previews the amount of shares to be minted for a given deposit of token1 and token2. */
    function previewDeposit(
        uint256 asset1,
        uint256 asset2
    ) public view virtual returns (uint256) {
        return _convertToShares(asset1, asset2, Math.Rounding.Down);
    }

    /** @dev Previews the amount of token1 and token2 to be received for a given amount of shares to be minted. */
    function previewMint(
        uint256 shares
    ) public view virtual returns (uint256, uint256) {
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    /** @dev Previews the amount of shares to be burned for a given withdrawal of token1 and token2. */
    function previewWithdraw(
        uint256 asset1,
        uint256 asset2
    ) public view virtual returns (uint256) {
        return _convertToShares(asset1, asset2, Math.Rounding.Up);
    }

    /** @dev Previews the amount of token1 and token2 to be received for a given amount of shares to be burned. */
    function previewRedeem(
        uint256 shares
    ) public view virtual returns (uint256, uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    /** @dev Returns the total assets of the vault in token1 and token2. */
    function totalAssets() public view returns (uint256, uint256) {
        return (
            marginAccount.getBalance(address(this), token1),
            marginAccount.getBalance(address(this), token2)
        );
    }

    /** @dev Deposits token1 and token2 into the vault and mints shares to the receiver. */
    function deposit(
        uint256 amount1,
        uint256 amount2,
        address receiver
    ) public payable returns (uint256) {
        require(
            msg.value ==
                (
                    token1 == address(0)
                        ? amount1
                        : token2 == address(0)
                            ? amount2
                            : 0
                ),
            "KuruAMMVault: incorrect amount"
        );

        return _depositAndMint(amount1, amount2, receiver);
    }

    /** @dev Internal function to handle the deposit logic and minting of shares. */
    function _depositAndMint(
        uint256 amount1,
        uint256 amount2,
        address receiver
    ) internal returns (uint256) {
        uint256 shares = totalSupply() == 0
            ? Math.sqrt(amount1 * amount2)
            : _convertToShares(amount1, amount2, Math.Rounding.Down);
        require(shares > 0, "KuruAMMVault: INSUFFICIENT_LIQUIDITY_MINTED");
    
        _updateMarketVaultOrderSize(amount1, amount2, true);

        _depositToMarginAccount(amount1, token1);
        _depositToMarginAccount(amount2, token2);

        _mint(receiver, shares);

        return shares;
    }

    /** @dev Internal function to handle deposits to the margin account. */
    function _depositToMarginAccount(uint256 amount, address token) internal {
        if (token == address(0)) {
            marginAccount.deposit{value: amount}(address(this), token, amount);
        } else {
            ERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            marginAccount.deposit(address(this), token, amount);
        }
    }

    /** @dev Updates the vault order size in the market. */
    function _updateMarketVaultOrderSize(
        uint256 amount1,
        uint256 amount2,
        bool isDeposit
    ) internal {
        MarketParams memory _marketParams = marketParams;
        (uint256 _baseAmount, uint256 _currentAskPrice) = _returnNormalizedAmountAndPrice();
        uint256 _quoteAmount = (_baseAmount * 10**_marketParams.quoteAssetDecimals / 10**_marketParams.baseAssetDecimals) * 10**18 / _currentAskPrice;
        emit testEvent(_baseAmount, _quoteAmount);
        uint256 _postActionBaseAmount = isDeposit? _baseAmount + amount1 : _baseAmount - amount1;
        uint256 _postActionQuoteAmount = isDeposit ? _quoteAmount + amount2 : _quoteAmount - amount2;
        emit testEvent(_postActionBaseAmount, _postActionQuoteAmount);
        uint256 _newAskPrice;
        uint256 _newBidPrice;
        if(_currentAskPrice == type(uint256).max) {
            _newAskPrice = (_postActionQuoteAmount * 10**_marketParams.baseAssetDecimals / 10**_marketParams.quoteAssetDecimals) * 10**18 / (_postActionBaseAmount);
            _newBidPrice = FixedPointMathLib.mulDivRound(_newAskPrice, 1000, 1003);
        }
        uint96 _newAskSize = uint96((3 * _postActionBaseAmount * _marketParams.sizePrecision) / (2003 * 10**_marketParams.baseAssetDecimals));
        uint96 _newBidSize = uint96((3 * _postActionBaseAmount * _marketParams.sizePrecision) / (2000 * 10**_marketParams.baseAssetDecimals));
        market.updateVaultOrdSz(_newAskSize, _newBidSize, _newAskPrice, _newBidPrice); 
    }

    /** @dev Withdraws token1 and token2 from the vault by burning the specified amount of shares. */
    function withdraw(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256, uint256) {
        require(
            shares <= balanceOf(owner),
            "KuruAMMVault: withdraw more than balance"
        );

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        return _burnAndWithdraw(shares, receiver, owner);
    }

    /** @dev Internal function to handle the burning of shares and withdrawal logic. */
    function _burnAndWithdraw(
        uint256 shares,
        address receiver,
        address owner
    ) internal returns (uint256, uint256) {
        (uint256 amount1, uint256 amount2) = _convertToAssets(
            shares,
            Math.Rounding.Down
        );

        _burn(owner, shares);

        _updateMarketVaultOrderSize(amount1, amount2, false);

        _withdrawFromMarginAccount(amount1, token1, receiver);
        _withdrawFromMarginAccount(amount2, token2, receiver);

        return (amount1, amount2);
    }

    /** @dev Internal function to handle withdrawals from the margin account. */
    function _withdrawFromMarginAccount(
        uint256 amount,
        address token,
        address receiver
    ) internal {
        marginAccount.withdraw(amount, token);
        if (token == address(0)) {
            // @audit: This is surely a bug.
            (bool success, ) = receiver.call{value: amount}("");
            require(success, "KuruAMMVault: failed to transfer native token");
        } else {
            ERC20(token).safeTransfer(receiver, amount);
        }
    }

    /** @dev Mints shares to the receiver in exchange for depositing token1 and token2. */
    function mint(
        uint256 shares,
        address receiver
    ) public payable returns (uint256, uint256) {
        (uint256 amount1, uint256 amount2) = previewMint(shares);

        deposit(amount1, amount2, receiver);

        return (amount1, amount2);
    }

    /** @dev Redeems shares by burning the specified amount and withdrawing token1 and token2 to the receiver. */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public returns (uint256, uint256) {
        require(
            shares <= balanceOf(owner),
            "KuruAMMVault: redeem more than balance"
        );

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        return _burnAndWithdraw(shares, receiver, owner);
    }

    /**
    * @dev Returns normalized base asset amount without profits
     */
    function _returnNormalizedAmountAndPrice() internal view returns (uint256, uint256) {
        uint96 _normalizedAskSize = (market.vaultAskOrderSize() * 2003) / 3; //TODO: rounding
        uint256 _price = market.vaultBestAsk();
        return (_normalizedAskSize * 10**marketParams.baseAssetDecimals / marketParams.sizePrecision, _price);
    }

    /** @dev Internal function to convert asset amounts to shares. */
    function _convertToShares(
        uint256 amount1,
        uint256 amount2,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        (uint256 _reserve1, uint256 _reserve2) = totalAssets();
        return
            Math.min(
                amount1.mulDiv(totalSupply(), _reserve1, rounding),
                amount2.mulDiv(totalSupply(), _reserve2, rounding)
            );
    }

    /** @dev Internal function to convert shares to asset amounts. */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view returns (uint256, uint256) {
        (uint256 _reserve1, uint256 _reserve2) = totalAssets();
        return (
            shares.mulDiv(_reserve1, totalSupply(), rounding),
            shares.mulDiv(_reserve2, totalSupply(), rounding)
        );
    }

    receive() external payable {}
}
