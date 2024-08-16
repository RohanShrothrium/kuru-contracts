// SPDX-License-Identifier: GPL-3.0-only
// Borrowed from DittoETH test suite
pragma solidity ^0.8.21;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {stdJson} from "../../../lib/forge-std/src/StdJson.sol";
import {Test, console} from "forge-std/Test.sol";

function slice(string memory s, uint256 start, uint256 end) pure returns (string memory) {
    bytes memory s_bytes = bytes(s);
    require(start <= end && end <= s_bytes.length, "invalid");

    bytes memory sliced = new bytes(end - start);
    for (uint256 i = start; i < end; i++) {
        sliced[i - start] = s_bytes[i];
    }
    return string(sliced);
}

function eq(string memory s1, string memory s2) pure returns (bool) {
    return keccak256(bytes(s1)) == keccak256(bytes(s2));
}

contract Gas is Test {
    using stdJson for string;

    string private constant SNAPSHOT_DIRECTORY = "./.forge-snapshots/";
    string private constant JSON_PATH = "./.gas.json";
    bool private overwrite = false;
    string private checkpointLabel;
    uint256 private checkpointGasLeft = 12;

    constructor() {
        string[] memory cmd = new string[](3);
        cmd[0] = "mkdir";
        cmd[1] = "-p";
        cmd[2] = SNAPSHOT_DIRECTORY;
        vm.ffi(cmd);

        // try vm.envBool(string("OVERWRITE")) returns (bool _check) {
        //     overwrite = _check;
        // } catch {}
    }

    function startMeasuringGas(string memory label) internal virtual {
        checkpointLabel = label;
        checkpointGasLeft = gasleft(); // 5000 gas to set storage first time, set to make first call consistent
        checkpointGasLeft = gasleft(); // 100
    }

    function stringToUint(string memory s) private pure returns (uint256 result) {
        bytes memory b = bytes(s);
        uint256 i;
        result = 0;
        for (i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
    }

    function stopMeasuringGas() internal virtual returns (uint256) {
        uint256 checkpointGasLeft2 = gasleft();

        // Subtract 146 to account for startMeasuringGas/stopMeasuringGas
        // 100 for cost of setting checkpointGasLeft to same value
        // 40 to call function?
        uint256 gasUsed = (checkpointGasLeft - checkpointGasLeft2) - 140;

        // @dev take the average if test is like `DistributeYieldx100`
        // if the last 4 char of a label == `x100`
        //Not needed for our tests
        // if (eq(slice(checkpointLabel, bytes(checkpointLabel).length - 4, bytes(checkpointLabel).length), "x100")) {
        //     gasUsed = gasUsed.div(100 ether);
        // }

        // string memory gasJson = string(abi.encodePacked(JSON_PATH));

        // string memory snapFile = string(abi.encodePacked(SNAPSHOT_DIRECTORY, checkpointLabel, ".snap"));
        // string calldata exp = "XX";
        // vm.writeFile(exp, exp);
        // if (overwrite) {
        //     vm.writeFile(snapFile, vm.toString(gasUsed));
        // } else {
        //     // if snap file exists
        //     try vm.readLine(snapFile) returns (string memory oldValue) {
        //         uint256 oldGasUsed = stringToUint(oldValue);
        //         bool gasIncrease = gasUsed >= oldGasUsed;
        //         string memory sign = gasIncrease ? "+" : "-";
        //         string memory diff =
        //             string.concat(sign, Strings.toString(gasIncrease ? gasUsed - oldGasUsed : oldGasUsed - gasUsed));

        //         if (gasUsed != oldGasUsed) {
        //             vm.writeFile(snapFile, vm.toString(gasUsed));
        //             if (gasUsed > oldGasUsed + 10000) {
        //                 console.log(
        //                     string.concat(
        //                         string(abi.encodePacked(checkpointLabel)), vm.toString(gasUsed), vm.toString(oldGasUsed), diff
        //                     )
        //                 );
        //             }
        //         }
        //     } catch {
        //         // if not, read gas.json
        //         try vm.readFile(gasJson) returns (string memory json) {
        //             bytes memory parsed = vm.parseJson(json, string.concat(".", checkpointLabel));

        //             // if no key
        //             if (parsed.length == 0) {
        //                 // write new file
        //                 vm.writeFile(snapFile, vm.toString(gasUsed));
        //             } else {
        //                 // otherwise use this value as the old
        //                 uint256 oldGasUsed = abi.decode(parsed, (uint256));
        //                 bool gasIncrease = gasUsed >= oldGasUsed;
        //                 string memory sign = gasIncrease ? "+" : "-";
        //                 string memory diff =
        //                     string.concat(sign, Strings.toString(gasIncrease ? gasUsed - oldGasUsed : oldGasUsed - gasUsed));

        //                 if (gasUsed != oldGasUsed) {
        //                     vm.writeFile(snapFile, vm.toString(gasUsed));
        //                     if (gasUsed > oldGasUsed + 10000) {
        //                         console.log(
        //                             string.concat(
        //                                 string(abi.encodePacked(checkpointLabel)),
        //                                 vm.toString(gasUsed),
        //                                 vm.toString(oldGasUsed),
        //                                 diff
        //                             )
        //                         );
        //                     }
        //                 }
        //             }
        //         } catch {
        //             vm.writeFile(snapFile, vm.toString(gasUsed));
        //         }
        //     }
        // }

        return gasUsed;
    }
}
