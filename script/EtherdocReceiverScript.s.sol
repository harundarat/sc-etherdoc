// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

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
        _validateDeploymentGovernance(network, governance);
        address pauser = vm.envAddress("PAUSER");

        bool deployed;
        if (network.receiver == address(0)) {
            vm.startBroadcast();
            (etherdocReceiver, deployed) = _deployOrReuse(network, governance, pauser);
            vm.stopBroadcast();
        } else {
            (etherdocReceiver, deployed) = _deployOrReuse(network, governance, pauser);
        }

        _persistDeployment(networkName, network.sender, address(etherdocReceiver));
        console.log(
            deployed ? "EtherdocReceiver deployed at:" : "EtherdocReceiver already deployed at:",
            address(etherdocReceiver)
        );
        console.log("Governance:", governance);
        console.log("Pauser:", pauser);
    }

    function _deployOrReuse(NetworkConfig memory _network, address _governance, address _pauser)
        internal
        returns (EtherdocReceiver receiver, bool deployed)
    {
        if (_network.receiver == address(0)) {
            receiver = new EtherdocReceiver(_network.router, _governance, _pauser);
            return (receiver, true);
        }

        _requireLocalCode(_network, "EtherdocReceiver", _network.receiver);
        receiver = EtherdocReceiver(_network.receiver);
        address actualRouter = receiver.getRouter();
        if (actualRouter != _network.router) {
            revert DeploymentDependencyMismatch(
                _network.name, "EtherdocReceiver", "router", _network.router, actualRouter
            );
        }
        return (receiver, false);
    }
}
