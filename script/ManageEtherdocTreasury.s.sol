// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/utils/SafeERC20.sol";
import {EtherdocSender} from "../src/EtherdocSender.sol";
import {NetworkConfigScript} from "./NetworkConfig.s.sol";

contract ManageEtherdocTreasuryScript is NetworkConfigScript {
    using SafeERC20 for IERC20;

    error UnsupportedTreasuryAction(string action);

    function run() public {
        NetworkConfig memory network = _loadNetwork(vm.envString("NETWORK"));
        _validateCurrentNetwork(network, true);
        _requireDeployment(network.sender, network.name, "EtherdocSender");
        _requireLocalCode(network, "EtherdocSender", network.sender);

        string memory action = vm.envString("TREASURY_ACTION");
        bytes32 actionHash = keccak256(bytes(action));
        if (actionHash == keccak256("FUND")) {
            _fund(network);
            return;
        }
        if (actionHash == keccak256("WITHDRAW")) {
            _withdraw(network);
            return;
        }
        revert UnsupportedTreasuryAction(action);
    }

    function _fund(NetworkConfig memory _network) private {
        IERC20 link = IERC20(_network.linkToken);
        uint256 currentBalance = link.balanceOf(_network.sender);
        uint256 targetBalance = vm.envUint("TARGET_LINK_BALANCE");
        uint256 amount = _fundingDeficit(currentBalance, targetBalance);
        if (amount == 0) {
            console.log("EtherdocSender LINK balance already meets target; no transaction created");
            return;
        }

        vm.startBroadcast();
        link.safeTransfer(_network.sender, amount);
        vm.stopBroadcast();

        console.log("Funded EtherdocSender:", _network.sender);
        console.log("LINK amount:", amount);
        console.log("Target LINK balance:", targetBalance);
    }

    function _withdraw(NetworkConfig memory _network) private {
        IERC20 link = IERC20(_network.linkToken);
        uint256 currentBalance = link.balanceOf(_network.sender);
        uint256 retainedBalance = vm.envUint("RETAIN_LINK_BALANCE");
        uint256 amount = _withdrawalExcess(currentBalance, retainedBalance);
        if (amount == 0) {
            console.log("EtherdocSender LINK balance does not exceed retention target; no transaction created");
            return;
        }

        address treasury = vm.envAddress("TREASURY");
        EtherdocSender sender = EtherdocSender(_network.sender);
        if (_network.governanceMode == GovernanceMode.DIRECT) {
            _requireDirectGovernance(_network);
            vm.startBroadcast();
            sender.withdrawToken(_network.linkToken, treasury, amount);
            vm.stopBroadcast();
        } else {
            bytes memory callData = abi.encodeCall(EtherdocSender.withdrawToken, (_network.linkToken, treasury, amount));
            (string memory path, bool written) = _persistMultisigProposal(
                _network,
                sender.owner(),
                address(sender),
                callData,
                "withdraw-excess-link",
                "Withdraw excess LINK from EtherdocSender"
            );
            console.log(written ? "Multisig proposal written:" : "Multisig proposal already current:", path);
        }

        console.log("EtherdocSender:", _network.sender);
        console.log("Treasury:", treasury);
        console.log("LINK withdrawal amount:", amount);
        console.log("Retained LINK balance:", retainedBalance);
    }

    function _fundingDeficit(uint256 _currentBalance, uint256 _targetBalance) internal pure returns (uint256) {
        return _currentBalance < _targetBalance ? _targetBalance - _currentBalance : 0;
    }

    function _withdrawalExcess(uint256 _currentBalance, uint256 _retainedBalance) internal pure returns (uint256) {
        return _currentBalance > _retainedBalance ? _currentBalance - _retainedBalance : 0;
    }
}
