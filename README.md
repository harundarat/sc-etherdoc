# Etherdoc

Etherdoc registers a canonical document CID on a source chain and dispatches that document to one or
more destination chains through Chainlink CCIP.

## Document workflow

Registration and cross-chain dispatch are separate operations:

1. Call `registerDocument(cid)` once. It returns `documentId = keccak256(bytes(cid))`.
2. Configure each destination lane with `configureDestinationChain(selector, receiver, true)`.
3. Call `dispatchDocument(documentId, selector)` in a separate transaction for every destination.
4. Read `getDispatch(documentId, selector)` to track the CCIP `messageId`, destination, receiver,
   send timestamp, and source-side dispatch status for each lane.

Cross-chain replication is asynchronous and non-atomic. Dispatching to several chains is one
off-chain orchestrated workflow, not one transaction that becomes final everywhere simultaneously.
The orchestrator should submit and monitor one transaction per destination. Consequently, a failure
on one lane does not revert successful lanes. If a router call fails, no dispatch record is written
for that lane and the orchestrator can retry it. A successful lane rejects duplicate normal
dispatches.

`DISPATCHED` only means that the source Router accepted the CCIP message. It does not prove that the
destination received or processed it; destination events and CCIP message status must be monitored
separately.

## Development

```shell
forge build
forge test
forge fmt --check
```
