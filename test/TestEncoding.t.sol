// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

contract EncodingTest is Test {
    function testEncodeDecode() public view {
        bytes memory first = abi.encode(address(1), address(2), uint256(10), true);
        bytes memory second = abi.encode(address(3), address(4), uint256(20), false);

        (address[] memory add, address[] memory tooken, uint256[] memory sizes, bool[] memory isMargin) =
            this.decode(bytes.concat(first, second), 2);

        console.log(add[0]);
        console.log(add[1]);
        console.log(tooken[0]);
        console.log(tooken[1]);
        console.log(sizes[0]);
        console.log(sizes[1]);
        console.log(isMargin[0]);
        console.log(isMargin[1]);
    }

    function decode(bytes calldata encoded, uint32 numItems)
        external
        pure
        returns (address[] memory, address[] memory, uint256[] memory, bool[] memory)
    {
        address[] memory owners = new address[](numItems);
        address[] memory tokens = new address[](numItems);
        uint256[] memory sizes = new uint256[](numItems);
        bool[] memory isMargin = new bool[](numItems);
        uint256 offset = 0;
        uint256 i = 0;
        while (offset < encoded.length) {
            (owners[i], tokens[i], sizes[i], isMargin[i]) =
                abi.decode(encoded[offset:offset + 128], (address, address, uint256, bool));
            offset += 128;
            i += 1;
        }

        return (owners, tokens, sizes, isMargin);
    }
}
