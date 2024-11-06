//SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import {TreeMath} from "../contracts/libraries/TreeMath.sol";
import "forge-std/Test.sol";

contract TreeMathTest is Test {
    using TreeMath for TreeMath.TreeUint32;

    TreeMath.TreeUint32 tree;

    function testTreeMathAdd() public {
        tree.add(1);
        assertEq(tree.contains(1), true);
    }

    function testTreeMathWithRandomNumbers(bytes32 seed) public {
        uint32[1000] memory randomNumbers = generateRandomNumbers(seed);

        for (uint256 i = 0; i < 500; i++) {
            console.log("Adding ", randomNumbers[i]);
            tree.add(randomNumbers[i]);
        }

        for (uint256 i = 0; i < 500; i++) {
            console.log(randomNumbers[i], " ", tree.contains(randomNumbers[i]));
            assertTrue(tree.contains(randomNumbers[i]));
        }

        for (uint256 i = 500; i < 1000; i++) {
            console.log(randomNumbers[i], " ", tree.contains(randomNumbers[i]));
            assertFalse(tree.contains(randomNumbers[i]));
        }
    }

    function generateRandomNumbers(bytes32 seed) internal view returns (uint32[1000] memory) {
        uint32[1000] memory numbers;
        bytes32 currentSeed = seed;
        for (uint16 i = 0; i < 1000; i++) {
            currentSeed = keccak256(abi.encodePacked(currentSeed));
            uint256 randomNumber = uint256(currentSeed);
            console.log("Random uint256:", randomNumber);
            numbers[i] = uint32(randomNumber);
        }

        return numbers;
    }
}
