// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {
    IERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    EIP712
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/utils/cryptography/EIP712.sol";
import {
    ECDSA
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import {EtherdocTypes} from "./EtherdocTypes.sol";

contract EtherdocSender is OwnerIsCreator, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTER_DOCUMENT_TYPEHASH = keccak256(
        "RegisterDocument(address issuer,bytes32 documentId,bytes32 contentCommitment,bytes32 metadataCommitment,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant REVOKE_DOCUMENT_TYPEHASH = keccak256(
        "RevokeDocument(address issuer,bytes32 documentId,uint64 currentVersion,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SUPERSEDE_DOCUMENT_TYPEHASH = keccak256(
        "SupersedeDocument(address issuer,bytes32 oldDocumentId,uint64 currentVersion,bytes32 newDocumentId,bytes32 newContentCommitment,bytes32 metadataCommitment,uint256 nonce,uint256 deadline)"
    );

    enum DispatchStatus {
        NOT_DISPATCHED,
        DISPATCHED
    }

    struct DispatchRecord {
        bytes32 messageId;
        uint64 destinationChainSelector;
        address receiver;
        uint64 sentAt;
        uint64 documentVersion;
        uint256 gasLimit;
        DispatchStatus status;
    }

    struct RemoteConfig {
        address receiver;
        uint256 gasLimit;
        bool allowlisted;
    }

    struct SupersedeAuthorization {
        address issuer;
        bytes32 oldDocumentId;
        uint64 currentVersion;
        bytes32 newDocumentId;
        bytes32 newContentCommitment;
        bytes32 metadataCommitment;
        uint256 nonce;
        uint256 deadline;
    }

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error InvalidDocumentCID();
    error DocumentCIDTooLong(uint256 actualLength, uint256 maximumLength);
    error PayloadTooLarge(uint256 actualLength, uint256 maximumLength);
    error InvalidIssuerAddress();
    error IssuerNotAuthorized(address issuer);
    error CallerNotDocumentIssuer(address caller, address issuer);
    error SignatureExpired(uint256 deadline);
    error InvalidIssuerSignature(address expectedIssuer, address recoveredSigner);
    error DocumentAlreadyRegistered(bytes32 documentId);
    error DocumentNotRegistered(bytes32 documentId);
    error DocumentNotActive(bytes32 documentId);
    error DocumentAlreadyDispatched(bytes32 documentId, uint64 destinationChainSelector, uint64 documentVersion);
    error InvalidDestinationChainSelector(uint64 destinationChainSelector);
    error InvalidReceiverAddress();
    error InvalidGasLimit(uint256 gasLimit);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error FeeExceedsMaximum(uint256 calculatedFees, uint256 maximumFee);
    error InvalidTokenAddress();
    error InvalidWithdrawalRecipient();

    event IssuerAuthorizationUpdated(address indexed issuer, bool authorized);
    event DocumentRegistered(
        bytes32 indexed documentId,
        bytes32 indexed contentCommitment,
        address indexed issuer,
        string documentCID,
        bytes32 metadataCommitment,
        uint256 sourceChainId,
        uint64 registeredAt,
        uint16 schemaVersion
    );
    event DocumentStatusChanged(
        bytes32 indexed documentId,
        address indexed issuer,
        EtherdocTypes.DocumentStatus status,
        uint64 version,
        bytes32 relatedDocumentId,
        uint64 updatedAt
    );
    event RemoteConfigUpdated(
        uint64 indexed destinationChainSelector, address indexed receiver, uint256 gasLimit, bool allowlisted
    );
    event TokenWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event MessageSent(
        bytes32 indexed messageId,
        bytes32 indexed documentId,
        uint64 indexed destinationChainSelector,
        address receiver,
        string documentCID,
        uint64 documentVersion,
        EtherdocTypes.DocumentStatus documentStatus,
        uint256 gasLimit,
        address feeToken,
        uint256 fees
    );

    IRouterClient private immutable i_router;
    IERC20 private immutable i_linkToken;
    mapping(bytes32 documentId => EtherdocTypes.DocumentRecord document) private s_documents;
    mapping(
        bytes32 documentId
            => mapping(
            uint64 destinationChainSelector => mapping(uint64 documentVersion => DispatchRecord dispatchRecord)
        )
    ) private s_dispatches;
    mapping(uint64 destinationChainSelector => RemoteConfig config) private s_remotes;
    mapping(address issuer => bool authorized) private s_authorizedIssuers;
    mapping(address issuer => uint256 nonce) private s_issuerNonces;

    constructor(address _router, address _link) EIP712("Etherdoc", "1") {
        i_router = IRouterClient(_router);
        i_linkToken = IERC20(_link);
        s_authorizedIssuers[msg.sender] = true;
        emit IssuerAuthorizationUpdated(msg.sender, true);
    }

    /**
     * @notice Registers a canonical document issued directly by the caller.
     * @param _documentCID The Content Identifier (CID) of the document.
     * @return documentId The deterministic identifier derived from issuer and CID commitment.
     */
    function registerDocument(string calldata _documentCID) external returns (bytes32 documentId) {
        return _registerDocument(_documentCID, bytes32(0), msg.sender);
    }

    /**
     * @notice Registers a canonical document with an optional non-PII metadata commitment.
     */
    function registerDocument(string calldata _documentCID, bytes32 _metadataCommitment)
        external
        returns (bytes32 documentId)
    {
        return _registerDocument(_documentCID, _metadataCommitment, msg.sender);
    }

    /**
     * @notice Lets a relayer register a document while preserving the EIP-712 signer's provenance.
     */
    function registerDocumentBySig(
        string calldata _documentCID,
        bytes32 _metadataCommitment,
        address _issuer,
        uint256 _deadline,
        bytes calldata _signature
    ) external returns (bytes32 documentId) {
        bytes32 commitment = EtherdocTypes.contentCommitment(_documentCID);
        documentId = EtherdocTypes.documentId(_issuer, commitment);
        uint256 nonce = s_issuerNonces[_issuer];
        bytes32 structHash = keccak256(
            abi.encode(
                REGISTER_DOCUMENT_TYPEHASH, _issuer, documentId, commitment, _metadataCommitment, nonce, _deadline
            )
        );
        _validateAndConsumeSignature(_issuer, _deadline, structHash, _signature);
        return _registerDocument(_documentCID, _metadataCommitment, _issuer);
    }

    /**
     * @notice Revokes an active document without deleting its provenance.
     */
    function revokeDocument(bytes32 _documentId) external {
        _revokeDocument(_documentId, msg.sender);
    }

    /**
     * @notice Lets a relayer revoke a document authorized by its issuer.
     */
    function revokeDocumentBySig(bytes32 _documentId, address _issuer, uint256 _deadline, bytes calldata _signature)
        external
    {
        EtherdocTypes.DocumentRecord storage document = s_documents[_documentId];
        bytes32 structHash = keccak256(
            abi.encode(
                REVOKE_DOCUMENT_TYPEHASH, _issuer, _documentId, document.version, s_issuerNonces[_issuer], _deadline
            )
        );
        _validateAndConsumeSignature(_issuer, _deadline, structHash, _signature);
        _revokeDocument(_documentId, _issuer);
    }

    /**
     * @notice Supersedes an active record with a new CID while retaining both records.
     */
    function supersedeDocument(bytes32 _oldDocumentId, string calldata _newDocumentCID, bytes32 _metadataCommitment)
        external
        returns (bytes32 newDocumentId)
    {
        return _supersedeDocument(_oldDocumentId, _newDocumentCID, _metadataCommitment, msg.sender);
    }

    /**
     * @notice Lets a relayer supersede a record authorized by its issuer.
     */
    function supersedeDocumentBySig(
        bytes32 _oldDocumentId,
        string calldata _newDocumentCID,
        bytes32 _metadataCommitment,
        address _issuer,
        uint256 _deadline,
        bytes calldata _signature
    ) external returns (bytes32 newDocumentId) {
        bytes32 newCommitment = EtherdocTypes.contentCommitment(_newDocumentCID);
        newDocumentId = EtherdocTypes.documentId(_issuer, newCommitment);
        EtherdocTypes.DocumentRecord storage oldDocument = s_documents[_oldDocumentId];
        SupersedeAuthorization memory authorization = SupersedeAuthorization({
            issuer: _issuer,
            oldDocumentId: _oldDocumentId,
            currentVersion: oldDocument.version,
            newDocumentId: newDocumentId,
            newContentCommitment: newCommitment,
            metadataCommitment: _metadataCommitment,
            nonce: s_issuerNonces[_issuer],
            deadline: _deadline
        });
        bytes32 structHash = _supersedeStructHash(authorization);
        _validateAndConsumeSignature(_issuer, _deadline, structHash, _signature);
        return _supersedeDocument(_oldDocumentId, _newDocumentCID, _metadataCommitment, _issuer);
    }

    /**
     * @notice Dispatches a registered document to one configured destination lane.
     * @dev A failed router call reverts without creating a dispatch record, so the same lane can be
     *      retried. A successful lane cannot be dispatched again through this function.
     * @param _documentId The canonical document identifier returned by registerDocument.
     * @param _destinationChainSelector The CCIP selector of the destination lane.
     * @param _maximumFee The largest LINK fee the caller permits for this transaction.
     * @return messageId The unique identifier of the accepted CCIP message.
     */
    function dispatchDocument(bytes32 _documentId, uint64 _destinationChainSelector, uint256 _maximumFee)
        external
        onlyOwner
        returns (bytes32 messageId)
    {
        RemoteConfig memory remote = s_remotes[_destinationChainSelector];
        if (!remote.allowlisted) {
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        }

        EtherdocTypes.DocumentRecord storage document = s_documents[_documentId];
        if (document.status == EtherdocTypes.DocumentStatus.UNKNOWN) {
            revert DocumentNotRegistered(_documentId);
        }

        DispatchRecord storage existingDispatch = s_dispatches[_documentId][_destinationChainSelector][document.version];
        if (existingDispatch.status == DispatchStatus.DISPATCHED) {
            revert DocumentAlreadyDispatched(_documentId, _destinationChainSelector, document.version);
        }

        EtherdocTypes.DocumentRecord memory documentSnapshot = document;
        EtherdocTypes.Operation operation = EtherdocTypes.operationFor(documentSnapshot.status);
        uint256 fees;
        (messageId, fees) = _sendMessage(_destinationChainSelector, remote, documentSnapshot, operation, _maximumFee);

        uint64 sentAt = uint64(block.timestamp);
        s_dispatches[_documentId][_destinationChainSelector][document.version] = DispatchRecord({
            messageId: messageId,
            destinationChainSelector: _destinationChainSelector,
            receiver: remote.receiver,
            sentAt: sentAt,
            documentVersion: document.version,
            gasLimit: remote.gasLimit,
            status: DispatchStatus.DISPATCHED
        });

        emit MessageSent(
            messageId,
            _documentId,
            _destinationChainSelector,
            remote.receiver,
            document.documentCID,
            document.version,
            document.status,
            remote.gasLimit,
            address(i_linkToken),
            fees
        );
    }

    function _sendMessage(
        uint64 _destinationChainSelector,
        RemoteConfig memory _remote,
        EtherdocTypes.DocumentRecord memory _document,
        EtherdocTypes.Operation _operation,
        uint256 _maximumFee
    ) private returns (bytes32 messageId, uint256 fees) {
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildMessage(_remote, _document, _operation);

        fees = i_router.getFee(_destinationChainSelector, evm2AnyMessage);
        if (fees > _maximumFee) {
            revert FeeExceedsMaximum(fees, _maximumFee);
        }
        uint256 linkBalance = i_linkToken.balanceOf(address(this));
        if (fees > linkBalance) {
            revert NotEnoughBalance(linkBalance, fees);
        }

        i_linkToken.forceApprove(address(i_router), fees);
        messageId = i_router.ccipSend(_destinationChainSelector, evm2AnyMessage);
    }

    function _buildMessage(
        RemoteConfig memory _remote,
        EtherdocTypes.DocumentRecord memory _document,
        EtherdocTypes.Operation _operation
    ) private view returns (Client.EVM2AnyMessage memory evm2AnyMessage) {
        EtherdocTypes.DocumentPayload memory payload = EtherdocTypes.DocumentPayload({
            schemaVersion: EtherdocTypes.SCHEMA_VERSION,
            operation: _operation,
            documentId: _document.documentId,
            documentVersion: _document.version,
            document: _document
        });
        bytes memory encodedPayload = abi.encode(payload);
        if (encodedPayload.length > EtherdocTypes.MAX_PAYLOAD_LENGTH) {
            revert PayloadTooLarge(encodedPayload.length, EtherdocTypes.MAX_PAYLOAD_LENGTH);
        }

        evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_remote.receiver),
            data: encodedPayload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: _remote.gasLimit, allowOutOfOrderExecution: true})
            ),
            feeToken: address(i_linkToken)
        });
    }

    /**
     * @notice Atomically configures the receiver and execution gas for one destination selector.
     * @dev Destination bytecode cannot be inspected from the source chain. The deployment script
     *      validates the remote receiver code at configuration time.
     */
    function configureRemote(uint64 _destinationChainSelector, address _receiver, uint256 _gasLimit, bool _allowlisted)
        external
        onlyOwner
    {
        if (_destinationChainSelector == 0) {
            revert InvalidDestinationChainSelector(_destinationChainSelector);
        }
        if (_receiver == address(0)) {
            revert InvalidReceiverAddress();
        }
        if (_gasLimit == 0) {
            revert InvalidGasLimit(_gasLimit);
        }

        s_remotes[_destinationChainSelector] =
            RemoteConfig({receiver: _receiver, gasLimit: _gasLimit, allowlisted: _allowlisted});

        emit RemoteConfigUpdated(_destinationChainSelector, _receiver, _gasLimit, _allowlisted);
    }

    function setIssuerAuthorization(address _issuer, bool _authorized) external onlyOwner {
        if (_issuer == address(0)) {
            revert InvalidIssuerAddress();
        }
        s_authorizedIssuers[_issuer] = _authorized;
        emit IssuerAuthorizationUpdated(_issuer, _authorized);
    }

    /**
     * @notice Quotes the current LINK fee for a document and configured destination.
     * @dev The Router can return a different fee when dispatchDocument is mined. Callers must set
     *      their acceptable upper bound through dispatchDocument's maximumFee argument.
     */
    function quoteFee(bytes32 _documentId, uint64 _destinationChainSelector) external view returns (uint256 fee) {
        RemoteConfig memory remote = s_remotes[_destinationChainSelector];
        if (!remote.allowlisted) {
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        }

        EtherdocTypes.DocumentRecord memory document = s_documents[_documentId];
        if (document.status == EtherdocTypes.DocumentStatus.UNKNOWN) {
            revert DocumentNotRegistered(_documentId);
        }

        Client.EVM2AnyMessage memory message =
            _buildMessage(remote, document, EtherdocTypes.operationFor(document.status));
        return i_router.getFee(_destinationChainSelector, message);
    }

    /**
     * @notice Rescues ERC-20 funds from this contract to an owner-selected recipient.
     */
    function withdrawToken(address _token, address _recipient, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            revert InvalidTokenAddress();
        }
        if (_recipient == address(0)) {
            revert InvalidWithdrawalRecipient();
        }

        IERC20(_token).safeTransfer(_recipient, _amount);
        emit TokenWithdrawn(_token, _recipient, _amount);
    }

    function getDocument(bytes32 _documentId) external view returns (EtherdocTypes.DocumentRecord memory) {
        return s_documents[_documentId];
    }

    function getDispatch(bytes32 _documentId, uint64 _destinationChainSelector)
        external
        view
        returns (DispatchRecord memory)
    {
        uint64 currentVersion = s_documents[_documentId].version;
        return s_dispatches[_documentId][_destinationChainSelector][currentVersion];
    }

    function getDispatchAtVersion(bytes32 _documentId, uint64 _destinationChainSelector, uint64 _documentVersion)
        external
        view
        returns (DispatchRecord memory)
    {
        return s_dispatches[_documentId][_destinationChainSelector][_documentVersion];
    }

    function getRemoteConfig(uint64 _destinationChainSelector) external view returns (RemoteConfig memory) {
        return s_remotes[_destinationChainSelector];
    }

    function isDocumentRegistered(bytes32 _documentId) external view returns (bool) {
        return s_documents[_documentId].status != EtherdocTypes.DocumentStatus.UNKNOWN;
    }

    function isDocumentActive(bytes32 _documentId) external view returns (bool) {
        return s_documents[_documentId].status == EtherdocTypes.DocumentStatus.ACTIVE;
    }

    function isIssuerAuthorized(address _issuer) external view returns (bool) {
        return s_authorizedIssuers[_issuer];
    }

    function issuerNonce(address _issuer) external view returns (uint256) {
        return s_issuerNonces[_issuer];
    }

    function computeDocumentId(address _issuer, string calldata _documentCID) external pure returns (bytes32) {
        return EtherdocTypes.documentId(_issuer, EtherdocTypes.contentCommitment(_documentCID));
    }

    function verifyDocument(bytes32 _documentId, string calldata _documentCID)
        external
        view
        returns (EtherdocTypes.DocumentRecord memory document, bool integrityMatches, bool isActive)
    {
        document = s_documents[_documentId];
        integrityMatches = document.contentCommitment == EtherdocTypes.contentCommitment(_documentCID)
            && document.documentId == _documentId;
        isActive = document.status == EtherdocTypes.DocumentStatus.ACTIVE;
    }

    function getRegisterDocumentDigest(
        address _issuer,
        string calldata _documentCID,
        bytes32 _metadataCommitment,
        uint256 _nonce,
        uint256 _deadline
    ) external view returns (bytes32) {
        bytes32 commitment = EtherdocTypes.contentCommitment(_documentCID);
        bytes32 documentId = EtherdocTypes.documentId(_issuer, commitment);
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REGISTER_DOCUMENT_TYPEHASH, _issuer, documentId, commitment, _metadataCommitment, _nonce, _deadline
                )
            )
        );
    }

    function getRevokeDocumentDigest(
        address _issuer,
        bytes32 _documentId,
        uint64 _currentVersion,
        uint256 _nonce,
        uint256 _deadline
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(REVOKE_DOCUMENT_TYPEHASH, _issuer, _documentId, _currentVersion, _nonce, _deadline))
        );
    }

    function _registerDocument(string calldata _documentCID, bytes32 _metadataCommitment, address _issuer)
        private
        returns (bytes32 documentId)
    {
        if (!s_authorizedIssuers[_issuer]) {
            revert IssuerNotAuthorized(_issuer);
        }
        _validateDocumentCID(_documentCID);

        bytes32 commitment = EtherdocTypes.contentCommitment(_documentCID);
        documentId = EtherdocTypes.documentId(_issuer, commitment);
        if (s_documents[documentId].status != EtherdocTypes.DocumentStatus.UNKNOWN) {
            revert DocumentAlreadyRegistered(documentId);
        }

        uint64 registeredAt = uint64(block.timestamp);
        s_documents[documentId] = EtherdocTypes.DocumentRecord({
            documentId: documentId,
            contentCommitment: commitment,
            metadataCommitment: _metadataCommitment,
            documentCID: _documentCID,
            issuer: _issuer,
            sourceChainId: block.chainid,
            registeredAt: registeredAt,
            updatedAt: registeredAt,
            version: 1,
            schemaVersion: EtherdocTypes.SCHEMA_VERSION,
            status: EtherdocTypes.DocumentStatus.ACTIVE,
            supersedes: bytes32(0),
            supersededBy: bytes32(0)
        });

        emit DocumentRegistered(
            documentId,
            commitment,
            _issuer,
            _documentCID,
            _metadataCommitment,
            block.chainid,
            registeredAt,
            EtherdocTypes.SCHEMA_VERSION
        );
    }

    function _revokeDocument(bytes32 _documentId, address _issuer) private {
        EtherdocTypes.DocumentRecord storage document = s_documents[_documentId];
        _requireActiveDocumentIssuer(document, _documentId, _issuer);

        document.status = EtherdocTypes.DocumentStatus.REVOKED;
        document.version++;
        document.updatedAt = uint64(block.timestamp);

        emit DocumentStatusChanged(
            _documentId, _issuer, EtherdocTypes.DocumentStatus.REVOKED, document.version, bytes32(0), document.updatedAt
        );
    }

    function _supersedeDocument(
        bytes32 _oldDocumentId,
        string calldata _newDocumentCID,
        bytes32 _metadataCommitment,
        address _issuer
    ) private returns (bytes32 newDocumentId) {
        EtherdocTypes.DocumentRecord storage oldDocument = s_documents[_oldDocumentId];
        _requireActiveDocumentIssuer(oldDocument, _oldDocumentId, _issuer);

        newDocumentId = _registerDocument(_newDocumentCID, _metadataCommitment, _issuer);
        EtherdocTypes.DocumentRecord storage newDocument = s_documents[newDocumentId];
        newDocument.supersedes = _oldDocumentId;

        oldDocument.status = EtherdocTypes.DocumentStatus.SUPERSEDED;
        oldDocument.supersededBy = newDocumentId;
        oldDocument.version++;
        oldDocument.updatedAt = uint64(block.timestamp);

        emit DocumentStatusChanged(
            _oldDocumentId,
            _issuer,
            EtherdocTypes.DocumentStatus.SUPERSEDED,
            oldDocument.version,
            newDocumentId,
            oldDocument.updatedAt
        );
    }

    function _requireActiveDocumentIssuer(
        EtherdocTypes.DocumentRecord storage _document,
        bytes32 _documentId,
        address _issuer
    ) private view {
        if (_document.status == EtherdocTypes.DocumentStatus.UNKNOWN) {
            revert DocumentNotRegistered(_documentId);
        }
        if (_document.issuer != _issuer) {
            revert CallerNotDocumentIssuer(_issuer, _document.issuer);
        }
        if (_document.status != EtherdocTypes.DocumentStatus.ACTIVE) {
            revert DocumentNotActive(_documentId);
        }
    }

    function _validateAndConsumeSignature(
        address _issuer,
        uint256 _deadline,
        bytes32 _structHash,
        bytes calldata _signature
    ) private {
        if (_deadline < block.timestamp) {
            revert SignatureExpired(_deadline);
        }
        address recoveredSigner = ECDSA.recover(_hashTypedDataV4(_structHash), _signature);
        if (recoveredSigner != _issuer) {
            revert InvalidIssuerSignature(_issuer, recoveredSigner);
        }
        s_issuerNonces[_issuer]++;
    }

    function _validateDocumentCID(string calldata _documentCID) private pure {
        uint256 cidLength = bytes(_documentCID).length;
        if (cidLength == 0) {
            revert InvalidDocumentCID();
        }
        if (cidLength > EtherdocTypes.MAX_DOCUMENT_CID_LENGTH) {
            revert DocumentCIDTooLong(cidLength, EtherdocTypes.MAX_DOCUMENT_CID_LENGTH);
        }
    }

    function _supersedeStructHash(SupersedeAuthorization memory _authorization) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SUPERSEDE_DOCUMENT_TYPEHASH,
                _authorization.issuer,
                _authorization.oldDocumentId,
                _authorization.currentVersion,
                _authorization.newDocumentId,
                _authorization.newContentCommitment,
                _authorization.metadataCommitment,
                _authorization.nonce,
                _authorization.deadline
            )
        );
    }
}
