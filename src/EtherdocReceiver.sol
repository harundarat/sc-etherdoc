// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {EtherdocGovernance} from "./EtherdocGovernance.sol";
import {EtherdocTypes} from "./EtherdocTypes.sol";

contract EtherdocReceiver is CCIPReceiver, EtherdocGovernance {
    uint16 public constant PAYLOAD_SCHEMA_VERSION = EtherdocTypes.SCHEMA_VERSION;
    uint256 public constant CANONICAL_CID_LENGTH = EtherdocTypes.CANONICAL_CID_LENGTH;
    uint256 public constant MAX_PAYLOAD_LENGTH = EtherdocTypes.MAX_PAYLOAD_LENGTH;

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
        EtherdocTypes.Operation operation;
        EtherdocTypes.DocumentRecord document;
    }

    error InvalidMessageId();
    error InvalidSenderEncoding(uint256 encodedLength);
    error InvalidSourceChainSelector(uint64 sourceChainSelector);
    error InvalidRemoteSender(address sender);
    error UntrustedRemote(uint64 sourceChainSelector, address sender);
    error InvalidPayloadLength(uint256 actualLength, uint256 maximumLength);
    error InvalidPayloadSchema(uint16 payloadSchemaVersion, uint16 documentSchemaVersion);
    error InvalidPayloadDocumentId(bytes32 payloadDocumentId, bytes32 documentId);
    error InvalidPayloadVersion(uint64 payloadVersion, uint64 documentVersion);
    error InvalidPayloadOperation(EtherdocTypes.Operation operation, EtherdocTypes.DocumentStatus status);
    error InvalidContentDigest(bytes32 documentId);
    error InvalidDocumentCID();
    error InvalidCIDMetadata(bytes32 documentId);
    error RawCIDContentDigestMismatch(bytes32 contentDigest, bytes32 cidDigest);
    error InvalidDocumentCommitment(bytes32 documentId);
    error InvalidDocumentVersion(bytes32 documentId);
    error ConflictingDocumentProvenance(bytes32 documentId);
    error ConflictingDocumentState(bytes32 documentId, uint64 version);
    error ReceiveIsPaused();
    error ReceiveNotPaused();

    event MessageReceived(
        bytes32 indexed messageId,
        bytes32 indexed documentId,
        uint64 indexed sourceChainSelector,
        address sender,
        address issuer,
        uint64 documentVersion,
        EtherdocTypes.Operation operation,
        EtherdocTypes.DocumentStatus documentStatus,
        uint64 receivedAt
    );
    event MessageIgnored(
        bytes32 indexed messageId,
        bytes32 indexed documentId,
        uint64 incomingVersion,
        uint64 storedVersion,
        bool duplicateMessage
    );
    event TrustedRemoteConfigured(uint64 indexed sourceChainSelector, address indexed sender, bool trusted);
    event ReceivePaused(address indexed account);
    event ReceiveUnpaused(address indexed account);

    mapping(bytes32 documentId => ReceiptRecord receipt) private s_receipts;
    mapping(bytes32 messageId => bool processed) private s_processedMessages;
    mapping(bytes32 messageId => bytes32 documentId) private s_messageDocuments;
    mapping(uint64 sourceChainSelector => mapping(address sender => bool trusted)) private s_trustedRemotes;
    bool private s_receivePaused;

    constructor(address _router, address _governance, address _initialPauser)
        CCIPReceiver(_router)
        EtherdocGovernance(_governance)
    {
        if (_router.code.length == 0) {
            revert InvalidRouter(_router);
        }
        _setRole(PAUSER_ROLE, _initialPauser, true);
    }

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

    function setPauser(address _pauser, bool _authorized) external onlyOwner {
        _setRole(PAUSER_ROLE, _pauser, _authorized);
    }

    function pauseReceive() external onlyRole(PAUSER_ROLE) {
        if (s_receivePaused) {
            revert ReceiveIsPaused();
        }
        s_receivePaused = true;
        emit ReceivePaused(msg.sender);
    }

    function unpauseReceive() external onlyOwner {
        if (!s_receivePaused) {
            revert ReceiveNotPaused();
        }
        s_receivePaused = false;
        emit ReceiveUnpaused(msg.sender);
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
        if (s_receivePaused) {
            revert ReceiveIsPaused();
        }
        if (message.messageId == bytes32(0)) {
            revert InvalidMessageId();
        }
        if (message.sender.length != 32) {
            revert InvalidSenderEncoding(message.sender.length);
        }
        address sender = abi.decode(message.sender, (address));
        if (!s_trustedRemotes[message.sourceChainSelector][sender]) {
            revert UntrustedRemote(message.sourceChainSelector, sender);
        }
        if (s_processedMessages[message.messageId]) {
            bytes32 processedDocumentId = s_messageDocuments[message.messageId];
            uint64 storedVersion = s_receipts[processedDocumentId].document.version;
            emit MessageIgnored(message.messageId, processedDocumentId, storedVersion, storedVersion, true);
            return;
        }
        if (message.data.length == 0 || message.data.length > EtherdocTypes.MAX_PAYLOAD_LENGTH) {
            revert InvalidPayloadLength(message.data.length, EtherdocTypes.MAX_PAYLOAD_LENGTH);
        }

        EtherdocTypes.DocumentPayload memory payload = abi.decode(message.data, (EtherdocTypes.DocumentPayload));
        _validatePayload(payload);
        EtherdocTypes.DocumentRecord memory document = payload.document;

        ReceiptRecord storage existingReceipt = s_receipts[document.documentId];
        if (existingReceipt.status == ReceiptStatus.RECEIVED) {
            _validateSameProvenance(existingReceipt.document, document);
            if (document.version == existingReceipt.document.version) {
                _validateSameState(existingReceipt.document, document);
            }
            if (document.version <= existingReceipt.document.version) {
                _markProcessed(message.messageId, document.documentId);
                emit MessageIgnored(
                    message.messageId, document.documentId, document.version, existingReceipt.document.version, false
                );
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
            operation: payload.operation,
            document: document
        });
        _markProcessed(message.messageId, document.documentId);

        emit MessageReceived(
            message.messageId,
            document.documentId,
            message.sourceChainSelector,
            sender,
            document.issuer,
            document.version,
            payload.operation,
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

    function isMessageProcessed(bytes32 _messageId) external view returns (bool) {
        return s_processedMessages[_messageId];
    }

    function receivePaused() external view returns (bool) {
        return s_receivePaused;
    }

    function getMessageDocument(bytes32 _messageId) external view returns (bytes32) {
        return s_messageDocuments[_messageId];
    }

    function isDocumentReceived(bytes32 _documentId) external view returns (bool) {
        return s_receipts[_documentId].status == ReceiptStatus.RECEIVED;
    }

    function isDocumentActive(bytes32 _documentId) external view returns (bool) {
        return s_receipts[_documentId].document.status == EtherdocTypes.DocumentStatus.ACTIVE;
    }

    function verifyDocument(bytes32 _documentId, bytes32 _contentDigest)
        external
        view
        returns (EtherdocTypes.DocumentRecord memory document, bool integrityMatches, bool isActive)
    {
        document = s_receipts[_documentId].document;
        integrityMatches = document.contentDigest == _contentDigest && document.documentId == _documentId;
        isActive = document.status == EtherdocTypes.DocumentStatus.ACTIVE;
    }

    function _validatePayload(EtherdocTypes.DocumentPayload memory _payload) private pure {
        if (
            _payload.schemaVersion != EtherdocTypes.SCHEMA_VERSION
                || _payload.document.schemaVersion != EtherdocTypes.SCHEMA_VERSION
        ) {
            revert InvalidPayloadSchema(_payload.schemaVersion, _payload.document.schemaVersion);
        }
        if (_payload.documentId != _payload.document.documentId) {
            revert InvalidPayloadDocumentId(_payload.documentId, _payload.document.documentId);
        }
        if (_payload.documentVersion != _payload.document.version) {
            revert InvalidPayloadVersion(_payload.documentVersion, _payload.document.version);
        }
        _validateOperation(_payload.operation, _payload.document);
        _validateDocument(_payload.document);
    }

    function _validateOperation(EtherdocTypes.Operation _operation, EtherdocTypes.DocumentRecord memory _document)
        private
        pure
    {
        if (_operation != EtherdocTypes.operationFor(_document.status)) {
            revert InvalidPayloadOperation(_operation, _document.status);
        }
        if (_operation == EtherdocTypes.Operation.REGISTER) {
            if (_document.version != 1 || _document.supersededBy != bytes32(0)) {
                revert InvalidPayloadOperation(_operation, _document.status);
            }
            return;
        }
        if (_operation == EtherdocTypes.Operation.REVOKE) {
            if (_document.version != 2 || _document.supersededBy != bytes32(0)) {
                revert InvalidPayloadOperation(_operation, _document.status);
            }
            return;
        }
        if (
            _operation != EtherdocTypes.Operation.SUPERSEDE || _document.version != 2
                || _document.supersededBy == bytes32(0)
        ) {
            revert InvalidPayloadOperation(_operation, _document.status);
        }
    }

    function _validateDocument(EtherdocTypes.DocumentRecord memory _document) private pure {
        if (_document.contentDigest == bytes32(0)) {
            revert InvalidContentDigest(_document.documentId);
        }
        (bool validCID, uint8 cidCodec, bytes32 cidDigest) = EtherdocTypes.decodeCanonicalCID(_document.documentCID);
        if (!validCID) {
            revert InvalidDocumentCID();
        }
        if (_document.cidCodec != cidCodec || _document.cidDigest != cidDigest) {
            revert InvalidCIDMetadata(_document.documentId);
        }
        if (cidCodec == EtherdocTypes.CID_CODEC_RAW && cidDigest != _document.contentDigest) {
            revert RawCIDContentDigestMismatch(_document.contentDigest, cidDigest);
        }
        bytes32 expectedDocumentId = EtherdocTypes.documentId(_document.issuer, _document.contentDigest);
        if (_document.issuer == address(0) || _document.documentId != expectedDocumentId) {
            revert InvalidDocumentCommitment(_document.documentId);
        }
        if (
            _document.version == 0 || _document.status == EtherdocTypes.DocumentStatus.UNKNOWN
                || _document.sourceChainId == 0 || _document.registeredAt == 0
                || _document.updatedAt < _document.registeredAt
        ) {
            revert InvalidDocumentVersion(_document.documentId);
        }
    }

    function _validateSameProvenance(
        EtherdocTypes.DocumentRecord storage _existing,
        EtherdocTypes.DocumentRecord memory _incoming
    ) private view {
        if (
            _existing.documentId != _incoming.documentId || _existing.contentDigest != _incoming.contentDigest
                || _existing.metadataCommitment != _incoming.metadataCommitment
                || _existing.cidCodec != _incoming.cidCodec || _existing.cidDigest != _incoming.cidDigest
                || _existing.issuer != _incoming.issuer || _existing.sourceChainId != _incoming.sourceChainId
                || _existing.registeredAt != _incoming.registeredAt
                || _existing.schemaVersion != _incoming.schemaVersion || _existing.supersedes != _incoming.supersedes
        ) {
            revert ConflictingDocumentProvenance(_incoming.documentId);
        }
    }

    function _validateSameState(
        EtherdocTypes.DocumentRecord storage _existing,
        EtherdocTypes.DocumentRecord memory _incoming
    ) private view {
        if (
            _existing.updatedAt != _incoming.updatedAt || _existing.status != _incoming.status
                || _existing.supersededBy != _incoming.supersededBy
        ) {
            revert ConflictingDocumentState(_incoming.documentId, _incoming.version);
        }
    }

    function _markProcessed(bytes32 _messageId, bytes32 _documentId) private {
        s_processedMessages[_messageId] = true;
        s_messageDocuments[_messageId] = _documentId;
    }
}
