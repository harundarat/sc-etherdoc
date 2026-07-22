// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {EtherdocGovernance} from "../src/EtherdocGovernance.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {DeferredRouter} from "./mocks/DeferredRouter.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract EtherdocNegativeTest is Test {
    uint64 private constant DESTINATION = 11;
    uint32 private constant GAS_LIMIT = 500_000;
    address private constant RECEIVER = address(0xA11CE);

    MockRouter private s_router;
    MockLinkToken private s_link;
    EtherdocSender private s_sender;

    function setUp() public {
        vm.warp(1_000_000);
        s_router = new MockRouter();
        s_link = new MockLinkToken();
        s_sender = new EtherdocSender(
            address(s_router), address(s_link), address(this), address(this), address(this), address(this)
        );
        s_sender.configureRemote(DESTINATION, RECEIVER, GAS_LIMIT, true);
        assertTrue(s_link.transfer(address(s_sender), 100 ether));
    }

    function test_constructorsRejectInvalidGovernanceAndInitialRoles() external {
        vm.expectRevert(EtherdocGovernance.InvalidGovernanceAddress.selector);
        new EtherdocSender(address(s_router), address(s_link), address(0), address(this), address(this), address(this));

        vm.expectRevert(EtherdocSender.InvalidIssuerAddress.selector);
        new EtherdocSender(address(s_router), address(s_link), address(this), address(0), address(this), address(this));

        vm.expectRevert(EtherdocGovernance.InvalidRoleAccount.selector);
        new EtherdocSender(address(s_router), address(s_link), address(this), address(this), address(0), address(this));

        vm.expectRevert(EtherdocGovernance.InvalidRoleAccount.selector);
        new EtherdocSender(address(s_router), address(s_link), address(this), address(this), address(this), address(0));

        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(0)));
        new EtherdocReceiver(address(0), address(this), address(this), 99, block.chainid, address(s_sender));

        vm.expectRevert(EtherdocGovernance.InvalidGovernanceAddress.selector);
        new EtherdocReceiver(address(s_router), address(0), address(this), 99, block.chainid, address(s_sender));

        vm.expectRevert(EtherdocGovernance.InvalidRoleAccount.selector);
        new EtherdocReceiver(address(s_router), address(this), address(0), 99, block.chainid, address(s_sender));

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidSourceChainSelector.selector, uint64(0)));
        new EtherdocReceiver(address(s_router), address(this), address(this), 0, block.chainid, address(s_sender));

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidSourceChainId.selector, uint256(0)));
        new EtherdocReceiver(address(s_router), address(this), address(this), 99, 0, address(s_sender));

        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidRemoteSender.selector, address(0)));
        new EtherdocReceiver(address(s_router), address(this), address(this), 99, block.chainid, address(0));
    }

    function test_senderConstructorRejectsInvalidRouterAndLinkDependencies() external {
        address routerWithoutCode = makeAddr("router-without-code");
        address linkWithoutCode = makeAddr("link-without-code");

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.InvalidRouter.selector, address(0)));
        new EtherdocSender(address(0), address(s_link), address(this), address(this), address(this), address(this));

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.InvalidRouter.selector, routerWithoutCode));
        new EtherdocSender(
            routerWithoutCode, address(s_link), address(this), address(this), address(this), address(this)
        );

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.InvalidLinkToken.selector, address(0)));
        new EtherdocSender(address(s_router), address(0), address(this), address(this), address(this), address(this));

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.InvalidLinkToken.selector, linkWithoutCode));
        new EtherdocSender(
            address(s_router), linkWithoutCode, address(this), address(this), address(this), address(this)
        );
    }

    function test_receiverConstructorRejectsRouterWithoutCode() external {
        address routerWithoutCode = makeAddr("receiver-router-without-code");

        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, routerWithoutCode));
        new EtherdocReceiver(routerWithoutCode, address(this), address(this), 99, block.chainid, address(s_sender));
    }

    function test_constructorsAcceptDeployedDependencies() external {
        EtherdocSender sender = new EtherdocSender(
            address(s_router), address(s_link), address(this), address(this), address(this), address(this)
        );
        EtherdocReceiver receiver =
            new EtherdocReceiver(address(s_router), address(this), address(this), 99, block.chainid, address(s_sender));

        assertEq(sender.getRouter(), address(s_router));
        assertEq(sender.getFeeToken(), address(s_link));
        assertEq(receiver.getRouter(), address(s_router));
    }

    function test_onlyGovernanceCanUseEverySenderAdminFunction() external {
        address attacker = makeAddr("attacker");
        bytes memory onlyOwner = bytes("Only callable by owner");

        vm.startPrank(attacker);
        vm.expectRevert(onlyOwner);
        s_sender.configureRemote(22, RECEIVER, GAS_LIMIT, true);
        vm.expectRevert(onlyOwner);
        s_sender.setIssuerAuthorization(attacker, true);
        vm.expectRevert(onlyOwner);
        s_sender.setOperator(attacker, true);
        vm.expectRevert(onlyOwner);
        s_sender.setPauser(attacker, true);
        vm.expectRevert(onlyOwner);
        s_sender.unpauseRegistration();
        vm.expectRevert(onlyOwner);
        s_sender.unpauseDispatch();
        vm.expectRevert(onlyOwner);
        s_sender.withdrawToken(address(s_link), attacker, 1);
        vm.stopPrank();
    }

    function test_onlyGovernanceCanUseEveryReceiverAdminFunction() external {
        DeferredRouter router = new DeferredRouter();
        EtherdocReceiver receiver = new EtherdocReceiver(
            address(router),
            address(this),
            address(this),
            router.SOURCE_CHAIN_SELECTOR(),
            block.chainid,
            address(s_sender)
        );
        address attacker = makeAddr("attacker");
        bytes memory onlyOwner = bytes("Only callable by owner");
        vm.startPrank(attacker);
        vm.expectRevert(onlyOwner);
        receiver.setTrustedSender(attacker);
        vm.expectRevert(onlyOwner);
        receiver.setPauser(attacker, true);
        vm.expectRevert(onlyOwner);
        receiver.unpauseReceive();
        vm.stopPrank();
    }

    function test_onlyPauserCanPauseAndGovernanceCanRevokeRoles() external {
        address pauser = makeAddr("pauser");
        bytes32 pauserRole = s_sender.PAUSER_ROLE();

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(EtherdocGovernance.UnauthorizedRole.selector, pauserRole, pauser));
        s_sender.pauseRegistration();

        s_sender.setPauser(pauser, true);
        assertTrue(s_sender.hasRole(pauserRole, pauser));
        s_sender.setPauser(pauser, false);
        assertFalse(s_sender.hasRole(pauserRole, pauser));

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(EtherdocGovernance.UnauthorizedRole.selector, pauserRole, pauser));
        s_sender.pauseDispatch();
    }

    function test_adminSettersRejectZeroAndExposeIssuerAuthorization() external {
        address issuer = makeAddr("issuer");
        assertFalse(s_sender.isIssuerAuthorized(issuer));

        vm.expectEmit(true, false, false, true);
        emit EtherdocSender.IssuerAuthorizationUpdated(issuer, true);
        s_sender.setIssuerAuthorization(issuer, true);
        assertTrue(s_sender.isIssuerAuthorized(issuer));

        s_sender.setIssuerAuthorization(issuer, false);
        assertFalse(s_sender.isIssuerAuthorized(issuer));

        vm.expectRevert(EtherdocSender.InvalidIssuerAddress.selector);
        s_sender.setIssuerAuthorization(address(0), true);
    }

    function test_pauseFunctionsRejectRepeatedStateChanges() external {
        s_sender.pauseRegistration();
        vm.expectRevert(EtherdocSender.RegistrationIsPaused.selector);
        s_sender.pauseRegistration();
        s_sender.unpauseRegistration();
        vm.expectRevert(EtherdocSender.RegistrationNotPaused.selector);
        s_sender.unpauseRegistration();

        s_sender.pauseDispatch();
        vm.expectRevert(EtherdocSender.DispatchIsPaused.selector);
        s_sender.pauseDispatch();
        s_sender.unpauseDispatch();
        vm.expectRevert(EtherdocSender.DispatchNotPaused.selector);
        s_sender.unpauseDispatch();

        DeferredRouter router = new DeferredRouter();
        EtherdocReceiver receiver = new EtherdocReceiver(
            address(router),
            address(this),
            address(this),
            router.SOURCE_CHAIN_SELECTOR(),
            block.chainid,
            address(s_sender)
        );
        receiver.pauseReceive();
        vm.expectRevert(EtherdocReceiver.ReceiveIsPaused.selector);
        receiver.pauseReceive();
        receiver.unpauseReceive();
        vm.expectRevert(EtherdocReceiver.ReceiveNotPaused.selector);
        receiver.unpauseReceive();
    }

    function test_documentIssuerChecksMissingWrongCallerAndInactiveRecords() external {
        bytes32 missingDocumentId = keccak256("missing");
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentNotRegistered.selector, missingDocumentId));
        s_sender.revokeDocument(missingDocumentId);

        bytes32 documentId = _register("issuer-checks");
        address attacker = makeAddr("attacker");
        bytes32 replacementDigest = CIDTestHelper.digestFor("replacement");
        string memory replacementCID = CIDTestHelper.rawCIDFor("replacement");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocSender.CallerNotDocumentIssuer.selector, attacker, address(this))
        );
        s_sender.revokeDocument(documentId);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocSender.CallerNotDocumentIssuer.selector, attacker, address(this))
        );
        s_sender.supersedeDocument(documentId, replacementDigest, replacementCID, bytes32(0));

        s_sender.revokeDocument(documentId);
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentNotActive.selector, documentId));
        s_sender.revokeDocument(documentId);
    }

    function test_dispatchAndQuoteRejectMissingOrDisabledConfiguration() external {
        bytes32 missingDocumentId = keccak256("missing");
        uint256 fee = s_router.FEE();
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentNotRegistered.selector, missingDocumentId));
        s_sender.dispatchDocument(missingDocumentId, DESTINATION, fee);

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentNotRegistered.selector, missingDocumentId));
        s_sender.quoteFee(missingDocumentId, DESTINATION);

        bytes32 documentId = _register("disabled-quote");
        s_sender.configureRemote(DESTINATION, RECEIVER, GAS_LIMIT, false);
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DestinationChainNotAllowlisted.selector, DESTINATION));
        s_sender.quoteFee(documentId, DESTINATION);
    }

    function test_routerQuoteFailureBubblesFromQuoteAndDispatchWithoutRecording() external {
        bytes32 documentId = _register("quote-failure");
        s_router.setQuoteFailure(DESTINATION, true);
        bytes memory errorData = abi.encodeWithSelector(MockRouter.SimulatedQuoteFailure.selector, DESTINATION);

        vm.expectRevert(errorData);
        s_sender.quoteFee(documentId, DESTINATION);
        vm.expectRevert(errorData);
        s_sender.dispatchDocument(documentId, DESTINATION, type(uint256).max);

        assertEq(
            uint8(s_sender.getDispatch(documentId, DESTINATION).status),
            uint8(EtherdocSender.DispatchStatus.NOT_DISPATCHED)
        );
    }

    function test_dispatchRejectsZeroRouterMessageIdWithoutRecordingOrApproval() external {
        bytes32 documentId = _register("zero-message-id");
        uint256 balanceBefore = s_link.balanceOf(address(s_sender));
        uint256 fee = s_router.FEE();
        s_router.setReturnZeroMessageId(true);

        vm.expectRevert(EtherdocSender.InvalidOutboundMessageId.selector);
        s_sender.dispatchDocument(documentId, DESTINATION, fee);

        assertEq(s_link.balanceOf(address(s_sender)), balanceBefore);
        assertEq(s_link.allowance(address(s_sender), address(s_router)), 0);
        assertEq(
            uint8(s_sender.getDispatch(documentId, DESTINATION).status),
            uint8(EtherdocSender.DispatchStatus.NOT_DISPATCHED)
        );
    }

    function test_documentLifecycleEventsExposeIndexedDocumentIdAndCompleteFields() external {
        bytes32 digest = CIDTestHelper.digestFor("event-document");
        string memory documentCID = CIDTestHelper.rawCIDFor("event-document");
        bytes32 metadataCommitment = keccak256("metadata");
        bytes32 documentId = s_sender.computeDocumentId(address(this), digest);

        vm.expectEmit(true, true, true, true);
        emit EtherdocSender.DocumentRegistered(
            documentId,
            digest,
            address(this),
            documentCID,
            0x55,
            digest,
            metadataCommitment,
            block.chainid,
            uint64(block.timestamp),
            3
        );
        s_sender.registerDocument(digest, documentCID, metadataCommitment);

        vm.expectEmit(false, true, true, true);
        emit EtherdocSender.MessageSent(
            bytes32(0),
            documentId,
            DESTINATION,
            RECEIVER,
            documentCID,
            1,
            EtherdocTypes.DocumentStatus.ACTIVE,
            GAS_LIMIT,
            address(s_link),
            s_router.FEE()
        );
        bytes32 messageId = s_sender.dispatchDocument(documentId, DESTINATION, s_router.FEE());
        assertNotEq(messageId, bytes32(0));

        vm.expectEmit(true, true, false, true);
        emit EtherdocSender.DocumentStatusChanged(
            documentId, address(this), EtherdocTypes.DocumentStatus.REVOKED, 2, bytes32(0), uint64(block.timestamp)
        );
        s_sender.revokeDocument(documentId);
    }

    function _register(string memory _content) private returns (bytes32) {
        return s_sender.registerDocument(CIDTestHelper.digestFor(_content), CIDTestHelper.rawCIDFor(_content));
    }
}

contract EtherdocReceiverNegativeTest is Test {
    uint64 private constant SOURCE_SELECTOR = 99;

    DeferredRouter private s_router;
    EtherdocReceiver private s_receiver;
    address private s_remoteSender;
    EtherdocTypes.DocumentRecord private s_document;

    function setUp() public {
        vm.warp(1_000_000);
        s_router = new DeferredRouter();
        s_remoteSender = makeAddr("remote-sender");
        s_receiver = new EtherdocReceiver(
            address(s_router), address(this), address(this), SOURCE_SELECTOR, 5_003, s_remoteSender
        );
        s_document = _validDocument("receiver-negative");
    }

    function test_onlyRouterCanDeliverMessages() external {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("direct-call"),
            sourceChainSelector: SOURCE_SELECTOR,
            sender: abi.encode(s_remoteSender),
            data: abi.encode(_payload(s_document, EtherdocTypes.Operation.REGISTER)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(this)));
        s_receiver.ccipReceive(message);
    }

    function test_rejectsZeroMessageIdMalformedSenderAndUntrustedPair() external {
        bytes memory data = abi.encode(_payload(s_document, EtherdocTypes.Operation.REGISTER));

        vm.expectRevert(EtherdocReceiver.InvalidMessageId.selector);
        s_router.deliverRaw(address(s_receiver), bytes32(0), SOURCE_SELECTOR, s_remoteSender, data);

        bytes32 malformedSenderMessage = keccak256("malformed-sender");
        bytes memory malformedSender = new bytes(31);
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidSenderEncoding.selector, malformedSender.length));
        s_router.deliverRawSender(address(s_receiver), malformedSenderMessage, SOURCE_SELECTOR, malformedSender, data);

        address untrustedSender = makeAddr("untrusted");
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.UntrustedRemote.selector, SOURCE_SELECTOR, untrustedSender)
        );
        s_router.deliverRaw(address(s_receiver), keccak256("untrusted"), SOURCE_SELECTOR, untrustedSender, data);
    }

    function test_rejectsEmptyAndMalformedAbiPayloadWithoutMarkingMessage() external {
        bytes32 emptyMessageId = keccak256("empty");
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.InvalidPayloadLength.selector, 0, s_receiver.PAYLOAD_LENGTH())
        );
        s_router.deliverRaw(address(s_receiver), emptyMessageId, SOURCE_SELECTOR, s_remoteSender, "");

        bytes32 malformedMessageId = keccak256("malformed");
        bytes memory truncatedPayload = new bytes(s_receiver.PAYLOAD_LENGTH() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadLength.selector, truncatedPayload.length, s_receiver.PAYLOAD_LENGTH()
            )
        );
        s_router.deliverRaw(address(s_receiver), malformedMessageId, SOURCE_SELECTOR, s_remoteSender, truncatedPayload);

        assertFalse(s_receiver.isMessageProcessed(emptyMessageId));
        assertFalse(s_receiver.isMessageProcessed(malformedMessageId));
    }

    function test_rejectsEveryOperationShapeMismatch() external {
        EtherdocTypes.DocumentRecord memory document = s_document;

        document.version = 2;
        _expectPayloadError(
            keccak256("register-version"),
            _payload(document, EtherdocTypes.Operation.REGISTER),
            EtherdocTypes.Operation.REGISTER,
            EtherdocTypes.DocumentStatus.ACTIVE
        );

        document = s_document;
        document.status = EtherdocTypes.DocumentStatus.REVOKED;
        document.version = 1;
        _expectPayloadError(
            keccak256("revoke-version"),
            _payload(document, EtherdocTypes.Operation.REVOKE),
            EtherdocTypes.Operation.REVOKE,
            EtherdocTypes.DocumentStatus.REVOKED
        );

        document = s_document;
        document.status = EtherdocTypes.DocumentStatus.SUPERSEDED;
        document.version = 2;
        _expectPayloadError(
            keccak256("supersede-link"),
            _payload(document, EtherdocTypes.Operation.SUPERSEDE),
            EtherdocTypes.Operation.SUPERSEDE,
            EtherdocTypes.DocumentStatus.SUPERSEDED
        );

        document = s_document;
        document.status = EtherdocTypes.DocumentStatus.UNKNOWN;
        _expectPayloadError(
            keccak256("unknown-operation"),
            _payload(document, EtherdocTypes.Operation.UNKNOWN),
            EtherdocTypes.Operation.UNKNOWN,
            EtherdocTypes.DocumentStatus.UNKNOWN
        );
    }

    function test_rejectsInvalidDocumentIntegrityAndCommitmentFields() external {
        EtherdocTypes.DocumentRecord memory document = s_document;
        document.contentDigest = bytes32(0);
        bytes32 zeroContentDocumentId = _documentId(document.issuer, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidContentDigest.selector, zeroContentDocumentId));
        _deliver(keccak256("zero-content"), document, EtherdocTypes.Operation.REGISTER);

        document = s_document;
        document.cidCodec = 0x71;
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.UnsupportedCIDCodec.selector, uint8(0x71)));
        _deliver(keccak256("wrong-codec"), document, EtherdocTypes.Operation.REGISTER);

        document = s_document;
        document.contentDigest = sha256("different-file");
        document.documentId = _documentId(document.issuer, document.contentDigest);
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.RawCIDContentDigestMismatch.selector, document.contentDigest, document.cidDigest
            )
        );
        _deliver(keccak256("raw-mismatch"), document, EtherdocTypes.Operation.REGISTER);

        document = s_document;
        document.issuer = address(0);
        bytes32 zeroIssuerDocumentId = _documentId(address(0), document.contentDigest);
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.InvalidDocumentCommitment.selector, zeroIssuerDocumentId)
        );
        _deliver(keccak256("zero-issuer"), document, EtherdocTypes.Operation.REGISTER);
    }

    function test_rejectsInvalidDocumentVersionAndTimestamps() external {
        EtherdocTypes.DocumentRecord memory document = s_document;
        document.sourceChainId = 0;
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.UnexpectedSourceChainId.selector, 5_003, 0));
        _deliver(keccak256("zero-source-chain"), document, EtherdocTypes.Operation.REGISTER);

        document = s_document;
        document.registeredAt = 0;
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidDocumentVersion.selector, document.documentId));
        _deliver(keccak256("zero-registration-time"), document, EtherdocTypes.Operation.REGISTER);

        document = s_document;
        document.updatedAt = document.registeredAt - 1;
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidDocumentVersion.selector, document.documentId));
        _deliver(keccak256("backwards-time"), document, EtherdocTypes.Operation.REGISTER);
    }

    function test_rejectsConflictingProvenanceAndStateForSameDocumentVersion() external {
        _deliver(keccak256("first"), s_document, EtherdocTypes.Operation.REGISTER);

        EtherdocTypes.DocumentRecord memory conflict = s_document;
        conflict.metadataCommitment = keccak256("conflicting-metadata");
        vm.expectRevert(
            abi.encodeWithSelector(EtherdocReceiver.ConflictingDocumentProvenance.selector, conflict.documentId)
        );
        _deliver(keccak256("provenance-conflict"), conflict, EtherdocTypes.Operation.REGISTER);

        conflict = s_document;
        conflict.updatedAt++;
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.ConflictingDocumentState.selector, conflict.documentId, conflict.version
            )
        );
        _deliver(keccak256("state-conflict"), conflict, EtherdocTypes.Operation.REGISTER);

        EtherdocTypes.DocumentRecord memory superseded = _validDocument("superseded-state");
        superseded.version = 2;
        superseded.status = EtherdocTypes.DocumentStatus.SUPERSEDED;
        superseded.supersededBy = keccak256("replacement-a");
        _deliver(keccak256("superseded"), superseded, EtherdocTypes.Operation.SUPERSEDE);

        superseded.supersededBy = keccak256("replacement-b");
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.ConflictingDocumentState.selector, superseded.documentId, superseded.version
            )
        );
        _deliver(keccak256("superseded-link-conflict"), superseded, EtherdocTypes.Operation.SUPERSEDE);
    }

    function test_rejectsUnsupportedFutureLifecycleVersion() external {
        _deliver(keccak256("active"), s_document, EtherdocTypes.Operation.REGISTER);

        EtherdocTypes.DocumentRecord memory futureDocument = s_document;
        futureDocument.version = 3;
        futureDocument.status = EtherdocTypes.DocumentStatus.REVOKED;
        futureDocument.updatedAt++;
        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadOperation.selector,
                EtherdocTypes.Operation.REVOKE,
                EtherdocTypes.DocumentStatus.REVOKED
            )
        );
        _deliver(keccak256("invalid-revoke-version"), futureDocument, EtherdocTypes.Operation.REVOKE);
    }

    function test_receiverEventAndVerificationExposeCompleteDeliveryEvidence() external {
        bytes32 messageId = keccak256("observable-receipt");
        vm.expectEmit(true, true, true, true);
        emit EtherdocReceiver.MessageReceived(
            messageId,
            s_document.documentId,
            SOURCE_SELECTOR,
            s_remoteSender,
            s_document.issuer,
            1,
            EtherdocTypes.Operation.REGISTER,
            EtherdocTypes.DocumentStatus.ACTIVE,
            uint64(block.timestamp)
        );
        _deliver(messageId, s_document, EtherdocTypes.Operation.REGISTER);

        (EtherdocTypes.DocumentRecord memory document, bool integrityMatches, bool isActive) =
            s_receiver.verifyDocument(s_document.documentId, s_document.contentDigest);
        assertEq(document.documentId, s_document.documentId);
        assertTrue(integrityMatches);
        assertTrue(isActive);

        (, bool wrongIntegrity,) = s_receiver.verifyDocument(s_document.documentId, sha256("tampered"));
        assertFalse(wrongIntegrity);
    }

    function _expectPayloadError(
        bytes32 _messageId,
        EtherdocTypes.DocumentPayload memory _payloadData,
        EtherdocTypes.Operation _operation,
        EtherdocTypes.DocumentStatus _status
    ) private {
        vm.expectRevert(abi.encodeWithSelector(EtherdocReceiver.InvalidPayloadOperation.selector, _operation, _status));
        s_router.deliverRaw(address(s_receiver), _messageId, SOURCE_SELECTOR, s_remoteSender, abi.encode(_payloadData));
    }

    function _deliver(
        bytes32 _messageId,
        EtherdocTypes.DocumentRecord memory _document,
        EtherdocTypes.Operation _operation
    ) private {
        s_router.deliverRaw(
            address(s_receiver),
            _messageId,
            SOURCE_SELECTOR,
            s_remoteSender,
            abi.encode(_payload(_document, _operation))
        );
    }

    function _payload(EtherdocTypes.DocumentRecord memory _document, EtherdocTypes.Operation _operation)
        private
        pure
        returns (EtherdocTypes.DocumentPayload memory)
    {
        return EtherdocTypes.payloadFor(_document, _operation);
    }

    function _validDocument(string memory _content) private returns (EtherdocTypes.DocumentRecord memory) {
        bytes32 contentDigest = CIDTestHelper.digestFor(_content);
        address issuer = makeAddr("issuer");
        return EtherdocTypes.DocumentRecord({
            documentId: _documentId(issuer, contentDigest),
            contentDigest: contentDigest,
            metadataCommitment: bytes32(0),
            documentCID: CIDTestHelper.rawCIDFor(_content),
            cidCodec: 0x55,
            cidDigest: contentDigest,
            issuer: issuer,
            sourceChainId: 5_003,
            registeredAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            version: 1,
            schemaVersion: 3,
            status: EtherdocTypes.DocumentStatus.ACTIVE,
            supersedes: bytes32(0),
            supersededBy: bytes32(0)
        });
    }

    function _documentId(address _issuer, bytes32 _digest) private pure returns (bytes32) {
        return keccak256(abi.encode(_issuer, _digest));
    }
}
