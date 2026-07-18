// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {LinkToken} from "@chainlink/local/src/shared/LinkToken.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";

contract DeferredRouter is IRouterClient {
    struct QueuedMessage {
        address receiver;
        address sender;
        bytes data;
        bool exists;
    }

    uint64 public constant SOURCE_CHAIN_SELECTOR = 99;
    uint256 public constant FEE = 1 ether;

    uint256 private s_nonce;
    mapping(bytes32 messageId => QueuedMessage message) private s_messages;

    function isChainSupported(uint64) external pure returns (bool supported) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256 fee) {
        return FEE;
    }

    function ccipSend(uint64 _destinationChainSelector, Client.EVM2AnyMessage calldata _message)
        external
        payable
        returns (bytes32 messageId)
    {
        s_nonce++;
        messageId = keccak256(abi.encode(_destinationChainSelector, msg.sender, _message.receiver, s_nonce));
        s_messages[messageId] = QueuedMessage({
            receiver: abi.decode(_message.receiver, (address)), sender: msg.sender, data: _message.data, exists: true
        });
    }

    function deliver(bytes32 _messageId) external {
        _deliverAs(_messageId, SOURCE_CHAIN_SELECTOR, s_messages[_messageId].sender);
    }

    function deliverAs(bytes32 _messageId, uint64 _sourceChainSelector, address _sender) external {
        _deliverAs(_messageId, _sourceChainSelector, _sender);
    }

    function deliverRaw(
        address _receiver,
        bytes32 _messageId,
        uint64 _sourceChainSelector,
        address _sender,
        bytes calldata _data
    ) external {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: _sourceChainSelector,
            sender: abi.encode(_sender),
            data: _data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        EtherdocReceiver(_receiver).ccipReceive(message);
    }

    function getData(bytes32 _messageId) external view returns (bytes memory) {
        return s_messages[_messageId].data;
    }

    function _deliverAs(bytes32 _messageId, uint64 _sourceChainSelector, address _sender) private {
        QueuedMessage storage queuedMessage = s_messages[_messageId];
        require(queuedMessage.exists, "message not queued");

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: _sourceChainSelector,
            sender: abi.encode(_sender),
            data: queuedMessage.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        EtherdocReceiver(queuedMessage.receiver).ccipReceive(message);
    }
}

contract EtherdocLifecycleTest is Test {
    uint64 private constant DESTINATION_A = 11;
    uint64 private constant DESTINATION_B = 22;
    string private constant DOCUMENT_CID = "ipfs://bafy-lifecycle";

    DeferredRouter private s_router;
    LinkToken private s_link;
    EtherdocSender private s_sender;
    EtherdocReceiver private s_receiverA;
    EtherdocReceiver private s_receiverB;
    bytes32 private s_documentId;
    uint64 private s_sourceChainSelector;

    function setUp() public {
        s_router = new DeferredRouter();
        s_link = new LinkToken();
        s_sender = new EtherdocSender(address(s_router), address(s_link));
        s_receiverA = new EtherdocReceiver(address(s_router));
        s_receiverB = new EtherdocReceiver(address(s_router));
        s_sourceChainSelector = s_router.SOURCE_CHAIN_SELECTOR();

        assertTrue(s_link.transfer(address(s_sender), 100 ether));
        s_sender.configureRemote(DESTINATION_A, address(s_receiverA), 500_000, true);
        s_sender.configureRemote(DESTINATION_B, address(s_receiverB), 500_000, true);
        s_documentId = s_sender.registerDocument(DOCUMENT_CID);
    }

    function test_pendingDispatchIsNotReportedAsReceived() external {
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);

        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocSender.DispatchRecord memory dispatch = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocTypes.DocumentPayload memory payload =
            abi.decode(s_router.getData(messageId), (EtherdocTypes.DocumentPayload));
        EtherdocReceiver.ReceiptRecord memory receipt = s_receiverA.getReceipt(s_documentId);

        assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(dispatch.messageId, messageId);
        assertEq(uint8(dispatch.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(payload.schemaVersion, 1);
        assertEq(uint8(payload.operation), uint8(EtherdocTypes.Operation.REGISTER));
        assertEq(payload.documentId, s_documentId);
        assertEq(payload.documentVersion, 1);
        assertEq(payload.document.documentId, s_documentId);
        assertEq(payload.document.documentCID, DOCUMENT_CID);
        assertEq(receipt.messageId, bytes32(0));
        assertEq(uint8(receipt.status), uint8(EtherdocReceiver.ReceiptStatus.NOT_RECEIVED));
        assertFalse(s_receiverA.isDocumentReceived(s_documentId));
    }

    function test_failedDestinationExecutionCanRetrySameMessage() external {
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.UntrustedRemote.selector, s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender)
            )
        );
        s_router.deliver(messageId);

        EtherdocSender.DispatchRecord memory dispatch = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocReceiver.ReceiptRecord memory failedReceipt = s_receiverA.getReceipt(s_documentId);
        assertEq(dispatch.messageId, messageId);
        assertEq(uint8(dispatch.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(uint8(failedReceipt.status), uint8(EtherdocReceiver.ReceiptStatus.NOT_RECEIVED));

        s_receiverA.configureTrustedRemote(s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender), true);
        vm.warp(block.timestamp + 15);
        s_router.deliver(messageId);

        EtherdocReceiver.ReceiptRecord memory retriedReceipt = s_receiverA.getReceipt(s_documentId);
        assertEq(retriedReceipt.messageId, messageId);
        assertEq(retriedReceipt.document.documentCID, DOCUMENT_CID);
        assertEq(retriedReceipt.document.issuer, address(this));
        assertEq(retriedReceipt.document.sourceChainId, block.chainid);
        assertEq(uint8(retriedReceipt.document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(retriedReceipt.sourceChainSelector, s_router.SOURCE_CHAIN_SELECTOR());
        assertEq(retriedReceipt.sender, address(s_sender));
        assertEq(retriedReceipt.receivedAt, block.timestamp);
        assertEq(uint8(retriedReceipt.operation), uint8(EtherdocTypes.Operation.REGISTER));
        assertEq(uint8(retriedReceipt.status), uint8(EtherdocReceiver.ReceiptStatus.RECEIVED));
        assertTrue(s_receiverA.isMessageProcessed(messageId));
        assertEq(s_receiverA.getMessageDocument(messageId), s_documentId);
    }

    function test_workflowIsCompleteOnlyAfterEveryDestinationHasReceipt() external {
        _allowReceiver(s_receiverA);
        _allowReceiver(s_receiverB);

        bytes32 messageIdA = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        bytes32 messageIdB = s_sender.dispatchDocument(s_documentId, DESTINATION_B);

        s_router.deliver(messageIdA);
        assertTrue(s_receiverA.isDocumentReceived(s_documentId));
        assertFalse(s_receiverB.isDocumentReceived(s_documentId));

        s_router.deliver(messageIdB);

        EtherdocReceiver.ReceiptRecord memory receiptA = s_receiverA.getReceipt(s_documentId);
        EtherdocReceiver.ReceiptRecord memory receiptB = s_receiverB.getReceipt(s_documentId);
        assertTrue(s_receiverA.isDocumentReceived(s_documentId));
        assertTrue(s_receiverB.isDocumentReceived(s_documentId));
        assertEq(receiptA.messageId, messageIdA);
        assertEq(receiptB.messageId, messageIdB);
    }

    function test_revocationCanBeDispatchedWithoutDeletingRegistrationHistory() external {
        _allowReceiver(s_receiverA);

        bytes32 activeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        s_router.deliver(activeMessageId);
        assertTrue(s_receiverA.isDocumentActive(s_documentId));

        s_sender.revokeDocument(s_documentId);
        EtherdocTypes.DocumentRecord memory sourceDocument = s_sender.getDocument(s_documentId);
        assertEq(uint8(sourceDocument.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        assertEq(sourceDocument.version, 2);
        assertEq(sourceDocument.documentCID, DOCUMENT_CID);

        bytes32 revokedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        s_router.deliver(revokedMessageId);

        EtherdocReceiver.ReceiptRecord memory destinationReceipt = s_receiverA.getReceipt(s_documentId);
        EtherdocSender.DispatchRecord memory activeDispatch =
            s_sender.getDispatchAtVersion(s_documentId, DESTINATION_A, 1);
        assertEq(activeDispatch.messageId, activeMessageId);
        assertEq(destinationReceipt.messageId, revokedMessageId);
        assertEq(destinationReceipt.document.version, 2);
        assertEq(uint8(destinationReceipt.operation), uint8(EtherdocTypes.Operation.REVOKE));
        assertEq(uint8(destinationReceipt.document.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        assertTrue(s_receiverA.isDocumentReceived(s_documentId));
        assertFalse(s_receiverA.isDocumentActive(s_documentId));

        s_router.deliver(activeMessageId);
        EtherdocReceiver.ReceiptRecord memory receiptAfterStaleDelivery = s_receiverA.getReceipt(s_documentId);
        assertEq(receiptAfterStaleDelivery.messageId, revokedMessageId);
        assertEq(receiptAfterStaleDelivery.document.version, 2);
        assertEq(uint8(receiptAfterStaleDelivery.document.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
    }

    function test_duplicateMessageIsIgnoredAndRemainsObservable() external {
        _allowReceiver(s_receiverA);
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        s_router.deliver(messageId);

        EtherdocReceiver.ReceiptRecord memory firstReceipt = s_receiverA.getReceipt(s_documentId);
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, true, false, true);
        emit EtherdocReceiver.MessageIgnored(messageId, s_documentId, 1, 1, true);
        s_router.deliver(messageId);

        EtherdocReceiver.ReceiptRecord memory duplicateReceipt = s_receiverA.getReceipt(s_documentId);
        assertEq(duplicateReceipt.messageId, firstReceipt.messageId);
        assertEq(duplicateReceipt.receivedAt, firstReceipt.receivedAt);
        assertTrue(s_receiverA.isMessageProcessed(messageId));
        assertEq(s_receiverA.getMessageDocument(messageId), s_documentId);
    }

    function test_outOfOrderOlderMessageCannotReactivateRevokedDocument() external {
        _allowReceiver(s_receiverA);
        bytes32 activeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        s_sender.revokeDocument(s_documentId);
        bytes32 revokedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);

        s_router.deliver(revokedMessageId);
        assertFalse(s_receiverA.isDocumentActive(s_documentId));

        s_router.deliver(activeMessageId);

        EtherdocReceiver.ReceiptRecord memory receipt = s_receiverA.getReceipt(s_documentId);
        assertEq(receipt.messageId, revokedMessageId);
        assertEq(receipt.document.version, 2);
        assertEq(uint8(receipt.operation), uint8(EtherdocTypes.Operation.REVOKE));
        assertEq(uint8(receipt.document.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        assertTrue(s_receiverA.isMessageProcessed(activeMessageId));
        assertTrue(s_receiverA.isMessageProcessed(revokedMessageId));
    }

    function test_supersessionPayloadLinksBothRecordsWithExplicitOperations() external {
        _allowReceiver(s_receiverA);
        bytes32 replacementId =
            s_sender.supersedeDocument(s_documentId, "ipfs://bafy-lifecycle-replacement", bytes32(uint256(123)));

        bytes32 supersedeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        bytes32 replacementMessageId = s_sender.dispatchDocument(replacementId, DESTINATION_A);
        s_router.deliver(supersedeMessageId);
        s_router.deliver(replacementMessageId);

        EtherdocReceiver.ReceiptRecord memory oldReceipt = s_receiverA.getReceipt(s_documentId);
        EtherdocReceiver.ReceiptRecord memory replacementReceipt = s_receiverA.getReceipt(replacementId);
        assertEq(uint8(oldReceipt.operation), uint8(EtherdocTypes.Operation.SUPERSEDE));
        assertEq(uint8(oldReceipt.document.status), uint8(EtherdocTypes.DocumentStatus.SUPERSEDED));
        assertEq(oldReceipt.document.version, 2);
        assertEq(oldReceipt.document.supersededBy, replacementId);
        assertEq(uint8(replacementReceipt.operation), uint8(EtherdocTypes.Operation.REGISTER));
        assertEq(uint8(replacementReceipt.document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(replacementReceipt.document.version, 1);
        assertEq(replacementReceipt.document.supersedes, s_documentId);
    }

    function test_receiverRejectsOversizedPayload() external {
        _allowReceiver(s_receiverA);
        bytes32 messageId = keccak256("oversized-payload");
        bytes memory oversizedPayload = new bytes(s_receiverA.MAX_PAYLOAD_LENGTH() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadLength.selector,
                oversizedPayload.length,
                s_receiverA.MAX_PAYLOAD_LENGTH()
            )
        );
        s_router.deliverRaw(address(s_receiverA), messageId, s_sourceChainSelector, address(s_sender), oversizedPayload);

        assertFalse(s_receiverA.isMessageProcessed(messageId));
    }

    function test_receiverRejectsEnvelopeWithMismatchedOperationAndVersion() external {
        _allowReceiver(s_receiverA);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocTypes.DocumentPayload memory payload = EtherdocTypes.DocumentPayload({
            schemaVersion: 1,
            operation: EtherdocTypes.Operation.REVOKE,
            documentId: document.documentId,
            documentVersion: document.version + 1,
            document: document
        });

        bytes32 operationMessageId = keccak256("invalid-operation");
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadVersion.selector, payload.documentVersion, document.version
            )
        );
        _deliverPayload(operationMessageId, payload);
        assertFalse(s_receiverA.isMessageProcessed(operationMessageId));

        payload.documentVersion = document.version;
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadOperation.selector,
                EtherdocTypes.Operation.REVOKE,
                EtherdocTypes.DocumentStatus.ACTIVE
            )
        );
        _deliverPayload(operationMessageId, payload);
        assertFalse(s_receiverA.isMessageProcessed(operationMessageId));

        payload.operation = EtherdocTypes.Operation.REGISTER;
        payload.documentId = bytes32(uint256(123));
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadDocumentId.selector, payload.documentId, document.documentId
            )
        );
        _deliverPayload(operationMessageId, payload);
        assertFalse(s_receiverA.isMessageProcessed(operationMessageId));
    }

    function test_receiverRejectsUnsupportedSchemaAndEmptyCID() external {
        _allowReceiver(s_receiverA);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocTypes.DocumentPayload memory payload = EtherdocTypes.DocumentPayload({
            schemaVersion: 2,
            operation: EtherdocTypes.Operation.REGISTER,
            documentId: document.documentId,
            documentVersion: document.version,
            document: document
        });

        bytes32 schemaMessageId = keccak256("invalid-schema");
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidPayloadSchema.selector, uint16(2), uint16(1)));
        _deliverPayload(schemaMessageId, payload);

        payload.schemaVersion = 1;
        payload.document.documentCID = "";
        bytes32 emptyCIDMessageId = keccak256("empty-cid");
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidDocumentCID.selector, uint256(0)));
        _deliverPayload(emptyCIDMessageId, payload);

        uint256 oversizedCIDLength = s_receiverA.MAX_DOCUMENT_CID_LENGTH() + 1;
        payload.document.documentCID = string(new bytes(oversizedCIDLength));
        bytes32 oversizedCIDMessageId = keccak256("oversized-cid");
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidDocumentCID.selector, oversizedCIDLength));
        _deliverPayload(oversizedCIDMessageId, payload);

        assertFalse(s_receiverA.isMessageProcessed(schemaMessageId));
        assertFalse(s_receiverA.isMessageProcessed(emptyCIDMessageId));
        assertFalse(s_receiverA.isMessageProcessed(oversizedCIDMessageId));
    }

    function test_trustedRemotePairsDoNotAllowCrossProduct() external {
        uint64 sourceA = 101;
        uint64 sourceB = 202;
        address senderX = makeAddr("sender-x");
        address senderY = makeAddr("sender-y");

        s_receiverA.configureTrustedRemote(sourceA, senderX, true);
        s_receiverA.configureTrustedRemote(sourceB, senderY, true);

        bytes32 messageAX = _queueDocument("ipfs://pair-a-x");
        bytes32 messageBY = _queueDocument("ipfs://pair-b-y");
        bytes32 messageAY = _queueDocument("ipfs://pair-a-y");
        bytes32 messageBX = _queueDocument("ipfs://pair-b-x");

        s_router.deliverAs(messageAX, sourceA, senderX);
        s_router.deliverAs(messageBY, sourceB, senderY);

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.UntrustedRemote.selector, sourceA, senderY));
        s_router.deliverAs(messageAY, sourceA, senderY);

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.UntrustedRemote.selector, sourceB, senderX));
        s_router.deliverAs(messageBX, sourceB, senderX);

        assertTrue(s_receiverA.isTrustedRemote(sourceA, senderX));
        assertTrue(s_receiverA.isTrustedRemote(sourceB, senderY));
        assertFalse(s_receiverA.isTrustedRemote(sourceA, senderY));
        assertFalse(s_receiverA.isTrustedRemote(sourceB, senderX));
    }

    function test_configureTrustedRemoteEmitsEventAndCanRevokePair() external {
        uint64 sourceChainSelector = 101;
        address remoteSender = makeAddr("remote-sender");

        vm.expectEmit(true, true, false, true);
        emit EtherdocReceiver.TrustedRemoteConfigured(sourceChainSelector, remoteSender, true);
        s_receiverA.configureTrustedRemote(sourceChainSelector, remoteSender, true);
        assertTrue(s_receiverA.isTrustedRemote(sourceChainSelector, remoteSender));

        vm.expectEmit(true, true, false, true);
        emit EtherdocReceiver.TrustedRemoteConfigured(sourceChainSelector, remoteSender, false);
        s_receiverA.configureTrustedRemote(sourceChainSelector, remoteSender, false);
        assertFalse(s_receiverA.isTrustedRemote(sourceChainSelector, remoteSender));
    }

    function test_configureTrustedRemoteRejectsInvalidPair() external {
        uint64 sourceChainSelector = s_router.SOURCE_CHAIN_SELECTOR();

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidSourceChainSelector.selector, uint64(0)));
        s_receiverA.configureTrustedRemote(0, address(s_sender), true);

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidRemoteSender.selector, address(0)));
        s_receiverA.configureTrustedRemote(sourceChainSelector, address(0), true);
    }

    function _allowReceiver(EtherdocReceiver _receiver) private {
        _receiver.configureTrustedRemote(s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender), true);
    }

    function _queueDocument(string memory _documentCID) private returns (bytes32 messageId) {
        bytes32 documentId = s_sender.registerDocument(_documentCID);
        return s_sender.dispatchDocument(documentId, DESTINATION_A);
    }

    function _deliverPayload(bytes32 _messageId, EtherdocTypes.DocumentPayload memory _payload) private {
        s_router.deliverRaw(
            address(s_receiverA), _messageId, s_sourceChainSelector, address(s_sender), abi.encode(_payload)
        );
    }
}
