// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract EtherdocProvenanceTest is Test {
    uint256 private constant ISSUER_PRIVATE_KEY = 0xA11CE;
    uint256 private constant UNAUTHORIZED_ISSUER_PRIVATE_KEY = 0xBAD;
    bytes32 private constant DOCUMENT_DIGEST = 0x96d815328a42cb4ef89d5e0b7a1df6be43b484832c83a7b4596d8402c7c0b12b;
    string private constant DOCUMENT_CID = "bafkreiew3aktfcscznhprhk6bn5b35v6io2ijazmqot3iwlnqqbmpqfrfm";
    bytes32 private constant METADATA_COMMITMENT = keccak256("private metadata");

    EtherdocSender private s_sender;
    address private s_issuer;
    address private s_unauthorizedIssuer;

    function setUp() public {
        MockRouter router = new MockRouter();
        MockLinkToken link = new MockLinkToken();
        s_sender = new EtherdocSender(
            address(router), address(link), address(this), address(this), address(this), address(this)
        );
        s_issuer = vm.addr(ISSUER_PRIVATE_KEY);
        s_unauthorizedIssuer = vm.addr(UNAUTHORIZED_ISSUER_PRIVATE_KEY);
    }

    function test_rejectsUnauthorizedIssuer() external {
        vm.prank(s_unauthorizedIssuer);
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.IssuerNotAuthorized.selector, s_unauthorizedIssuer));
        s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT);
    }

    function test_relayerPreservesIssuerProvenanceAndRejectsSignatureReplay() external {
        s_sender.setIssuerAuthorization(s_issuer, true);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegistration(ISSUER_PRIVATE_KEY, s_issuer, 0, deadline);
        address relayer = address(0xBEEF);

        vm.prank(relayer);
        bytes32 documentId = s_sender.registerDocumentBySig(
            DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT, s_issuer, deadline, signature
        );

        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(documentId);
        assertEq(document.documentId, documentId);
        assertEq(document.contentDigest, DOCUMENT_DIGEST);
        assertEq(document.cidCodec, 0x55);
        assertEq(document.cidDigest, DOCUMENT_DIGEST);
        assertEq(document.metadataCommitment, METADATA_COMMITMENT);
        assertEq(document.issuer, s_issuer);
        assertNotEq(document.issuer, relayer);
        assertEq(document.sourceChainId, block.chainid);
        assertEq(document.registeredAt, block.timestamp);
        assertEq(document.updatedAt, block.timestamp);
        assertEq(document.version, 1);
        assertEq(document.schemaVersion, 3);
        assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(s_sender.issuerNonce(s_issuer), 1);

        vm.prank(relayer);
        vm.expectPartialRevert(EtherdocSender.InvalidIssuerSignature.selector);
        s_sender.registerDocumentBySig(
            DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT, s_issuer, deadline, signature
        );
        assertEq(s_sender.issuerNonce(s_issuer), 1);
    }

    function test_rejectsSignatureFromIssuerOutsideTrustRegistry() external {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegistration(UNAUTHORIZED_ISSUER_PRIVATE_KEY, s_unauthorizedIssuer, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.IssuerNotAuthorized.selector, s_unauthorizedIssuer));
        s_sender.registerDocumentBySig(
            DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT, s_unauthorizedIssuer, deadline, signature
        );
        assertEq(s_sender.issuerNonce(s_unauthorizedIssuer), 0);
    }

    function test_rejectsExpiredIssuerSignature() external {
        s_sender.setIssuerAuthorization(s_issuer, true);
        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _signRegistration(ISSUER_PRIVATE_KEY, s_issuer, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.SignatureExpired.selector, deadline));
        s_sender.registerDocumentBySig(
            DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT, s_issuer, deadline, signature
        );
        assertEq(s_sender.issuerNonce(s_issuer), 0);
    }

    function test_registrationSignatureBindsCIDMetadata() external {
        s_sender.setIssuerAuthorization(s_issuer, true);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signRegistration(ISSUER_PRIVATE_KEY, s_issuer, 0, deadline);
        string memory substitutedCID = CIDTestHelper.cidForDigest(0x70, sha256("substituted dag root"));

        vm.expectPartialRevert(EtherdocSender.InvalidIssuerSignature.selector);
        s_sender.registerDocumentBySig(
            DOCUMENT_DIGEST, substitutedCID, METADATA_COMMITMENT, s_issuer, deadline, signature
        );
        assertEq(s_sender.issuerNonce(s_issuer), 0);
    }

    function test_relayerCanRevokeWithFreshIssuerSignature() external {
        s_sender.setIssuerAuthorization(s_issuer, true);
        vm.prank(s_issuer);
        bytes32 documentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = s_sender.getRevokeDocumentDigest(s_issuer, documentId, 1, 0, deadline);
        bytes memory signature = _sign(ISSUER_PRIVATE_KEY, digest);

        vm.prank(address(0xBEEF));
        s_sender.revokeDocumentBySig(documentId, s_issuer, deadline, signature);

        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(documentId);
        assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.REVOKED));
        assertEq(document.version, 2);
        assertEq(document.documentCID, DOCUMENT_CID);
        assertEq(document.issuer, s_issuer);
        assertEq(s_sender.issuerNonce(s_issuer), 1);

        vm.expectPartialRevert(EtherdocSender.InvalidIssuerSignature.selector);
        s_sender.revokeDocumentBySig(documentId, s_issuer, deadline, signature);
    }

    function test_supersessionLinksRecordsAndKeepsOldHistory() external {
        s_sender.setIssuerAuthorization(s_issuer, true);
        vm.startPrank(s_issuer);
        bytes32 oldDocumentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT);
        vm.warp(block.timestamp + 1 hours);
        bytes32 replacementDigest = CIDTestHelper.digestFor("replacement");
        string memory replacementCID = CIDTestHelper.rawCIDFor("replacement");
        bytes32 newDocumentId =
            s_sender.supersedeDocument(oldDocumentId, replacementDigest, replacementCID, bytes32(uint256(123)));
        vm.stopPrank();

        EtherdocTypes.DocumentRecord memory oldDocument = s_sender.getDocument(oldDocumentId);
        EtherdocTypes.DocumentRecord memory newDocument = s_sender.getDocument(newDocumentId);

        assertEq(oldDocument.documentCID, DOCUMENT_CID);
        assertEq(oldDocument.issuer, s_issuer);
        assertEq(oldDocument.version, 2);
        assertEq(uint8(oldDocument.status), uint8(EtherdocTypes.DocumentStatus.SUPERSEDED));
        assertEq(oldDocument.supersededBy, newDocumentId);
        assertEq(newDocument.supersedes, oldDocumentId);
        assertEq(newDocument.issuer, s_issuer);
        assertEq(newDocument.version, 1);
        assertEq(uint8(newDocument.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertFalse(s_sender.isDocumentActive(oldDocumentId));
        assertTrue(s_sender.isDocumentActive(newDocumentId));

        vm.prank(s_issuer);
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentNotActive.selector, oldDocumentId));
        s_sender.revokeDocument(oldDocumentId);
    }

    function test_relayerCanSupersedeWithFreshIssuerSignature() external {
        s_sender.setIssuerAuthorization(s_issuer, true);
        vm.prank(s_issuer);
        bytes32 oldDocumentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT);

        bytes32 replacementDigest = CIDTestHelper.digestFor("signed-replacement");
        string memory replacementCID = CIDTestHelper.rawCIDFor("signed-replacement");
        bytes32 newDocumentId = s_sender.computeDocumentId(s_issuer, replacementDigest);
        bytes32 replacementMetadata = keccak256("replacement metadata");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                s_sender.SUPERSEDE_DOCUMENT_TYPEHASH(),
                s_issuer,
                oldDocumentId,
                uint64(1),
                newDocumentId,
                replacementDigest,
                uint8(0x55),
                replacementDigest,
                replacementMetadata,
                uint256(0),
                deadline
            )
        );
        bytes memory signature = _sign(ISSUER_PRIVATE_KEY, _toEtherdocTypedDataHash(structHash));

        vm.prank(address(0xBEEF));
        bytes32 returnedDocumentId = s_sender.supersedeDocumentBySig(
            oldDocumentId, replacementDigest, replacementCID, replacementMetadata, s_issuer, deadline, signature
        );

        EtherdocTypes.DocumentRecord memory oldDocument = s_sender.getDocument(oldDocumentId);
        EtherdocTypes.DocumentRecord memory newDocument = s_sender.getDocument(newDocumentId);
        assertEq(returnedDocumentId, newDocumentId);
        assertEq(uint8(oldDocument.status), uint8(EtherdocTypes.DocumentStatus.SUPERSEDED));
        assertEq(oldDocument.version, 2);
        assertEq(oldDocument.supersededBy, newDocumentId);
        assertEq(newDocument.supersedes, oldDocumentId);
        assertEq(newDocument.issuer, s_issuer);
        assertEq(s_sender.issuerNonce(s_issuer), 1);

        vm.expectPartialRevert(EtherdocSender.InvalidIssuerSignature.selector);
        s_sender.supersedeDocumentBySig(
            oldDocumentId, replacementDigest, replacementCID, replacementMetadata, s_issuer, deadline, signature
        );
    }

    function test_verificationSeparatesIntegrityFromValidity() external {
        bytes32 documentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT);

        (EtherdocTypes.DocumentRecord memory activeRecord, bool integrityMatches, bool isActive) =
            s_sender.verifyDocument(documentId, DOCUMENT_DIGEST);
        assertEq(activeRecord.issuer, address(this));
        assertTrue(integrityMatches);
        assertTrue(isActive);

        (, bool wrongIntegrity,) = s_sender.verifyDocument(documentId, sha256("tampered"));
        assertFalse(wrongIntegrity);

        s_sender.revokeDocument(documentId);
        (, bool retainedIntegrity, bool remainsActive) = s_sender.verifyDocument(documentId, DOCUMENT_DIGEST);
        assertTrue(retainedIntegrity);
        assertFalse(remainsActive);
    }

    function _signRegistration(uint256 _privateKey, address _issuer, uint256 _nonce, uint256 _deadline)
        private
        view
        returns (bytes memory)
    {
        bytes32 digest = s_sender.getRegisterDocumentDigest(
            _issuer, DOCUMENT_DIGEST, DOCUMENT_CID, METADATA_COMMITMENT, _nonce, _deadline
        );
        return _sign(_privateKey, digest);
    }

    function _sign(uint256 _privateKey, bytes32 _digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, _digest);
        return abi.encodePacked(r, s, v);
    }

    function _toEtherdocTypedDataHash(bytes32 _structHash) private view returns (bytes32) {
        bytes32 domainTypeHash =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(
            abi.encode(domainTypeHash, keccak256("Etherdoc"), keccak256("2"), block.chainid, address(s_sender))
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, _structHash));
    }
}
