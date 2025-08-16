//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

library OrderBookErrors {
    /**
     * @dev Thrown when a user is not the owner and tries to execute a privileged function
     */
    error Unauthorized();
    /**
     * @dev Thrown when a market is paused and a user tries to execute an action or if the owner passes an already existing market state for toggling
     */
    error MarketStateError();
    /**
     * @dev Thrown when maker fee passed to initializer is too high/invalid
     */
    error MarketFeeError();
    /**
     * @dev Thrown when minSize = 0 or maxSize < minSize
     */
    error MarketSizeError();
    /**
     * @dev Thrown when Kuru AMM Vault spread passed to initializer is too high or too low or is not a multiple of 10
     */
    error InvalidSpread();
    /**
     * @dev Thrown when the inputted price while adding an order is invalid
     */
    error PriceError();
    /**
     * @dev Thrown when the size inputted is invalid, i.e, < minSize or > maxSize
     */
    error SizeError();
    /**
     * @dev Thrown when price is not divisible by tick
     */
    error TickSizeError();
    /**
     * @dev Thrown when a post only order gets filled
     */
    error PostOnlyError();
    /**
     * @dev Thrown when a flip order matches with a price
     */
    error ProvisionError();
    /**
     * @dev Thrown when a non-owner tries to execute a privileged function, i.e, if non owner tries to pause/unpause a market or
     * if a user tries to cancel an order that they did not place
     */
    error OnlyOwnerAllowedError();
    /**
     * @dev Thrown when wrong interface is called for a cancel
     */
    error WrongOrderTypeCancel();
    /**
     * @dev Thrown when cancelOrder is called on an order which is already filled or cancelled
     */
    error OrderAlreadyFilledOrCancelled();
    /**
     * @dev Thrown when length mismatch occurs between inputted arrays
     */
    error LengthMismatch();
    /**
     * @dev Thrown when msg.value is insufficient in market orders
     */
    error NativeAssetInsufficient();
    /**
     * @dev Thrown when msg.value is surplus in market orders
     */
    error NativeAssetSurplus();
    /**
     * @dev Thrown when msg.value is greater than 0 when native assets are not required
     */
    error NativeAssetNotRequired();
    /**
     * @dev Thrown when native asset transfer fails
     */
    error NativeAssetTransferFail();
    /**
     * @dev Thrown when IOC orders do not get filled by the market
     */
    error InsufficientLiquidity();
    /**
     * @dev Throws when slippage is exceeded in market orders
     */
    error SlippageExceeded();
    /**
     * @dev Thrown when quote size in uint32 overflows
     */
    error TooMuchSizeFilled();
    /**
     * @dev Thrown when safe transfer from fails
     */
    error TransferFromFailed();
    /**
     * @dev Thrown when the call is not made by the vault
     */
    error OnlyVaultAllowed();
    /**
     * @dev Thrown when safe cast to uint96 fails
     */
    error Uint96Overflow();
    /**
     * @dev Thrown when safe cast to uint32 fails
     */
    error Uint32Overflow();
}

library MarginAccountErrors {
    /**
     * @dev Thrown when a non-router tries to update markets
     */
    error OnlyRouterAllowed();
    /**
     * @dev Thrown when a non-verified market tries to execute a market action
     */
    error OnlyVerifiedMarketsAllowed();
    /**
     * @dev Thrown when a user has insufficient margin account balance
     */
    error InsufficientBalance();
    /**
     * @dev Thrown when native asset transfer fails
     */
    error NativeAssetTransferFail();
    /**
     * @dev Thrown when msg.value is not zero when native assets are not required
     */
    error NativeAssetMismatch();
    /**
     * @dev Thrown when zero address is passed as a parameter
     */
    error ZeroAddressNotAllowed();
    /**
     * @dev Thrown when protocol is paused
     */
    error ProtocolPaused();
    /**
     * @dev Thrown when protocol state is not changed
     */
    error ProtocolStateNotChanged();
    /**
     * @dev Thrown when fee collector is not set
     */
    error FeeCollectorNotChanged();
}

library RouterErrors {
    /**
     * @dev Thrown when base and quote asset addresses are the same
     */
    error BaseAndQuoteAssetSame();
    /**
     * @dev Thrown when market type given and token addresses are not compatible
     */
    error MarketTypeMismatch();
    /**
     * @dev Thrown when tick size is 0
     */
    error InvalidTickSize();
    /**
     * @dev Thrown when size precision is not a power of 10
     */
    error InvalidSizePrecision();
    /**
     * @dev Thrown when price precision is not a power of 10
     */
    error InvalidPricePrecision();
    /**
     * @dev Thrown when no markets are passed as input
     */
    error NoMarketsPassed();
    /**
     * @dev Thrown when the length of market addresses, isBuy, and nativeSend arrays are not the same
     */
    error LengthMismatch();
    /**
     * @dev Thrown when the market is invalid
     */
    error InvalidMarket();
    /**
     * @dev Thrown when the slippage exceeds the expected value
     */
    error SlippageExceeded();
    /**
     * @dev Thrown when the native asset transfer fails
     */
    error NativeAssetTransferFail();
    /**
     * @dev Thrown when safe cast to uint96 fails
     */
    error Uint96Overflow();
}

library KuruAMMVaultErrors {
    /**
     * @dev Thrown when a user is not the owner and tries to execute a privileged function
     */
    error Unauthorized();
    /**
     * @dev Thrown when native token passed as argument and msg.value does not match
     */
    error NativeAssetMismatch();
    /**
     * @dev Thrown when amount of quote tokens passed is insufficient
     */
    error InsufficientQuoteToken();
    /**
     * @dev Thrown when insufficient liquidity is minted
     */
    error InsufficientLiquidityMinted();
    /**
     * @dev Thrown when balance of owner is too less
     */
    error InsufficientBalance();
    /**
     * @dev Thrown when native asset transfer fails
     */
    error NativeAssetTransferFail();
    /**
     * @dev Thrown when new size exceeds partially filled size
     */
    error NewSizeExceedsPartiallyFilledSize();
    /**
     * @dev Thrown when vault initialization price crosses the book
     */
    error VaultInitializationPriceCrossesBook();
    /**
     * @dev Thrown when the amounts withdrawn are negative
     */
    error NegativeAmountWithdrawn();
    /**
     * @dev Thrown when safe cast to uint96 fails
     */
    error Uint96Overflow();
}

library KuruForwarderErrors {
    /**
     * @dev Thrown when the signature does not match the request
     */
    error SignatureMismatch();
    /**
     * @dev Thrown when the interface is not allowed
     */
    error InterfaceNotAllowed();
    /**
     * @dev Thrown when the execution fails
     */
    error ExecutionFailed();
    /**
     * @dev Thrown when the nonce is already used
     */
    error NonceAlreadyUsed();
    /**
     * @dev Thrown when the value is insufficient
     */
    error InsufficientValue();
}
