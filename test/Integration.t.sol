// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocTypes} from "../src/EtherdocTypes.sol";

contract Integration is Test {
    CCIPLocalSimulator public ccipLocalSimulator;
    EtherdocSender public etherdocSender;
    EtherdocReceiver public etherdocReceiver;

    uint64 public destinationChainSelector;

    function setUp() public {
        ccipLocalSimulator = new CCIPLocalSimulator();

        (uint64 chainSelector, IRouterClient sourceRouter, IRouterClient destinationRouter,, LinkToken link,,) =
            ccipLocalSimulator.configuration();

        destinationChainSelector = chainSelector;

        etherdocSender = new EtherdocSender(
            address(sourceRouter), address(link), address(this), address(this), address(this), address(this)
        );
        etherdocReceiver = new EtherdocReceiver(address(destinationRouter), address(this), address(this));

        etherdocSender.configureRemote(destinationChainSelector, address(etherdocReceiver), 500_000, true);
        etherdocReceiver.configureTrustedRemote(chainSelector, address(etherdocSender), true);
    }

    function test_sendAndReceiveCrossChainMessagePayFeesInLink() external {
        ccipLocalSimulator.requestLinkFromFaucet(address(etherdocSender), 10 ether);

        string memory documentCID = "hello";

        bytes32 documentId = etherdocSender.registerDocument(documentCID);
        uint256 quotedFee = etherdocSender.quoteFee(documentId, destinationChainSelector);
        bytes32 messageId = etherdocSender.dispatchDocument(documentId, destinationChainSelector, quotedFee);

        bool isRegisteredInSourceChain = etherdocSender.isDocumentRegistered(documentId);
        bool isReceivedInDestinationChain = etherdocReceiver.isDocumentReceived(documentId);
        EtherdocReceiver.ReceiptRecord memory receipt = etherdocReceiver.getReceipt(documentId);

        assertEq(isRegisteredInSourceChain, true);
        assertEq(isReceivedInDestinationChain, true);
        assertEq(receipt.messageId, messageId);
        assertEq(receipt.document.documentCID, documentCID);
        assertEq(receipt.document.documentId, documentId);
        assertEq(receipt.document.contentCommitment, keccak256(bytes(documentCID)));
        assertEq(receipt.document.issuer, address(this));
        assertEq(receipt.document.sourceChainId, block.chainid);
        assertEq(receipt.document.version, 1);
        assertEq(uint8(receipt.document.status), uint8(EtherdocTypes.DocumentStatus.ACTIVE));
        assertEq(receipt.sourceChainSelector, destinationChainSelector);
        assertEq(receipt.sender, address(etherdocSender));
        assertEq(receipt.receivedAt, block.timestamp);
        assertEq(uint8(receipt.status), uint8(EtherdocReceiver.ReceiptStatus.RECEIVED));
    }
}
