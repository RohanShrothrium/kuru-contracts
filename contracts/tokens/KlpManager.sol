// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";

import "../tokens/MintableBaseToken.sol";
import "../LendingContract.sol";
import "../tokens/interfaces/IMintable.sol";

contract KlpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDC_PRECISION = 10 ** 6;
    uint256 public constant USDC_DECIMALS_DIVISOR = 10**24;
    uint256 public constant ERC_DECIMALS_DIVISOR = 10**12;
    uint public constant KLP_PRECISION = 10**18;

    // liquidity provider token contract address
    address klp;
    address gov;

    // kuru app addresses
    address lendingContractAddress;

    // external tokens addresses
    address usdcAddress;

    modifier onlyGov() {
        require(msg.sender == gov, "BaseToken: forbidden");
        _;
    }

    constructor(address _klp, address _lendingContractAddress, address _usdcAddress) {
        gov = msg.sender;
        klp = _klp;
        lendingContractAddress = _lendingContractAddress;
        usdcAddress = _usdcAddress;
    }

    function setKlp(address _klp) external onlyGov {
        klp = _klp;
    }

    function setGov(address _gov) external onlyGov {
        gov = _gov;
    }

    function setLendingContractAddress(address _lendingContractAddress) external onlyGov {
        lendingContractAddress = _lendingContractAddress;
    }

    function setUsdcAddress(address _ussdcAddress) external onlyGov {
        usdcAddress = _ussdcAddress;
    }

    function addLiquidity(address _token, uint256 _amount) external returns (uint256) {
        // todo allow swap with _minOut feature?
        require(_token == usdcAddress, "unsupported token");

        IERC20(_token).transferFrom(msg.sender, lendingContractAddress, _amount.div(USDC_DECIMALS_DIVISOR));

        uint256 _klpSupply = IERC20(klp).totalSupply();
        uint256 _existingLiquidity = LendingContract(lendingContractAddress).totalLiquidityProvided();

        uint256 _mintAmount = _klpSupply == 0 ? _amount.div(ERC_DECIMALS_DIVISOR) : _klpSupply.mul(_amount).div(_existingLiquidity);

        IMintable(klp).mint(msg.sender, _mintAmount);

        return _mintAmount;
    }

    function removeLiquidity(address _tokenOut, uint256 _klpAmount) external returns (uint256) {
        // todo allow swap with at the end with _minOut feature
        require(_tokenOut == usdcAddress, "unsupported token");

        uint256 _klpSupply = IERC20(klp).totalSupply();
        uint256 _existingLiquidity = LendingContract(lendingContractAddress).totalLiquidityProvided();

        uint256 usdcAmount = _klpAmount.div(ERC_DECIMALS_DIVISOR).mul(_existingLiquidity).div(_klpSupply).div(USDC_DECIMALS_DIVISOR);
        
        IMintable(klp).burn(msg.sender, _klpAmount.div(ERC_DECIMALS_DIVISOR));

        LendingContract(lendingContractAddress).sendUsdcToLp(msg.sender, usdcAmount);

        return usdcAmount;
    }
}
