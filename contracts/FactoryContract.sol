// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./AbstractPosition.sol";
import "./interfaces/IFactoryContract.sol";

contract FactoryContract is IFactoryContract {
    address public gov;
    address public lendingContractAddress;

    address public positionRouterAddress;
    address public routerAddress;
    address public orderBookAddress;
    address public vaultContractAddress;

    mapping(address => address) public abstractPositionMap;

    constructor(
        address _lendingContractAddress,
        address _positionRouterAddress,
        address _routerAddress,
        address _orderBookAddress,
        address _vaultContractAddress
    ) {
        // init state variables
        gov = msg.sender;
        lendingContractAddress = _lendingContractAddress;
        positionRouterAddress = _positionRouterAddress;
        routerAddress = _routerAddress;
        orderBookAddress = _orderBookAddress;
        vaultContractAddress = _vaultContractAddress;
    }

    // this creates an abstract position contract instance for the user, ie, msg.sender and saves as a state variable.
    function createAbstractPosition() public override returns (address) {
        require(abstractPositionMap[msg.sender] == address(0), "abstract position contract already exists for user");

        AbstractPosition abstractPosition = new AbstractPosition(
            gov,
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


    // gets the abstract position contract address for a particular user.
    function getContractForAccount(address account) public override view returns (address) {
        return abstractPositionMap[account];
    }
}
