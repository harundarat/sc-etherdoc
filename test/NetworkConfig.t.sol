// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {NetworkConfigScript} from "../script/NetworkConfig.s.sol";

contract ConfigMockRouter is IRouterClient {
    bool private s_supported;

    function setSupported(bool _supported) external {
        s_supported = _supported;
    }

    function isChainSupported(uint64) external view returns (bool supported) {
        return s_supported;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256 fee) {
        return 0;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage calldata) external payable returns (bytes32 messageId) {
        return bytes32(uint256(1));
    }
}

contract ConfigCodeStub {}

contract NetworkConfigHarness is NetworkConfigScript {
    function loadNetwork(string memory _networkName) external view returns (NetworkConfig memory) {
        return _loadNetwork(_networkName);
    }

    function validateCurrentNetwork(NetworkConfig memory _network, bool _requireFeeToken) external view {
        _validateCurrentNetwork(_network, _requireFeeToken);
    }

    function validateLane(NetworkConfig memory _source, NetworkConfig memory _destination) external view {
        _validateLane(_source, _destination);
    }

    function requireDeployment(address _account, string memory _network, string memory _contractRole) external pure {
        _requireDeployment(_account, _network, _contractRole);
    }
}

contract NetworkConfigTest is Test {
    NetworkConfigHarness private s_harness;
    ConfigMockRouter private s_router;
    ConfigCodeStub private s_linkToken;

    function setUp() public {
        s_harness = new NetworkConfigHarness();
        s_router = new ConfigMockRouter();
        s_linkToken = new ConfigCodeStub();
    }

    function test_loadsEachSupportedChainFromJson() external view {
        NetworkConfigScript.NetworkConfig memory source = s_harness.loadNetwork("mantleSepolia");
        NetworkConfigScript.NetworkConfig memory destination = s_harness.loadNetwork("inkSepolia");

        assertEq(source.name, "mantleSepolia");
        assertEq(source.chainId, 5_003);
        assertEq(source.chainSelector, 8_236_463_271_206_331_221);
        assertNotEq(source.router, address(0));
        assertNotEq(source.linkToken, address(0));
        assertEq(source.rpcAlias, "mantle_sepolia");
        assertEq(source.gasLimit, 500_000);
        assertEq(uint8(source.feeMode), uint8(NetworkConfigScript.FeeMode.LINK));
        assertEq(source.sender, address(0));

        assertEq(destination.name, "inkSepolia");
        assertEq(destination.chainId, 763_373);
        assertEq(destination.chainSelector, 9_763_904_284_804_119_144);
        assertNotEq(destination.router, address(0));
        assertNotEq(destination.linkToken, address(0));
        assertEq(destination.rpcAlias, "ink_sepolia");
        assertEq(destination.gasLimit, 500_000);
        assertEq(destination.receiver, address(0));
    }

    function test_dryRunRejectsWrongRpcChain() external {
        NetworkConfigScript.NetworkConfig memory network = _network("source");
        vm.chainId(network.chainId + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.ChainIdMismatch.selector, network.name, network.chainId, block.chainid
            )
        );
        s_harness.validateCurrentNetwork(network, true);
    }

    function test_dryRunRejectsRouterWithoutCode() external {
        NetworkConfigScript.NetworkConfig memory network = _network("source");
        network.router = address(0xBEEF);
        vm.chainId(network.chainId);

        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.ContractCodeMissing.selector, network.name, "router", network.router
            )
        );
        s_harness.validateCurrentNetwork(network, true);
    }

    function test_dryRunRejectsUnsupportedLane() external {
        NetworkConfigScript.NetworkConfig memory source = _network("source");
        NetworkConfigScript.NetworkConfig memory destination = _network("destination");
        vm.chainId(source.chainId);
        s_router.setSupported(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DestinationChainUnsupported.selector,
                source.name,
                destination.name,
                destination.chainSelector
            )
        );
        s_harness.validateLane(source, destination);
    }

    function test_acceptsMatchingChainContractsAndSupportedLane() external {
        NetworkConfigScript.NetworkConfig memory source = _network("source");
        NetworkConfigScript.NetworkConfig memory destination = _network("destination");
        vm.chainId(source.chainId);
        s_router.setSupported(true);

        s_harness.validateLane(source, destination);
    }

    function test_configureRejectsMissingDeploymentAddress() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DeploymentAddressMissing.selector, "inkSepolia", "EtherdocReceiver"
            )
        );
        s_harness.requireDeployment(address(0), "inkSepolia", "EtherdocReceiver");
    }

    function _network(string memory _name) private view returns (NetworkConfigScript.NetworkConfig memory network) {
        network = NetworkConfigScript.NetworkConfig({
            name: _name,
            chainId: 12_345,
            chainSelector: 99,
            router: address(s_router),
            linkToken: address(s_linkToken),
            explorer: "https://explorer.example",
            rpcAlias: "test",
            sender: address(0),
            receiver: address(0),
            gasLimit: 500_000,
            feeMode: NetworkConfigScript.FeeMode.LINK,
            directoryVerifiedAt: 1
        });
    }
}
