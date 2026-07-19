// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/utils/SafeERC20.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {CIDTestHelper} from "./utils/CIDTestHelper.sol";

contract CCIPV2RouterHarness is IRouterClient {
    using SafeERC20 for IERC20;

    uint64 public constant SOURCE_CHAIN_SELECTOR = 5_003;
    uint64 public constant DESTINATION_CHAIN_SELECTOR = 763_373;
    uint256 public constant FEE = 1 ether;

    IERC20 private immutable i_link;
    uint256 private s_nonce;

    constructor(address _link) {
        i_link = IERC20(_link);
    }

    function isChainSupported(uint64 _destinationChainSelector) external pure returns (bool supported) {
        return _destinationChainSelector == DESTINATION_CHAIN_SELECTOR;
    }

    function getFee(uint64 _destinationChainSelector, Client.EVM2AnyMessage memory _message)
        external
        view
        returns (uint256 fee)
    {
        _validateEnvelope(_destinationChainSelector, _message.feeToken, _message.extraArgs);
        return FEE;
    }

    function ccipSend(uint64 _destinationChainSelector, Client.EVM2AnyMessage calldata _message)
        external
        payable
        returns (bytes32 messageId)
    {
        _validateEnvelope(_destinationChainSelector, _message.feeToken, _message.extraArgs);
        ExtraArgsCodec.GenericExtraArgsV3 memory extraArgs =
            ExtraArgsCodec._decodeGenericExtraArgsV3(_message.extraArgs);
        require(extraArgs.gasLimit == 500_000, "unexpected gas limit");
        require(extraArgs.requestedFinalityConfig == FinalityCodec.WAIT_FOR_FINALITY_FLAG, "unexpected finality");
        require(extraArgs.ccvs.length == 0 && extraArgs.ccvArgs.length == 0, "custom CCV");
        require(extraArgs.executor == address(0) && extraArgs.executorArgs.length == 0, "custom executor");
        require(extraArgs.tokenReceiver.length == 0 && extraArgs.tokenArgs.length == 0, "unexpected token args");
        require(_message.tokenAmounts.length == 0, "unexpected token transfer");

        i_link.safeTransferFrom(msg.sender, address(this), FEE);
        s_nonce++;
        messageId = keccak256(abi.encode(_destinationChainSelector, msg.sender, _message.data, s_nonce));

        Client.Any2EVMMessage memory inboundMessage = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(msg.sender),
            data: _message.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        IAny2EVMMessageReceiver(abi.decode(_message.receiver, (address))).ccipReceive(inboundMessage);
    }

    function _validateEnvelope(uint64 _destinationChainSelector, address _feeToken, bytes memory _extraArgs)
        private
        view
    {
        require(_destinationChainSelector == DESTINATION_CHAIN_SELECTOR, "unsupported destination");
        require(_feeToken == address(i_link), "unexpected fee token");
        require(_extraArgs.length >= 4, "missing extra args");
        bytes4 tag;
        assembly ("memory-safe") {
            tag := mload(add(_extraArgs, 32))
        }
        require(tag == ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG, "unexpected extra args");
    }
}

contract Integration is Test {
    CCIPV2RouterHarness public router;
    MockLinkToken public link;
    EtherdocSender public etherdocSender;
    EtherdocReceiver public etherdocReceiver;

    function setUp() public {
        link = new MockLinkToken();
        router = new CCIPV2RouterHarness(address(link));
        etherdocSender = new EtherdocSender(
            address(router), address(link), address(this), address(this), address(this), address(this)
        );
        etherdocReceiver = new EtherdocReceiver(address(router), address(this), address(this));

        etherdocSender.configureRemote(router.DESTINATION_CHAIN_SELECTOR(), address(etherdocReceiver), 500_000, true);
        etherdocReceiver.configureTrustedRemote(router.SOURCE_CHAIN_SELECTOR(), address(etherdocSender), true);
        assertTrue(link.transfer(address(etherdocSender), 10 ether));
    }

    function test_sendAndReceiveCrossChainMessagePayFeesInLink() external {
        bytes32 contentDigest = 0x2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824;
        string memory documentCID = "bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq";

        bytes32 documentId = etherdocSender.registerDocument(contentDigest, documentCID);
        uint256 quotedFee = etherdocSender.quoteFee(documentId, router.DESTINATION_CHAIN_SELECTOR());
        bytes32 messageId = etherdocSender.dispatchDocument(documentId, router.DESTINATION_CHAIN_SELECTOR(), quotedFee);

        EtherdocReceiver.ReceiptRecord memory receipt = etherdocReceiver.getReceipt(documentId);
        assertTrue(etherdocSender.isDocumentRegistered(documentId));
        assertTrue(etherdocReceiver.isDocumentReceived(documentId));
        assertEq(link.balanceOf(address(router)), quotedFee);
        assertEq(receipt.messageId, messageId);
        assertEq(receipt.document.documentCID, documentCID);
        assertEq(receipt.document.documentId, documentId);
        assertEq(receipt.document.contentDigest, contentDigest);
        assertEq(receipt.document.cidCodec, 0x55);
        assertEq(receipt.document.cidDigest, contentDigest);
        assertEq(receipt.document.issuer, address(this));
        assertEq(receipt.document.sourceChainId, block.chainid);
        assertEq(receipt.document.version, 1);
        assertEq(uint8(receipt.document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(receipt.sourceChainSelector, router.SOURCE_CHAIN_SELECTOR());
        assertEq(receipt.sender, address(etherdocSender));
        assertEq(receipt.receivedAt, block.timestamp);
        assertEq(uint8(receipt.status), uint8(EtherdocReceiver.ReceiptStatus.RECEIVED));
    }

    function test_sendAndReceiveDagPbReconstructsCanonicalCID() external {
        bytes32 contentDigest = sha256("dag-pb file bytes");
        bytes32 cidDigest = sha256("dag-pb root block");
        string memory documentCID = CIDTestHelper.cidForDigest(0x70, cidDigest);

        bytes32 documentId = etherdocSender.registerDocument(contentDigest, documentCID);
        bytes32 messageId = etherdocSender.dispatchDocument(
            documentId,
            router.DESTINATION_CHAIN_SELECTOR(),
            etherdocSender.quoteFee(documentId, router.DESTINATION_CHAIN_SELECTOR())
        );

        EtherdocReceiver.ReceiptRecord memory receipt = etherdocReceiver.getReceipt(documentId);
        assertNotEq(messageId, bytes32(0));
        assertEq(receipt.document.documentCID, documentCID);
        assertEq(receipt.document.contentDigest, contentDigest);
        assertEq(receipt.document.cidCodec, 0x70);
        assertEq(receipt.document.cidDigest, cidDigest);
    }
}
