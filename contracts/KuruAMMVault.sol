// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============ External Imports ============
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// ============ Internal Imports ============
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {KuruAMMVaultErrors} from "./libraries/Errors.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

contract KuruAMMVault is IKuruAMMVault, ERC20, Initializable, UUPSUpgradeable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    address public owner;
    address private token1;
    uint256 private token1Decimals;

    address private token2;
    uint256 private token2Decimals;

    IMarginAccount private marginAccount;
    IOrderBook private market;
    MarketParams private marketParams;
    uint256 constant vaultPricePrecision = 10 ** 18;
    uint256 constant MIN_LIQUIDITY = 10 ** 3;
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
        owner = _owner;
        token1 = token1_;
        token1Decimals = token1_ != address(0) ? ERC20(token1_).decimals() : 18;
        token2 = token2_;
        token2Decimals = token2_ != address(0) ? ERC20(token2_).decimals() : 18;
        marginAccount = IMarginAccount(_marginAccount);
        market = IOrderBook(_market);
        SPREAD_CONSTANT = _spreadConstant;
        if (token1_ != address(0)) {
            token1_.safeApprove(_marginAccount, type(uint256).max);
        }
        if (token2_ != address(0)) {
            token2_.safeApprove(_marginAccount, type(uint256).max);
        }
    }

    // ============ auth =================
    function transferOwnership(address _newOwner) external {
        _checkOwner();
        owner = _newOwner;
    }

    function _checkOwner() internal view {
        require(msg.sender == owner, KuruAMMVaultErrors.Unauthorized());
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
        (, uint256 _price) = _returnNormalizedAmountAndPrice(true);
        return _convertToShares(asset1, asset2, _price, false);
    }

    /**
     * @dev Previews the amount of token1 and token2 to be received for a given amount of shares to be minted.
     */
    function previewMint(uint256 shares) public view virtual returns (uint256, uint256) {
        return _convertToAssets(shares, true);
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
    function deposit(uint256 baseDeposit, uint256 quoteDeposit, address receiver) public payable returns (uint256) {
        require(
            (token1 == address(0) || token2 == address(0))
                ? msg.value >= (token1 == address(0) ? baseDeposit : quoteDeposit)
                : msg.value == 0,
            KuruAMMVaultErrors.NativeAssetMismatch()
        );

        return _mintAndDeposit(baseDeposit, quoteDeposit, receiver);
    }

    /**
     * @dev Internal function to handle the deposit logic and minting of shares.
     */
    function _mintAndDeposit(uint256 baseDeposit, uint256 quoteDeposit, address receiver) internal returns (uint256) {
        (uint256 _baseAmount, uint256 _currentAskPrice) = _returnNormalizedAmountAndPrice(true);
        uint256 _shares;
        if (totalSupply() != 0) {
            uint256 _expectedQuoteAmount = (
                (
                    FixedPointMathLib.mulDivUp(baseDeposit, _currentAskPrice, vaultPricePrecision)
                        * 10 ** marketParams.quoteAssetDecimals
                )
            ) / 10 ** marketParams.baseAssetDecimals;
            require(_expectedQuoteAmount <= quoteDeposit, KuruAMMVaultErrors.InsufficientQuoteToken());
            _shares = _convertToShares(baseDeposit, _expectedQuoteAmount, _currentAskPrice, false);
            quoteDeposit = _expectedQuoteAmount;
            _mint(receiver, _shares);
        } else {
            _shares = FixedPointMathLib.sqrt(baseDeposit * quoteDeposit);
            _mint(address(marginAccount), MIN_LIQUIDITY);
            _shares -= MIN_LIQUIDITY;
            _mint(receiver, _shares);
            _currentAskPrice = (
                ((quoteDeposit * 10 ** marketParams.baseAssetDecimals)) * vaultPricePrecision
                    / 10 ** marketParams.quoteAssetDecimals
            ) / (baseDeposit);
        }
        require(_shares > 0, KuruAMMVaultErrors.InsufficientLiquidityMinted());
        (uint96 _newAskSize, uint96 _newBidSize) = _getVaultSizesForBaseAmount(_baseAmount + baseDeposit);
        market.updateVaultOrdSz(
            _newAskSize,
            _newBidSize,
            _currentAskPrice,
            FixedPointMathLib.mulDivRound(_currentAskPrice, 1000, 1000 + SPREAD_CONSTANT),
            false
        );
        address _token1 = token1;
        address _token2 = token2;
        _depositToMarginAccount(baseDeposit, _token1);
        _depositToMarginAccount(quoteDeposit, _token2);
        uint256 _nativeRefund =
            _token1 == address(0) ? (msg.value - baseDeposit) : (_token2 == address(0) ? (msg.value - quoteDeposit) : 0);
        if (_nativeRefund > 0) {
            (bool success,) = msg.sender.call{value: _nativeRefund}("");
            require(success, KuruAMMVaultErrors.NativeAssetTransferFail());
        }
        emit KuruVaultDeposit(baseDeposit, quoteDeposit, _shares, receiver);
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
        (
            uint256 _baseOwedToUser,
            uint256 _quoteOwedToUser,
            uint96 _newAskSize,
            uint96 _newBidSize,
            bool _nullifyPartialFills
        ) = _convertToAssetsWithNewSize(shares);

        _burn(owner, shares);

        // we pass 0,0 as the prices because prices are only set on the first deposit
        // since we burn 10 ** 3 shares, supply of total shares never goes to 0
        market.updateVaultOrdSz(_newAskSize, _newBidSize, 0, 0, _nullifyPartialFills);

        _withdrawFromMarginAccount(_baseOwedToUser, _quoteOwedToUser, receiver);

        emit KuruVaultWithdraw(_baseOwedToUser, _quoteOwedToUser, shares, owner);

        return (_baseOwedToUser, _quoteOwedToUser);
    }

    /**
     * @dev Internal function to handle withdrawals from the margin account.
     */
    function _withdrawFromMarginAccount(uint256 baseWithdraw, uint256 quoteWithdraw, address receiver) internal {
        marginAccount.withdraw(baseWithdraw, token1);
        marginAccount.withdraw(quoteWithdraw, token2);

        _transferTokensToUser(baseWithdraw, token1, receiver);
        _transferTokensToUser(quoteWithdraw, token2, receiver);
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
        (uint256 baseDeposit, uint256 quoteDeposit) = previewMint(shares);

        deposit(baseDeposit, quoteDeposit, receiver);

        return (baseDeposit, quoteDeposit);
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
    function _returnNormalizedAmountAndPrice(bool roundUp) internal view returns (uint256, uint256) {
        // @audit what is the right way to round this value?
        // ideally, should be rounded up during deposits and rounded down during withdrawals
        uint96 _normalizedAskSize = roundUp
            ? toU96(FixedPointMathLib.mulDivUp(market.vaultAskOrderSize(), 20000 + SPREAD_CONSTANT, SPREAD_CONSTANT))
            : toU96(FixedPointMathLib.mulDiv(market.vaultAskOrderSize(), 20000 + SPREAD_CONSTANT, SPREAD_CONSTANT));
        uint256 _price = market.vaultBestAsk();
        return ((_normalizedAskSize * 10 ** marketParams.baseAssetDecimals) / marketParams.sizePrecision, _price);
    }

    /**
     * @dev Internal function to convert asset amounts to shares.
     */
    function _convertToShares(uint256 baseAmount, uint256 quoteAmount, uint256 _currentAskPrice, bool roundUp)
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
                ? FixedPointMathLib.mulDivUp(baseAmount, totalSupply(), _reserve1)
                : FixedPointMathLib.mulDiv(baseAmount, totalSupply(), _reserve1),
            roundUp
                ? FixedPointMathLib.mulDivUp(quoteAmount, totalSupply(), _reserve2)
                : FixedPointMathLib.mulDiv(quoteAmount, totalSupply(), _reserve2)
        );
    }

    function _convertToAssets(uint256 shares, bool isDeposit) internal view returns (uint256, uint256) {
        if (isDeposit) {
            if (totalSupply() == 0) {
                return (0, 0);
            }
            (uint256 _reserve1,) = totalAssets();
            uint256 _baseAmount = FixedPointMathLib.mulDiv(shares, _reserve1, totalSupply());
            uint256 _bestAsk = market.vaultBestAsk();
            uint256 _expectedQuoteAmount = (
                (
                    FixedPointMathLib.mulDivUp(_baseAmount, _bestAsk, vaultPricePrecision)
                        * 10 ** marketParams.quoteAssetDecimals
                )
            ) / 10 ** marketParams.baseAssetDecimals;
            return (_baseAmount, _expectedQuoteAmount);
        } else {
            (uint256 _baseAmount, uint256 _quoteAmount,,,) = _convertToAssetsWithNewSize(shares);
            return (_baseAmount, _quoteAmount);
        }
    }

    function _convertToAssetsWithNewSize(uint256 shares)
        internal
        view
        returns (uint256, uint256, uint96, uint96, bool)
    {
        (uint256 _baseAmount,) = _returnNormalizedAmountAndPrice(false);
        uint256 _baseAmountAfterRemoval = _baseAmount - FixedPointMathLib.mulDiv(shares, _baseAmount, totalSupply());
        (uint96 _newAskSize, uint96 _newBidSize) = _getVaultSizesForBaseAmount(_baseAmountAfterRemoval);
        (
            ,
            uint256 _vaultBestBid,
            uint96 _partiallyFilledBidSize,
            uint256 _vaultBestAsk,
            uint96 _partiallyFilledAskSize,
            ,
            ,
        ) = market.getVaultParams();
        MarketParams memory _marketParams = marketParams;
        (uint256 _reserveBase, uint256 _reserveQuote) = totalAssets();
        if (_partiallyFilledAskSize > _newAskSize || _partiallyFilledBidSize > _newBidSize) {
            int256 _baseOwedToVault = (
                int256(uint256(_partiallyFilledAskSize)) - int256(uint256(_partiallyFilledBidSize))
            ) * int256(10 ** _marketParams.baseAssetDecimals) / int256(uint256(_marketParams.sizePrecision));
            int256 _quoteOwedToVault = (
                int256(FixedPointMathLib.mulDivUp(_partiallyFilledBidSize, _vaultBestBid, _marketParams.sizePrecision))
                    - int256(FixedPointMathLib.mulDiv(_partiallyFilledAskSize, _vaultBestAsk, _marketParams.sizePrecision))
            ) * int256(10 ** _marketParams.quoteAssetDecimals) / int256(vaultPricePrecision);
            uint256 _baseOwedToUser;
            uint256 _quoteOwedToUser;
            if (_baseOwedToVault < 0) {
                _reserveBase = _reserveBase - (uint256(-1 * _baseOwedToVault));
                _baseOwedToUser =
                    FixedPointMathLib.mulDiv(shares, _reserveBase, totalSupply()) + uint256(-1 * _baseOwedToVault);
            } else {
                _reserveBase = _reserveBase + (uint256(_baseOwedToVault));
                _baseOwedToUser =
                    FixedPointMathLib.mulDiv(shares, _reserveBase, totalSupply()) - uint256(_baseOwedToVault);
            }
            if (_quoteOwedToVault < 0) {
                _reserveQuote = _reserveQuote - (uint256(-1 * _quoteOwedToVault));
                _quoteOwedToUser =
                    FixedPointMathLib.mulDiv(shares, _reserveQuote, totalSupply()) + uint256(-1 * _quoteOwedToVault);
            } else {
                _reserveQuote = _reserveQuote + (uint256(_quoteOwedToVault));
                _quoteOwedToUser =
                    FixedPointMathLib.mulDiv(shares, _reserveQuote, totalSupply()) - uint256(_quoteOwedToVault);
            }
            return (_baseOwedToUser, _quoteOwedToUser, _newAskSize, _newBidSize, true);
        } else {
            uint256 _baseOwedToUser = FixedPointMathLib.mulDiv(shares, _reserveBase, totalSupply());
            uint256 _quoteOwedToUser = FixedPointMathLib.mulDiv(shares, _reserveQuote, totalSupply());
            return (_baseOwedToUser, _quoteOwedToUser, _newAskSize, _newBidSize, false);
        }
    }

    function _getVaultSizesForBaseAmount(uint256 _baseAmount) internal view returns (uint96, uint96) {
        MarketParams memory _marketParams = marketParams;
        uint96 _newAskSize = toU96(
            (SPREAD_CONSTANT * _baseAmount * _marketParams.sizePrecision)
                / ((20000 + SPREAD_CONSTANT) * 10 ** _marketParams.baseAssetDecimals)
        );
        uint96 _newBidSize = toU96(
            (SPREAD_CONSTANT * _baseAmount * _marketParams.sizePrecision)
                / (20000 * 10 ** _marketParams.baseAssetDecimals)
        );
        return (_newAskSize, _newBidSize);
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

    function toU96(uint256 _from) internal pure returns (uint96 _to) {
        require((_to = uint96(_from)) == _from, KuruAMMVaultErrors.Uint96Overflow());
    }

    receive() external payable {}
}
