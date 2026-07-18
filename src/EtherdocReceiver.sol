// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {EtherdocTypes} from "./EtherdocTypes.sol";

contract EtherdocReceiver is CCIPReceiver, OwnerIsCreator {
    enum ReceiptStatus {
        NOT_RECEIVED,
        RECEIVED
    }

    struct ReceiptRecord {
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sender;
        uint64 receivedAt;
        ReceiptStatus status;
        EtherdocTypes.DocumentRecord document;
    }

    error InvalidSourceChainSelector(uint64 sourceChainSelector);
    error InvalidRemoteSender(address sender);
    error UntrustedRemote(uint64 sourceChainSelector, address sender);
    error InvalidDocumentSchema(uint16 schemaVersion);
    error InvalidDocumentCommitment(bytes32 documentId);
    error InvalidDocumentVersion(bytes32 documentId);
    error ConflictingDocumentProvenance(bytes32 documentId);

    event MessageReceived(
        bytes32 indexed messageId,
        bytes32 indexed documentId,
        uint64 indexed sourceChainSelector,
        address sender,
        address issuer,
        uint64 documentVersion,
        EtherdocTypes.DocumentStatus documentStatus,
        uint64 receivedAt
    );
    event TrustedRemoteConfigured(uint64 indexed sourceChainSelector, address indexed sender, bool trusted);

    mapping(bytes32 documentId => ReceiptRecord receipt) private s_receipts;
    mapping(uint64 sourceChainSelector => mapping(address sender => bool trusted)) private s_trustedRemotes;

    constructor(address _router) CCIPReceiver(_router) {}

    function configureTrustedRemote(uint64 _sourceChainSelector, address _sender, bool _trusted) external onlyOwner {
        if (_sourceChainSelector == 0) {
            revert InvalidSourceChainSelector(_sourceChainSelector);
        }
        if (_sender == address(0)) {
            revert InvalidRemoteSender(_sender);
        }

        s_trustedRemotes[_sourceChainSelector][_sender] = _trusted;
        emit TrustedRemoteConfigured(_sourceChainSelector, _sender, _trusted);
    }

    /**
     * @dev Internal function to handle incoming CCIP messages
     * @notice This function validates the source chain and sender, then stores the received document
     * @param message The CCIP message containing document data from another chain
     *
     * Requirements:
     * - The source chain and sender pair must be trusted
     *
     * @custom:security Only processes messages from verified sources
     * @custom:storage Writes a destination-side receipt keyed by the canonical document identifier
     *
     * Emits:
     * - MessageReceived event with message details
     *
     * Reverts:
     * - UntrustedRemote if the source chain and sender pair is not trusted
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual override {
        address sender = abi.decode(message.sender, (address));
        if (!s_trustedRemotes[message.sourceChainSelector][sender]) {
            revert UntrustedRemote(message.sourceChainSelector, sender);
        }

        EtherdocTypes.DocumentRecord memory document = abi.decode(message.data, (EtherdocTypes.DocumentRecord));
        _validateDocument(document);

        ReceiptRecord storage existingReceipt = s_receipts[document.documentId];
        if (existingReceipt.status == ReceiptStatus.RECEIVED) {
            _validateSameProvenance(existingReceipt.document, document);
            if (document.version <= existingReceipt.document.version) {
                return;
            }
        }

        uint64 receivedAt = uint64(block.timestamp);
        s_receipts[document.documentId] = ReceiptRecord({
            messageId: message.messageId,
            sourceChainSelector: message.sourceChainSelector,
            sender: sender,
            receivedAt: receivedAt,
            status: ReceiptStatus.RECEIVED,
            document: document
        });

        emit MessageReceived(
            message.messageId,
            document.documentId,
            message.sourceChainSelector,
            sender,
            document.issuer,
            document.version,
            document.status,
            receivedAt
        );
    }

    /**
     * @notice Returns destination-side delivery evidence for one canonical document.
     * @dev A source-side DISPATCHED record is not a substitute for this receipt.
     */
    function getReceipt(bytes32 _documentId) external view returns (ReceiptRecord memory) {
        return s_receipts[_documentId];
    }

    function isTrustedRemote(uint64 _sourceChainSelector, address _sender) external view returns (bool) {
        return s_trustedRemotes[_sourceChainSelector][_sender];
    }

    function isDocumentReceived(bytes32 _documentId) external view returns (bool) {
        return s_receipts[_documentId].status == ReceiptStatus.RECEIVED;
    }

    function isDocumentActive(bytes32 _documentId) external view returns (bool) {
        return s_receipts[_documentId].document.status == EtherdocTypes.DocumentStatus.ACTIVE;
    }

    function verifyDocument(bytes32 _documentId, string calldata _documentCID)
        external
        view
        returns (EtherdocTypes.DocumentRecord memory document, bool integrityMatches, bool isActive)
    {
        document = s_receipts[_documentId].document;
        integrityMatches = document.contentCommitment == EtherdocTypes.contentCommitment(_documentCID)
            && document.documentId == _documentId;
        isActive = document.status == EtherdocTypes.DocumentStatus.ACTIVE;
    }

    function _validateDocument(EtherdocTypes.DocumentRecord memory _document) private pure {
        if (_document.schemaVersion != EtherdocTypes.SCHEMA_VERSION) {
            revert InvalidDocumentSchema(_document.schemaVersion);
        }
        bytes32 commitment = EtherdocTypes.contentCommitment(_document.documentCID);
        bytes32 expectedDocumentId = EtherdocTypes.documentId(_document.issuer, commitment);
        if (
            _document.issuer == address(0) || _document.contentCommitment != commitment
                || _document.documentId != expectedDocumentId
        ) {
            revert InvalidDocumentCommitment(_document.documentId);
        }
        if (_document.version == 0 || _document.status == EtherdocTypes.DocumentStatus.UNKNOWN) {
            revert InvalidDocumentVersion(_document.documentId);
        }
    }

    function _validateSameProvenance(
        EtherdocTypes.DocumentRecord storage _existing,
        EtherdocTypes.DocumentRecord memory _incoming
    ) private view {
        if (
            _existing.documentId != _incoming.documentId || _existing.contentCommitment != _incoming.contentCommitment
                || _existing.metadataCommitment != _incoming.metadataCommitment || _existing.issuer != _incoming.issuer
                || _existing.sourceChainId != _incoming.sourceChainId
                || _existing.registeredAt != _incoming.registeredAt
                || _existing.schemaVersion != _incoming.schemaVersion || _existing.supersedes != _incoming.supersedes
        ) {
            revert ConflictingDocumentProvenance(_incoming.documentId);
        }
    }
}
