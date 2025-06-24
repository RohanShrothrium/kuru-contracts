// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract KuruERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply, address mintRecipient)
        ERC20(name, symbol)
    {
        // Mint the initial supply to the owner's address
        _mint(mintRecipient, initialSupply);
    }
}
