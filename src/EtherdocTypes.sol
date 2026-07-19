// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

library EtherdocTypes {
    uint16 internal constant SCHEMA_VERSION = 2;
    uint8 internal constant CID_VERSION = 1;
    uint8 internal constant CID_CODEC_RAW = 0x55;
    uint8 internal constant CID_CODEC_DAG_PB = 0x70;
    uint8 internal constant MULTIHASH_SHA2_256 = 0x12;
    uint8 internal constant SHA2_256_DIGEST_LENGTH = 32;
    uint256 internal constant CANONICAL_CID_LENGTH = 59;
    uint256 internal constant MAX_PAYLOAD_LENGTH = 1_024;

    enum DocumentStatus {
        UNKNOWN,
        ACTIVE,
        REVOKED,
        SUPERSEDED
    }

    enum Operation {
        UNKNOWN,
        REGISTER,
        REVOKE,
        SUPERSEDE
    }

    struct DocumentRecord {
        bytes32 documentId;
        bytes32 contentDigest;
        bytes32 metadataCommitment;
        string documentCID;
        uint8 cidCodec;
        bytes32 cidDigest;
        address issuer;
        uint256 sourceChainId;
        uint64 registeredAt;
        uint64 updatedAt;
        uint64 version;
        uint16 schemaVersion;
        DocumentStatus status;
        bytes32 supersedes;
        bytes32 supersededBy;
    }

    struct DocumentPayload {
        uint16 schemaVersion;
        Operation operation;
        bytes32 documentId;
        uint64 documentVersion;
        DocumentRecord document;
    }

    function documentId(address issuer, bytes32 contentDigest) internal pure returns (bytes32) {
        return keccak256(abi.encode(issuer, contentDigest));
    }

    /**
     * @dev Decodes the strict Etherdoc CID profile:
     *      CIDv1, lowercase unpadded base32, raw or dag-pb codec, sha2-256 multihash.
     */
    function decodeCanonicalCID(string memory documentCID)
        internal
        pure
        returns (bool valid, uint8 cidCodec, bytes32 cidDigest)
    {
        bytes memory cid = bytes(documentCID);
        if (cid.length != CANONICAL_CID_LENGTH || cid[0] != 0x62) {
            return (false, 0, bytes32(0));
        }

        bytes memory decoded = new bytes(36);
        uint256 accumulator;
        uint256 bitCount;
        uint256 outputIndex;

        for (uint256 i = 1; i < cid.length; i++) {
            (bool characterValid, uint8 value) = _base32Value(uint8(cid[i]));
            if (!characterValid) {
                return (false, 0, bytes32(0));
            }

            accumulator = (accumulator << 5) | value;
            bitCount += 5;
            if (bitCount >= 8) {
                bitCount -= 8;
                if (outputIndex >= decoded.length) {
                    return (false, 0, bytes32(0));
                }
                // The shift leaves exactly one decoded byte.
                // forge-lint: disable-next-line(unsafe-typecast)
                decoded[outputIndex] = bytes1(uint8(accumulator >> bitCount));
                outputIndex++;
                accumulator &= (2 ** bitCount) - 1;
            }
        }

        if (outputIndex != decoded.length || bitCount != 2 || accumulator != 0) {
            return (false, 0, bytes32(0));
        }

        cidCodec = uint8(decoded[1]);
        if (
            uint8(decoded[0]) != CID_VERSION || (cidCodec != CID_CODEC_RAW && cidCodec != CID_CODEC_DAG_PB)
                || uint8(decoded[2]) != MULTIHASH_SHA2_256 || uint8(decoded[3]) != SHA2_256_DIGEST_LENGTH
        ) {
            return (false, 0, bytes32(0));
        }

        assembly {
            cidDigest := mload(add(decoded, 36))
        }
        return (true, cidCodec, cidDigest);
    }

    function _base32Value(uint8 character) private pure returns (bool valid, uint8 value) {
        if (character >= 97 && character <= 122) {
            return (true, character - 97);
        }
        if (character >= 50 && character <= 55) {
            return (true, character - 50 + 26);
        }
        return (false, 0);
    }

    function operationFor(DocumentStatus status) internal pure returns (Operation) {
        if (status == DocumentStatus.ACTIVE) {
            return Operation.REGISTER;
        }
        if (status == DocumentStatus.REVOKED) {
            return Operation.REVOKE;
        }
        if (status == DocumentStatus.SUPERSEDED) {
            return Operation.SUPERSEDE;
        }
        return Operation.UNKNOWN;
    }
}
