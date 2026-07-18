// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {NetworkConfigScript} from "./NetworkConfig.s.sol";

contract EtherdocSenderScript is NetworkConfigScript {
    EtherdocSender public etherdocSender;

    function setUp() public {}

    function run() public {
        string memory networkName = vm.envString("NETWORK");
        NetworkConfig memory network = _loadNetwork(networkName);
        _validateCurrentNetwork(network, true);

        vm.startBroadcast();
        etherdocSender = new EtherdocSender(network.router, network.linkToken);
        vm.stopBroadcast();

        _persistDeployment(networkName, address(etherdocSender), network.receiver);
        console.log("EtherdocSender deployed at:", address(etherdocSender));
    }
}
