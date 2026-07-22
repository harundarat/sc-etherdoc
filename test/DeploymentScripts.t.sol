// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {EtherdocReceiver} from "../src/EtherdocReceiver.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {EtherdocReceiverScript} from "../script/EtherdocReceiverScript.s.sol";
import {EtherdocSenderScript} from "../script/EtherdocSenderScript.s.sol";
import {ConfigureEtherdocRemotesScript} from "../script/ConfigureEtherdocRemotes.s.sol";
import {ManageEtherdocTreasuryScript} from "../script/ManageEtherdocTreasury.s.sol";
import {NetworkConfigScript} from "../script/NetworkConfig.s.sol";
import {MockLinkToken} from "./mocks/MockLinkToken.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract SenderDeploymentHarness is EtherdocSenderScript {
    function deployOrReuse(
        NetworkConfig memory _network,
        address _governance,
        address _initialIssuer,
        address _operator,
        address _pauser
    ) external returns (EtherdocSender sender, bool deployed) {
        return _deployOrReuse(_network, _governance, _initialIssuer, _operator, _pauser);
    }
}

contract ReceiverDeploymentHarness is EtherdocReceiverScript {
    function deployOrReuse(
        NetworkConfig memory _network,
        NetworkConfig memory _source,
        address _governance,
        address _pauser
    ) external returns (EtherdocReceiver receiver, bool deployed) {
        return _deployOrReuse(_network, _source, _governance, _pauser);
    }
}

contract RemoteConfigurationHarness is ConfigureEtherdocRemotesScript {
    function remoteMatches(EtherdocSender _sender, NetworkConfig memory _destination) external view returns (bool) {
        return _senderRemoteMatches(_sender, _destination);
    }

    function trustedRemoteMatches(EtherdocReceiver _receiver, NetworkConfig memory _source)
        external
        view
        returns (bool)
    {
        return _receiverRemoteMatches(_receiver, _source);
    }

    function requireReceiverOrigin(
        EtherdocReceiver _receiver,
        NetworkConfig memory _source,
        NetworkConfig memory _destination
    ) external view {
        _requireReceiverOrigin(_receiver, _source, _destination);
    }
}

contract TreasuryHarness is ManageEtherdocTreasuryScript {
    function fundingDeficit(uint256 _currentBalance, uint256 _targetBalance) external pure returns (uint256) {
        return _fundingDeficit(_currentBalance, _targetBalance);
    }

    function withdrawalExcess(uint256 _currentBalance, uint256 _retainedBalance) external pure returns (uint256) {
        return _withdrawalExcess(_currentBalance, _retainedBalance);
    }
}

contract DeploymentScriptsTest is Test {
    SenderDeploymentHarness private s_senderHarness;
    ReceiverDeploymentHarness private s_receiverHarness;
    RemoteConfigurationHarness private s_remoteConfigurationHarness;
    TreasuryHarness private s_treasuryHarness;
    MockRouter private s_router;
    MockLinkToken private s_link;

    function setUp() external {
        s_senderHarness = new SenderDeploymentHarness();
        s_receiverHarness = new ReceiverDeploymentHarness();
        s_remoteConfigurationHarness = new RemoteConfigurationHarness();
        s_treasuryHarness = new TreasuryHarness();
        s_router = new MockRouter();
        s_link = new MockLinkToken();
    }

    function test_senderDeploymentReusesMatchingAddress() external {
        NetworkConfigScript.NetworkConfig memory network = _network();

        (EtherdocSender sender, bool deployed) =
            s_senderHarness.deployOrReuse(network, address(this), address(this), address(this), address(this));
        assertTrue(deployed);
        assertEq(sender.getRouter(), address(s_router));
        assertEq(sender.getFeeToken(), address(s_link));

        network.sender = address(sender);
        (EtherdocSender reusedSender, bool redeployed) =
            s_senderHarness.deployOrReuse(network, address(this), address(this), address(this), address(this));
        assertFalse(redeployed);
        assertEq(address(reusedSender), address(sender));
    }

    function test_receiverDeploymentReusesMatchingAddress() external {
        NetworkConfigScript.NetworkConfig memory network = _network();
        NetworkConfigScript.NetworkConfig memory source = _network();
        source.sender = makeAddr("source-sender");

        (EtherdocReceiver receiver, bool deployed) =
            s_receiverHarness.deployOrReuse(network, source, address(this), address(this));
        assertTrue(deployed);
        assertEq(receiver.getRouter(), address(s_router));
        assertEq(receiver.getSourceChainSelector(), source.chainSelector);
        assertEq(receiver.getSourceChainId(), source.chainId);
        assertEq(receiver.getTrustedSender(), source.sender);

        network.receiver = address(receiver);
        (EtherdocReceiver reusedReceiver, bool redeployed) =
            s_receiverHarness.deployOrReuse(network, source, address(this), address(this));
        assertFalse(redeployed);
        assertEq(address(reusedReceiver), address(receiver));
    }

    function test_senderDeploymentRejectsAddressWithDifferentDependencies() external {
        NetworkConfigScript.NetworkConfig memory network = _network();
        (EtherdocSender sender,) =
            s_senderHarness.deployOrReuse(network, address(this), address(this), address(this), address(this));
        network.sender = address(sender);
        network.router = address(new MockRouter());

        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DeploymentDependencyMismatch.selector,
                network.name,
                "EtherdocSender",
                "router",
                network.router,
                address(s_router)
            )
        );
        s_senderHarness.deployOrReuse(network, address(this), address(this), address(this), address(this));
    }

    function test_receiverDeploymentRejectsAddressWithoutCode() external {
        NetworkConfigScript.NetworkConfig memory network = _network();
        NetworkConfigScript.NetworkConfig memory source = _network();
        source.sender = makeAddr("source-sender");
        network.receiver = makeAddr("missing-receiver");

        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.ContractCodeMissing.selector, network.name, "EtherdocReceiver", network.receiver
            )
        );
        s_receiverHarness.deployOrReuse(network, source, address(this), address(this));
    }

    function test_receiverDeploymentRejectsDifferentCanonicalOrigin() external {
        NetworkConfigScript.NetworkConfig memory network = _network();
        NetworkConfigScript.NetworkConfig memory source = _network();
        source.sender = makeAddr("source-sender");
        (EtherdocReceiver receiver,) = s_receiverHarness.deployOrReuse(network, source, address(this), address(this));
        network.receiver = address(receiver);

        source.chainSelector++;
        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DeploymentValueMismatch.selector,
                network.name,
                "EtherdocReceiver",
                "sourceChainSelector",
                source.chainSelector,
                receiver.getSourceChainSelector()
            )
        );
        s_receiverHarness.deployOrReuse(network, source, address(this), address(this));

        source.chainSelector = receiver.getSourceChainSelector();
        source.chainId++;
        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DeploymentValueMismatch.selector,
                network.name,
                "EtherdocReceiver",
                "sourceChainId",
                source.chainId,
                receiver.getSourceChainId()
            )
        );
        s_receiverHarness.deployOrReuse(network, source, address(this), address(this));
    }

    function test_remoteConfigurationDetectsNoOpAndDrift() external {
        NetworkConfigScript.NetworkConfig memory source = _network();
        NetworkConfigScript.NetworkConfig memory destination = _network();
        destination.chainSelector = 2;

        (EtherdocSender sender,) =
            s_senderHarness.deployOrReuse(source, address(this), address(this), address(this), address(this));
        source.sender = address(sender);
        (EtherdocReceiver receiver,) =
            s_receiverHarness.deployOrReuse(destination, source, address(this), address(this));
        destination.receiver = address(receiver);

        assertFalse(s_remoteConfigurationHarness.remoteMatches(sender, destination));
        assertTrue(s_remoteConfigurationHarness.trustedRemoteMatches(receiver, source));

        sender.configureRemote(destination.chainSelector, destination.receiver, destination.gasLimit, true);
        assertTrue(s_remoteConfigurationHarness.remoteMatches(sender, destination));
        assertTrue(s_remoteConfigurationHarness.trustedRemoteMatches(receiver, source));
        s_remoteConfigurationHarness.requireReceiverOrigin(receiver, source, destination);

        destination.gasLimit++;
        assertFalse(s_remoteConfigurationHarness.remoteMatches(sender, destination));

        source.chainSelector++;
        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DeploymentValueMismatch.selector,
                destination.name,
                "EtherdocReceiver",
                "sourceChainSelector",
                source.chainSelector,
                receiver.getSourceChainSelector()
            )
        );
        s_remoteConfigurationHarness.requireReceiverOrigin(receiver, source, destination);

        source.chainSelector = receiver.getSourceChainSelector();
        source.chainId++;
        vm.expectRevert(
            abi.encodeWithSelector(
                NetworkConfigScript.DeploymentValueMismatch.selector,
                destination.name,
                "EtherdocReceiver",
                "sourceChainId",
                source.chainId,
                receiver.getSourceChainId()
            )
        );
        s_remoteConfigurationHarness.requireReceiverOrigin(receiver, source, destination);
    }

    function test_treasuryTargetsAreIdempotent() external view {
        assertEq(s_treasuryHarness.fundingDeficit(25 ether, 100 ether), 75 ether);
        assertEq(s_treasuryHarness.fundingDeficit(100 ether, 100 ether), 0);
        assertEq(s_treasuryHarness.fundingDeficit(125 ether, 100 ether), 0);

        assertEq(s_treasuryHarness.withdrawalExcess(125 ether, 100 ether), 25 ether);
        assertEq(s_treasuryHarness.withdrawalExcess(100 ether, 100 ether), 0);
        assertEq(s_treasuryHarness.withdrawalExcess(75 ether, 100 ether), 0);
    }

    function _network() private view returns (NetworkConfigScript.NetworkConfig memory network) {
        network = NetworkConfigScript.NetworkConfig({
            name: "local",
            chainId: block.chainid,
            chainSelector: 1,
            router: address(s_router),
            linkToken: address(s_link),
            explorer: "http://localhost",
            rpcAlias: "local",
            sender: address(0),
            receiver: address(0),
            gasLimit: 500_000,
            feeMode: NetworkConfigScript.FeeMode.LINK,
            governanceMode: NetworkConfigScript.GovernanceMode.DIRECT,
            production: false,
            directoryVerifiedAt: 1
        });
    }
}
