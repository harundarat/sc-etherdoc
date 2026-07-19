// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";

contract CCIPV2MantleForkTest is Test {
    uint256 private constant MANTLE_SEPOLIA_CHAIN_ID = 5_003;
    uint64 private constant INK_SEPOLIA_CHAIN_SELECTOR = 9_763_904_284_804_119_144;
    address private constant MANTLE_SEPOLIA_ROUTER = 0xFd33fd627017fEf041445FC19a2B6521C9778f86;
    address private constant MANTLE_SEPOLIA_LINK = 0x22bdEdEa0beBdD7CfFC95bA53826E55afFE9DE04;
    address private constant RECEIVER = address(0xBEEF);
    bytes32 private constant DOCUMENT_DIGEST = 0x43cc23fa52b87b4cc1d02b5b114154151d6adddb17c9fddc06b027fa99e24008;
    string private constant DOCUMENT_CID = "bafkreicdzqr7uuvypngmdubllmiucvavdvvn3wyxzh65ybvqe75jtysaba";

    bool private s_rpcAvailable;
    EtherdocSender private s_sender;
    bytes32 private s_documentId;

    function setUp() public {
        string memory rpcUrl = vm.envOr("MANTLE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, MANTLE_SEPOLIA_CHAIN_ID);
        s_rpcAvailable = true;
        s_sender = new EtherdocSender(
            MANTLE_SEPOLIA_ROUTER, MANTLE_SEPOLIA_LINK, address(this), address(this), address(this), address(this)
        );
        s_sender.configureRemote(INK_SEPOLIA_CHAIN_SELECTOR, RECEIVER, 500_000, true);
        s_documentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID);
    }

    function test_mantleRouterSupportsInkAndQuotesExtraArgsV3() external {
        if (!s_rpcAvailable) {
            vm.skip(true);
        }

        assertGt(MANTLE_SEPOLIA_ROUTER.code.length, 0);
        assertGt(MANTLE_SEPOLIA_LINK.code.length, 0);
        assertTrue(IRouterClient(MANTLE_SEPOLIA_ROUTER).isChainSupported(INK_SEPOLIA_CHAIN_SELECTOR));
        assertGt(s_sender.quoteFee(s_documentId, INK_SEPOLIA_CHAIN_SELECTOR), 0);
    }
}

contract CCIPV2InkForkTest is Test {
    uint256 private constant INK_SEPOLIA_CHAIN_ID = 763_373;
    uint64 private constant MANTLE_SEPOLIA_CHAIN_SELECTOR = 8_236_463_271_206_331_221;
    address private constant INK_SEPOLIA_ROUTER = 0x17fCda531D8E43B4e2a2A2492FBcd4507a1685A1;
    address private constant INK_SEPOLIA_LINK = 0x3423C922911956b1Ccbc2b5d4f38216a6f4299b4;
    address private constant RECEIVER = address(0xBEEF);
    bytes32 private constant DOCUMENT_DIGEST = 0x43cc23fa52b87b4cc1d02b5b114154151d6adddb17c9fddc06b027fa99e24008;
    string private constant DOCUMENT_CID = "bafkreicdzqr7uuvypngmdubllmiucvavdvvn3wyxzh65ybvqe75jtysaba";

    bool private s_rpcAvailable;
    EtherdocSender private s_sender;
    bytes32 private s_documentId;

    function setUp() public {
        string memory rpcUrl = vm.envOr("INK_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, INK_SEPOLIA_CHAIN_ID);
        s_rpcAvailable = true;
        s_sender = new EtherdocSender(
            INK_SEPOLIA_ROUTER, INK_SEPOLIA_LINK, address(this), address(this), address(this), address(this)
        );
        s_sender.configureRemote(MANTLE_SEPOLIA_CHAIN_SELECTOR, RECEIVER, 500_000, true);
        s_documentId = s_sender.registerDocument(DOCUMENT_DIGEST, DOCUMENT_CID);
    }

    function test_inkRouterSupportsMantleAndQuotesExtraArgsV3() external {
        if (!s_rpcAvailable) {
            vm.skip(true);
        }

        assertGt(INK_SEPOLIA_ROUTER.code.length, 0);
        assertGt(INK_SEPOLIA_LINK.code.length, 0);
        assertTrue(IRouterClient(INK_SEPOLIA_ROUTER).isChainSupported(MANTLE_SEPOLIA_CHAIN_SELECTOR));
        assertGt(s_sender.quoteFee(s_documentId, MANTLE_SEPOLIA_CHAIN_SELECTOR), 0);
    }
}
