# Etherdoc

Etherdoc registers a canonical document CID on a source chain and dispatches that document to one or
more destination chains through Chainlink CCIP.

## Trust model and verification semantics

Etherdoc is an issuer registry, not a legal identity provider. Source governance administers the
trusted issuer set with `setIssuerAuthorization`; the initial issuer is an explicit constructor
argument and is not implicitly the deployer. An authorized issuer may register directly, or a
relayer may call `registerDocumentBySig` with the issuer's EIP-712 signature. Off-chain consumers
remain responsible for mapping an issuer address to a real organization and deciding whether that
organization is trusted for the document type being checked.

Issuer authorization gates new registrations and superseding records. Removing an issuer prevents
new issuance but does not invalidate its historical records automatically. The original issuer can
still revoke its existing records, so removing issuance permission does not remove the recovery
path. Governance ownership alone does not let the administrator rewrite or revoke another issuer's
record.

Verification terms have deliberately separate meanings:

- **Integrity**: the supplied CID produces the stored `contentCommitment`.
- **Existence/timestamping**: a record was registered at `registeredAt` on `sourceChainId`.
- **Authenticity**: the source contract accepted the record from an authorized issuer, directly or
  through a valid EIP-712 signature. This is only as strong as the off-chain trust mapping for that
  issuer address.
- **Validity**: the current record status is `ACTIVE`; `REVOKED` and `SUPERSEDED` records remain
  queryable but are not valid.

`verifyDocument(documentId, cid)` returns the full record, an integrity result, and current validity.
It does not collapse those claims into one "authentic" boolean.

## Document provenance

`documentId` is `keccak256(abi.encode(issuer, keccak256(bytes(cid))))`, so two issuers may attest to
the same content independently. Every record stores the document ID, CID and content commitment,
optional `bytes32` metadata commitment, issuer, source chain ID, registration/update timestamps,
schema version, monotonic record version, status, and supersession links. Store only a commitment to
sensitive metadata; do not put PII plaintext in the CID or metadata field.

Records start at version 1 with status `ACTIVE`. `revokeDocument` increments the version and changes
the status to `REVOKED` without deleting the CID, issuer, timestamps, or prior dispatch records.
`supersedeDocument` marks the old record `SUPERSEDED`, links it to a new active record, and preserves
both sides of the history. Revoked and superseded records cannot be reactivated.

Relayed registration, revocation, and supersession use the EIP-712 domain `Etherdoc`, version `1`,
the current chain ID, and the sender contract address. Each signature has an issuer-scoped monotonic
nonce and deadline. A successful signed operation consumes one nonce, preventing replay.

## Document workflow

Registration and cross-chain dispatch are separate operations:

1. Authorize the issuer, then call `registerDocument(cid[, metadataCommitment])` directly or use the
   corresponding EIP-712 relayer function.
2. Configure each destination lane atomically with
   `configureRemote(selector, receiver, gasLimit, true)`.
3. The configured operator calls `quoteFee(documentId, selector)`, chooses the largest acceptable
   LINK fee, then calls `dispatchDocument(documentId, selector, maximumFee)` in a separate
   transaction for every destination.
4. Read `getDispatch(documentId, selector)` to track the CCIP `messageId`, destination, receiver,
   configured gas limit, document version, send timestamp, and source-side dispatch status for each
   lane.

Cross-chain replication is asynchronous and non-atomic. Dispatching to several chains is one
off-chain orchestrated workflow, not one transaction that becomes final everywhere simultaneously.
The orchestrator should submit and monitor one transaction per destination. Consequently, a failure
on one lane does not revert successful lanes. If a router call fails, no dispatch record is written
for that lane and the orchestrator can retry it. A successful lane rejects duplicate normal
dispatches for the same document version. After revocation or supersession increments a record's
version, that new state can be dispatched to the same lane. Historical dispatch evidence remains
available through `getDispatchAtVersion`.

The sender uses a treasury-funded LINK model: LINK is transferred to the sender ahead of dispatch,
and only an authorized operator can spend it through `dispatchDocument`. It does not pull fees from
document issuers or relayers and does not support native-fee payment. A quote is only a point-in-time
Router estimate, not a reservation; the fee may change before mining. The required `maximumFee`
bounds that race, so an orchestrator should apply an explicit tolerance to the quote and requote
after `FeeExceedsMaximum` instead of using an unlimited value.

LINK approval uses `SafeERC20.forceApprove` for tokens that require resetting a non-zero allowance.
Governance can return excess LINK or rescue any other ERC-20 with
`withdrawToken(token, recipient, amount)`; zero token and recipient addresses are rejected and every
successful withdrawal emits `TokenWithdrawn`. Operators should retain enough LINK for pending
dispatches and send withdrawals to the configured treasury.

`DISPATCHED` only means that the source Router accepted the CCIP message. It does not prove that the
destination received or processed it; destination events and CCIP message status must be monitored
separately. The destination applies only a higher record version, so an out-of-order older message
cannot reactivate a revoked or superseded document.

CCIP data uses the versioned `DocumentPayload` envelope. Schema version 1 binds the operation
(`REGISTER`, `REVOKE`, or `SUPERSEDE`), canonical document ID, document version, and full provenance
record. Both endpoints reject an empty CID, CIDs longer than 256 bytes, unsupported or internally
inconsistent envelopes, and encoded payloads larger than 1,024 bytes. A CID remains an opaque
application identifier; clients that require a particular URI or multibase representation should
enforce that policy before registration.

The receiver authenticates the source pair before decoding payload data and records every
successfully handled CCIP `messageId`. Re-delivery of the same message and a distinct message carrying
an equal or older document version are ignored idempotently and emit `MessageIgnored`; invalid or
conflicting payloads revert. `isMessageProcessed(messageId)` and `getMessageDocument(messageId)`
provide replay and indexing evidence. Out-of-order execution remains enabled, but schema v1 permits
only version 1 `REGISTER` records followed by one version 2 terminal operation, so an older active
record cannot overwrite a received revocation or supersession.

Receiver failures deliberately revert so CCIP retains the failed execution and return data for
monitoring and manual execution. Authentication failures are never stored as valid messages. After a
source Router has accepted a dispatch, recover the same message ID instead of sending a duplicate
payload. See the [CCIP recovery runbook](docs/CCIP_RECOVERY_RUNBOOK.md) for monitoring, triage, manual
execution, lane pause/resume, and incident evidence.

## Governance and emergency controls

Production `owner()` addresses must be multisig contracts supplied explicitly at deployment.
Governance controls issuers, operational roles, remotes, treasury withdrawal, and unpause. A separate
`OPERATOR_ROLE` can only dispatch; `PAUSER_ROLE` can pause registration/dispatch on the sender and
receive on the destination. Relayers receive no privileged role and can only submit valid issuer
signatures. Ownership transfer remains two-step through `transferOwnership` and `acceptOwnership`.

A registration pause still permits issuer-authorized revocation. A receive pause deliberately
reverts CCIP execution without marking the message processed, so the same message ID can be retried.
Only governance can unpause after incident review; resume destination receive before source
dispatch. Contracts are intentionally non-upgradeable—logic changes use redeployment and explicit
remote rotation. See the
[governance and emergency pause runbook](docs/GOVERNANCE_RUNBOOK.md) for the role matrix, deployment,
rotation, and recovery policy.

## Development

```shell
forge build
forge test
forge fmt --check
```

## Network configuration and deployment

Deployment scripts do not contain network addresses or chain selectors. They load one
`NetworkConfig` per chain from `NETWORK_CONFIG_PATH` and load generated Etherdoc addresses from
`DEPLOYMENT_DIR/<network>.json`. The checked-in testnet example uses the Ethereum Sepolia ↔ Base
Sepolia lane and LINK fee payment.

The lane and Router/LINK values in `config/networks/testnet.json` were last verified on
**2026-07-18** against the official CCIP Directory:

- [Ethereum Sepolia CCIP configuration](https://docs.chain.link/ccip/directory/testnet/chain/ethereum-testnet-sepolia)
- [Base Sepolia CCIP configuration](https://docs.chain.link/ccip/directory/testnet/chain/ethereum-testnet-sepolia-base-1)

CCIP network support can change. Recheck both Directory pages and update `directoryVerifiedAt`
before a production-like deployment.

Copy `.env-example` to `.env`, provide both RPC URLs, and load it into the shell. Deploy and
configure are deliberately separate. Set `GOVERNANCE` to the production multisig plus explicit
`INITIAL_ISSUER`, `OPERATOR`, and `PAUSER` addresses before source deployment; receiver deployment
uses `GOVERNANCE` and `PAUSER`:

```shell
set -a
source .env
set +a

# Destination deployment
NETWORK=baseSepolia forge script script/EtherdocReceiverScript.s.sol \
  --target-contract EtherdocReceiverScript \
  --rpc-url base_sepolia --broadcast

# Source deployment
NETWORK=ethereumSepolia forge script script/EtherdocSenderScript.s.sol \
  --target-contract EtherdocSenderScript \
  --rpc-url ethereum_sepolia --broadcast

# Configure the destination to accept the source deployment
SOURCE_NETWORK=ethereumSepolia DESTINATION_NETWORK=baseSepolia \
  forge script script/ConfigureEtherdocReceiver.s.sol \
  --target-contract ConfigureEtherdocReceiverScript \
  --rpc-url base_sepolia --broadcast

# Configure the source lane and destination receiver
SOURCE_NETWORK=ethereumSepolia DESTINATION_NETWORK=baseSepolia \
  forge script script/ConfigureEtherdocSender.s.sol \
  --target-contract ConfigureEtherdocSenderScript \
  --rpc-url ethereum_sepolia --broadcast
```

Successful broadcast runs write generated address books under `deployments/testnet/`; dry-runs do
not write deployment addresses. The configure scripts require those artifacts.

Every deploy/configure command performs preflight validation before broadcasting:

- the connected RPC chain ID must match its config;
- the local Router, LINK token when required, and Etherdoc deployment must have bytecode;
- the source Router must report the destination selector as supported;
- remote Router, sender, and receiver bytecode is checked through the configured remote RPC alias;
- the configured destination gas limit must match the sender contract;
- missing deployment artifacts and unsupported fee modes fail with explicit custom errors.

The current sender pays fees in LINK. Setting `feeMode` to `NATIVE` is rejected until native fee
payment is implemented in the contract. The configure commands can broadcast directly only when
their signer is governance. For production multisig ownership, review the validated parameters and
execute the equivalent `configureTrustedRemote` and `configureRemote` calldata through the multisig.
