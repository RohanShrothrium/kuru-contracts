// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============ External Imports ============
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// ============ Internal Imports ============
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {KuruAMMVaultErrors} from "./libraries/Errors.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

contract KuruAMMVault is IKuruAMMVault, ERC20, Ownable, Initializable, UUPSUpgradeable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    address private token1;
    uint256 private token1Decimals;

    address private token2;
    uint256 private token2Decimals;

    IMarginAccount private marginAccount;
    IOrderBook private market;
    MarketParams private marketParams;
    //TODO: Add minimum initial liquidity and burn it, analogous to Uniswap V2.
    uint256 constant vaultPricePrecision = 10 ** 18;
    uint256 constant MIN_LIQUIDITY = 10 ** 3;
    //TODO: Add vault share precision
    uint96 SPREAD_CONSTANT;

    constructor() {
        _disableInitializers();
    }

    // ============ initializer =================
    function initialize(
        address _owner,
        address token1_,
        address token2_,
        address _marginAccount,
        address _market,
        uint96 _spreadConstant,
        string memory _name,
        string memory _symbol
    ) public initializer {
        _initializeOwner(_owner);
        token1 = token1_;
        token1Decimals = token1_ != address(0) ? ERC20(token1_).decimals() : 18;
        token2 = token2_;
        token2Decimals = token2_ != address(0) ? ERC20(token2_).decimals() : 18;
        marginAccount = IMarginAccount(_marginAccount);
        market = IOrderBook(_market);
        SPREAD_CONSTANT = _spreadConstant;
        if (token1_ != address(0)) {
            ERC20(token1_).approve(_marginAccount, type(uint256).max);
        }
        if (token2_ != address(0)) {
            ERC20(token2_).approve(_marginAccount, type(uint256).max);
        }
    }

    // ============ auth =================
    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    function name() public view virtual override returns (string memory) {
        return "KuruAMMVault";
    }

    function symbol() public view virtual override returns (string memory) {
        return "KURU-AMM-VAULT";
    }

    /**
     * @dev Fetches and stores the market params from the market contract.
     */
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

    /**
     * @dev Previews the amount of shares to be minted for a given deposit of token1 and token2.
     */
    function previewDeposit(uint256 asset1, uint256 asset2) public view virtual returns (uint256) {
        (, uint256 _price) = _returnNormalizedAmountAndPrice();
        return _convertToShares(asset1, asset2, _price, false);
    }

    /**
     * @dev Previews the amount of token1 and token2 to be received for a given amount of shares to be minted.
     */
    function previewMint(uint256 shares) public view virtual returns (uint256, uint256) {
        return _convertToAssets(shares, true);
    }

    /**
     * @dev Previews the amount of shares to be burned for a given withdrawal of token1 and token2.
     */
    function previewWithdraw(uint256 asset1, uint256 asset2) public view virtual returns (uint256) {
        return _convertToShares(asset1, asset2, 0, true);
    }

    /**
     * @dev Previews the amount of token1 and token2 to be received for a given amount of shares to be burned.
     */
    function previewRedeem(uint256 shares) public view virtual returns (uint256, uint256) {
        return _convertToAssets(shares, false);
    }

    /**
     * @dev Returns the total assets of the vault in token1 and token2.
     */
    function totalAssets() public view returns (uint256, uint256) {
        return (marginAccount.getBalance(address(this), token1), marginAccount.getBalance(address(this), token2));
    }

    /**
     * @dev Deposits token1 and token2 into the vault and mints shares to the receiver.
     */
    function deposit(uint256 amount1, uint256 amount2, address receiver) public payable returns (uint256) {
        require(
            (token1 == address(0) || token2 == address(0))
                ? msg.value >= (token1 == address(0) ? amount1 : amount2)
                : msg.value == 0,
            KuruAMMVaultErrors.NativeAssetMismatch()
        );

        return _depositAndMint(amount1, amount2, receiver);
    }

    /**
     * @dev Internal function to handle the deposit logic and minting of shares.
     */
    function _depositAndMint(uint256 amount1, uint256 amount2, address receiver) internal returns (uint256) {
        (uint256 _baseAmount, uint256 _currentAskPrice) = _returnNormalizedAmountAndPrice();
        uint256 _shares;
        if (totalSupply() != 0) {
            uint256 _expectedQuoteAmount = (
                (
                    FixedPointMathLib.mulDivUp(amount1, _currentAskPrice, vaultPricePrecision)
                        * 10 ** marketParams.quoteAssetDecimals
                )
            ) / 10 ** marketParams.baseAssetDecimals;
            require(_expectedQuoteAmount <= amount2, KuruAMMVaultErrors.InsufficientQuoteToken());
            _shares = _convertToShares(amount1, _expectedQuoteAmount, _currentAskPrice, false);
            amount2 = _expectedQuoteAmount;
            _mint(receiver, _shares);
        } else {
            _shares = FixedPointMathLib.sqrt(amount1 * amount2);
            _mint(address(marginAccount), MIN_LIQUIDITY);
            _shares -= MIN_LIQUIDITY;
            _mint(receiver, _shares);
        }
        require(_shares > 0, KuruAMMVaultErrors.InsufficientLiquidityMinted());
        _updateMarketVaultOrderSize(amount1, amount2, _baseAmount, _currentAskPrice, true);
        address _token1 = token1;
        address _token2 = token2;
        _depositToMarginAccount(amount1, _token1);
        _depositToMarginAccount(amount2, _token2);
        uint256 _nativeRefund =
            _token1 == address(0) ? (msg.value - amount1) : (_token2 == address(0) ? (msg.value - amount2) : 0);
        if (_nativeRefund > 0) {
            (bool success,) = receiver.call{value: _nativeRefund}("");
            require(success, KuruAMMVaultErrors.NativeAssetTransferFail());
        }
        emit KuruVaultDeposit(amount1, amount2, _shares, receiver);
        return _shares;
    }

    /**
     * @dev Internal function to handle deposits to the margin account.
     */
    function _depositToMarginAccount(uint256 amount, address token) internal {
        if (token == address(0)) {
            marginAccount.deposit{value: amount}(address(this), token, amount);
        } else {
            token.safeTransferFrom(msg.sender, address(this), amount);
            marginAccount.deposit(address(this), token, amount);
        }
    }

    /**
     * @dev Updates the vault order size in the market.
     */
    function _updateMarketVaultOrderSize(
        uint256 amount1,
        uint256 amount2,
        uint256 _baseAmount,
        uint256 _currentAskPrice,
        bool isDeposit
    ) internal {
        MarketParams memory _marketParams = marketParams;
        uint256 _postActionBaseAmount = isDeposit ? _baseAmount + amount1 : _baseAmount - amount1;
        uint256 _newAskPrice;
        uint256 _newBidPrice;
        if (_currentAskPrice == type(uint256).max) {
            uint256 _postActionQuoteAmount = amount2;
            _newAskPrice = (
                (
                    (_postActionQuoteAmount * 10 ** _marketParams.baseAssetDecimals)
                ) * vaultPricePrecision
                        / 10 ** _marketParams.quoteAssetDecimals
            ) / (_postActionBaseAmount);
            _newBidPrice = FixedPointMathLib.mulDivRound(_newAskPrice, 1000, 1000 + SPREAD_CONSTANT);
            (uint256 _bestBid, uint256 _bestAsk) = market.bestBidAsk();
            if (
                (_bestBid > _newAskPrice && _bestBid != type(uint256).max) || (_bestAsk < _newBidPrice && _bestAsk != 0)
            ) {
                revert KuruAMMVaultErrors.VaultInitializationPriceCrossesBook();
            }
        }
        (
            ,
            uint256 _vaultBestBid,
            uint96 _partiallyFilledBidSize,
            ,
            uint96 _partiallyFilledAskSize,
            uint96 _vaultBidSize,
            ,
        ) = market.getVaultParams();
        uint96 _newAskSize = uint96(
            (SPREAD_CONSTANT * _postActionBaseAmount * _marketParams.sizePrecision)
                / ((2000 + SPREAD_CONSTANT) * 10 ** _marketParams.baseAssetDecimals)
        );
        uint96 _newBidSize = uint96(
            (SPREAD_CONSTANT * _postActionBaseAmount * _marketParams.sizePrecision)
                / (2000 * 10 ** _marketParams.baseAssetDecimals)
        );
        if (_newAskSize <= _partiallyFilledAskSize || _newBidSize <= _partiallyFilledBidSize) {
            int256 _quoteOwedToUser;
            int256 _baseOwedToUser;
            //process vault bid
            _quoteOwedToUser += int256(
                (
                    FixedPointMathLib.mulDiv(
                        _vaultBidSize - _partiallyFilledBidSize, _vaultBestBid, _marketParams.sizePrecision
                    )
                ) * 10 ** _marketParams.quoteAssetDecimals / 10 ** 18
            );
            _baseOwedToUser = (-1)
                * int256(
                    (_vaultBidSize - _partiallyFilledBidSize) * 10 ** _marketParams.baseAssetDecimals
                        / _marketParams.sizePrecision
                );

            // process vault ask
            // price has moved down now, new vault ask parameters become old vault bid parameters
            // only partially filled ask size remains same
            _quoteOwedToUser += (-1)
                * int256(
                    (
                        FixedPointMathLib.mulDivUp(
                            _vaultBidSize - _partiallyFilledAskSize, _vaultBestBid, _marketParams.sizePrecision
                        )
                    ) * 10 ** _marketParams.quoteAssetDecimals / 10 ** 18
                );
            _baseOwedToUser += int256(
                (_vaultBidSize - _partiallyFilledAskSize) * 10 ** _marketParams.baseAssetDecimals
                    / _marketParams.sizePrecision
            );
            if (_baseOwedToUser > 0) {
                amount1 += uint256(_baseOwedToUser);
            } else {
                if (amount1 < uint256((-1) * _baseOwedToUser)) {
                    revert KuruAMMVaultErrors.NewSizeExceedsPartiallyFilledSize();
                }
                amount1 -= uint256((-1) * _baseOwedToUser);
            }
            if (_quoteOwedToUser > 0) {
                amount2 += uint256(_quoteOwedToUser);
            } else {
                if (amount2 < uint256((-1) * _quoteOwedToUser)) {
                    revert KuruAMMVaultErrors.NewSizeExceedsPartiallyFilledSize();
                }
                amount2 -= uint256((-1) * _quoteOwedToUser);
            }
            _partiallyFilledBidSize = 0;
            _partiallyFilledAskSize = 0;
        }
        market.updateVaultOrdSz(
            _newAskSize, _partiallyFilledAskSize, _newBidSize, _partiallyFilledBidSize, _newAskPrice, _newBidPrice
        );
    }

    /**
     * @dev Withdraws token1 and token2 from the vault by burning the specified amount of shares.
     */
    function withdraw(uint256 shares, address receiver, address owner) public returns (uint256, uint256) {
        require(shares <= balanceOf(owner), KuruAMMVaultErrors.InsufficientBalance());

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        return _burnAndWithdraw(shares, receiver, owner);
    }

    /**
     * @dev Internal function to handle the burning of shares and withdrawal logic.
     */
    function _burnAndWithdraw(uint256 shares, address receiver, address owner) internal returns (uint256, uint256) {
        (uint256 amount1, uint256 amount2) = _convertToAssets(shares, false);

        (uint256 _baseAmount, uint256 _currentAskPrice) = _returnNormalizedAmountAndPrice();
        uint256 _normalizedRemoveAmount = amount1;
        if (totalSupply() != 0) {
            //@audit muldivdown or up?
            _normalizedRemoveAmount = FixedPointMathLib.mulDiv(shares, _baseAmount, totalSupply());
        }
        _burn(owner, shares);

        _updateMarketVaultOrderSize(_normalizedRemoveAmount, amount2, _baseAmount, _currentAskPrice, false);

        _withdrawFromMarginAccount(amount1, amount2, receiver);

        emit KuruVaultWithdraw(amount1, amount2, shares, owner);

        return (amount1, amount2);
    }

    /**
     * @dev Internal function to handle withdrawals from the margin account.
     */
    function _withdrawFromMarginAccount(uint256 amount1, uint256 amount2, address receiver) internal {
        marginAccount.withdraw(amount1, token1);
        marginAccount.withdraw(amount2, token2);

        _transferTokensToUser(amount1, token1, receiver);
        _transferTokensToUser(amount2, token2, receiver);
    }

    /**
     * @dev Internal function to transfer tokens to the receiver.
     */
    function _transferTokensToUser(uint256 amount, address token, address receiver) internal {
        if (token == address(0)) {
            (bool success,) = receiver.call{value: amount}("");
            require(success, KuruAMMVaultErrors.NativeAssetTransferFail());
        } else {
            token.safeTransfer(receiver, amount);
        }
    }

    /**
     * @dev Mints shares to the receiver in exchange for depositing token1 and token2.
     */
    function mint(uint256 shares, address receiver) public payable returns (uint256, uint256) {
        (uint256 amount1, uint256 amount2) = previewMint(shares);

        deposit(amount1, amount2, receiver);

        return (amount1, amount2);
    }

    /**
     * @dev Redeems shares by burning the specified amount and withdrawing token1 and token2 to the receiver.
     */
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256, uint256) {
        require(shares <= balanceOf(owner), KuruAMMVaultErrors.InsufficientBalance());

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        return _burnAndWithdraw(shares, receiver, owner);
    }

    /**
     * @dev Returns normalized base asset amount without profits
     */
    function _returnNormalizedAmountAndPrice() internal view returns (uint256, uint256) {
        uint96 _normalizedAskSize = (market.vaultAskOrderSize() * (2000 + SPREAD_CONSTANT)) / SPREAD_CONSTANT; //TODO: rounding
        uint256 _price = market.vaultBestAsk();
        return ((_normalizedAskSize * 10 ** marketParams.baseAssetDecimals) / marketParams.sizePrecision, _price);
    }

    /**
     * @dev Internal function to convert asset amounts to shares.
     */
    function _convertToShares(uint256 amount1, uint256 amount2, uint256 _currentAskPrice, bool roundUp)
        internal
        view
        returns (uint256)
    {
        (uint256 _reserve1, uint256 _reserve2) = totalAssets();
        if (!roundUp) {
            (_reserve1, _reserve2) = _returnVirtuallyRebalancedTotalAssets(_reserve1, _reserve2, _currentAskPrice);
        }
        return FixedPointMathLib.min(
            roundUp
                ? FixedPointMathLib.mulDivUp(amount1, totalSupply(), _reserve1)
                : FixedPointMathLib.mulDiv(amount1, totalSupply(), _reserve1),
            roundUp
                ? FixedPointMathLib.mulDivUp(amount2, totalSupply(), _reserve2)
                : FixedPointMathLib.mulDiv(amount2, totalSupply(), _reserve2)
        );
    }

    /**
     * @dev Internal function to convert shares to asset amounts.
     */
    function _convertToAssets(uint256 shares, bool roundUp) internal view returns (uint256, uint256) {
        (uint256 _reserve1, uint256 _reserve2) = totalAssets();
        return (
            roundUp
                ? FixedPointMathLib.mulDivUp(shares, _reserve1, totalSupply())
                : FixedPointMathLib.mulDiv(shares, _reserve1, totalSupply()),
            roundUp
                ? FixedPointMathLib.mulDivUp(shares, _reserve2, totalSupply())
                : FixedPointMathLib.mulDiv(shares, _reserve2, totalSupply())
        );
    }

    function _returnVirtuallyRebalancedTotalAssets(uint256 _reserve1, uint256 _reserve2, uint256 _vaultPrice)
        internal
        view
        returns (uint256, uint256)
    {
        MarketParams memory _marketParams = marketParams;
        uint256 _halfTotalValuationInQuote = (
            (_reserve1 * _vaultPrice * 10 ** _marketParams.quoteAssetDecimals)
                / (10 ** _marketParams.baseAssetDecimals * vaultPricePrecision) + _reserve2
        ) / 2;
        uint256 _rebalancedBaseAsset = (
            _halfTotalValuationInQuote * vaultPricePrecision * 10 ** _marketParams.baseAssetDecimals
        ) / (10 ** _marketParams.quoteAssetDecimals * _vaultPrice);
        return (_rebalancedBaseAsset, _halfTotalValuationInQuote);
    }

    receive() external payable {}
}
