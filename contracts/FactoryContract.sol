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

    address public bnbOrderManagerAddress;
    address public bnbPoolAddress;
    address public bnbLevelOracleAddress;

    // Mapping to store AbstractPosition contract addresses for each user
    mapping(address => address) public abstractPositionMap;

    constructor(
        address _lendingContractAddress,
        address _bnbOrderManagerAddress,
        address _bnbPoolAddress,
        address _bnbLevelOracleAddress
    ) {
        // Initialize state variables
        gov = msg.sender;
        lendingContractAddress = _lendingContractAddress;

        bnbOrderManagerAddress = _bnbOrderManagerAddress;
        bnbPoolAddress = _bnbPoolAddress;
        bnbLevelOracleAddress = _bnbLevelOracleAddress;
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
            bnbOrderManagerAddress,
            bnbPoolAddress,
            bnbLevelOracleAddress
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
