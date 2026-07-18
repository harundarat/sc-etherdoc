// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EtherdocTypes {
    uint16 internal constant SCHEMA_VERSION = 1;
    uint256 internal constant MAX_DOCUMENT_CID_LENGTH = 256;
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

    struct DocumentPayload {
        uint16 schemaVersion;
        Operation operation;
        bytes32 documentId;
        uint64 documentVersion;
        DocumentRecord document;
    }

    function contentCommitment(string memory documentCID) internal pure returns (bytes32) {
        return keccak256(bytes(documentCID));
    }

    function documentId(address issuer, bytes32 commitment) internal pure returns (bytes32) {
        return keccak256(abi.encode(issuer, commitment));
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
