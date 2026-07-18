// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract EtherdocSender is OwnerIsCreator {
    enum DocumentStatus {
        NOT_REGISTERED,
        REGISTERED
    }

    enum DispatchStatus {
        NOT_DISPATCHED,
        DISPATCHED
    }

    struct DocumentRecord {
        string documentCID;
        uint64 registeredAt;
        DocumentStatus status;
    }

    struct DispatchRecord {
        bytes32 messageId;
        uint64 destinationChainSelector;
        address receiver;
        uint64 sentAt;
        DispatchStatus status;
    }

    struct DestinationConfig {
        address receiver;
        bool allowlisted;
    }

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error InvalidDocumentCID();
    error DocumentAlreadyRegistered(bytes32 documentId);
    error DocumentNotRegistered(bytes32 documentId);
    error DocumentAlreadyDispatched(bytes32 documentId, uint64 destinationChainSelector);
    error InvalidReceiverAddress();
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);

    event DocumentRegistered(bytes32 indexed documentId, string documentCID, uint64 registeredAt);
    event DestinationChainConfigured(
        uint64 indexed destinationChainSelector, address indexed receiver, bool allowlisted
    );
    event MessageSent(
        bytes32 indexed messageId,
        bytes32 indexed documentId,
        uint64 indexed destinationChainSelector,
        address receiver,
        string documentCID,
        address feeToken,
        uint256 fees
    );

    IRouterClient private immutable i_router;
    LinkTokenInterface private immutable i_linkToken;
    mapping(bytes32 documentId => DocumentRecord document) private s_documents;
    mapping(bytes32 documentId => mapping(uint64 destinationChainSelector => DispatchRecord dispatchRecord)) private
        s_dispatches;
    mapping(uint64 destinationChainSelector => DestinationConfig config) private s_destinations;

    constructor(address _router, address _link) {
        i_router = IRouterClient(_router);
        i_linkToken = LinkTokenInterface(_link);
    }

    /**
     * @notice Registers a canonical document without dispatching it cross-chain.
     * @param _documentCID The Content Identifier (CID) of the document.
     * @return documentId The deterministic identifier derived from the CID.
     */
    function registerDocument(string calldata _documentCID) external onlyOwner returns (bytes32 documentId) {
        if (bytes(_documentCID).length == 0) {
            revert InvalidDocumentCID();
        }

        documentId = keccak256(bytes(_documentCID));
        if (s_documents[documentId].status == DocumentStatus.REGISTERED) {
            revert DocumentAlreadyRegistered(documentId);
        }

        uint64 registeredAt = uint64(block.timestamp);
        s_documents[documentId] =
            DocumentRecord({documentCID: _documentCID, registeredAt: registeredAt, status: DocumentStatus.REGISTERED});

        emit DocumentRegistered(documentId, _documentCID, registeredAt);
    }

    /**
     * @notice Dispatches a registered document to one configured destination lane.
     * @dev A failed router call reverts without creating a dispatch record, so the same lane can be
     *      retried. A successful lane cannot be dispatched again through this function.
     * @param _documentId The canonical document identifier returned by registerDocument.
     * @param _destinationChainSelector The CCIP selector of the destination lane.
     * @return messageId The unique identifier of the accepted CCIP message.
     */
    function dispatchDocument(bytes32 _documentId, uint64 _destinationChainSelector)
        external
        onlyOwner
        returns (bytes32 messageId)
    {
        DestinationConfig memory destination = s_destinations[_destinationChainSelector];
        if (!destination.allowlisted) {
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        }

        DocumentRecord storage document = s_documents[_documentId];
        if (document.status != DocumentStatus.REGISTERED) {
            revert DocumentNotRegistered(_documentId);
        }

        if (s_dispatches[_documentId][_destinationChainSelector].status == DispatchStatus.DISPATCHED) {
            revert DocumentAlreadyDispatched(_documentId, _destinationChainSelector);
        }

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destination.receiver),
            data: abi.encode(document.documentCID),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})
            ),
            feeToken: address(i_linkToken)
        });

        uint256 fees = i_router.getFee(_destinationChainSelector, evm2AnyMessage);
        uint256 linkBalance = i_linkToken.balanceOf(address(this));
        if (fees > linkBalance) {
            revert NotEnoughBalance(linkBalance, fees);
        }

        i_linkToken.approve(address(i_router), fees);
        messageId = i_router.ccipSend(_destinationChainSelector, evm2AnyMessage);

        uint64 sentAt = uint64(block.timestamp);
        s_dispatches[_documentId][_destinationChainSelector] = DispatchRecord({
            messageId: messageId,
            destinationChainSelector: _destinationChainSelector,
            receiver: destination.receiver,
            sentAt: sentAt,
            status: DispatchStatus.DISPATCHED
        });

        emit MessageSent(
            messageId,
            _documentId,
            _destinationChainSelector,
            destination.receiver,
            document.documentCID,
            address(i_linkToken),
            fees
        );
    }

    function configureDestinationChain(uint64 _destinationChainSelector, address _receiver, bool _allowlisted)
        external
        onlyOwner
    {
        if (_receiver == address(0)) {
            revert InvalidReceiverAddress();
        }

        s_destinations[_destinationChainSelector] = DestinationConfig({receiver: _receiver, allowlisted: _allowlisted});

        emit DestinationChainConfigured(_destinationChainSelector, _receiver, _allowlisted);
    }

    function getDocument(bytes32 _documentId) external view returns (DocumentRecord memory) {
        return s_documents[_documentId];
    }

    function getDispatch(bytes32 _documentId, uint64 _destinationChainSelector)
        external
        view
        returns (DispatchRecord memory)
    {
        return s_dispatches[_documentId][_destinationChainSelector];
    }

    function getDestinationConfig(uint64 _destinationChainSelector) external view returns (DestinationConfig memory) {
        return s_destinations[_destinationChainSelector];
    }

    function isDocumentRegistered(bytes32 _documentId) external view returns (bool) {
        return s_documents[_documentId].status == DocumentStatus.REGISTERED;
    }
}
