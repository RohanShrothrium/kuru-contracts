// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract KuruERC20 is ERC20 {

    string private _name;

    string private _symbol;

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_, address mintRecipient_) {
        _name = name_;
        _symbol = symbol_;
        // Mint the initial supply to the owner's address
        _mint(mintRecipient_, initialSupply_);
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }
}
