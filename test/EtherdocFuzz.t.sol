// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {DeferredRouter} from "./mocks/DeferredRouter.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract EtherdocFuzzTest is Test {
    uint256 private constant CURVE_ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint64 private constant DESTINATION = 11;
    uint64 private constant SOURCE_SELECTOR = 99;
    address private constant RECEIVER = address(0xA11CE);
    address private constant REMOTE_SENDER = address(0xBEEF);

    MockRouter private s_router;
    MockLinkToken private s_link;
    EtherdocSender private s_sender;
    DeferredRouter private s_deferredRouter;
    EtherdocReceiver private s_receiver;

    function setUp() public {
        vm.warp(1_000_000);
        s_router = new MockRouter();
        s_link = new MockLinkToken();
        s_sender = new EtherdocSender(
            address(s_router), address(s_link), address(this), address(this), address(this), address(this)
        );
        assertTrue(s_link.transfer(address(s_sender), 1_000 ether));
        s_sender.configureRemote(DESTINATION, RECEIVER, 500_000, true);

        s_deferredRouter = new DeferredRouter();
        s_receiver = new EtherdocReceiver(address(s_deferredRouter), address(this), address(this));
        s_receiver.configureTrustedRemote(SOURCE_SELECTOR, REMOTE_SENDER, true);
    }

    function testFuzz_registersAnyNonzeroRawDigest(bytes32 _contentDigest, bytes32 _metadataCommitment) external {
        vm.assume(_contentDigest != bytes32(0));
        string memory documentCID = CIDTestHelper.cidForDigest(0x55, _contentDigest);

        bytes32 documentId = s_sender.registerDocument(_contentDigest, documentCID, _metadataCommitment);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(documentId);

        assertEq(documentId, keccak256(abi.encode(address(this), _contentDigest)));
        assertEq(document.contentDigest, _contentDigest);
        assertEq(document.cidDigest, _contentDigest);
        assertEq(document.metadataCommitment, _metadataCommitment);
        assertEq(document.documentCID, documentCID);
        assertTrue(s_sender.isDocumentRegistered(documentId));
        assertTrue(s_sender.isDocumentActive(documentId));
    }

    function testFuzz_acceptsDagPbRootIndependentFromFileDigest(bytes32 _contentDigest, bytes32 _dagRootDigest)
        external
    {
        vm.assume(_contentDigest != bytes32(0));
        string memory documentCID = CIDTestHelper.cidForDigest(0x70, _dagRootDigest);

        bytes32 documentId = s_sender.registerDocument(_contentDigest, documentCID);
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(documentId);

        assertEq(document.contentDigest, _contentDigest);
        assertEq(document.cidCodec, 0x70);
        assertEq(document.cidDigest, _dagRootDigest);
    }

    function testFuzz_sameCidFromDistinctIssuersHasDistinctProvenance(
        bytes32 _contentDigest,
        address _issuerA,
        address _issuerB
    ) external {
        vm.assume(_contentDigest != bytes32(0));
        vm.assume(_issuerA != address(0) && _issuerB != address(0) && _issuerA != _issuerB);
        string memory documentCID = CIDTestHelper.cidForDigest(0x55, _contentDigest);
        s_sender.setIssuerAuthorization(_issuerA, true);
        s_sender.setIssuerAuthorization(_issuerB, true);

        vm.prank(_issuerA);
        bytes32 documentA = s_sender.registerDocument(_contentDigest, documentCID);
        vm.prank(_issuerB);
        bytes32 documentB = s_sender.registerDocument(_contentDigest, documentCID);

        assertNotEq(documentA, documentB);
        assertEq(s_sender.getDocument(documentA).issuer, _issuerA);
        assertEq(s_sender.getDocument(documentB).issuer, _issuerB);
    }

    function testFuzz_remoteConfigPreservesFullWidthValues(
        uint64 _selector,
        address _receiver,
        uint32 _gasLimit,
        bool _allowlisted
    ) external {
        vm.assume(_selector != 0 && _receiver != address(0) && _gasLimit != 0);

        s_sender.configureRemote(_selector, _receiver, _gasLimit, _allowlisted);
        EtherdocSender.RemoteConfig memory remote = s_sender.getRemoteConfig(_selector);

        assertEq(remote.receiver, _receiver);
        assertEq(remote.gasLimit, _gasLimit);
        assertEq(remote.allowlisted, _allowlisted);
    }

    function testFuzz_dispatchAcceptsExactFeeCeiling(uint96 _fee, bytes32 _contentDigest) external {
        vm.assume(_contentDigest != bytes32(0));
        uint256 fee = bound(uint256(_fee), 0, 1_000 ether);
        s_router.setFee(fee);
        bytes32 documentId = s_sender.registerDocument(_contentDigest, CIDTestHelper.cidForDigest(0x55, _contentDigest));

        bytes32 messageId = s_sender.dispatchDocument(documentId, DESTINATION, fee);

        assertNotEq(messageId, bytes32(0));
        assertEq(s_sender.getDispatch(documentId, DESTINATION).messageId, messageId);
    }

    function testFuzz_validIssuerSignaturePreservesSigner(
        uint256 _privateKey,
        bytes32 _contentDigest,
        bytes32 _metadataCommitment,
        uint32 _ttl
    ) external {
        vm.assume(_contentDigest != bytes32(0));
        uint256 privateKey = bound(_privateKey, 1, CURVE_ORDER - 1);
        address issuer = vm.addr(privateKey);
        uint256 deadline = block.timestamp + bound(uint256(_ttl), 0, 365 days);
        string memory documentCID = CIDTestHelper.cidForDigest(0x55, _contentDigest);
        s_sender.setIssuerAuthorization(issuer, true);

        bytes32 digest =
            s_sender.getRegisterDocumentDigest(issuer, _contentDigest, documentCID, _metadataCommitment, 0, deadline);
        bytes memory signature = _sign(privateKey, digest);
        vm.prank(makeAddr("relayer"));
        bytes32 documentId = s_sender.registerDocumentBySig(
            _contentDigest, documentCID, _metadataCommitment, issuer, deadline, signature
        );

        assertEq(s_sender.getDocument(documentId).issuer, issuer);
        assertEq(s_sender.issuerNonce(issuer), 1);
    }

    function testFuzz_issuerSignatureRejectsMetadataSubstitution(
        uint256 _privateKey,
        bytes32 _contentDigest,
        bytes32 _signedMetadata
    ) external {
        vm.assume(_contentDigest != bytes32(0));
        uint256 privateKey = bound(_privateKey, 1, CURVE_ORDER - 1);
        address issuer = vm.addr(privateKey);
        uint256 deadline = block.timestamp + 1 days;
        string memory documentCID = CIDTestHelper.cidForDigest(0x55, _contentDigest);
        s_sender.setIssuerAuthorization(issuer, true);

        bytes32 digest =
            s_sender.getRegisterDocumentDigest(issuer, _contentDigest, documentCID, _signedMetadata, 0, deadline);
        bytes memory signature = _sign(privateKey, digest);

        vm.expectPartialRevert(EtherdocSender.InvalidIssuerSignature.selector);
        s_sender.registerDocumentBySig(_contentDigest, documentCID, ~_signedMetadata, issuer, deadline, signature);
        assertEq(s_sender.issuerNonce(issuer), 0);
    }

    function testFuzz_rejectsInvalidBase32Character(bytes32 _contentDigest, uint8 _index) external {
        vm.assume(_contentDigest != bytes32(0));
        bytes memory malformedCID = bytes(CIDTestHelper.cidForDigest(0x55, _contentDigest));
        uint256 index = bound(uint256(_index), 1, malformedCID.length - 1);
        malformedCID[index] = "A";

        vm.expectRevert(EtherdocSender.InvalidDocumentCID.selector);
        s_sender.registerDocument(_contentDigest, string(malformedCID));
    }

    function testFuzz_compactCIDRoundTrips(bool _dagPb, bytes32 _cidDigest) external pure {
        uint8 codec = _dagPb ? 0x70 : 0x55;
        string memory documentCID = EtherdocTypes.encodeCanonicalCID(codec, _cidDigest);
        (bool valid, uint8 decodedCodec, bytes32 decodedDigest) = EtherdocTypes.decodeCanonicalCID(documentCID);

        assertTrue(valid);
        assertEq(decodedCodec, codec);
        assertEq(decodedDigest, _cidDigest);
    }

    function testFuzz_receiverAcceptsBoundedCanonicalPayload(
        bytes32 _messageId,
        bytes32 _contentDigest,
        bytes32 _metadataCommitment,
        address _issuer
    ) external {
        vm.assume(_messageId != bytes32(0) && _contentDigest != bytes32(0) && _issuer != address(0));
        EtherdocTypes.DocumentRecord memory document = _makeDocument(_contentDigest, _metadataCommitment, _issuer);
        bytes memory data = abi.encode(_payload(document));
        assertEq(data.length, s_receiver.PAYLOAD_LENGTH());

        s_deferredRouter.deliverRaw(address(s_receiver), _messageId, SOURCE_SELECTOR, REMOTE_SENDER, data);

        EtherdocReceiver.ReceiptRecord memory receipt = s_receiver.getReceipt(document.documentId);
        assertEq(receipt.messageId, _messageId);
        assertEq(receipt.document.contentDigest, _contentDigest);
        assertEq(receipt.document.metadataCommitment, _metadataCommitment);
        assertEq(receipt.document.issuer, _issuer);
    }

    function testFuzz_receiverRejectsPayloadAboveBound(uint16 _excess) external {
        uint256 excess = bound(uint256(_excess), 1, 4_096);
        bytes memory oversized = new bytes(s_receiver.PAYLOAD_LENGTH() + excess);
        bytes32 messageId = keccak256(abi.encode(_excess));

        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocReceiver.InvalidPayloadLength.selector, oversized.length, s_receiver.PAYLOAD_LENGTH()
            )
        );
        s_deferredRouter.deliverRaw(address(s_receiver), messageId, SOURCE_SELECTOR, REMOTE_SENDER, oversized);
        assertFalse(s_receiver.isMessageProcessed(messageId));
    }

    function testFuzz_dispatchesOneDocumentAcrossIndependentLanes(uint8 _laneCount) external {
        uint256 laneCount = bound(uint256(_laneCount), 2, 8);
        bytes32 contentDigest = CIDTestHelper.digestFor("fuzz-multichain");
        bytes32 documentId = s_sender.registerDocument(contentDigest, CIDTestHelper.rawCIDFor("fuzz-multichain"));

        for (uint256 i; i < laneCount; i++) {
            // laneCount is bounded to eight, so these deterministic test values cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 selector = uint64(1_000 + i);
            // forge-lint: disable-next-line(unsafe-typecast)
            address receiver = address(uint160(10_000 + i));
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 gasLimit = uint32(300_000 + i);
            s_sender.configureRemote(selector, receiver, gasLimit, true);
            bytes32 messageId = s_sender.dispatchDocument(documentId, selector, s_router.FEE());
            EtherdocSender.DispatchRecord memory dispatch = s_sender.getDispatch(documentId, selector);
            assertEq(dispatch.messageId, messageId);
            assertEq(dispatch.receiver, receiver);
            assertEq(dispatch.gasLimit, gasLimit);
        }
    }

    function _makeDocument(bytes32 _contentDigest, bytes32 _metadataCommitment, address _issuer)
        private
        view
        returns (EtherdocTypes.DocumentRecord memory)
    {
        return EtherdocTypes.DocumentRecord({
            documentId: keccak256(abi.encode(_issuer, _contentDigest)),
            contentDigest: _contentDigest,
            metadataCommitment: _metadataCommitment,
            documentCID: CIDTestHelper.cidForDigest(0x55, _contentDigest),
            cidCodec: 0x55,
            cidDigest: _contentDigest,
            issuer: _issuer,
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

    function _payload(EtherdocTypes.DocumentRecord memory _record)
        private
        pure
        returns (EtherdocTypes.DocumentPayload memory)
    {
        return EtherdocTypes.payloadFor(_record, EtherdocTypes.Operation.REGISTER);
    }

    function _sign(uint256 _privateKey, bytes32 _digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, _digest);
        return abi.encodePacked(r, s, v);
    }
}
