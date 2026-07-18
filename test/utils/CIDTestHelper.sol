// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library CIDTestHelper {
    bytes internal constant BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

    function digestFor(string memory content) internal pure returns (bytes32) {
        return sha256(bytes(content));
    }

    function rawCIDFor(string memory content) internal pure returns (string memory) {
        return cidForDigest(0x55, digestFor(content));
    }

    function cidForDigest(uint8 codec, bytes32 digest) internal pure returns (string memory) {
        bytes memory input = abi.encodePacked(bytes1(0x01), bytes1(codec), bytes1(0x12), bytes1(0x20), digest);
        bytes memory output = new bytes(59);
        output[0] = "b";

        uint256 accumulator;
        uint256 bitCount;
        uint256 outputIndex = 1;
        for (uint256 i; i < input.length; i++) {
            accumulator = (accumulator << 8) | uint8(input[i]);
            bitCount += 8;
            while (bitCount >= 5) {
                bitCount -= 5;
                output[outputIndex] = BASE32_ALPHABET[(accumulator >> bitCount) & 31];
                outputIndex++;
                accumulator &= (2 ** bitCount) - 1;
            }
        }
        if (bitCount != 0) {
            output[outputIndex] = BASE32_ALPHABET[(accumulator << (5 - bitCount)) & 31];
            outputIndex++;
        }

        require(outputIndex == output.length, "unexpected CID length");
        return string(output);
    }
}
