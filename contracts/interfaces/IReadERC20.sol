// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IReadERC20 {
    /** 
     * @notice Returns the name of the token
     * @return The name of the token
     */
    function name() external view returns (string memory);

    /** 
     * @notice Returns the symbol of the token
     * @return The symbol of the token
     */
    function symbol() external view returns (string memory);

    /** 
     * @notice Returns the number of decimals the token uses
     * @return The number of decimals
     */
    function decimals() external view returns (uint8);

    /** 
     * @notice Returns the balance of the token for a given address
     * @param account The address to get the balance of
     * @return The balance of the token
     */
    function balanceOf(address account) external view returns (uint256);
}
