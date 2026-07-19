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
        _validateDeploymentGovernance(network, governance);
        address initialIssuer = vm.envAddress("INITIAL_ISSUER");
        address operator = vm.envAddress("OPERATOR");
        address pauser = vm.envAddress("PAUSER");

        bool deployed;
        if (network.sender == address(0)) {
            vm.startBroadcast();
            (etherdocSender, deployed) = _deployOrReuse(network, governance, initialIssuer, operator, pauser);
            vm.stopBroadcast();
        } else {
            (etherdocSender, deployed) = _deployOrReuse(network, governance, initialIssuer, operator, pauser);
        }

        _persistDeployment(networkName, address(etherdocSender), network.receiver);
        console.log(
            deployed ? "EtherdocSender deployed at:" : "EtherdocSender already deployed at:", address(etherdocSender)
        );
        console.log("Governance:", governance);
        console.log("Initial issuer:", initialIssuer);
        console.log("Operator:", operator);
        console.log("Pauser:", pauser);
    }

    function _deployOrReuse(
        NetworkConfig memory _network,
        address _governance,
        address _initialIssuer,
        address _operator,
        address _pauser
    ) internal returns (EtherdocSender sender, bool deployed) {
        if (_network.sender == address(0)) {
            sender = new EtherdocSender(
                _network.router, _network.linkToken, _governance, _initialIssuer, _operator, _pauser
            );
            return (sender, true);
        }

        _requireLocalCode(_network, "EtherdocSender", _network.sender);
        sender = EtherdocSender(_network.sender);
        address actualRouter = sender.getRouter();
        if (actualRouter != _network.router) {
            revert DeploymentDependencyMismatch(
                _network.name, "EtherdocSender", "router", _network.router, actualRouter
            );
        }
        address actualFeeToken = sender.getFeeToken();
        if (actualFeeToken != _network.linkToken) {
            revert DeploymentDependencyMismatch(
                _network.name, "EtherdocSender", "LINK", _network.linkToken, actualFeeToken
            );
        }
        return (sender, false);
    }
}
