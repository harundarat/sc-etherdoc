// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";

contract EtherdocSenderScript is Script {
    EtherdocSender public etherdocSender;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        etherdocSender =
            new EtherdocSender(0xb9531b46fE8808fB3659e39704953c2B1112DD43, 0x685cE6742351ae9b618F383883D6d1e0c5A31B4B);
        etherdocSender.allowlistDestinationChain(10344971235874465080, true); // Base Sepolia
        vm.stopBroadcast();

        console.log("EtherdocSender deployed at:", address(etherdocSender));
    }
}
