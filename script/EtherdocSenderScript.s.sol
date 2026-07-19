// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

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
        address governance = vm.envAddress("GOVERNANCE");
        address initialIssuer = vm.envAddress("INITIAL_ISSUER");
        address operator = vm.envAddress("OPERATOR");
        address pauser = vm.envAddress("PAUSER");

        vm.startBroadcast();
        etherdocSender =
            new EtherdocSender(network.router, network.linkToken, governance, initialIssuer, operator, pauser);
        vm.stopBroadcast();

        _persistDeployment(networkName, address(etherdocSender), network.receiver);
        console.log("EtherdocSender deployed at:", address(etherdocSender));
        console.log("Governance:", governance);
        console.log("Initial issuer:", initialIssuer);
        console.log("Operator:", operator);
        console.log("Pauser:", pauser);
    }
}
