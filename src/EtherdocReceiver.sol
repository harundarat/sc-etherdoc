// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";

contract EtherdocReceiver is CCIPReceiver, OwnerIsCreator {
    enum ReceiptStatus {
        NOT_RECEIVED,
        RECEIVED
    }

    struct ReceiptRecord {
        bytes32 messageId;
        string documentCID;
        uint64 sourceChainSelector;
        address sender;
        uint64 receivedAt;
        ReceiptStatus status;
    }

    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted();

    event MessageReceived(
        bytes32 indexed messageId,
        bytes32 indexed documentId,
        uint64 indexed sourceChainSelector,
        address sender,
        string documentCID,
        uint64 receivedAt
    );

    mapping(bytes32 documentId => ReceiptRecord receipt) private s_receipts;
    mapping(uint64 sourceChainSelector => bool allowlisted) private s_allowlistedSourceChains;
    mapping(address sender => bool allowlisted) private s_allowlistedSenders;

    constructor(address _router) CCIPReceiver(_router) {}

    function allowlistSender(address _sender, bool _allowlisted) external onlyOwner {
        s_allowlistedSenders[_sender] = _allowlisted;
    }

    function allowListSourceChain(uint64 _sourceChainSelector, bool _allowlisted) external onlyOwner {
        s_allowlistedSourceChains[_sourceChainSelector] = _allowlisted;
    }

    /**
     * @dev Internal function to handle incoming CCIP messages
     * @notice This function validates the source chain and sender, then stores the received document
     * @param message The CCIP message containing document data from another chain
     *
     * Requirements:
     * - Source chain must be allowlisted
     * - Sender address must be allowlisted
     *
     * @custom:security Only processes messages from verified sources
     * @custom:storage Writes a destination-side receipt keyed by the canonical document identifier
     *
     * Emits:
     * - MessageReceived event with message details
     *
     * Reverts:
     * - SourceChainNotAllowlisted if source chain is not in allowlist
     * - SenderNotAllowlisted if sender is not in allowlist
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual override {
        if (!s_allowlistedSourceChains[message.sourceChainSelector]) {
            revert SourceChainNotAllowlisted(message.sourceChainSelector);
        }

        address sender = abi.decode(message.sender, (address));
        if (!s_allowlistedSenders[sender]) {
            revert SenderNotAllowlisted();
        }

        string memory documentCID = abi.decode(message.data, (string));
        bytes32 documentId = keccak256(bytes(documentCID));
        uint64 receivedAt = uint64(block.timestamp);
        s_receipts[documentId] = ReceiptRecord({
            messageId: message.messageId,
            documentCID: documentCID,
            sourceChainSelector: message.sourceChainSelector,
            sender: sender,
            receivedAt: receivedAt,
            status: ReceiptStatus.RECEIVED
        });

        emit MessageReceived(
            message.messageId, documentId, message.sourceChainSelector, sender, documentCID, receivedAt
        );
    }

    /**
     * @notice Returns destination-side delivery evidence for one canonical document.
     * @dev A source-side DISPATCHED record is not a substitute for this receipt.
     */
    function getReceipt(bytes32 _documentId) external view returns (ReceiptRecord memory) {
        return s_receipts[_documentId];
    }

    function isDocumentReceived(bytes32 _documentId) external view returns (bool) {
        return s_receipts[_documentId].status == ReceiptStatus.RECEIVED;
    }
}
