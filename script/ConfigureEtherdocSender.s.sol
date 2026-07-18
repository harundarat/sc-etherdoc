// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {NetworkConfigScript} from "./NetworkConfig.s.sol";

contract ConfigureEtherdocSenderScript is NetworkConfigScript {
    function run() public {
        NetworkConfig memory source = _loadNetwork(vm.envString("SOURCE_NETWORK"));
        NetworkConfig memory destination = _loadNetwork(vm.envString("DESTINATION_NETWORK"));

        _validateLane(source, destination);
        _requireDeployment(source.sender, source.name, "EtherdocSender");
        _requireLocalCode(source, "EtherdocSender", source.sender);
        _requireDeployment(destination.receiver, destination.name, "EtherdocReceiver");
        _requireRemoteCode(destination, "router", destination.router);
        _requireRemoteCode(destination, "EtherdocReceiver", destination.receiver);

        EtherdocSender sender = EtherdocSender(source.sender);

        vm.startBroadcast();
        sender.configureRemote(destination.chainSelector, destination.receiver, destination.gasLimit, true);
        vm.stopBroadcast();

        console.log("Configured EtherdocSender:", source.sender);
        console.log("Destination receiver:", destination.receiver);
        console.log("Destination selector:", destination.chainSelector);
        console.log("Destination gas limit:", destination.gasLimit);
    }
}
