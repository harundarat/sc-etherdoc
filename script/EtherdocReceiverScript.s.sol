// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";

contract EtherdocReceiverScript is Script {
    EtherdocReceiver public etherdocReceiver;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        etherdocReceiver = new EtherdocReceiver(0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93);
        etherdocReceiver.allowlistSender(0x50D1672685E594B27F298Ac5bFACa4F3488AAA9c, true);
        etherdocReceiver.allowListSourceChain(7717148896336251131, true); // Base Sepolia
        vm.stopBroadcast();

        console.log("EtherdocReceiver deployed at:", address(etherdocReceiver));
    }
}
