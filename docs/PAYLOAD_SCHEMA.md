# Etherdoc CCIP Payload Schema

Etherdoc uses one fixed-size ABI payload for arbitrary-data CCIP messages. The contracts do not
accept older schemas: every schema change requires a new sender and receiver deployment followed by
explicit remote rotation.

## Schema version 3

Schema v3 encodes this static tuple as `EtherdocTypes.DocumentPayload`:

| Offset | ABI type | Field |
| ---: | --- | --- |
| 0 | `uint16` | `schemaVersion` |
| 32 | `Operation` | `operation` |
| 64 | `bytes32` | `contentDigest` |
| 96 | `bytes32` | `metadataCommitment` |
| 128 | `uint8` | `cidCodec` |
| 160 | `bytes32` | `cidDigest` |
| 192 | `address` | `issuer` |
| 224 | `uint256` | `sourceChainId` |
| 256 | `uint64` | `registeredAt` |
| 288 | `uint64` | `updatedAt` |
| 320 | `uint64` | `version` |
| 352 | `DocumentStatus` | `status` |
| 384 | `bytes32` | `supersedes` |
| 416 | `bytes32` | `supersededBy` |

The encoded length must be exactly 448 bytes. Exact length checking rejects truncated data and
trailing-data malleability before `abi.decode`.

The receiver derives rather than transports:

- `documentId = keccak256(abi.encode(issuer, contentDigest))`;
- `document.schemaVersion = payload.schemaVersion`;
- the canonical CID string from `cidCodec` and `cidDigest`.

The CID binary form is `[0x01, cidCodec, 0x12, 0x20, cidDigest]`. The receiver encodes those 36
bytes as lowercase unpadded base32 and prepends the `b` multibase prefix. Only the Etherdoc profile's
`raw` (`0x55`) and `dag-pb` (`0x70`) codecs are accepted. This follows the
[CIDv1 binary/string form](https://github.com/multiformats/cid) and the
[base32 multibase registration](https://github.com/multiformats/multibase).

## Benchmark and decision

`EtherdocPayloadCodecTest` compares the same record in the former schema-v2 shape against schema v3:

| Measurement | Schema v2 | Schema v3 | Reduction |
| --- | ---: | ---: | ---: |
| ABI payload | 768 bytes | 448 bytes | 320 bytes (41.67%) |
| Fixture calldata gas | 5,976 | 3,136 | 2,840 (47.52%) |

The byte reduction is invariant for every accepted CID because both schemas have fixed lengths.
The calldata-gas row uses the checked-in known-answer fixture and EVM zero/nonzero byte pricing; it
is not a LINK fee quote. Actual CCIP fees depend on the Router, lane, execution gas, and network
conditions.

This saving is material enough to adopt. Fixed-width ABI was chosen instead of a manually
bit-packed 241-byte representation because native decoding, enum/range checks, inspectability, and
simple receiver validation are worth the remaining bytes. The receiver still stores and exposes the
full canonical CID, so independent retrieval and verification semantics do not change.

The known-answer payload hash, legacy-size benchmark, CID reconstruction vector, invalid codec,
invalid schema, exact-length negatives, fuzz round trips, and local end-to-end delivery are covered
by the Solidity test suite.
