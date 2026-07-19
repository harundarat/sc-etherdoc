// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {console} from "forge-std/Script.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {NetworkConfigScript} from "./NetworkConfig.s.sol";

contract ConfigureEtherdocReceiverScript is NetworkConfigScript {
    function run() public {
        NetworkConfig memory source = _loadNetwork(vm.envString("SOURCE_NETWORK"));
        NetworkConfig memory destination = _loadNetwork(vm.envString("DESTINATION_NETWORK"));

        _validateCurrentNetwork(destination, false);
        _validateStaticNetwork(source);
        _requireDeployment(source.sender, source.name, "EtherdocSender");
        _requireRemoteCode(source, "router", source.router);
        _requireRemoteCode(source, "EtherdocSender", source.sender);
        _requireDeployment(destination.receiver, destination.name, "EtherdocReceiver");
        _requireLocalCode(destination, "EtherdocReceiver", destination.receiver);

        EtherdocReceiver receiver = EtherdocReceiver(destination.receiver);

        vm.startBroadcast();
        receiver.configureTrustedRemote(source.chainSelector, source.sender, true);
        vm.stopBroadcast();

        console.log("Configured EtherdocReceiver:", destination.receiver);
        console.log("Source sender:", source.sender);
        console.log("Source selector:", source.chainSelector);
    }
}
