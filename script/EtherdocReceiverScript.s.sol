// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {NetworkConfigScript} from "./NetworkConfig.s.sol";

contract EtherdocReceiverScript is NetworkConfigScript {
    EtherdocReceiver public etherdocReceiver;

    function setUp() public {}

    function run() public {
        string memory networkName = vm.envString("NETWORK");
        NetworkConfig memory network = _loadNetwork(networkName);
        _validateCurrentNetwork(network, false);
        address governance = vm.envAddress("GOVERNANCE");
        address pauser = vm.envAddress("PAUSER");

        vm.startBroadcast();
        etherdocReceiver = new EtherdocReceiver(network.router, governance, pauser);
        vm.stopBroadcast();

        _persistDeployment(networkName, network.sender, address(etherdocReceiver));
        console.log("EtherdocReceiver deployed at:", address(etherdocReceiver));
        console.log("Governance:", governance);
        console.log("Pauser:", pauser);
    }
}
