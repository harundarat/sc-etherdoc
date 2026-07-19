// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

abstract contract NetworkConfigScript is Script {
    enum FeeMode {
        LINK,
        NATIVE
    }

    struct NetworkConfig {
        string name;
        uint256 chainId;
        uint64 chainSelector;
        address router;
        address linkToken;
        string explorer;
        string rpcAlias;
        address sender;
        address receiver;
        uint32 gasLimit;
        FeeMode feeMode;
        uint64 directoryVerifiedAt;
    }

    error InvalidNetworkConfig(string network, string field);
    error ChainIdMismatch(string network, uint256 expected, uint256 actual);
    error ContractCodeMissing(string network, string contractRole, address account);
    error RemoteContractCodeMissing(string network, string contractRole, address account);
    error DestinationChainUnsupported(string sourceNetwork, string destinationNetwork, uint64 chainSelector);
    error DeploymentAddressMissing(string network, string contractRole);
    error UnsupportedFeeMode(string network, FeeMode feeMode);

    function _loadNetwork(string memory _networkName) internal view returns (NetworkConfig memory config) {
        string memory json = vm.readFile(_networkConfigPath());
        string memory root = string.concat(".networks.", _networkName);

        uint256 chainSelector = vm.parseJsonUint(json, string.concat(root, ".chainSelector"));
        uint256 directoryVerifiedAt = vm.parseJsonUint(json, string.concat(root, ".directoryVerifiedAt"));
        uint256 gasLimit = vm.parseJsonUint(json, string.concat(root, ".gasLimit"));
        if (chainSelector > type(uint64).max) {
            revert InvalidNetworkConfig(_networkName, "chainSelector");
        }
        if (directoryVerifiedAt > type(uint64).max) {
            revert InvalidNetworkConfig(_networkName, "directoryVerifiedAt");
        }
        if (gasLimit == 0 || gasLimit > type(uint32).max) {
            revert InvalidNetworkConfig(_networkName, "gasLimit");
        }

        config = NetworkConfig({
            name: _networkName,
            chainId: vm.parseJsonUint(json, string.concat(root, ".chainId")),
            // Values above uint64 are rejected before constructing the config.
            // forge-lint: disable-next-line(unsafe-typecast)
            chainSelector: uint64(chainSelector),
            router: vm.parseJsonAddress(json, string.concat(root, ".router")),
            linkToken: vm.parseJsonAddress(json, string.concat(root, ".linkToken")),
            explorer: vm.parseJsonString(json, string.concat(root, ".explorer")),
            rpcAlias: vm.parseJsonString(json, string.concat(root, ".rpcAlias")),
            sender: address(0),
            receiver: address(0),
            // Values above uint32 are rejected before constructing the config.
            // forge-lint: disable-next-line(unsafe-typecast)
            gasLimit: uint32(gasLimit),
            feeMode: _parseFeeMode(_networkName, vm.parseJsonString(json, string.concat(root, ".feeMode"))),
            // Values above uint64 are rejected before constructing the config.
            // forge-lint: disable-next-line(unsafe-typecast)
            directoryVerifiedAt: uint64(directoryVerifiedAt)
        });

        string memory deploymentPath = _deploymentPath(_networkName);
        if (vm.isFile(deploymentPath)) {
            string memory deploymentJson = vm.readFile(deploymentPath);
            config.sender = vm.parseJsonAddress(deploymentJson, ".sender");
            config.receiver = vm.parseJsonAddress(deploymentJson, ".receiver");
        }
    }

    function _validateCurrentNetwork(NetworkConfig memory _network, bool _requireFeeToken) internal view {
        _validateStaticNetwork(_network);
        if (block.chainid != _network.chainId) {
            revert ChainIdMismatch(_network.name, _network.chainId, block.chainid);
        }
        _requireLocalCode(_network, "router", _network.router);
        if (_requireFeeToken) {
            if (_network.feeMode != FeeMode.LINK) {
                revert UnsupportedFeeMode(_network.name, _network.feeMode);
            }
            _requireLocalCode(_network, "LINK", _network.linkToken);
        }
    }

    function _validateLane(NetworkConfig memory _source, NetworkConfig memory _destination) internal view {
        _validateCurrentNetwork(_source, true);
        _validateStaticNetwork(_destination);
        if (!IRouterClient(_source.router).isChainSupported(_destination.chainSelector)) {
            revert DestinationChainUnsupported(_source.name, _destination.name, _destination.chainSelector);
        }
    }

    function _validateStaticNetwork(NetworkConfig memory _network) internal pure {
        if (_network.chainId == 0) {
            revert InvalidNetworkConfig(_network.name, "chainId");
        }
        if (_network.chainSelector == 0) {
            revert InvalidNetworkConfig(_network.name, "chainSelector");
        }
        if (_network.router == address(0)) {
            revert InvalidNetworkConfig(_network.name, "router");
        }
        if (_network.feeMode == FeeMode.LINK && _network.linkToken == address(0)) {
            revert InvalidNetworkConfig(_network.name, "linkToken");
        }
        if (bytes(_network.explorer).length == 0) {
            revert InvalidNetworkConfig(_network.name, "explorer");
        }
        if (bytes(_network.rpcAlias).length == 0) {
            revert InvalidNetworkConfig(_network.name, "rpcAlias");
        }
        if (_network.gasLimit == 0) {
            revert InvalidNetworkConfig(_network.name, "gasLimit");
        }
        if (_network.directoryVerifiedAt == 0) {
            revert InvalidNetworkConfig(_network.name, "directoryVerifiedAt");
        }
    }

    function _requireDeployment(address _account, string memory _network, string memory _contractRole) internal pure {
        if (_account == address(0)) {
            revert DeploymentAddressMissing(_network, _contractRole);
        }
    }

    function _requireLocalCode(NetworkConfig memory _network, string memory _contractRole, address _account)
        internal
        view
    {
        if (_account.code.length == 0) {
            revert ContractCodeMissing(_network.name, _contractRole, _account);
        }
    }

    function _requireRemoteCode(NetworkConfig memory _network, string memory _contractRole, address _account) internal {
        _requireDeployment(_account, _network.name, _contractRole);
        string memory params = string.concat("[\"", vm.toString(_account), "\",\"latest\"]");
        bytes memory response = vm.rpc(_network.rpcAlias, "eth_getCode", params);
        bytes memory runtimeCode = abi.decode(response, (bytes));
        if (runtimeCode.length == 0) {
            revert RemoteContractCodeMissing(_network.name, _contractRole, _account);
        }
    }

    function _persistDeployment(string memory _networkName, address _sender, address _receiver) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            return;
        }

        string memory objectKey = string.concat("etherdoc-", _networkName);
        vm.serializeAddress(objectKey, "sender", _sender);
        string memory json = vm.serializeAddress(objectKey, "receiver", _receiver);
        vm.writeJson(json, _deploymentPath(_networkName));
    }

    function _networkConfigPath() internal view returns (string memory) {
        return vm.envOr("NETWORK_CONFIG_PATH", string("config/networks/testnet.json"));
    }

    function _deploymentPath(string memory _networkName) internal view returns (string memory) {
        string memory deploymentDirectory = vm.envOr("DEPLOYMENT_DIR", string("deployments/testnet"));
        return string.concat(deploymentDirectory, "/", _networkName, ".json");
    }

    function _parseFeeMode(string memory _networkName, string memory _feeMode) private pure returns (FeeMode) {
        bytes32 feeModeHash = keccak256(bytes(_feeMode));
        if (feeModeHash == keccak256("LINK")) {
            return FeeMode.LINK;
        }
        if (feeModeHash == keccak256("NATIVE")) {
            return FeeMode.NATIVE;
        }
        revert InvalidNetworkConfig(_networkName, "feeMode");
    }
}
