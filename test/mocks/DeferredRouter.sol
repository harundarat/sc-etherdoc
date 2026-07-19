// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

contract DeferredRouter is IRouterClient {
    enum ExecutionState {
        UNTOUCHED,
        SUCCESS,
        FAILURE
    }

    struct QueuedMessage {
        address receiver;
        address sender;
        bytes data;
        bool exists;
    }

    uint64 public constant SOURCE_CHAIN_SELECTOR = 99;
    uint256 public constant FEE = 1 ether;

    uint256 private s_nonce;
    mapping(bytes32 messageId => QueuedMessage message) private s_messages;
    mapping(bytes32 messageId => ExecutionState state) private s_executionStates;
    mapping(bytes32 messageId => bytes returnData) private s_executionReturnData;

    event ExecutionAttempted(bytes32 indexed messageId, ExecutionState state, bytes returnData);

    function isChainSupported(uint64) external pure returns (bool supported) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256 fee) {
        return FEE;
    }

    function ccipSend(uint64 _destinationChainSelector, Client.EVM2AnyMessage calldata _message)
        external
        payable
        returns (bytes32 messageId)
    {
        s_nonce++;
        messageId = keccak256(abi.encode(_destinationChainSelector, msg.sender, _message.receiver, s_nonce));
        s_messages[messageId] = QueuedMessage({
            receiver: abi.decode(_message.receiver, (address)), sender: msg.sender, data: _message.data, exists: true
        });
    }

    function deliver(bytes32 _messageId) external {
        _deliverAs(_messageId, SOURCE_CHAIN_SELECTOR, s_messages[_messageId].sender);
    }

    function deliverAs(bytes32 _messageId, uint64 _sourceChainSelector, address _sender) external {
        _deliverAs(_messageId, _sourceChainSelector, _sender);
    }

    function execute(bytes32 _messageId) external returns (bool success, bytes memory returnData) {
        QueuedMessage storage queuedMessage = s_messages[_messageId];
        require(queuedMessage.exists, "message not queued");

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(queuedMessage.sender),
            data: queuedMessage.data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        (success, returnData) =
            queuedMessage.receiver.call(abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (message)));
        ExecutionState state = success ? ExecutionState.SUCCESS : ExecutionState.FAILURE;
        s_executionStates[_messageId] = state;
        s_executionReturnData[_messageId] = returnData;
        emit ExecutionAttempted(_messageId, state, returnData);
    }

    function deliverRaw(
        address _receiver,
        bytes32 _messageId,
        uint64 _sourceChainSelector,
        address _sender,
        bytes calldata _data
    ) external {
        _deliverRaw(_receiver, _messageId, _sourceChainSelector, abi.encode(_sender), _data);
    }

    function deliverRawSender(
        address _receiver,
        bytes32 _messageId,
        uint64 _sourceChainSelector,
        bytes calldata _sender,
        bytes calldata _data
    ) external {
        _deliverRaw(_receiver, _messageId, _sourceChainSelector, _sender, _data);
    }

    function getData(bytes32 _messageId) external view returns (bytes memory) {
        return s_messages[_messageId].data;
    }

    function getExecutionState(bytes32 _messageId) external view returns (ExecutionState) {
        return s_executionStates[_messageId];
    }

    function getExecutionReturnData(bytes32 _messageId) external view returns (bytes memory) {
        return s_executionReturnData[_messageId];
    }

    function _deliverAs(bytes32 _messageId, uint64 _sourceChainSelector, address _sender) private {
        QueuedMessage storage queuedMessage = s_messages[_messageId];
        require(queuedMessage.exists, "message not queued");
        _deliverRaw(queuedMessage.receiver, _messageId, _sourceChainSelector, abi.encode(_sender), queuedMessage.data);
    }

    function _deliverRaw(
        address _receiver,
        bytes32 _messageId,
        uint64 _sourceChainSelector,
        bytes memory _sender,
        bytes memory _data
    ) private {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: _sourceChainSelector,
            sender: _sender,
            data: _data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        IAny2EVMMessageReceiver(_receiver).ccipReceive(message);
    }
}
