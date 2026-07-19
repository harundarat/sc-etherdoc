// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {DeferredRouter} from "./mocks/DeferredRouter.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract EtherdocDeliveryHandler {
    DeferredRouter public immutable router;
    EtherdocReceiver public immutable receiver;
    bytes32 public immutable documentId;
    bytes32 public immutable activeMessageId;
    bytes32 public immutable revokedMessageId;

    bool public monotonic = true;
    uint64 public lastObservedVersion;
    EtherdocTypes.DocumentStatus public lastObservedStatus;
    uint256 public deliveryFailures;
    uint256 public calls;

    constructor(
        DeferredRouter _router,
        EtherdocReceiver _receiver,
        bytes32 _documentId,
        bytes32 _activeMessageId,
        bytes32 _revokedMessageId
    ) {
        router = _router;
        receiver = _receiver;
        documentId = _documentId;
        activeMessageId = _activeMessageId;
        revokedMessageId = _revokedMessageId;
    }

    function deliverActive() external {
        _deliver(activeMessageId);
    }

    function deliverRevoked() external {
        _deliver(revokedMessageId);
    }

    function replayActive() external {
        _deliver(activeMessageId);
    }

    function replayRevoked() external {
        _deliver(revokedMessageId);
    }

    function _deliver(bytes32 _messageId) private {
        calls++;
        try router.deliver(_messageId) {
            _observeReceipt();
        } catch {
            deliveryFailures++;
        }
    }

    function _observeReceipt() private {
        EtherdocTypes.DocumentRecord memory document = receiver.getReceipt(documentId).document;
        if (document.version < lastObservedVersion) {
            monotonic = false;
        }
        if (document.version == lastObservedVersion && document.status != lastObservedStatus) {
            monotonic = false;
        }
        lastObservedVersion = document.version;
        lastObservedStatus = document.status;
    }
}

contract EtherdocInvariantTest is StdInvariant, Test {
    uint64 private constant DESTINATION = 11;

    DeferredRouter private s_router;
    EtherdocSender private s_sender;
    EtherdocReceiver private s_receiver;
    EtherdocDeliveryHandler private s_handler;
    bytes32 private s_documentId;
    bytes32 private s_activeMessageId;
    bytes32 private s_revokedMessageId;

    function setUp() public {
        vm.warp(1_000_000);
        s_router = new DeferredRouter();
        MockLinkToken link = new MockLinkToken();
        s_sender = new EtherdocSender(
            address(s_router), address(link), address(this), address(this), address(this), address(this)
        );
        s_receiver = new EtherdocReceiver(address(s_router), address(this), address(this));
        assertTrue(link.transfer(address(s_sender), 100 ether));
        s_sender.configureRemote(DESTINATION, address(s_receiver), 500_000, true);
        s_receiver.configureTrustedRemote(s_router.SOURCE_CHAIN_SELECTOR(), address(s_sender), true);

        s_documentId = s_sender.registerDocument(
            CIDTestHelper.digestFor("invariant-document"), CIDTestHelper.rawCIDFor("invariant-document")
        );
        s_activeMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION, s_router.FEE());
        s_sender.revokeDocument(s_documentId);
        s_revokedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION, s_router.FEE());

        s_handler =
            new EtherdocDeliveryHandler(s_router, s_receiver, s_documentId, s_activeMessageId, s_revokedMessageId);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = EtherdocDeliveryHandler.deliverActive.selector;
        selectors[1] = EtherdocDeliveryHandler.deliverRevoked.selector;
        selectors[2] = EtherdocDeliveryHandler.replayActive.selector;
        selectors[3] = EtherdocDeliveryHandler.replayRevoked.selector;
        targetSelector(FuzzSelector({addr: address(s_handler), selectors: selectors}));
        targetContract(address(s_handler));
    }

    function invariant_receiverVersionAndStatusNeverMoveBackward() external view {
        assertTrue(s_handler.monotonic());
        assertEq(s_handler.deliveryFailures(), 0);

        EtherdocTypes.DocumentRecord memory document = s_receiver.getReceipt(s_documentId).document;
        assertLe(document.version, 2);
        if (document.version == 0) {
            assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.UNKNOWN));
        } else if (document.version == 1) {
            assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        } else {
            assertEq(document.version, 2);
            assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        }
    }

    function invariant_sourceLifecycleRemainsTerminalAndDispatchesRemainImmutable() external view {
        EtherdocTypes.DocumentRecord memory sourceDocument = s_sender.getDocument(s_documentId);
        assertEq(sourceDocument.version, 2);
        assertEq(uint8(sourceDocument.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        assertEq(s_sender.getDispatchAtVersion(s_documentId, DESTINATION, 1).messageId, s_activeMessageId);
        assertEq(s_sender.getDispatchAtVersion(s_documentId, DESTINATION, 2).messageId, s_revokedMessageId);
    }

    function invariant_processedMessagesAlwaysResolveToCanonicalDocument() external view {
        if (s_receiver.isMessageProcessed(s_activeMessageId)) {
            assertEq(s_receiver.getMessageDocument(s_activeMessageId), s_documentId);
        }
        if (s_receiver.isMessageProcessed(s_revokedMessageId)) {
            assertEq(s_receiver.getMessageDocument(s_revokedMessageId), s_documentId);
        }
    }
}
