// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {FixedPointMathLib} from "./libraries/FixedPointMathLib.sol";

contract MultiAssetKuruVault is ERC4626 {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    // Base and quote assets
    ERC20 public immutable baseAsset;
    ERC20 public immutable quoteAsset;

    // State variables to keep track of epochs and TVL for each asset
    uint256 public currentEpoch;
    mapping(uint256 => uint256) public baseAssetEpochTVL;
    mapping(uint256 => uint256) public quoteAssetEpochTVL;

    // Event to log epoch updates
    event EpochUpdated(uint256 epoch, uint256 baseAssetTVL, uint256 quoteAssetTVL);

    constructor(
        ERC20 _baseAsset,
        ERC20 _quoteAsset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_baseAsset) ERC20(_name, _symbol) {
        baseAsset = _baseAsset;
        quoteAsset = _quoteAsset;
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
        // Placeholder implementation
        // TODO: Replace with actual oracle call or market price retrieval
        return baseAmount;
    }

    // Placeholder function to get the value of quote asset in base asset terms
    function quoteInBase(uint256 quoteAmount) public view returns (uint256) {
        // Placeholder implementation
        // TODO: Replace with actual oracle call or market price retrieval
        return quoteAmount;
    }

    // Override totalAssets to return the combined TVL of the latest epoch
    function totalAssets() public view override returns (uint256) {
        return baseInQuote(baseAssetEpochTVL[currentEpoch - 1]) + quoteAssetEpochTVL[currentEpoch - 1];
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
        
        uint256 totalValueInQuote = baseInQuote(actualBaseAmount) + actualQuoteAmount;
        
        shares = previewDeposit(totalValueInQuote);
        require(shares > 0, "ZERO_SHARES");

        baseAsset.safeTransferFrom(_msgSender(), address(this), actualBaseAmount);
        quoteAsset.safeTransferFrom(_msgSender(), address(this), actualQuoteAmount);

        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, totalValueInQuote, shares);

        afterDeposit(totalValueInQuote, shares);
    }

    // Override mint to use the epoch TVL for calculations
    function mint(uint256 shares, address receiver) public override returns (uint256 totalValueInQuote) {
        require(currentEpoch > 0, "Epoch not initialized");

        totalValueInQuote = previewMint(shares);
        uint256 halfValueInQuote = totalValueInQuote / 2;

        uint256 baseAmount = quoteInBase(halfValueInQuote);
        uint256 quoteAmount = halfValueInQuote;

        baseAsset.safeTransferFrom(_msgSender(), address(this), baseAmount);
        quoteAsset.safeTransferFrom(_msgSender(), address(this), quoteAmount);

        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, totalValueInQuote, shares);

        afterDeposit(totalValueInQuote, shares);
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
        uint256 baseAmount = quoteInBase(halfAssets);
        uint256 quoteAmount = halfAssets;

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
        uint256 baseAmount = quoteInBase(halfAssets);
        uint256 quoteAmount = halfAssets;

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
