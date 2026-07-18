// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {LinkToken} from "@chainlink/local/src/shared/LinkToken.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";

contract MockRouter is IRouterClient {
    error SimulatedLaneFailure(uint64 destinationChainSelector);

    uint256 public constant FEE = 1 ether;
    uint256 private s_nonce;
    mapping(uint64 destinationChainSelector => bool shouldFail) private s_failingLanes;

    function setLaneFailure(uint64 _destinationChainSelector, bool _shouldFail) external {
        s_failingLanes[_destinationChainSelector] = _shouldFail;
    }

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
        if (s_failingLanes[_destinationChainSelector]) {
            revert SimulatedLaneFailure(_destinationChainSelector);
        }

        s_nonce++;
        return keccak256(abi.encode(_destinationChainSelector, _message.receiver, _message.data, s_nonce));
    }
}

contract EtherdocSenderTest is Test {
    uint64 private constant DESTINATION_A = 11;
    uint64 private constant DESTINATION_B = 22;
    address private constant RECEIVER_A = address(0xA11CE);
    address private constant RECEIVER_B = address(0xB0B);
    string private constant DOCUMENT_CID = "ipfs://bafy-document";

    MockRouter private s_router;
    LinkToken private s_link;
    EtherdocSender private s_sender;
    bytes32 private s_documentId;

    function setUp() public {
        s_router = new MockRouter();
        s_link = new LinkToken();
        s_sender = new EtherdocSender(address(s_router), address(s_link));

        assertTrue(s_link.transfer(address(s_sender), 100 ether));
        s_sender.configureDestinationChain(DESTINATION_A, RECEIVER_A, true);
        s_sender.configureDestinationChain(DESTINATION_B, RECEIVER_B, true);
        s_documentId = s_sender.registerDocument(DOCUMENT_CID);
    }

    function test_registersCanonicalDocumentOnce() external {
        EtherdocSender.DocumentRecord memory document = s_sender.getDocument(s_documentId);

        assertEq(s_documentId, keccak256(bytes(DOCUMENT_CID)));
        assertEq(document.documentCID, DOCUMENT_CID);
        assertEq(document.registeredAt, block.timestamp);
        assertEq(uint8(document.status), uint8(EtherdocSender.DocumentStatus.REGISTERED));

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentAlreadyRegistered.selector, s_documentId));
        s_sender.registerDocument(DOCUMENT_CID);
    }

    function test_dispatchesOneDocumentToTwoDestinationChains() external {
        bytes32 messageIdA = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        bytes32 messageIdB = s_sender.dispatchDocument(s_documentId, DESTINATION_B);

        EtherdocSender.DispatchRecord memory dispatchA = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocSender.DispatchRecord memory dispatchB = s_sender.getDispatch(s_documentId, DESTINATION_B);

        assertNotEq(messageIdA, bytes32(0));
        assertNotEq(messageIdB, bytes32(0));
        assertNotEq(messageIdA, messageIdB);
        assertEq(dispatchA.messageId, messageIdA);
        assertEq(dispatchA.destinationChainSelector, DESTINATION_A);
        assertEq(dispatchA.receiver, RECEIVER_A);
        assertEq(dispatchA.sentAt, block.timestamp);
        assertEq(uint8(dispatchA.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(dispatchB.messageId, messageIdB);
        assertEq(dispatchB.destinationChainSelector, DESTINATION_B);
        assertEq(dispatchB.receiver, RECEIVER_B);
        assertEq(dispatchB.sentAt, block.timestamp);
        assertEq(uint8(dispatchB.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
    }

    function test_rejectsDuplicateLaneButAllowsAnotherLane() external {
        s_sender.dispatchDocument(s_documentId, DESTINATION_A);

        vm.expectRevert(
            abi.encodeWithSelector(EtherdocSender.DocumentAlreadyDispatched.selector, s_documentId, DESTINATION_A)
        );
        s_sender.dispatchDocument(s_documentId, DESTINATION_A);

        bytes32 messageIdB = s_sender.dispatchDocument(s_documentId, DESTINATION_B);
        assertNotEq(messageIdB, bytes32(0));
    }

    function test_failedLaneDoesNotEraseSuccessfulLaneAndCanBeRetried() external {
        bytes32 messageIdA = s_sender.dispatchDocument(s_documentId, DESTINATION_A);
        s_router.setLaneFailure(DESTINATION_B, true);

        vm.expectRevert(abi.encodeWithSelector(MockRouter.SimulatedLaneFailure.selector, DESTINATION_B));
        s_sender.dispatchDocument(s_documentId, DESTINATION_B);

        EtherdocSender.DispatchRecord memory dispatchA = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocSender.DispatchRecord memory failedDispatch = s_sender.getDispatch(s_documentId, DESTINATION_B);

        assertEq(dispatchA.messageId, messageIdA);
        assertEq(uint8(dispatchA.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(failedDispatch.messageId, bytes32(0));
        assertEq(uint8(failedDispatch.status), uint8(EtherdocSender.DispatchStatus.NOT_DISPATCHED));

        s_router.setLaneFailure(DESTINATION_B, false);
        bytes32 retriedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_B);

        EtherdocSender.DispatchRecord memory retriedDispatch = s_sender.getDispatch(s_documentId, DESTINATION_B);
        assertEq(retriedDispatch.messageId, retriedMessageId);
        assertEq(uint8(retriedDispatch.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
    }
}
