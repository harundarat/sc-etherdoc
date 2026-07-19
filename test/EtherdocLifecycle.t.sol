// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract DeferredRouter is IRouterClient {
    enum ExecutionState {
        UNTOUCHED,
        SUCCESS,
        FAILURE
    }

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
    mapping(bytes32 messageId => ExecutionState state) private s_executionStates;
    mapping(bytes32 messageId => bytes returnData) private s_executionReturnData;

    event ExecutionAttempted(bytes32 indexed messageId, ExecutionState state, bytes returnData);

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

    function execute(bytes32 _messageId) external returns (bool success, bytes memory returnData) {
        QueuedMessage storage queuedMessage = s_messages[_messageId];
        require(queuedMessage.exists, "message not queued");

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(queuedMessage.sender),
            data: queuedMessage.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        (success, returnData) =
            queuedMessage.receiver.call(abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
        ExecutionState state = success ? ExecutionState.SUCCESS : ExecutionState.FAILURE;
        s_executionStates[_messageId] = state;
        s_executionReturnData[_messageId] = returnData;
        emit ExecutionAttempted(_messageId, state, returnData);
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

    function getExecutionState(bytes32 _messageId) external view returns (ExecutionState) {
        return s_executionStates[_messageId];
    }

    function getExecutionReturnData(bytes32 _messageId) external view returns (bytes memory) {
        return s_executionReturnData[_messageId];
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
    bytes32 private constant DOCUMENT_DIGEST = 0xf31168c67a1482e74cb97ec041650a193c18a4bb0847d656aa70707e72cd4e9d;
    string private constant DOCUMENT_CID = "bafkreihtcfumm6quqltuzol6ybawkcqzhqmkjoyii7lfnktqob7hftkotu";

    DeferredRouter private s_router;
    MockLinkToken private s_link;
    EtherdocSender private s_sender;
    EtherdocReceiver private s_receiverA;
    EtherdocReceiver private s_receiverB;
    bytes32 private s_documentId;
    uint64 private s_sourceChainSelector;

    function setUp() public {
        s_router = new DeferredRouter();
        s_link = new MockLinkToken();
        s_sender = new EtherdocSender(
            address(s_router), address(s_link), address(this), address(this), address(this), address(this)
        );
        s_receiverA = new EtherdocReceiver(address(s_router), address(this), address(this));
        s_receiverB = new EtherdocReceiver(address(s_router), address(this), address(this));
        s_sourceChainSelector = s_router.SOURCE_CHAIN_SELECTOR();

        assertTrue(s_link.transfer(address(s_sender), 100 ether));
        s_sender.configureRemote(DESTINATION_A, address(s_receiverA), 500_000, true);
        s_sender.configureRemote(DESTINATION_B, address(s_receiverB), 500_000, true);
        s_documentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID);
    }

    function test_pendingDispatchIsNotReportedAsReceived() external {
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());

        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocSender.DispatchRecord memory dispatch = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocTypes.DocumentPayload memory payload =
            abi.decode(s_router.getData(messageId), (EtherdocTypes.DocumentPayload));
        EtherdocReceiver.ReceiptRecord memory receipt = s_receiverA.getReceipt(s_documentId);

        assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(dispatch.messageId, messageId);
        assertEq(uint8(dispatch.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(payload.schemaVersion, 2);
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
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        bytes memory authenticationError = abi.encodeWithSelector(
            EtherdocReceiver.UntrustedRemote.selector, s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender)
        );

        vm.expectEmit(true, false, false, true);
        emit DeferredRouter.ExecutionAttempted(messageId, DeferredRouter.ExecutionState.FAILURE, authenticationError);
        (bool firstAttemptSucceeded, bytes memory returnData) = s_router.execute(messageId);

        EtherdocSender.DispatchRecord memory dispatch = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocReceiver.ReceiptRecord memory failedReceipt = s_receiverA.getReceipt(s_documentId);
        assertFalse(firstAttemptSucceeded);
        assertEq(returnData, authenticationError);
        assertEq(uint8(s_router.getExecutionState(messageId)), uint8(DeferredRouter.ExecutionState.FAILURE));
        assertEq(s_router.getExecutionReturnData(messageId), authenticationError);
        assertEq(dispatch.messageId, messageId);
        assertEq(uint8(dispatch.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(uint8(failedReceipt.status), uint8(EtherdocReceiver.ReceiptStatus.NOT_RECEIVED));
        assertFalse(s_receiverA.isMessageProcessed(messageId));

        s_receiverA.configureTrustedRemote(s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender), true);
        vm.warp(block.timestamp + 15);
        vm.expectEmit(true, false, false, true);
        emit DeferredRouter.ExecutionAttempted(messageId, DeferredRouter.ExecutionState.SUCCESS, "");
        (bool retrySucceeded, bytes memory retryReturnData) = s_router.execute(messageId);

        EtherdocReceiver.ReceiptRecord memory retriedReceipt = s_receiverA.getReceipt(s_documentId);
        assertTrue(retrySucceeded);
        assertEq(retryReturnData, "");
        assertEq(uint8(s_router.getExecutionState(messageId)), uint8(DeferredRouter.ExecutionState.SUCCESS));
        assertEq(s_router.getExecutionReturnData(messageId), "");
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

    function test_pausedReceiveFailsSafelyAndSameMessageCanRetryAfterGovernanceUnpause() external {
        _allowReceiver(s_receiverA);
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());

        s_receiverA.pauseReceive();
        assertTrue(s_receiverA.receivePaused());

        (bool pausedAttemptSucceeded, bytes memory pausedReturnData) = s_router.execute(messageId);
        assertFalse(pausedAttemptSucceeded);
        assertEq(pausedReturnData, abi.encodeWithSelector(EtherdocReceiver.ReceiveIsPaused.selector));
        assertFalse(s_receiverA.isMessageProcessed(messageId));
        assertFalse(s_receiverA.isDocumentReceived(s_documentId));

        s_receiverA.unpauseReceive();
        assertFalse(s_receiverA.receivePaused());

        (bool retrySucceeded,) = s_router.execute(messageId);
        assertTrue(retrySucceeded);
        assertTrue(s_receiverA.isMessageProcessed(messageId));
        assertTrue(s_receiverA.isDocumentReceived(s_documentId));
    }

    function test_receiverPauserCannotUnpauseOrChangeTrustedRemote() external {
        address pauser = makeAddr("receiver-pauser");
        s_receiverA.setPauser(pauser, true);

        vm.prank(pauser);
        s_receiverA.pauseReceive();

        vm.prank(pauser);
        vm.expectRevert(bytes("Only callable by owner"));
        s_receiverA.unpauseReceive();

        vm.prank(pauser);
        vm.expectRevert(bytes("Only callable by owner"));
        s_receiverA.configureTrustedRemote(s_sourceChainSelector, address(s_sender), true);

        s_receiverA.unpauseReceive();
    }

    function test_workflowIsCompleteOnlyAfterEveryDestinationHasReceipt() external {
        _allowReceiver(s_receiverA);
        _allowReceiver(s_receiverB);

        bytes32 messageIdA = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        bytes32 messageIdB = s_sender.dispatchDocument(s_documentId, DESTINATION_B, s_router.FEE());

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

        bytes32 activeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        s_router.deliver(activeMessageId);
        assertTrue(s_receiverA.isDocumentActive(s_documentId));

        s_sender.revokeDocument(s_documentId);
        EtherdocTypes.DocumentRecord memory sourceDocument = s_sender.getDocument(s_documentId);
        assertEq(uint8(sourceDocument.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        assertEq(sourceDocument.version, 2);
        assertEq(sourceDocument.documentCID, DOCUMENT_CID);

        bytes32 revokedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
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
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
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
        bytes32 activeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        s_sender.revokeDocument(s_documentId);
        bytes32 revokedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());

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
        bytes32 replacementId = s_sender.supersedeDocument(
            s_documentId,
            CIDTestHelper.digestFor("lifecycle-replacement"),
            CIDTestHelper.rawCIDFor("lifecycle-replacement"),
            bytes32(uint256(123))
        );

        bytes32 supersedeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        bytes32 replacementMessageId = s_sender.dispatchDocument(replacementId, DESTINATION_A, s_router.FEE());
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
            schemaVersion: 2,
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

    function test_receiverRejectsUnsupportedSchemaAndMalformedCID() external {
        _allowReceiver(s_receiverA);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocTypes.DocumentPayload memory payload = EtherdocTypes.DocumentPayload({
            schemaVersion: 3,
            operation: EtherdocTypes.Operation.REGISTER,
            documentId: document.documentId,
            documentVersion: document.version,
            document: document
        });

        bytes32 schemaMessageId = keccak256("invalid-schema");
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidPayloadSchema.selector, uint16(3), uint16(2)));
        _deliverPayload(schemaMessageId, payload);

        payload.schemaVersion = 2;
        payload.document.documentCID = "";
        bytes32 emptyCIDMessageId = keccak256("empty-cid");
        vm.expectRevert(EtherdocReceiver.InvalidDocumentCID.selector);
        _deliverPayload(emptyCIDMessageId, payload);

        payload.document.documentCID = DOCUMENT_CID;
        payload.document.cidDigest = sha256("conflicting CID metadata");
        bytes32 metadataMessageId = keccak256("invalid-cid-metadata");
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.InvalidCIDMetadata.selector, payload.document.documentId)
        );
        _deliverPayload(metadataMessageId, payload);

        assertFalse(s_receiverA.isMessageProcessed(schemaMessageId));
        assertFalse(s_receiverA.isMessageProcessed(emptyCIDMessageId));
        assertFalse(s_receiverA.isMessageProcessed(metadataMessageId));
    }

    function test_trustedRemotePairsDoNotAllowCrossProduct() external {
        uint64 sourceA = 101;
        uint64 sourceB = 202;
        address senderX = makeAddr("sender-x");
        address senderY = makeAddr("sender-y");

        s_receiverA.configureTrustedRemote(sourceA, senderX, true);
        s_receiverA.configureTrustedRemote(sourceB, senderY, true);

        bytes32 messageAX = _queueDocument("pair-a-x");
        bytes32 messageBY = _queueDocument("pair-b-y");
        bytes32 messageAY = _queueDocument("pair-a-y");
        bytes32 messageBX = _queueDocument("pair-b-x");

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

    function test_receiverSupportsV1V2AndERC165Interfaces() external view {
        assertTrue(s_receiverA.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(s_receiverA.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
        assertTrue(s_receiverA.supportsInterface(type(IERC165).interfaceId));
        assertFalse(s_receiverA.supportsInterface(bytes4(0xffffffff)));
    }

    function test_receiverUsesDefaultCCVAndRequiresFullFinality() external view {
        (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        ) = s_receiverA.getCCVsAndFinalityConfig(s_sourceChainSelector, abi.encode(address(s_sender)));

        assertEq(requiredCCVs.length, 0);
        assertEq(optionalCCVs.length, 0);
        assertEq(optionalThreshold, 0);
        assertEq(allowedFinalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
    }

    function _allowReceiver(EtherdocReceiver _receiver) private {
        _receiver.configureTrustedRemote(s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender), true);
    }

    function _queueDocument(string memory _content) private returns (bytes32 messageId) {
        bytes32 documentId =
            s_sender.registerDocument(CIDTestHelper.digestFor(_content), CIDTestHelper.rawCIDFor(_content));
        return s_sender.dispatchDocument(documentId, DESTINATION_A, s_router.FEE());
    }

    function _deliverPayload(bytes32 _messageId, EtherdocTypes.DocumentPayload memory _payload) private {
        s_router.deliverRaw(
            address(s_receiverA), _messageId, s_sourceChainSelector, address(s_sender), abi.encode(_payload)
        );
    }
}
