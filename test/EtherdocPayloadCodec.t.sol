// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";

contract EtherdocPayloadCodecTest is Test {
    bytes32 private constant DOCUMENT_DIGEST = 0x43cc23fa52b87b4cc1d02b5b114154151d6adddb17c9fddc06b027fa99e24008;
    bytes32 private constant PAYLOAD_HASH = 0x2752d84a3d9421667124cc17076ea9564459e8f5ad00d52bcdf3c8dc330c856d;
    string private constant DOCUMENT_CID = "bafkreicdzqr7uuvypngmdubllmiucvavdvvn3wyxzh65ybvqe75jtysaba";
    address private constant ISSUER = address(0xA11CE);

    struct LegacyDocumentRecord {
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
        EtherdocTypes.DocumentStatus status;
        bytes32 supersedes;
        bytes32 supersededBy;
    }

    struct LegacyDocumentPayload {
        uint16 schemaVersion;
        EtherdocTypes.Operation operation;
        bytes32 documentId;
        uint64 documentVersion;
        LegacyDocumentRecord document;
    }

    function test_compactPayloadSavesFortyOnePercentAgainstSchemaV2() external {
        EtherdocTypes.DocumentRecord memory document = _sampleDocument();
        bytes memory compactPayload = abi.encode(EtherdocTypes.payloadFor(document, EtherdocTypes.Operation.REGISTER));
        bytes memory legacyPayload = abi.encode(_legacyPayload(document));
        uint256 compactCalldataGas = _calldataGas(compactPayload);
        uint256 legacyCalldataGas = _calldataGas(legacyPayload);

        emit log_named_uint("schema-v2 payload bytes", legacyPayload.length);
        emit log_named_uint("schema-v3 payload bytes", compactPayload.length);
        emit log_named_uint("schema-v2 calldata gas", legacyCalldataGas);
        emit log_named_uint("schema-v3 calldata gas", compactCalldataGas);

        assertEq(compactPayload.length, 448);
        assertEq(legacyPayload.length, 768);
        assertEq(legacyPayload.length - compactPayload.length, 320);
        assertEq((legacyPayload.length - compactPayload.length) * 10_000 / legacyPayload.length, 4_166);
        assertLt(compactCalldataGas, legacyCalldataGas);
    }

    function test_schemaV3PayloadKnownAnswerAndRoundTrip() external pure {
        EtherdocTypes.DocumentRecord memory document = _sampleDocument();
        EtherdocTypes.DocumentPayload memory payload =
            EtherdocTypes.payloadFor(document, EtherdocTypes.Operation.REGISTER);
        bytes memory encoded = abi.encode(payload);
        EtherdocTypes.DocumentPayload memory decoded = abi.decode(encoded, (EtherdocTypes.DocumentPayload));
        EtherdocTypes.DocumentRecord memory reconstructed = EtherdocTypes.documentFromPayload(decoded);

        assertEq(encoded.length, 448);
        assertEq(keccak256(encoded), PAYLOAD_HASH);
        assertEq(decoded.schemaVersion, 3);
        assertEq(uint8(decoded.operation), uint8(EtherdocTypes.Operation.REGISTER));
        assertEq(reconstructed.documentId, document.documentId);
        assertEq(reconstructed.documentCID, DOCUMENT_CID);
        assertEq(reconstructed.contentDigest, document.contentDigest);
        assertEq(reconstructed.cidCodec, document.cidCodec);
        assertEq(reconstructed.cidDigest, document.cidDigest);
        assertEq(reconstructed.issuer, document.issuer);
        assertEq(reconstructed.schemaVersion, 3);
    }

    function test_canonicalCIDReconstructionKnownAnswer() external pure {
        string memory reconstructedCID = EtherdocTypes.encodeCanonicalCID(0x55, DOCUMENT_DIGEST);
        (bool valid, uint8 codec, bytes32 digest) = EtherdocTypes.decodeCanonicalCID(reconstructedCID);

        assertEq(reconstructedCID, DOCUMENT_CID);
        assertTrue(valid);
        assertEq(codec, 0x55);
        assertEq(digest, DOCUMENT_DIGEST);
    }

    function _sampleDocument() private pure returns (EtherdocTypes.DocumentRecord memory) {
        return EtherdocTypes.DocumentRecord({
            documentId: keccak256(abi.encode(ISSUER, DOCUMENT_DIGEST)),
            contentDigest: DOCUMENT_DIGEST,
            metadataCommitment: keccak256("payload metadata"),
            documentCID: DOCUMENT_CID,
            cidCodec: 0x55,
            cidDigest: DOCUMENT_DIGEST,
            issuer: ISSUER,
            sourceChainId: 5_003,
            registeredAt: 1_700_000_000,
            updatedAt: 1_700_000_000,
            version: 1,
            schemaVersion: 3,
            status: EtherdocTypes.DocumentStatus.ACTIVE,
            supersedes: bytes32(0),
            supersededBy: bytes32(0)
        });
    }

    function _legacyPayload(EtherdocTypes.DocumentRecord memory _record)
        private
        pure
        returns (LegacyDocumentPayload memory)
    {
        LegacyDocumentRecord memory legacyDocument = LegacyDocumentRecord({
            documentId: _record.documentId,
            contentDigest: _record.contentDigest,
            metadataCommitment: _record.metadataCommitment,
            documentCID: _record.documentCID,
            cidCodec: _record.cidCodec,
            cidDigest: _record.cidDigest,
            issuer: _record.issuer,
            sourceChainId: _record.sourceChainId,
            registeredAt: _record.registeredAt,
            updatedAt: _record.updatedAt,
            version: _record.version,
            schemaVersion: 2,
            status: _record.status,
            supersedes: _record.supersedes,
            supersededBy: _record.supersededBy
        });
        return LegacyDocumentPayload({
            schemaVersion: 2,
            operation: EtherdocTypes.Operation.REGISTER,
            documentId: _record.documentId,
            documentVersion: _record.version,
            document: legacyDocument
        });
    }

    function _calldataGas(bytes memory _data) private pure returns (uint256 gasCost) {
        for (uint256 i; i < _data.length; i++) {
            gasCost += _data[i] == 0 ? 4 : 16;
        }
    }
}
