// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";

contract EtherdocReceiver is CCIPReceiver, OwnerIsCreator {
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted();

    event MessageReceived(
        bytes32 indexed messageId, uint64 indexed sourceChainSelector, address sender, string documentCID
    );

    mapping(string documentCID => bool exists) private s_documents;
    mapping(uint64 sourceChainSelector => bool allowlisted) private s_allowlistedSourceChains;
    mapping(address sender => bool allowlisted) private s_allowlistedSenders;

    constructor(address _router) CCIPReceiver(_router) {}

    function allowlistSender(address _sender, bool _allowlisted) external onlyOwner {
        s_allowlistedSenders[_sender] = _allowlisted;
    }

    function allowListSourceChain(uint64 _sourceChainSelector, bool _allowlisted) external onlyOwner {
        s_allowlistedSourceChains[_sourceChainSelector] = _allowlisted;
    }

    /**
     * @dev Internal function to handle incoming CCIP messages
     * @notice This function validates the source chain and sender, then stores the received document
     * @param message The CCIP message containing document data from another chain
     *
     * Requirements:
     * - Source chain must be allowlisted
     * - Sender address must be allowlisted
     *
     * @custom:security Only processes messages from verified sources
     * @custom:storage Updates s_documents mapping with received document identifier
     *
     * Emits:
     * - MessageReceived event with message details
     *
     * Reverts:
     * - SourceChainNotAllowlisted if source chain is not in allowlist
     * - SenderNotAllowlisted if sender is not in allowlist
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual override {
        if (!s_allowlistedSourceChains[message.sourceChainSelector]) {
            revert SourceChainNotAllowlisted(message.sourceChainSelector);
        }
        if (!s_allowlistedSenders[abi.decode(message.sender, (address))]) {
            revert SenderNotAllowlisted();
        }

        s_documents[abi.decode(message.data, (string))] = true;

        emit MessageReceived(
            message.messageId,
            message.sourceChainSelector,
            abi.decode(message.sender, (address)),
            abi.decode(message.data, (string))
        );
    }

    function documentExists(string calldata _documentCID) external view returns (bool) {
        return s_documents[_documentCID];
    }
}
