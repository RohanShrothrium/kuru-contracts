// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./AbstractPosition.sol";
import "./interfaces/IFactoryContract.sol";

/**
 * @title Factory Contract
 * @dev A contract that creates and manages AbstractPosition contracts for users.
 */
contract FactoryContract is IFactoryContract {

    address public gov;
    address public wethAddress;
    address public lendingContractAddress;

    address public positionRouterAddress;
    address public routerAddress;
    address public orderBookAddress;
    address public vaultContractAddress;

    // Mapping to store AbstractPosition contract addresses for each user
    mapping(address => address) public abstractPositionMap;

    /**
     * @dev Constructs the FactoryContract contract
     * @param _wethAddress The address of the WETH token contract
     * @param _lendingContractAddress The address of the lending contract
     * @param _positionRouterAddress The address of the PositionRouter contract
     * @param _routerAddress The address of the Router contract
     * @param _orderBookAddress The address of the OrderBook contract
     * @param _vaultContractAddress The address of the Vault contract
     */
    constructor(
        address _wethAddress,
        address _lendingContractAddress,
        address _positionRouterAddress,
        address _routerAddress,
        address _orderBookAddress,
        address _vaultContractAddress
    ) {
        // Initialize state variables
        gov = msg.sender;
        wethAddress = _wethAddress;
        lendingContractAddress = _lendingContractAddress;
        positionRouterAddress = _positionRouterAddress;
        routerAddress = _routerAddress;
        orderBookAddress = _orderBookAddress;
        vaultContractAddress = _vaultContractAddress;
    }

    /**
     * @dev Creates a new AbstractPosition contract for the caller
     * @dev Checks if the caller already has an AbstractPosition contract
     * @return The address of the new AbstractPosition contract
     */
    function createAbstractPosition() public override returns (address) {
        require(abstractPositionMap[msg.sender] == address(0), "abstract position contract already exists for user");

        AbstractPosition abstractPosition = new AbstractPosition(
            gov,
            wethAddress,
            lendingContractAddress,
            msg.sender,
            positionRouterAddress,
            routerAddress,
            orderBookAddress,
            vaultContractAddress
        );

        abstractPositionMap[msg.sender] = address(abstractPosition);

        return address(abstractPosition);
    }

    /**
     * @dev Gets the AbstractPosition contract address for a given user
     * @param account The user's address
     * @return The AbstractPosition contract address
     */
    function getContractForAccount(address account) public override view returns (address) {
        return abstractPositionMap[account];
    }
}
