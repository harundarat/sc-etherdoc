// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@5.3.0/utils/ReentrancyGuard.sol";
import {EtherdocGovernance} from "../src/EtherdocGovernance.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {ApprovalRestrictedToken} from "./mocks/ApprovalRestrictedToken.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract ExtraArgsCodecHarness {
    function encode(ExtraArgsCodec.GenericExtraArgsV3 memory _extraArgs) external pure returns (bytes memory) {
        return ExtraArgsCodec._encodeGenericExtraArgsV3(_extraArgs);
    }

    function decode(bytes calldata _extraArgs) external pure returns (ExtraArgsCodec.GenericExtraArgsV3 memory) {
        return ExtraArgsCodec._decodeGenericExtraArgsV3(_extraArgs);
    }
}

contract EtherdocSenderTest is Test {
    uint64 private constant DESTINATION_A = 11;
    uint64 private constant DESTINATION_B = 22;
    uint32 private constant GAS_LIMIT_A = 350_000;
    uint32 private constant GAS_LIMIT_B = 600_000;
    address private constant RECEIVER_A = address(0xA11CE);
    address private constant RECEIVER_B = address(0xB0B);
    bytes32 private constant DOCUMENT_DIGEST = 0x43cc23fa52b87b4cc1d02b5b114154151d6adddb17c9fddc06b027fa99e24008;
    string private constant DOCUMENT_CID = "bafkreicdzqr7uuvypngmdubllmiucvavdvvn3wyxzh65ybvqe75jtysaba";

    MockRouter private s_router;
    ExtraArgsCodecHarness private s_extraArgsCodec;
    MockLinkToken private s_link;
    EtherdocSender private s_sender;
    bytes32 private s_documentId;

    function setUp() public {
        s_router = new MockRouter();
        s_extraArgsCodec = new ExtraArgsCodecHarness();
        s_link = new MockLinkToken();
        s_sender = _deploySender(address(s_link));

        assertTrue(s_link.transfer(address(s_sender), 100 ether));
        s_sender.configureRemote(DESTINATION_A, RECEIVER_A, GAS_LIMIT_A, true);
        s_sender.configureRemote(DESTINATION_B, RECEIVER_B, GAS_LIMIT_B, true);
        s_documentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID);
    }

    function test_registersCanonicalDocumentOnce() external {
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(s_documentId);

        assertEq(sha256(bytes("document")), DOCUMENT_DIGEST);
        assertEq(CIDTestHelper.rawCIDFor("document"), DOCUMENT_CID);
        assertEq(s_documentId, s_sender.computeDocumentId(address(this), DOCUMENT_DIGEST));
        assertEq(document.documentId, s_documentId);
        assertEq(document.contentDigest, DOCUMENT_DIGEST);
        assertEq(document.cidCodec, 0x55);
        assertEq(document.cidDigest, DOCUMENT_DIGEST);
        assertEq(document.issuer, address(this));
        assertEq(document.sourceChainId, block.chainid);
        assertEq(document.documentCID, DOCUMENT_CID);
        assertEq(document.registeredAt, block.timestamp);
        assertEq(document.updatedAt, block.timestamp);
        assertEq(document.version, 1);
        assertEq(document.schemaVersion, 2);
        assertEq(uint8(document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DocumentAlreadyRegistered.selector, s_documentId));
        s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID);
    }

    function test_rejectsZeroDigestAndNonCanonicalCID() external {
        vm.expectRevert(EtherdocSender.InvalidContentDigest.selector);
        s_sender.registerDocument(bytes32(0), DOCUMENT_CID);

        vm.expectRevert(EtherdocSender.InvalidDocumentCID.selector);
        s_sender.registerDocument(DOCUMENT_DIGEST, "");

        vm.expectRevert(EtherdocSender.InvalidDocumentCID.selector);
        s_sender.registerDocument(DOCUMENT_DIGEST, "ipfs://bafkreicdzqr7uuvypngmdubllmiucvavdvvn3wyxzh65ybvqe75jtysaba");

        vm.expectRevert(EtherdocSender.InvalidDocumentCID.selector);
        s_sender.registerDocument(DOCUMENT_DIGEST, "BAFKREICDZQR7UUVYPNGM DUBLLMIUCVAVDVVN3WYXZH65YBVQE75JTYSABA");

        vm.expectRevert(EtherdocSender.InvalidDocumentCID.selector);
        s_sender.registerDocument(DOCUMENT_DIGEST, CIDTestHelper.cidForDigest(0x71, DOCUMENT_DIGEST));

        bytes memory nonCanonicalPadding = bytes(DOCUMENT_CID);
        nonCanonicalPadding[nonCanonicalPadding.length - 1] = "b";
        vm.expectRevert(EtherdocSender.InvalidDocumentCID.selector);
        s_sender.registerDocument(DOCUMENT_DIGEST, string(nonCanonicalPadding));
    }

    function test_acceptsCanonicalDagPbCIDWithIndependentRawFileDigest() external {
        bytes32 fileDigest = sha256("dag-pb file bytes");
        bytes32 dagRootDigest = sha256("dag-pb root block");
        string memory dagPbCID = CIDTestHelper.cidForDigest(0x70, dagRootDigest);

        bytes32 documentId = s_sender.registerDocument(fileDigest, dagPbCID);
        bytes32 messageId = s_sender.dispatchDocument(documentId, DESTINATION_A, s_router.FEE());
        EtherdocTypes.DocumentRecord memory document = s_sender.getDocument(documentId);

        assertNotEq(messageId, bytes32(0));
        assertEq(document.contentDigest, fileDigest);
        assertEq(document.cidCodec, 0x70);
        assertEq(document.cidDigest, dagRootDigest);
        assertEq(s_sender.getDispatch(documentId, DESTINATION_A).messageId, messageId);
    }

    function test_rejectsRawCIDWhoseMultihashDoesNotMatchFileDigest() external {
        bytes32 wrongDigest = sha256("different file bytes");

        vm.expectRevert(
            abi.encodeWithSelector(EtherdocSender.RawCIDContentDigestMismatch.selector, wrongDigest, DOCUMENT_DIGEST)
        );
        s_sender.registerDocument(wrongDigest, DOCUMENT_CID);
    }

    function test_dispatchesOneDocumentToTwoDestinationChains() external {
        bytes32 messageIdA = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        bytes32 messageIdB = s_sender.dispatchDocument(s_documentId, DESTINATION_B, s_router.FEE());

        EtherdocSender.DispatchRecord memory dispatchA = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocSender.DispatchRecord memory dispatchB = s_sender.getDispatch(s_documentId, DESTINATION_B);

        assertNotEq(messageIdA, bytes32(0));
        assertNotEq(messageIdB, bytes32(0));
        assertNotEq(messageIdA, messageIdB);
        assertEq(dispatchA.messageId, messageIdA);
        assertEq(dispatchA.destinationChainSelector, DESTINATION_A);
        assertEq(dispatchA.receiver, RECEIVER_A);
        assertEq(dispatchA.sentAt, block.timestamp);
        assertEq(dispatchA.documentVersion, 1);
        assertEq(dispatchA.gasLimit, GAS_LIMIT_A);
        assertEq(uint8(dispatchA.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(dispatchB.messageId, messageIdB);
        assertEq(dispatchB.destinationChainSelector, DESTINATION_B);
        assertEq(dispatchB.receiver, RECEIVER_B);
        assertEq(dispatchB.sentAt, block.timestamp);
        assertEq(dispatchB.documentVersion, 1);
        assertEq(dispatchB.gasLimit, GAS_LIMIT_B);
        assertEq(uint8(dispatchB.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(s_router.lastReceiver(DESTINATION_A), RECEIVER_A);
        assertEq(s_router.lastReceiver(DESTINATION_B), RECEIVER_B);
        assertEq(s_router.lastGasLimit(DESTINATION_A), GAS_LIMIT_A);
        assertEq(s_router.lastGasLimit(DESTINATION_B), GAS_LIMIT_B);
        assertEq(s_router.lastFinalityConfig(DESTINATION_A), FinalityCodec.WAIT_FOR_FINALITY_FLAG);
        assertEq(s_router.lastFinalityConfig(DESTINATION_B), FinalityCodec.WAIT_FOR_FINALITY_FLAG);
        assertEq(s_router.lastCCVCount(DESTINATION_A), 0);
        assertEq(s_router.lastCCVCount(DESTINATION_B), 0);
        assertEq(s_router.lastExecutor(DESTINATION_A), address(0));
        assertEq(s_router.lastExecutor(DESTINATION_B), address(0));
    }

    function test_dispatchRejectsRouterReentryEvenWhenRouterHasOperatorRole() external {
        s_sender.setOperator(address(s_router), true);
        s_router.configureReentry(
            address(s_sender), abi.encodeCall(s_sender.dispatchDocument, (s_documentId, DESTINATION_A, s_router.FEE()))
        );

        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        (bool reentrySucceeded, bytes memory returnData) = s_router.lastReentryResult();

        assertNotEq(messageId, bytes32(0));
        assertFalse(reentrySucceeded);
        assertEq(returnData, abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(s_sender.getDispatch(s_documentId, DESTINATION_A).messageId, messageId);
    }

    function test_onlyOperatorCanDispatch() external {
        address operator = makeAddr("operator");
        uint256 fee = s_router.FEE();
        s_sender.setOperator(operator, true);
        s_sender.setOperator(address(this), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                EtherdocGovernance.UnauthorizedRole.selector, s_sender.OPERATOR_ROLE(), address(this)
            )
        );
        s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);

        vm.prank(operator);
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);
        assertNotEq(messageId, bytes32(0));
    }

    function test_pauserStopsRegistrationButGovernanceControlsRecovery() external {
        address pauser = makeAddr("pauser");
        bytes32 pausedRegistrationDigest = CIDTestHelper.digestFor("paused-registration");
        string memory pausedRegistrationCID = CIDTestHelper.rawCIDFor("paused-registration");
        bytes32 pausedSupersessionDigest = CIDTestHelper.digestFor("paused-supersession");
        string memory pausedSupersessionCID = CIDTestHelper.rawCIDFor("paused-supersession");
        s_sender.setPauser(pauser, true);

        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit EtherdocSender.RegistrationPaused(pauser);
        s_sender.pauseRegistration();
        assertTrue(s_sender.registrationPaused());

        vm.expectRevert(EtherdocSender.RegistrationIsPaused.selector);
        s_sender.registerDocument(pausedRegistrationDigest, pausedRegistrationCID);

        vm.expectRevert(EtherdocSender.RegistrationIsPaused.selector);
        s_sender.supersedeDocument(s_documentId, pausedSupersessionDigest, pausedSupersessionCID, bytes32(0));

        s_sender.revokeDocument(s_documentId);
        assertFalse(s_sender.isDocumentActive(s_documentId));

        vm.prank(pauser);
        vm.expectRevert(bytes("Only callable by owner"));
        s_sender.unpauseRegistration();

        vm.expectEmit(true, false, false, true);
        emit EtherdocSender.RegistrationUnpaused(address(this));
        s_sender.unpauseRegistration();
        assertFalse(s_sender.registrationPaused());
        assertNotEq(
            s_sender.registerDocument(
                CIDTestHelper.digestFor("registration-restored"), CIDTestHelper.rawCIDFor("registration-restored")
            ),
            bytes32(0)
        );
    }

    function test_pauserStopsDispatchButGovernanceControlsRecovery() external {
        address pauser = makeAddr("pauser");
        address operator = makeAddr("operator");
        uint256 fee = s_router.FEE();
        s_sender.setPauser(pauser, true);
        s_sender.setOperator(operator, true);

        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit EtherdocSender.DispatchPaused(pauser);
        s_sender.pauseDispatch();
        assertTrue(s_sender.dispatchPaused());

        vm.prank(operator);
        vm.expectRevert(EtherdocSender.DispatchIsPaused.selector);
        s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);

        vm.prank(pauser);
        vm.expectRevert(bytes("Only callable by owner"));
        s_sender.unpauseDispatch();

        s_sender.unpauseDispatch();
        assertFalse(s_sender.dispatchPaused());

        vm.prank(operator);
        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);
        assertNotEq(messageId, bytes32(0));
    }

    function test_governanceAndOperationalRolesAreExplicitAndOwnershipRemainsTwoStep() external {
        address newGovernance = makeAddr("new-governance");
        address newOperator = makeAddr("new-operator");

        assertEq(s_sender.owner(), address(this));
        assertTrue(s_sender.hasRole(s_sender.OPERATOR_ROLE(), address(this)));
        assertTrue(s_sender.hasRole(s_sender.PAUSER_ROLE(), address(this)));

        s_sender.transferOwnership(newGovernance);
        vm.prank(newGovernance);
        s_sender.acceptOwnership();
        assertEq(s_sender.owner(), newGovernance);

        vm.expectRevert(bytes("Only callable by owner"));
        s_sender.setOperator(newOperator, true);

        vm.prank(newGovernance);
        s_sender.setOperator(newOperator, true);
        assertTrue(s_sender.hasRole(s_sender.OPERATOR_ROLE(), newOperator));
    }

    function test_governanceRejectsZeroRoleAccounts() external {
        vm.expectRevert(EtherdocGovernance.InvalidRoleAccount.selector);
        s_sender.setOperator(address(0), true);

        vm.expectRevert(EtherdocGovernance.InvalidRoleAccount.selector);
        s_sender.setPauser(address(0), true);
    }

    function test_rejectsDuplicateLaneButAllowsAnotherLane() external {
        uint256 fee = s_router.FEE();
        s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);

        vm.expectRevert(
            abi.encodeWithSelector(EtherdocSender.DocumentAlreadyDispatched.selector, s_documentId, DESTINATION_A, 1)
        );
        s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);

        bytes32 messageIdB = s_sender.dispatchDocument(s_documentId, DESTINATION_B, fee);
        assertNotEq(messageIdB, bytes32(0));
    }

    function test_failedLaneDoesNotEraseSuccessfulLaneAndCanBeRetried() external {
        uint256 fee = s_router.FEE();
        bytes32 messageIdA = s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);
        s_router.setLaneFailure(DESTINATION_B, true);

        vm.expectRevert(abi.encodeWithSelector(MockRouter.SimulatedLaneFailure.selector, DESTINATION_B));
        s_sender.dispatchDocument(s_documentId, DESTINATION_B, fee);

        EtherdocSender.DispatchRecord memory dispatchA = s_sender.getDispatch(s_documentId, DESTINATION_A);
        EtherdocSender.DispatchRecord memory failedDispatch = s_sender.getDispatch(s_documentId, DESTINATION_B);

        assertEq(dispatchA.messageId, messageIdA);
        assertEq(uint8(dispatchA.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
        assertEq(failedDispatch.messageId, bytes32(0));
        assertEq(uint8(failedDispatch.status), uint8(EtherdocSender.DispatchStatus.NOT_DISPATCHED));

        s_router.setLaneFailure(DESTINATION_B, false);
        bytes32 retriedMessageId = s_sender.dispatchDocument(s_documentId, DESTINATION_B, fee);

        EtherdocSender.DispatchRecord memory retriedDispatch = s_sender.getDispatch(s_documentId, DESTINATION_B);
        assertEq(retriedDispatch.messageId, retriedMessageId);
        assertEq(uint8(retriedDispatch.status), uint8(EtherdocSender.DispatchStatus.DISPATCHED));
    }

    function test_dispatchCannotOverrideConfiguredReceiver() external {
        address arbitraryReceiver = makeAddr("arbitrary-receiver");
        (bool success,) = address(s_sender)
            .call(
                abi.encodeWithSignature(
                    "dispatchDocument(bytes32,uint64,address)", s_documentId, DESTINATION_A, arbitraryReceiver
                )
            );

        assertFalse(success);

        s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        assertEq(s_router.lastReceiver(DESTINATION_A), RECEIVER_A);
        assertNotEq(s_router.lastReceiver(DESTINATION_A), arbitraryReceiver);
    }

    function test_configureRemoteRotatesReceiverAndGasLimitWithEvent() external {
        address rotatedReceiver = makeAddr("rotated-receiver");
        uint32 rotatedGasLimit = 700_000;

        vm.expectEmit(true, true, false, true);
        emit EtherdocSender.RemoteConfigUpdated(DESTINATION_A, rotatedReceiver, rotatedGasLimit, true);
        s_sender.configureRemote(DESTINATION_A, rotatedReceiver, rotatedGasLimit, true);

        EtherdocSender.RemoteConfig memory remote = s_sender.getRemoteConfig(DESTINATION_A);
        assertEq(remote.receiver, rotatedReceiver);
        assertEq(remote.gasLimit, rotatedGasLimit);
        assertTrue(remote.allowlisted);

        s_sender.dispatchDocument(s_documentId, DESTINATION_A, s_router.FEE());
        assertEq(s_router.lastReceiver(DESTINATION_A), rotatedReceiver);
        assertEq(s_router.lastGasLimit(DESTINATION_A), rotatedGasLimit);
    }

    function test_configureRemoteRejectsInvalidConfig() external {
        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.InvalidDestinationChainSelector.selector, uint64(0)));
        s_sender.configureRemote(0, RECEIVER_A, GAS_LIMIT_A, true);

        vm.expectRevert(EtherdocSender.InvalidReceiverAddress.selector);
        s_sender.configureRemote(DESTINATION_A, address(0), GAS_LIMIT_A, true);

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.InvalidGasLimit.selector, uint256(0)));
        s_sender.configureRemote(DESTINATION_A, RECEIVER_A, 0, true);

        bytes memory overflowCall = abi.encodeWithSelector(
            bytes4(keccak256("configureRemote(uint64,address,uint32,bool)")),
            DESTINATION_A,
            RECEIVER_A,
            uint256(type(uint32).max) + 1,
            true
        );
        (bool success,) = address(s_sender).call(overflowCall);
        assertFalse(success);
    }

    function test_extraArgsV3KnownAnswerRoundTripUsesFullFinalityAndDefaults() external view {
        ExtraArgsCodec.GenericExtraArgsV3 memory expected = ExtraArgsCodec.GenericExtraArgsV3({
            gasLimit: GAS_LIMIT_A,
            requestedFinalityConfig: FinalityCodec.WAIT_FOR_FINALITY_FLAG,
            ccvs: new address[](0),
            ccvArgs: new bytes[](0),
            executor: address(0),
            executorArgs: "",
            tokenReceiver: "",
            tokenArgs: ""
        });

        bytes memory encoded = s_extraArgsCodec.encode(expected);
        assertEq(encoded, hex"a69dd4aa000557300000000000000000000000");

        ExtraArgsCodec.GenericExtraArgsV3 memory decoded = s_extraArgsCodec.decode(encoded);
        assertEq(decoded.gasLimit, GAS_LIMIT_A);
        assertEq(decoded.requestedFinalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
        assertEq(decoded.ccvs.length, 0);
        assertEq(decoded.ccvArgs.length, 0);
        assertEq(decoded.executor, address(0));
        assertEq(decoded.executorArgs.length, 0);
        assertEq(decoded.tokenReceiver.length, 0);
        assertEq(decoded.tokenArgs.length, 0);
    }

    function test_dispatchRejectsDisabledRemote() external {
        uint256 fee = s_router.FEE();
        s_sender.configureRemote(DESTINATION_A, RECEIVER_A, GAS_LIMIT_A, false);

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.DestinationChainNotAllowlisted.selector, DESTINATION_A));
        s_sender.dispatchDocument(s_documentId, DESTINATION_A, fee);
    }

    function test_quoteFeeAndMaximumProtectAgainstFeeIncrease() external {
        uint256 quotedFee = s_sender.quoteFee(s_documentId, DESTINATION_A);
        assertEq(quotedFee, s_router.FEE());

        uint256 increasedFee = quotedFee + 0.25 ether;
        s_router.setFee(increasedFee);

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.FeeExceedsMaximum.selector, increasedFee, quotedFee));
        s_sender.dispatchDocument(s_documentId, DESTINATION_A, quotedFee);

        EtherdocSender.DispatchRecord memory failedDispatch = s_sender.getDispatch(s_documentId, DESTINATION_A);
        assertEq(uint8(failedDispatch.status), uint8(EtherdocSender.DispatchStatus.NOT_DISPATCHED));

        bytes32 messageId = s_sender.dispatchDocument(s_documentId, DESTINATION_A, increasedFee);
        assertNotEq(messageId, bytes32(0));
    }

    function test_dispatchRejectsInsufficientFeeBalance() external {
        uint256 fee = s_router.FEE();
        EtherdocSender unfundedSender = _deploySender(address(s_link));
        unfundedSender.configureRemote(DESTINATION_A, RECEIVER_A, GAS_LIMIT_A, true);
        bytes32 documentId =
            unfundedSender.registerDocument(CIDTestHelper.digestFor("unfunded"), CIDTestHelper.rawCIDFor("unfunded"));

        vm.expectRevert(abi.encodeWithSelector(EtherdocSender.NotEnoughBalance.selector, uint256(0), fee));
        unfundedSender.dispatchDocument(documentId, DESTINATION_A, fee);
    }

    function test_forceApproveSupportsTokenRequiringZeroAllowance() external {
        ApprovalRestrictedToken token = new ApprovalRestrictedToken();
        EtherdocSender sender = _deploySender(address(token));
        token.mint(address(sender), 10 ether);
        sender.configureRemote(DESTINATION_A, RECEIVER_A, GAS_LIMIT_A, true);
        sender.configureRemote(DESTINATION_B, RECEIVER_B, GAS_LIMIT_B, true);
        bytes32 documentId = sender.registerDocument(
            CIDTestHelper.digestFor("approval-reset"), CIDTestHelper.rawCIDFor("approval-reset")
        );

        sender.dispatchDocument(documentId, DESTINATION_A, s_router.FEE());
        sender.dispatchDocument(documentId, DESTINATION_B, s_router.FEE());

        assertEq(token.allowance(address(sender), address(s_router)), s_router.FEE());
    }

    function test_dispatchRevertsWhenApprovalFails() external {
        uint256 fee = s_router.FEE();
        ApprovalRestrictedToken token = new ApprovalRestrictedToken();
        EtherdocSender sender = _deploySender(address(token));
        token.mint(address(sender), 10 ether);
        token.setApprovalsDisabled(true);
        sender.configureRemote(DESTINATION_A, RECEIVER_A, GAS_LIMIT_A, true);
        bytes32 documentId = sender.registerDocument(
            CIDTestHelper.digestFor("approval-failure"), CIDTestHelper.rawCIDFor("approval-failure")
        );

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        sender.dispatchDocument(documentId, DESTINATION_A, fee);

        EtherdocSender.DispatchRecord memory failedDispatch = sender.getDispatch(documentId, DESTINATION_A);
        assertEq(uint8(failedDispatch.status), uint8(EtherdocSender.DispatchStatus.NOT_DISPATCHED));
    }

    function test_ownerCanWithdrawTokensWithEvent() external {
        address treasury = makeAddr("treasury");
        uint256 amount = 7 ether;
        uint256 senderBalanceBefore = s_link.balanceOf(address(s_sender));

        vm.expectEmit(true, true, false, true);
        emit EtherdocSender.TokenWithdrawn(address(s_link), treasury, amount);
        s_sender.withdrawToken(address(s_link), treasury, amount);

        assertEq(s_link.balanceOf(treasury), amount);
        assertEq(s_link.balanceOf(address(s_sender)), senderBalanceBefore - amount);
    }

    function test_withdrawTokenRejectsUnauthorizedAndZeroAddresses() external {
        address treasury = makeAddr("treasury");

        vm.prank(makeAddr("not-owner"));
        vm.expectRevert(bytes("Only callable by owner"));
        s_sender.withdrawToken(address(s_link), treasury, 1 ether);

        vm.expectRevert(EtherdocSender.InvalidTokenAddress.selector);
        s_sender.withdrawToken(address(0), treasury, 1 ether);

        vm.expectRevert(EtherdocSender.InvalidWithdrawalRecipient.selector);
        s_sender.withdrawToken(address(s_link), address(0), 1 ether);
    }

    function test_withdrawTokenRevertsWhenTransferFails() external {
        ApprovalRestrictedToken token = new ApprovalRestrictedToken();
        token.mint(address(s_sender), 1 ether);
        token.setTransfersDisabled(true);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        s_sender.withdrawToken(address(token), makeAddr("treasury"), 1 ether);
    }

    function _deploySender(address _feeToken) private returns (EtherdocSender) {
        return
            new EtherdocSender(address(s_router), _feeToken, address(this), address(this), address(this), address(this));
    }
}
