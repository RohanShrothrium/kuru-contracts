// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============ External Imports ============
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

// ============ Internal Imports ============
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";
import {KuruAMMVaultErrors} from "./libraries/Errors.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {IKuruAMMVault} from "./interfaces/IKuruAMMVault.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";

contract KuruAMMVault is IKuruAMMVault, ERC20, Initializable, UUPSUpgradeable, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    uint256 constant vaultPricePrecision = 10 ** 18;
    uint256 constant MIN_LIQUIDITY = 10 ** 3;
    uint256 constant BPS_MULTIPLIER = 10000;
    uint256 constant DOUBLE_BPS_MULTIPLIER = 20000;

    address public owner;
    address public token1;
    uint256 private token1Decimals;

    address public token2;
    uint256 private token2Decimals;

    IMarginAccount public marginAccount;
    IOrderBook public market;
    MarketParams public marketParams;
    uint96 public SPREAD_CONSTANT;
    string internal _name;

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
        uint96 _spreadConstant
    ) public initializer {
        owner = _owner;
        token1 = token1_;
        token1Decimals = token1_ != address(0) ? ERC20(token1_).decimals() : 18;
        token2 = token2_;
        token2Decimals = token2_ != address(0) ? ERC20(token2_).decimals() : 18;
        marginAccount = IMarginAccount(_marginAccount);
        market = IOrderBook(_market);
        SPREAD_CONSTANT = _spreadConstant;
        setMarketParams();
        if (token1_ != address(0)) {
            token1_.safeApprove(_marginAccount, type(uint256).max);
        }
        if (token2_ != address(0)) {
            token2_.safeApprove(_marginAccount, type(uint256).max);
        }
        string memory token1Symbol;
        string memory token2Symbol;
        if (token1_ != address(0)) {
            token1Symbol = ERC20(token1_).symbol();
        } else {
            token1Symbol = "MON";
        }
        if (token2_ != address(0)) {
            token2Symbol = ERC20(token2_).symbol();
        } else {
            token2Symbol = "MON";
        }
        _name = string.concat(token1Symbol, "-", token2Symbol, "-", "KURU-AMM-VAULT");
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
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Fetches and stores the market params from the market contract.
     */
    function setMarketParams() public {
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
        return _convertToShares(asset1, asset2, _price);
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
    function previewWithdraw(uint256 shares) public view virtual returns (uint256, uint256) {
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
    function deposit(uint256 baseDeposit, uint256 quoteDeposit, address receiver)
        public
        payable
        nonReentrant
        returns (uint256)
    {
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
            _shares = _convertToShares(baseDeposit, _expectedQuoteAmount, _currentAskPrice);
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
            FixedPointMathLib.mulDivRound(_currentAskPrice, BPS_MULTIPLIER, BPS_MULTIPLIER + SPREAD_CONSTANT),
            false
        );
        address _token1 = token1;
        address _token2 = token2;
        _depositAmountsToMarginAccount(_token1, _token2, baseDeposit, quoteDeposit);
        uint256 _nativeRefund =
            _token1 == address(0) ? (msg.value - baseDeposit) : (_token2 == address(0) ? (msg.value - quoteDeposit) : 0);
        if (_nativeRefund > 0) {
            msg.sender.safeTransferETH(_nativeRefund);
        }
        emit KuruVaultDeposit(baseDeposit, quoteDeposit, _shares, receiver);
        return _shares;
    }

    function _depositAmountsToMarginAccount(address _token1, address _token2, uint256 baseDeposit, uint256 quoteDeposit)
        internal
    {
        if (_token1 == address(0)) {
            marginAccount.deposit{value: baseDeposit}(address(this), _token1, baseDeposit);
        } else {
            _token1.safeTransferFrom(msg.sender, address(this), baseDeposit);
            marginAccount.deposit(address(this), _token1, baseDeposit);
        }

        if (_token2 == address(0)) {
            marginAccount.deposit{value: quoteDeposit}(address(this), _token2, quoteDeposit);
        } else {
            _token2.safeTransferFrom(msg.sender, address(this), quoteDeposit);
            marginAccount.deposit(address(this), _token2, quoteDeposit);
        }
    }

    /**
     * @dev Withdraws token1 and token2 from the vault by burning the specified amount of shares.
     */
    function withdraw(uint256 _shares, address _receiver, address _owner)
        public
        nonReentrant
        returns (uint256, uint256)
    {
        require(_shares <= balanceOf(_owner), KuruAMMVaultErrors.InsufficientBalance());

        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        return _burnAndWithdraw(_shares, _receiver, _owner);
    }

    /**
     * @dev Internal function to handle the burning of shares and withdrawal logic.
     */
    function _burnAndWithdraw(uint256 _shares, address _receiver, address _owner) internal returns (uint256, uint256) {
        (
            uint256 _baseOwedToUser,
            uint256 _quoteOwedToUser,
            uint96 _newAskSize,
            uint96 _newBidSize,
            bool _nullifyPartialFills
        ) = _convertToAssetsWithNewSize(_shares);

        _burn(_owner, _shares);

        // we pass 0,0 as the prices because prices are only set on the first deposit
        // since we burn 10 ** 3 shares, supply of total shares never goes to 0
        market.updateVaultOrdSz(_newAskSize, _newBidSize, 0, 0, _nullifyPartialFills);

        _withdrawFromMarginAccount(_baseOwedToUser, _quoteOwedToUser, _receiver);

        emit KuruVaultWithdraw(_baseOwedToUser, _quoteOwedToUser, _shares, _owner);

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
            receiver.safeTransferETH(amount);
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
     * @dev Returns normalized base asset amount without profits
     */
    function _returnNormalizedAmountAndPrice(bool roundUp) internal view returns (uint256, uint256) {
        // @audit what is the right way to round this value?
        // ideally, should be rounded up during deposits and rounded down during withdrawals
        uint96 _normalizedBaseAmount = roundUp
            ? toU96(
                FixedPointMathLib.mulDivUp(
                    market.vaultAskOrderSize(), DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT, SPREAD_CONSTANT
                )
            )
            : toU96(
                FixedPointMathLib.mulDiv(
                    market.vaultAskOrderSize(), DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT, SPREAD_CONSTANT
                )
            );
        uint256 _price = market.vaultBestAsk();
        return ((_normalizedBaseAmount * 10 ** marketParams.baseAssetDecimals) / marketParams.sizePrecision, _price);
    }

    /**
     * @dev Internal function to convert asset amounts to shares.
     */
    function _convertToShares(uint256 baseAmount, uint256 quoteAmount, uint256 _currentAskPrice)
        internal
        view
        returns (uint256)
    {
        (uint256 _reserve1, uint256 _reserve2) = totalAssets();
        (_reserve1, _reserve2) = _returnVirtuallyRebalancedTotalAssets(_reserve1, _reserve2, _currentAskPrice);
        return FixedPointMathLib.min(
            FixedPointMathLib.mulDiv(baseAmount, totalSupply(), _reserve1),
            FixedPointMathLib.mulDiv(quoteAmount, totalSupply(), _reserve2)
        );
    }

    function _convertToAssets(uint256 shares, bool isDeposit)
        internal
        view
        returns (uint256 _baseAmount, uint256 _quoteAmount)
    {
        if (isDeposit) {
            if (totalSupply() == 0) {
                return (0, 0);
            }
            (uint256 _baseReserve, uint256 _quoteReserve) = totalAssets();
            (, uint256 _currentAskPrice) = _returnNormalizedAmountAndPrice(true);
            (_baseReserve, _quoteReserve) =
                _returnVirtuallyRebalancedTotalAssets(_baseReserve, _quoteReserve, _currentAskPrice);
            _baseAmount = FixedPointMathLib.mulDiv(shares, _baseReserve, totalSupply());
            _quoteAmount = (
                (
                    FixedPointMathLib.mulDivUp(_baseAmount, _currentAskPrice, vaultPricePrecision)
                        * 10 ** marketParams.quoteAssetDecimals
                )
            ) / 10 ** marketParams.baseAssetDecimals;
            return (_baseAmount, _quoteAmount);
        } else {
            (_baseAmount, _quoteAmount,,,) = _convertToAssetsWithNewSize(shares);
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
                / ((DOUBLE_BPS_MULTIPLIER + SPREAD_CONSTANT) * 10 ** _marketParams.baseAssetDecimals)
        );
        uint96 _newBidSize = toU96(
            (SPREAD_CONSTANT * _baseAmount * _marketParams.sizePrecision)
                / (DOUBLE_BPS_MULTIPLIER * 10 ** _marketParams.baseAssetDecimals)
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
