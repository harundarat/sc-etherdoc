// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";

contract MockRouter is IRouterClient {
    error SimulatedLaneFailure(uint64 destinationChainSelector);
    error SimulatedQuoteFailure(uint64 destinationChainSelector);

    uint256 public constant FEE = 1 ether;
    uint256 private s_fee = FEE;
    uint256 private s_nonce;
    mapping(uint64 destinationChainSelector => bool shouldFail) private s_failingLanes;
    mapping(uint64 destinationChainSelector => bool shouldFail) private s_failingQuotes;
    mapping(uint64 destinationChainSelector => address receiver) private s_lastReceivers;
    mapping(uint64 destinationChainSelector => uint32 gasLimit) private s_lastGasLimits;
    mapping(uint64 destinationChainSelector => bytes4 finalityConfig) private s_lastFinalityConfigs;
    mapping(uint64 destinationChainSelector => uint256 ccvCount) private s_lastCCVCounts;
    mapping(uint64 destinationChainSelector => address executor) private s_lastExecutors;
    address private s_reentryTarget;
    bytes private s_reentryCalldata;
    bool private s_lastReentrySucceeded;
    bytes private s_lastReentryReturnData;

    function setLaneFailure(uint64 _destinationChainSelector, bool _shouldFail) external {
        s_failingLanes[_destinationChainSelector] = _shouldFail;
    }

    function setQuoteFailure(uint64 _destinationChainSelector, bool _shouldFail) external {
        s_failingQuotes[_destinationChainSelector] = _shouldFail;
    }

    function setFee(uint256 _fee) external {
        s_fee = _fee;
    }

    function configureReentry(address _target, bytes calldata _calldata) external {
        s_reentryTarget = _target;
        s_reentryCalldata = _calldata;
    }

    function isChainSupported(uint64) external pure returns (bool supported) {
        return true;
    }

    function getFee(uint64 _destinationChainSelector, Client.EVM2AnyMessage memory)
        external
        view
        returns (uint256 fee)
    {
        if (s_failingQuotes[_destinationChainSelector]) {
            revert SimulatedQuoteFailure(_destinationChainSelector);
        }
        return s_fee;
    }

    function ccipSend(uint64 _destinationChainSelector, Client.EVM2AnyMessage calldata _message)
        external
        payable
        returns (bytes32 messageId)
    {
        if (s_failingLanes[_destinationChainSelector]) {
            revert SimulatedLaneFailure(_destinationChainSelector);
        }

        ExtraArgsCodec.GenericExtraArgsV3 memory extraArgs =
            ExtraArgsCodec._decodeGenericExtraArgsV3(_message.extraArgs);
        s_lastReceivers[_destinationChainSelector] = abi.decode(_message.receiver, (address));
        s_lastGasLimits[_destinationChainSelector] = extraArgs.gasLimit;
        s_lastFinalityConfigs[_destinationChainSelector] = extraArgs.requestedFinalityConfig;
        s_lastCCVCounts[_destinationChainSelector] = extraArgs.ccvs.length;
        s_lastExecutors[_destinationChainSelector] = extraArgs.executor;

        if (s_reentryTarget != address(0)) {
            address target = s_reentryTarget;
            bytes memory callData = s_reentryCalldata;
            s_reentryTarget = address(0);
            (s_lastReentrySucceeded, s_lastReentryReturnData) = target.call(callData);
        }

        s_nonce++;
        return keccak256(abi.encode(_destinationChainSelector, _message.receiver, _message.data, s_nonce));
    }

    function lastReceiver(uint64 _destinationChainSelector) external view returns (address) {
        return s_lastReceivers[_destinationChainSelector];
    }

    function lastGasLimit(uint64 _destinationChainSelector) external view returns (uint32) {
        return s_lastGasLimits[_destinationChainSelector];
    }

    function lastFinalityConfig(uint64 _destinationChainSelector) external view returns (bytes4) {
        return s_lastFinalityConfigs[_destinationChainSelector];
    }

    function lastCCVCount(uint64 _destinationChainSelector) external view returns (uint256) {
        return s_lastCCVCounts[_destinationChainSelector];
    }

    function lastExecutor(uint64 _destinationChainSelector) external view returns (address) {
        return s_lastExecutors[_destinationChainSelector];
    }

    function lastReentryResult() external view returns (bool succeeded, bytes memory returnData) {
        return (s_lastReentrySucceeded, s_lastReentryReturnData);
    }
}
