# Etherdoc

Etherdoc registers a canonical file digest and CIDv1 retrieval reference on a source chain, then
dispatches that record to one or more destination chains through Chainlink CCIP.

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

- **Integrity**: SHA-256 of the exact bytes downloaded through the CID equals the stored
  `contentDigest`.
- **Existence/timestamping**: a record was registered at `registeredAt` on `sourceChainId`.
- **Authenticity**: the source contract accepted the record from an authorized issuer, directly or
  through a valid EIP-712 signature. This is only as strong as the off-chain trust mapping for that
  issuer address.
- **Validity**: the current record status is `ACTIVE`; `REVOKED` and `SUPERSEDED` records remain
  queryable but are not valid.

`verifyDocument(documentId, contentDigest)` compares a caller-supplied digest with the record and
returns the full record, an integrity result, and current validity. The contract cannot download
IPFS content: a verifier must download it and calculate SHA-256 first. The function does not collapse
integrity, issuer trust, and validity into one "authentic" boolean.

## Document provenance

The primary content identifier is SHA-256 of the exact uploaded file bytes. `documentId` is
`keccak256(abi.encode(issuer, contentDigest))`, so changing a filename, MIME type, gateway URL, or
IPFS DAG layout does not change the document identity, while changing one file byte does. Two
issuers may attest to the same bytes independently.

Every record stores the document ID, raw-file digest, canonical CIDv1, decoded CID codec and
multihash digest, optional `bytes32` metadata commitment, issuer, source chain ID,
registration/update timestamps, schema version, monotonic record version, status, and supersession
links. The accepted CID profile is CIDv1, lowercase unpadded base32 without an `ipfs://` prefix,
`raw` (`0x55`) or `dag-pb` (`0x70`) codec, and a 32-byte SHA2-256 multihash. For a `raw` CID, its
multihash must equal `contentDigest`; for `dag-pb`, the DAG-root hash and raw-file hash are expected
to differ and both are retained.

Hash bytes exactly as uploaded: Etherdoc performs no line-ending, Unicode, text-encoding, archive,
PDF-metadata, or EXIF normalization. Privacy-sensitive documents must be encrypted before upload;
the digest then commits to the ciphertext, and encryption keys remain off-chain. The complete
canonicalization, verifier, pinning, retention, and recovery requirements are in the
[IPFS and content integrity policy](docs/IPFS_POLICY.md).

Records start at version 1 with status `ACTIVE`. `revokeDocument` increments the version and changes
the status to `REVOKED` without deleting the CID, issuer, timestamps, or prior dispatch records.
`supersedeDocument` marks the old record `SUPERSEDED`, links it to a new active record, and preserves
both sides of the history. Revoked and superseded records cannot be reactivated.

Relayed registration, revocation, and supersession use the EIP-712 domain `Etherdoc`, version `2`,
the current chain ID, and the sender contract address. Each signature has an issuer-scoped monotonic
nonce and deadline. A successful signed operation consumes one nonce, preventing replay.

## Document workflow

Registration and cross-chain dispatch are separate operations:

1. Hash the exact upload bytes with SHA-256, upload them using the canonical IPFS profile, and meet
   the pin-confirmation gate in the IPFS policy.
2. Authorize the issuer, then call
   `registerDocument(contentDigest, cid[, metadataCommitment])` directly or use the corresponding
   EIP-712 relayer function.
3. Configure each destination lane atomically with
   `configureRemote(selector, receiver, gasLimit, true)`.
4. The configured operator calls `quoteFee(documentId, selector)`, chooses the largest acceptable
   LINK fee, then calls `dispatchDocument(documentId, selector, maximumFee)` in a separate
   transaction for every destination.
5. Read `getDispatch(documentId, selector)` to track the CCIP `messageId`, destination, receiver,
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

CCIP data uses the versioned `DocumentPayload` envelope. Schema version 2 binds the operation
(`REGISTER`, `REVOKE`, or `SUPERSEDE`), canonical document ID, document version, and full provenance
record. Both endpoints reject a zero file digest, a non-canonical or unsupported CID, inconsistent
decoded CID metadata, raw CID/file-digest mismatches, unsupported or internally inconsistent
envelopes, and encoded payloads larger than 1,024 bytes. Schema-v1 payloads are intentionally
incompatible and require a new deployment/remote rotation rather than being silently reinterpreted.

The receiver authenticates the source pair before decoding payload data and records every
successfully handled CCIP `messageId`. Re-delivery of the same message and a distinct message carrying
an equal or older document version are ignored idempotently and emit `MessageIgnored`; invalid or
conflicting payloads revert. `isMessageProcessed(messageId)` and `getMessageDocument(messageId)`
provide replay and indexing evidence. ExtraArgs V3 has no v1 `allowOutOfOrderExecution` toggle.
Etherdoc independently enforces monotonic state: schema 2 permits only version 1 `REGISTER` records
followed by one version 2 terminal operation, so an older active record cannot overwrite a received
revocation or supersession.

Every outbound message uses CCIP 2.0 `GenericExtraArgsV3`. The callback gas limit is stored as
`uint32` per remote. Etherdoc requests `WAIT_FOR_FINALITY_FLAG`, leaves the CCV list empty to select
the default CommitteeVerifier, and leaves the executor at `address(0)` to select the default
executor. Faster-than-finality (FTF), custom CCVs, custom executors, token transfers, and
`NO_EXECUTION_TAG` are not enabled. CCIP 2.0 execution is permissionless even when the default
executor is selected; verified messages remain manually executable.

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

Clone with recursive submodules, or initialize them before building an existing checkout:

```shell
git submodule sync --recursive
git submodule update --init --recursive
```

The supported toolchain is Foundry **v1.7.1**, recorded in `.foundry-version`. Install that exact
release instead of a floating `stable` build:

```shell
foundryup --install "$(cat .foundry-version)"
forge --version
```

All application, script, and test sources compile with Solidity **0.8.36**, target the **Paris** EVM,
and use the optimizer with **200 runs**. These settings live in `foundry.toml`; the Paris target
matches the CCIP 2.0 contract build target and avoids accidentally emitting newer opcodes on a
heterogeneous cross-chain lane. CI uses the same versions and raises fuzz runs through its explicit
`ci` profile.

```shell
forge build
forge test
forge fmt --check
```

Chainlink versions, exact commits, remapping rationale, and the upgrade gate are documented in the
[dependency policy](docs/DEPENDENCY_POLICY.md).

## Network configuration and deployment

Deployment scripts do not contain network addresses or chain selectors. They load one
`NetworkConfig` per chain from `NETWORK_CONFIG_PATH` and load generated Etherdoc addresses from
`DEPLOYMENT_DIR/<network>.json`. The checked-in testnet example uses Mantle Sepolia as source and Ink
Sepolia as destination with LINK fee payment.

The lane and Router/LINK values in `config/networks/testnet.json` were last verified on
**2026-07-19** against the official CCIP Directory. Both configured Routers accept ExtraArgs V3
quotes in fork tests. The Directory currently labels Mantle Sepolia → Ink Sepolia as lane `1.6.0`
and Ink Sepolia → Mantle Sepolia as `2.0.0`; contract package version, Router capability, and lane
version are tracked separately:

- [Mantle Sepolia CCIP configuration](https://docs.chain.link/ccip/directory/testnet/chain/ethereum-testnet-sepolia-mantle-1)
- [Ink Sepolia CCIP configuration](https://docs.chain.link/ccip/directory/testnet/chain/ink-testnet-sepolia)

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
NETWORK=inkSepolia forge script script/EtherdocReceiverScript.s.sol \
  --target-contract EtherdocReceiverScript \
  --rpc-url ink_sepolia --broadcast

# Source deployment
NETWORK=mantleSepolia forge script script/EtherdocSenderScript.s.sol \
  --target-contract EtherdocSenderScript \
  --rpc-url mantle_sepolia --broadcast

# Configure the destination to accept the source deployment
SOURCE_NETWORK=mantleSepolia DESTINATION_NETWORK=inkSepolia \
  forge script script/ConfigureEtherdocReceiver.s.sol \
  --target-contract ConfigureEtherdocReceiverScript \
  --rpc-url ink_sepolia --broadcast

# Configure the source lane and destination receiver
SOURCE_NETWORK=mantleSepolia DESTINATION_NETWORK=inkSepolia \
  forge script script/ConfigureEtherdocSender.s.sol \
  --target-contract ConfigureEtherdocSenderScript \
  --rpc-url mantle_sepolia --broadcast
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

The optional fork tests verify Router/LINK bytecode, lane support, and live V3 quotes in both
directions:

```shell
MANTLE_SEPOLIA_RPC_URL=<rpc-url> \
INK_SEPOLIA_RPC_URL=<rpc-url> \
  forge test --match-path test/CCIPV2Fork.t.sol -vv
```

Each direction is reported as skipped when its corresponding RPC is absent. The full unit,
negative, fuzz, invariant, fork, coverage, and scheduled live-E2E strategy is documented in
[Testing](docs/TESTING.md).
