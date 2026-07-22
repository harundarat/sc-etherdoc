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
        NetworkConfig memory source = _loadNetwork(vm.envString("SOURCE_NETWORK"));
        _validateCurrentNetwork(network, false);
        _validateStaticNetwork(source);
        bool sourceDeploymentRecorded = source.sender != address(0);
        if (source.sender == address(0)) {
            source.sender = vm.envAddress("TRUSTED_SENDER");
        }
        _requireDeployment(source.sender, source.name, "EtherdocSender");
        if (sourceDeploymentRecorded) {
            _requireRemoteCode(source, "EtherdocSender", source.sender);
        }
        address governance = vm.envAddress("GOVERNANCE");
        _validateDeploymentGovernance(network, governance);
        address pauser = vm.envAddress("PAUSER");

        bool deployed;
        if (network.receiver == address(0)) {
            vm.startBroadcast();
            (etherdocReceiver, deployed) = _deployOrReuse(network, source, governance, pauser);
            vm.stopBroadcast();
        } else {
            (etherdocReceiver, deployed) = _deployOrReuse(network, source, governance, pauser);
        }

        _persistDeployment(networkName, network.sender, address(etherdocReceiver));
        console.log(
            deployed ? "EtherdocReceiver deployed at:" : "EtherdocReceiver already deployed at:",
            address(etherdocReceiver)
        );
        console.log("Governance:", governance);
        console.log("Pauser:", pauser);
        console.log("Source chain selector:", source.chainSelector);
        console.log("Source chain ID:", source.chainId);
        console.log("Trusted sender:", source.sender);
    }

    function _deployOrReuse(
        NetworkConfig memory _network,
        NetworkConfig memory _source,
        address _governance,
        address _pauser
    ) internal returns (EtherdocReceiver receiver, bool deployed) {
        if (_network.receiver == address(0)) {
            receiver = new EtherdocReceiver(
                _network.router, _governance, _pauser, _source.chainSelector, _source.chainId, _source.sender
            );
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
        if (receiver.getSourceChainSelector() != _source.chainSelector) {
            revert DeploymentValueMismatch(
                _network.name,
                "EtherdocReceiver",
                "sourceChainSelector",
                _source.chainSelector,
                receiver.getSourceChainSelector()
            );
        }
        if (receiver.getSourceChainId() != _source.chainId) {
            revert DeploymentValueMismatch(
                _network.name, "EtherdocReceiver", "sourceChainId", _source.chainId, receiver.getSourceChainId()
            );
        }
        return (receiver, false);
    }
}
