// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EtherdocTypes {
    uint16 internal constant SCHEMA_VERSION = 1;

    enum DocumentStatus {
        UNKNOWN,
        ACTIVE,
        REVOKED,
        SUPERSEDED
    }

    struct DocumentRecord {
        bytes32 documentId;
        bytes32 contentCommitment;
        bytes32 metadataCommitment;
        string documentCID;
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

    function contentCommitment(string memory documentCID) internal pure returns (bytes32) {
        return keccak256(bytes(documentCID));
    }

    function documentId(address issuer, bytes32 commitment) internal pure returns (bytes32) {
        return keccak256(abi.encode(issuer, commitment));
    }
}
