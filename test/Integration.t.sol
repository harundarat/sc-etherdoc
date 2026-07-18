// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";

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

        etherdocSender = new EtherdocSender(address(sourceRouter), address(link));
        etherdocReceiver = new EtherdocReceiver(address(destinationRouter));

        etherdocSender.configureDestinationChain(destinationChainSelector, address(etherdocReceiver), true);
        etherdocReceiver.allowListSourceChain(chainSelector, true);
        etherdocReceiver.allowlistSender(address(etherdocSender), true);
    }

    function test_sendAndReceiveCrossChainMessagePayFeesInLink() external {
        ccipLocalSimulator.requestLinkFromFaucet(address(etherdocSender), 10 ether);

        string memory documentCID = "hello";

        bytes32 documentId = etherdocSender.registerDocument(documentCID);
        etherdocSender.dispatchDocument(documentId, destinationChainSelector);

        bool isRegisteredInSourceChain = etherdocSender.isDocumentRegistered(documentId);
        bool isExistInDestinationChain = etherdocReceiver.documentExists(documentCID);

        assertEq(isRegisteredInSourceChain, true);
        assertEq(isExistInDestinationChain, true);
    }
}
