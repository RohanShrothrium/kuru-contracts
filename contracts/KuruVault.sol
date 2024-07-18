// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";

contract MultiAssetKuruVault is ERC4626 {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    // Base and quote assets
    ERC20 public immutable baseAsset;
    ERC20 public immutable quoteAsset;

    IOrderBook public immutable market;
    uint96 sizePrecision;
    uint24 pricePrecision;

    // State variables to keep track of epochs and TVL for each asset
    uint256 public currentEpoch;
    mapping(uint256 => uint256) public baseAssetEpochTVL;
    mapping(uint256 => uint256) public quoteAssetEpochTVL;

    // Event to log epoch updates
    event EpochUpdated(uint256 epoch, uint256 baseAssetTVL, uint256 quoteAssetTVL);

    constructor(
        ERC20 _baseAsset,
        ERC20 _quoteAsset,
        address _marketAddress,
        uint96 _sizePrecision,
        uint24 _pricePrecision,
        string memory _name,
        string memory _symbol
    ) ERC4626(_baseAsset) ERC20(_name, _symbol) {
        baseAsset = _baseAsset;
        quoteAsset = _quoteAsset;

        market = IOrderBook(_marketAddress);
        pricePrecision = _pricePrecision;
        sizePrecision = _sizePrecision;
    }

    // Function to update the TVL at the end of each epoch for both assets
    function updateEpoch(uint256 baseAssetTVL, uint256 quoteAssetTVL) external {
        baseAssetEpochTVL[currentEpoch] = baseAssetTVL;
        quoteAssetEpochTVL[currentEpoch] = quoteAssetTVL;
        emit EpochUpdated(currentEpoch, baseAssetTVL, quoteAssetTVL);
        currentEpoch++;
    }

    // Placeholder function to get the value of base asset in quote asset terms
    function baseInQuote(uint256 baseAmount) public view returns (uint256) {
        // TODO: Should this be oracle price or this?
        (uint24 _bestBid, uint24 _bestAsk) = market.bestBidAsk();
        uint24 _price = (_bestBid + _bestAsk) / 2;

        return baseAmount.mulDivDown(_price, pricePrecision);
    }

    // Placeholder function to get the value of quote asset in base asset terms
    function quoteInBase(uint256 quoteAmount) public view returns (uint256) {
        // TODO: Should this be oracle price or this?
        (uint24 _bestBid, uint24 _bestAsk) = market.bestBidAsk();
        uint24 _price = (_bestBid + _bestAsk) / 2;

        return quoteAmount.mulDivDown(pricePrecision, _price);
    }

    // Override totalAssets to return the combined TVL of the latest epoch in base assets
    function totalAssets() public view override returns (uint256) {
        return baseAssetEpochTVL[currentEpoch - 1] + quoteInBase(quoteAssetEpochTVL[currentEpoch - 1]);
    }

    // Function to deposit both assets into the vault
    function deposit(uint256 baseAmount, uint256 quoteAmount, address receiver) public returns (uint256 shares) {
        require(currentEpoch > 0, "Epoch not initialized");

        uint256 baseValueInQuote = baseInQuote(baseAmount);

        uint256 actualBaseAmount;
        uint256 actualQuoteAmount;

        if (baseValueInQuote > quoteAmount) {
            actualBaseAmount = quoteInBase(quoteAmount);
            actualQuoteAmount = quoteAmount;
        } else {
            actualBaseAmount = baseAmount;
            actualQuoteAmount = baseValueInQuote;
        }
        
        uint256 totalValueInBase = actualBaseAmount + quoteInBase(actualQuoteAmount);
        
        shares = previewDeposit(totalValueInBase);
        require(shares > 0, "ZERO_SHARES");

        baseAsset.safeTransferFrom(_msgSender(), address(this), actualBaseAmount);
        quoteAsset.safeTransferFrom(_msgSender(), address(this), actualQuoteAmount);

        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, totalValueInBase, shares);

        afterDeposit(totalValueInBase, shares);
    }

    // Override mint to use the epoch TVL for calculations
    function mint(uint256 shares, address receiver) public override returns (uint256 totalValueInBase) {
        require(currentEpoch > 0, "Epoch not initialized");

        totalValueInBase = previewMint(shares);
        uint256 halfValueInBase = totalValueInBase / 2;

        uint256 baseAmount = halfValueInBase;
        uint256 quoteAmount = baseInQuote(halfValueInBase);

        baseAsset.safeTransferFrom(_msgSender(), address(this), baseAmount);
        quoteAsset.safeTransferFrom(_msgSender(), address(this), quoteAmount);

        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, totalValueInBase, shares);

        afterDeposit(totalValueInBase, shares);
    }

    /**
    * @dev See {IERC4626-withdraw}.
    */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256) {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");

        // Calculate the shares to withdraw
        uint256 shares = previewWithdraw(assets);
        
        // Split the assets into half for base and quote
        uint256 halfAssets = assets / 2;

        // Calculate the base amount equivalent to half the quote assets
        uint256 baseAmount = halfAssets;
        uint256 quoteAmount = baseInQuote(halfAssets);

        // Ensure proper allowances
        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }

        // Perform the withdrawal
        beforeWithdraw(assets, shares);

        // Burn the shares from the owner's balance
        _burn(owner, shares);

        emit Withdraw(_msgSender(), receiver, owner, assets, shares);

        // Transfer the base and quote assets to the receiver
        baseAsset.safeTransfer(receiver, baseAmount);
        quoteAsset.safeTransfer(receiver, quoteAmount);

        return shares;
    }

    // Override redeem to use the epoch TVL for calculations
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256 assets) {
        require(currentEpoch > 0, "Epoch not initialized");

        assets = previewRedeem(shares);

        uint256 halfAssets = assets / 2;
        uint256 baseAmount = halfAssets;
        uint256 quoteAmount = baseInQuote(halfAssets);

        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        emit Withdraw(_msgSender(), receiver, owner, assets, shares);

        baseAsset.safeTransfer(receiver, baseAmount);
        quoteAsset.safeTransfer(receiver, quoteAmount);
    }

    // Override functions to convert assets and shares
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDivUp(totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDivUp(supply, totalAssets());
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    // Internal hooks
    function beforeWithdraw(uint256 assets, uint256 shares) internal {}

    function afterDeposit(uint256 assets, uint256 shares) internal {}
}
