# Etherdoc IPFS and Content Integrity Policy

This policy defines the bytes Etherdoc identifies, the only accepted CID representation, and the
minimum availability and privacy controls around registration. The smart contracts enforce the
identifier profile; upload, pinning, monitoring, encryption, and verifier behavior belong in the
off-chain services that integrate with this repository.

## Canonical content identity

Etherdoc's primary content identity is `contentDigest = SHA-256(fileBytes)`, where `fileBytes` are
the exact bytes uploaded to and later returned from IPFS. `documentId` is
`keccak256(abi.encode(issuer, contentDigest))`.

There is no implicit canonicalization. In particular, do not normalize:

- LF versus CRLF line endings;
- Unicode normalization forms or text encoding;
- filename, MIME type, filesystem timestamps, or archive headers;
- PDF metadata, signatures, incremental updates, or image EXIF data;
- compression or encryption containers.

Any byte-level transformation creates a different digest and therefore a different document. If a
product needs semantic normalization, it must define a separate versioned document format, perform
that transformation before this policy starts, and upload/hash the resulting bytes.

Use streaming SHA-256 over the final upload artifact. Do not hash a hex string, base64 string,
browser object URL, multipart envelope, directory entry, filename, or CID text. A zero digest is
invalid.

## Canonical CIDv1 profile

`documentCID` is a retrieval reference and must be exactly:

- CID version 1;
- lowercase, unpadded base32 multibase (`b...`);
- bare CID text, without `ipfs://`, `/ipfs/`, a gateway hostname, query, or fragment;
- `raw` (`0x55`) or `dag-pb` (`0x70`) multicodec;
- SHA2-256 (`0x12`) multihash with a 32-byte digest.

Under this profile, the encoded CID is 59 ASCII bytes. The contracts decode it, reject invalid
alphabet/padding/version/codec/hash fields, and store the decoded `cidCodec` and `cidDigest`. A raw
CID addresses the uploaded bytes directly, so `cidDigest` must equal `contentDigest`. A dag-pb CID
addresses the UnixFS root block; its multihash generally differs from the raw-file digest.

An uploader must record the exact IPFS options used to reproduce a dag-pb DAG (client/version,
chunker, raw-leaves setting, CID version, hash algorithm, and directory wrapping). These options are
operational metadata, not part of `documentId`. Re-importing the same file with different DAG
options may produce a different CID while preserving the same `contentDigest`.

Schema version 2 and the EIP-712 registration/supersession signatures bind the file digest, decoded
CID codec, decoded CID multihash digest, and metadata commitment. Do not submit legacy schema-v1
records that committed only to CID text.

## Registration availability gate

The upload/orchestrator service must not request an issuer signature or submit registration until
all of these checks pass:

1. Calculate `contentDigest` locally from the final bytes.
2. Upload with the canonical CID profile and independently decode the returned CID.
3. Fetch the object by CID, stream SHA-256 over the returned file bytes, and compare it with
   `contentDigest`.
4. Confirm a recursive pin on at least two independently operated backends in different failure
   domains. At least one copy should be controlled by Etherdoc or the issuer rather than relying
   solely on public gateways.
5. Fetch through each backend (or its authenticated retrieval endpoint), verify the same CID and
   raw-file digest, and persist the pin receipts plus provider request IDs.
6. Back up the original bytes or a verified CAR export in storage independent from both pinning
   backends.

A public gateway response alone is not a pin confirmation. A CID proves content addressing, not
continued availability.

## Health checks, retention, and recovery

The integrating service must maintain a registry keyed by `documentId` containing the CID, expected
file digest, pin providers, last successful retrieval, consecutive failures, retention class, and
backup location. It must:

- check every pin backend and perform a full verified retrieval at least daily;
- alert after one complete health-check cycle in which fewer than two independent pins are healthy;
- never treat a gateway HTTP 200 as healthy until the streamed SHA-256 matches `contentDigest`;
- retain active records for the issuer's declared retention period, and retain revoked or
  superseded records for the same evidentiary period unless a documented legal deletion policy
  requires otherwise;
- preserve monitoring and deletion audit logs without putting provider credentials or document
  contents on-chain.

Recovery is:

1. quarantine any response whose digest does not match;
2. retrieve the original bytes/CAR from a healthy pin or independent backup;
3. recompute the raw-file digest and CID before use;
4. re-pin to a replacement failure domain;
5. verify retrieval from the replacement and restore two healthy copies;
6. attach timestamps, affected documents, provider evidence, and verification results to the
   incident record.

Never “repair” a missing object by uploading different bytes under the existing record. Different
bytes require a new document and, when appropriate, the supersession workflow.

## Privacy and verifier requirements

CID text, file digest, issuer, metadata commitment, status, timestamps, and events are public and
permanent. A digest can also enable guessing attacks against predictable documents.

Sensitive content must be encrypted before hashing and upload with an authenticated,
versioned encryption envelope. In that case `contentDigest` commits to the ciphertext bytes. Keep
decryption keys, recipient lists, plaintext digests, access tokens, and key-recovery material off
IPFS and off-chain registries; distribute and rotate keys through a separate access-control system.
Revoking an Etherdoc record does not erase public ciphertext or revoke previously shared keys.

A verifier must independently:

1. read the record from the canonical source deployment and confirm the expected chain/contract;
2. resolve the issuer address through its trust registry;
3. require `ACTIVE` status and follow any supersession link;
4. fetch by the stored bare CID from a trusted IPFS client;
5. verify that the returned CID uses the stored codec/multihash metadata;
6. stream SHA-256 over the exact returned file bytes and compare with `contentDigest`;
7. for encrypted content, authenticate/decrypt only after ciphertext integrity succeeds.

Source `DISPATCHED` status is not destination delivery evidence. A verifier using a destination
replica must also confirm the CCIP receipt and trusted source remote described in the main README.
