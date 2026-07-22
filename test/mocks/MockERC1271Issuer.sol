// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts@5.3.0/interfaces/IERC1271.sol";

contract MockERC1271Issuer is IERC1271 {
    bytes32 private s_validDigest;
    bytes32 private s_validSignatureHash;
    bool private s_shouldRevert;
    bool private s_returnInvalidMagicValue;

    function configure(bytes32 _digest, bytes calldata _signature) external {
        s_validDigest = _digest;
        s_validSignatureHash = keccak256(_signature);
    }

    function setShouldRevert(bool _shouldRevert) external {
        s_shouldRevert = _shouldRevert;
    }

    function setReturnInvalidMagicValue(bool _returnInvalidMagicValue) external {
        s_returnInvalidMagicValue = _returnInvalidMagicValue;
    }

    function isValidSignature(bytes32 _digest, bytes memory _signature) external view returns (bytes4) {
        if (s_shouldRevert) {
            revert("signature validation failed");
        }
        if (!s_returnInvalidMagicValue && _digest == s_validDigest && keccak256(_signature) == s_validSignatureHash) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }
}
