// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {console} from "forge-std/Script.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {NetworkConfigScript} from "./NetworkConfig.s.sol";

contract ConfigureEtherdocRemotesScript is NetworkConfigScript {
    error UnsupportedConfigurationTarget(string target);

    function run() public {
        NetworkConfig memory source = _loadNetwork(vm.envString("SOURCE_NETWORK"));
        NetworkConfig memory destination = _loadNetwork(vm.envString("DESTINATION_NETWORK"));
        string memory target = vm.envString("CONFIGURE_TARGET");
        bytes32 targetHash = keccak256(bytes(target));

        if (targetHash == keccak256("SENDER")) {
            _configureSender(source, destination);
            return;
        }
        if (targetHash == keccak256("RECEIVER")) {
            _configureReceiver(source, destination);
            return;
        }
        revert UnsupportedConfigurationTarget(target);
    }

    function _configureSender(NetworkConfig memory _source, NetworkConfig memory _destination) private {
        _validateLane(_source, _destination);
        _requireDeployment(_source.sender, _source.name, "EtherdocSender");
        _requireLocalCode(_source, "EtherdocSender", _source.sender);
        _requireDeployment(_destination.receiver, _destination.name, "EtherdocReceiver");
        _requireRemoteCode(_destination, "router", _destination.router);
        _requireRemoteCode(_destination, "EtherdocReceiver", _destination.receiver);

        EtherdocSender sender = EtherdocSender(_source.sender);
        if (_senderRemoteMatches(sender, _destination)) {
            console.log("EtherdocSender remote already configured; no transaction created");
            return;
        }

        bytes memory callData = abi.encodeCall(
            EtherdocSender.configureRemote,
            (_destination.chainSelector, _destination.receiver, _destination.gasLimit, true)
        );
        if (_source.governanceMode == GovernanceMode.DIRECT) {
            _requireDirectGovernance(_source);
            vm.startBroadcast();
            sender.configureRemote(_destination.chainSelector, _destination.receiver, _destination.gasLimit, true);
            vm.stopBroadcast();
        } else {
            (string memory path, bool written) = _persistMultisigProposal(
                _source,
                sender.owner(),
                address(sender),
                callData,
                string.concat("configure-sender-to-", _destination.name),
                string.concat("Configure EtherdocSender remote for ", _destination.name)
            );
            console.log(written ? "Multisig proposal written:" : "Multisig proposal already current:", path);
        }

        console.log("Configured EtherdocSender:", _source.sender);
        console.log("Destination receiver:", _destination.receiver);
        console.log("Destination selector:", _destination.chainSelector);
        console.log("Destination gas limit:", _destination.gasLimit);
    }

    function _configureReceiver(NetworkConfig memory _source, NetworkConfig memory _destination) private {
        _validateCurrentNetwork(_destination, false);
        _validateStaticNetwork(_source);
        _requireDeployment(_source.sender, _source.name, "EtherdocSender");
        _requireRemoteCode(_source, "router", _source.router);
        _requireRemoteCode(_source, "EtherdocSender", _source.sender);
        _requireDeployment(_destination.receiver, _destination.name, "EtherdocReceiver");
        _requireLocalCode(_destination, "EtherdocReceiver", _destination.receiver);

        EtherdocReceiver receiver = EtherdocReceiver(_destination.receiver);
        if (_receiverRemoteMatches(receiver, _source)) {
            console.log("EtherdocReceiver remote already trusted; no transaction created");
            return;
        }

        bytes memory callData =
            abi.encodeCall(EtherdocReceiver.configureTrustedRemote, (_source.chainSelector, _source.sender, true));
        if (_destination.governanceMode == GovernanceMode.DIRECT) {
            _requireDirectGovernance(_destination);
            vm.startBroadcast();
            receiver.configureTrustedRemote(_source.chainSelector, _source.sender, true);
            vm.stopBroadcast();
        } else {
            (string memory path, bool written) = _persistMultisigProposal(
                _destination,
                receiver.owner(),
                address(receiver),
                callData,
                string.concat("configure-receiver-from-", _source.name),
                string.concat("Trust EtherdocSender remote from ", _source.name)
            );
            console.log(written ? "Multisig proposal written:" : "Multisig proposal already current:", path);
        }

        console.log("Configured EtherdocReceiver:", _destination.receiver);
        console.log("Source sender:", _source.sender);
        console.log("Source selector:", _source.chainSelector);
    }

    function _senderRemoteMatches(EtherdocSender _sender, NetworkConfig memory _destination)
        internal
        view
        returns (bool)
    {
        EtherdocSender.RemoteConfig memory current = _sender.getRemoteConfig(_destination.chainSelector);
        return
            current.receiver == _destination.receiver && current.gasLimit == _destination.gasLimit
                && current.allowlisted;
    }

    function _receiverRemoteMatches(EtherdocReceiver _receiver, NetworkConfig memory _source)
        internal
        view
        returns (bool)
    {
        return _receiver.isTrustedRemote(_source.chainSelector, _source.sender);
    }
}
