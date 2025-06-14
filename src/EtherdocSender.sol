// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract EtherdocSender is OwnerIsCreator {
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DocumentAlreadyExists(string documentCID);
    error InvalidReceiverAddress();
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        string documentCID,
        address feeToken,
        uint256 fees
    );

    IRouterClient private s_router;
    LinkTokenInterface private s_linkToken;
    mapping(string documentCID => bool exists) private s_documents;
    mapping(uint64 destinationChainSelector => bool) private s_allowlistedDestinationChains;

    constructor(address _router, address _link) {
        s_router = IRouterClient(_router);
        s_linkToken = LinkTokenInterface(_link);
    }

    /**
     * @notice Adds a new document and sends it to a destination chain via CCIP
     * @dev This function validates the destination chain, receiver address, and document uniqueness
     *      before creating and sending a cross-chain message. The function requires LINK tokens
     *      for paying CCIP fees.
     * @param _destinationChainSelector The CCIP chain selector for the target blockchain
     * @param _receiver The address on the destination chain that will receive the document
     * @param _documentCID The Content Identifier (CID) of the document to be added and sent
     * @return messageId The unique identifier of the CCIP message sent
     * @custom:requirements
     * - Caller must be the contract owner
     * - Destination chain must be allowlisted
     * - Receiver address cannot be zero address
     * - Document CID must not already exist
     * - Contract must have sufficient LINK token balance for fees
     * @custom:emits MessageSent event with message details including fees paid
     * @custom:reverts DestinationChainNotAllowlisted if chain is not allowlisted
     * @custom:reverts InvalidReceiverAddress if receiver is zero address
     * @custom:reverts DocumentAlreadyExists if document CID already exists
     * @custom:reverts NotEnoughBalance if insufficient LINK tokens for fees
     */
    function addDocument(uint64 _destinationChainSelector, address _receiver, string calldata _documentCID)
        external
        onlyOwner
        returns (bytes32 messageId)
    {
        if (!s_allowlistedDestinationChains[_destinationChainSelector]) {
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        }
        if (_receiver == address(0)) {
            revert InvalidReceiverAddress();
        }
        if (s_documents[_documentCID]) {
            revert DocumentAlreadyExists(_documentCID);
        }

        s_documents[_documentCID] = true;

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(_documentCID),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})),
            feeToken: address(s_linkToken)
        });

        uint256 fees = s_router.getFee(_destinationChainSelector, evm2AnyMessage);
        if (fees > s_linkToken.balanceOf(address(this))) {
            revert NotEnoughBalance(s_linkToken.balanceOf(address(this)), fees);
        }

        s_linkToken.approve(address(s_router), fees);

        messageId = s_router.ccipSend(_destinationChainSelector, evm2AnyMessage);

        emit MessageSent(messageId, _destinationChainSelector, _receiver, _documentCID, address(s_linkToken), fees);

        return messageId;
    }

    function allowlistDestinationChain(uint64 _destinationChainSelector, bool _allowlisted) external onlyOwner {
        s_allowlistedDestinationChains[_destinationChainSelector] = _allowlisted;
    }

    function documentExists(string calldata _documentCID) external view returns (bool) {
        return s_documents[_documentCID];
    }
}
