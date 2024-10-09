//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Errors {
    /**
     * @dev Thrown when a market is paused and a user tries to execute an action or if the owner passes an already existing market state for toggling
     */
    error MarketStateError();
    /**
     * @dev Thrown when maker fee passed to initializer is too high/invalid
     */
    error MarketFeeError();
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
     * @dev Thrown when a non-owner tries to execute a privileged function, i.e, if non owner tries to pause/unpause a market or
     * if a user tries to cancel an order that they did not place
     */
    error OnlyOwnerAllowedError();
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
    @dev Throws when slippage is exceeded in market orders
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
}
