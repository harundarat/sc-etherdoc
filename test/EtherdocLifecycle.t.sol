// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {DeferredRouter} from "./mocks/DeferredRouter.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

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
        s_sourceChainSelector = s_router.SOURCE_CHAIN_SELECTOR();
        s_receiverA = new EtherdocReceiver(
            address(s_router), address(this), address(this), s_sourceChainSelector, block.chainid, address(0xDEAD)
        );
        s_receiverB = new EtherdocReceiver(
            address(s_router), address(this), address(this), s_sourceChainSelector, block.chainid, address(0xDEAD)
        );

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
        assertEq(payload.schemaVersion, 3);
        assertEq(uint8(payload.operation), uint8(EtherdocTypes.Operation.REGISTER));
        assertEq(payload.contentDigest, DOCUMENT_DIGEST);
        assertEq(payload.cidCodec, 0x55);
        assertEq(payload.cidDigest, DOCUMENT_DIGEST);
        assertEq(payload.version, 1);
        assertEq(EtherdocTypes.documentFromPayload(payload).documentId, s_documentId);
        assertEq(EtherdocTypes.documentFromPayload(payload).documentCID, DOCUMENT_CID);
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

        s_receiverA.setTrustedSender(address(s_sender));
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

    function test_receiverPauserCannotUnpauseOrChangeTrustedSender() external {
        address pauser = makeAddr("receiver-pauser");
        s_receiverA.setPauser(pauser, true);

        vm.prank(pauser);
        s_receiverA.pauseReceive();

        vm.prank(pauser);
        vm.expectRevert(bytes("Only callable by owner"));
        s_receiverA.unpauseReceive();

        vm.prank(pauser);
        vm.expectRevert(bytes("Only callable by owner"));
        s_receiverA.setTrustedSender(address(s_sender));

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

        EtherdocReceiver.ProcessedMessage memory activeMessage = s_receiverA.getProcessedMessage(activeMessageId);
        assertEq(activeMessage.documentId, s_documentId);
        assertEq(activeMessage.documentVersion, 1);
        assertTrue(activeMessage.processed);

        vm.expectEmit(true, true, false, true);
        emit EtherdocReceiver.MessageIgnored(activeMessageId, s_documentId, 1, 2, true);
        s_router.deliver(activeMessageId);
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
        bytes memory oversizedPayload = new bytes(s_receiverA.PAYLOAD_LENGTH() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadLength.selector, oversizedPayload.length, s_receiverA.PAYLOAD_LENGTH()
            )
        );
        s_router.deliverRaw(address(s_receiverA), messageId, s_sourceChainSelector, address(s_sender), oversizedPayload);

        assertFalse(s_receiverA.isMessageProcessed(messageId));
    }

    function test_receiverRejectsEnvelopeWithMismatchedOperationAndVersion() external {
        _allowReceiver(s_receiverA);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocTypes.DocumentPayload memory payload =
            EtherdocTypes.payloadFor(document, EtherdocTypes.Operation.REGISTER);
        payload.version = document.version + 1;

        bytes32 operationMessageId = keccak256("invalid-operation");
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadOperation.selector,
                EtherdocTypes.Operation.REGISTER,
                EtherdocTypes.DocumentStatus.ACTIVE
            )
        );
        _deliverPayload(operationMessageId, payload);
        assertFalse(s_receiverA.isMessageProcessed(operationMessageId));

        payload.version = document.version;
        payload.operation = EtherdocTypes.Operation.REVOKE;
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadOperation.selector,
                EtherdocTypes.Operation.REVOKE,
                EtherdocTypes.DocumentStatus.ACTIVE
            )
        );
        _deliverPayload(operationMessageId, payload);
        assertFalse(s_receiverA.isMessageProcessed(operationMessageId));
    }

    function test_receiverRejectsUnsupportedSchemaAndCIDCodec() external {
        _allowReceiver(s_receiverA);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);
        EtherdocTypes.DocumentPayload memory payload =
            EtherdocTypes.payloadFor(document, EtherdocTypes.Operation.REGISTER);
        payload.schemaVersion = 4;

        bytes32 schemaMessageId = keccak256("invalid-schema");
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidPayloadSchema.selector, uint16(4)));
        _deliverPayload(schemaMessageId, payload);

        payload.schemaVersion = 3;
        payload.cidCodec = 0x71;
        bytes32 unsupportedCodecMessageId = keccak256("unsupported-cid-codec");
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.UnsupportedCIDCodec.selector, uint8(0x71)));
        _deliverPayload(unsupportedCodecMessageId, payload);

        payload.cidCodec = 0x55;
        payload.cidDigest = sha256("conflicting CID metadata");
        bytes32 metadataMessageId = keccak256("raw-cid-digest-mismatch");
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.RawCIDContentDigestMismatch.selector, payload.contentDigest, payload.cidDigest
            )
        );
        _deliverPayload(metadataMessageId, payload);

        assertFalse(s_receiverA.isMessageProcessed(schemaMessageId));
        assertFalse(s_receiverA.isMessageProcessed(unsupportedCodecMessageId));
        assertFalse(s_receiverA.isMessageProcessed(metadataMessageId));
    }

    function test_receiverRejectsAnyNonCanonicalSelectorOrSender() external {
        _allowReceiver(s_receiverA);
        bytes32 wrongSelectorMessage = _queueDocument("wrong-selector");
        bytes32 wrongSenderMessage = _queueDocument("wrong-sender");
        uint64 wrongSelector = s_sourceChainSelector + 1;
        address wrongSender = makeAddr("wrong-sender");

        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.UntrustedRemote.selector, wrongSelector, address(s_sender))
        );
        s_router.deliverAs(wrongSelectorMessage, wrongSelector, address(s_sender));

        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.UntrustedRemote.selector, s_sourceChainSelector, wrongSender)
        );
        s_router.deliverAs(wrongSenderMessage, s_sourceChainSelector, wrongSender);

        assertTrue(s_receiverA.isTrustedRemote(s_sourceChainSelector, address(s_sender)));
        assertFalse(s_receiverA.isTrustedRemote(wrongSelector, address(s_sender)));
        assertFalse(s_receiverA.isTrustedRemote(s_sourceChainSelector, wrongSender));
    }

    function test_setTrustedSenderRotatesWithinImmutableSourceChain() external {
        address previousSender = s_receiverA.getTrustedSender();
        address remoteSender = makeAddr("rotated-sender");
        vm.expectEmit(true, true, false, true);
        emit EtherdocReceiver.TrustedSenderUpdated(previousSender, remoteSender);
        s_receiverA.setTrustedSender(remoteSender);

        assertEq(s_receiverA.getSourceChainSelector(), s_sourceChainSelector);
        assertEq(s_receiverA.getSourceChainId(), block.chainid);
        assertEq(s_receiverA.getTrustedSender(), remoteSender);
        assertTrue(s_receiverA.isTrustedRemote(s_sourceChainSelector, remoteSender));
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidRemoteSender.selector, address(0)));
        s_receiverA.setTrustedSender(address(0));
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
        _receiver.setTrustedSender(address(s_sender));
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
