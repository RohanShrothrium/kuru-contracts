// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";

import "../tokens/MintableBaseToken.sol";
import "../interfaces/ILendingContract.sol";
import "../tokens/interfaces/IMintable.sol";

/**
 * @title KlpManager
 * @dev Manages the liquidity for the Kuru liquidity pool.
 */
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

    // Modifiers
    /**
     * @dev Throws if called by any account other than the governance address.
     */
    modifier onlyGov() {
        require(msg.sender == gov, "BaseToken: forbidden");
        _;
    }

    // Constructor
    /**
     * @dev Initializes the contract with the given parameters.
     * @param _klp The liquidity provider token contract address.
     * @param _lendingContractAddress The kuru app lending contract address.
     * @param _usdcAddress The external USDC token contract address.
     */
    constructor(address _klp, address _lendingContractAddress, address _usdcAddress) {
        gov = msg.sender;
        klp = _klp;
        lendingContractAddress = _lendingContractAddress;
        usdcAddress = _usdcAddress;
    }

    // Setter functions
    /**
     * @dev Allows the governance address to set the liquidity provider token contract address.
     * @param _klp The new liquidity provider token contract address.
     */
    function setKlp(address _klp) external onlyGov {
        klp = _klp;
    }

    /**
     * @dev Allows the governance address to set the governance address.
     * @param _gov The new governance address.
     */
    function setGov(address _gov) external onlyGov {
        gov = _gov;
    }

    /**
     * @dev Allows the governance address to set the kuru app lending contract address.
     * @param _lendingContractAddress The new kuru app lending contract address.
     */
    function setLendingContractAddress(address _lendingContractAddress) external onlyGov {
        lendingContractAddress = _lendingContractAddress;
    }

    /**
     * @dev Allows the governance address to set the external USDC token contract address.
     * @param _usdcAddress The new external USDC token contract address.
     */
    function setUsdcAddress(address _usdcAddress) external onlyGov {
        usdcAddress = _usdcAddress;
    }

    // External functions
    /**
     * @dev Allows a user to add liquidity to the Kuru liquidity pool.
     * @param _token The token address of the asset being added.
     * @param _amount The amount of the asset being added.
     * @return The amount of liquidity provider tokens minted.
     */
    function addLiquidity(address _token, uint256 _amount) external returns (uint256) {
        // todo allow swap with _minOut feature?
        require(_token == usdcAddress, "unsupported token");

        uint256 _existingLiquidity = ILendingContract(lendingContractAddress).totalLiquidityProvided();

        IERC20(_token).transferFrom(msg.sender, lendingContractAddress, _amount.div(USDC_DECIMALS_DIVISOR));

        uint256 _klpSupply = IERC20(klp).totalSupply();

        uint256 _mintAmount = _klpSupply == 0 ? _amount.div(ERC_DECIMALS_DIVISOR) : _klpSupply.mul(_amount).div(_existingLiquidity);

        IMintable(klp).mint(msg.sender, _mintAmount);

        return _mintAmount;
    }

    /**
     * @dev Removes liquidity from the pool and returns USDC to the caller.
     * @param _tokenOut The address of the token being withdrawn. Only USDC is supported.
     * @param _klpAmount The amount of liquidity tokens to withdraw.
     * @return The amount of USDC returned to the caller.
     */
    function removeLiquidity(address _tokenOut, uint256 _klpAmount) external returns (uint256) {
        // todo allow swap with at the end with _minOut feature
        require(_tokenOut == usdcAddress, "unsupported token");

        uint256 _klpSupply = IERC20(klp).totalSupply();
        uint256 _existingLiquidity = ILendingContract(lendingContractAddress).totalLiquidityProvided();

        uint256 usdcAmount = _klpAmount.div(ERC_DECIMALS_DIVISOR).mul(_existingLiquidity).div(_klpSupply).div(USDC_DECIMALS_DIVISOR);
        
        IMintable(klp).burn(msg.sender, _klpAmount.div(ERC_DECIMALS_DIVISOR));

        ILendingContract(lendingContractAddress).sendUsdcToLp(msg.sender, usdcAmount);

        return usdcAmount;
    }
}
