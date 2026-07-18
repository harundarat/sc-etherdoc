# Etherdoc

Etherdoc registers a canonical document CID on a source chain and dispatches that document to one or
more destination chains through Chainlink CCIP.

## Trust model and verification semantics

Etherdoc is an issuer registry, not a legal identity provider. The source contract owner administers
the trusted issuer set with `setIssuerAuthorization`. The deploying owner is the first authorized
issuer. An authorized issuer may register directly, or a relayer may call `registerDocumentBySig`
with the issuer's EIP-712 signature. Off-chain consumers remain responsible for mapping an issuer
address to a real organization and deciding whether that organization is trusted for the document
type being checked.

Issuer authorization gates new registrations and superseding records. Removing an issuer prevents
new issuance but does not invalidate its historical records automatically. The original issuer can
still revoke its existing records, so removing issuance permission does not remove the recovery
path. Contract ownership alone does not let the administrator rewrite or revoke another issuer's
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
2. Configure each destination lane with `configureDestinationChain(selector, receiver, true)`.
3. Call `dispatchDocument(documentId, selector)` in a separate transaction for every destination.
4. Read `getDispatch(documentId, selector)` to track the CCIP `messageId`, destination, receiver,
   document version, send timestamp, and source-side dispatch status for each lane.

Cross-chain replication is asynchronous and non-atomic. Dispatching to several chains is one
off-chain orchestrated workflow, not one transaction that becomes final everywhere simultaneously.
The orchestrator should submit and monitor one transaction per destination. Consequently, a failure
on one lane does not revert successful lanes. If a router call fails, no dispatch record is written
for that lane and the orchestrator can retry it. A successful lane rejects duplicate normal
dispatches for the same document version. After revocation or supersession increments a record's
version, that new state can be dispatched to the same lane. Historical dispatch evidence remains
available through `getDispatchAtVersion`.

`DISPATCHED` only means that the source Router accepted the CCIP message. It does not prove that the
destination received or processed it; destination events and CCIP message status must be monitored
separately. The destination applies only a higher record version, so an out-of-order older message
cannot reactivate a revoked or superseded document.

## Development

```shell
forge build
forge test
forge fmt --check
```
