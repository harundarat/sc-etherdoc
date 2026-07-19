# Etherdoc Smart Contract Codebase TODO

Terakhir diperbarui: 2026-07-19.

Dokumen ini hanya melacak perubahan pada codebase smart contract Etherdoc: kontrak Solidity,
test, dependency, konfigurasi Foundry, script deployment, dan CI yang memverifikasi kontrak.
Implementasi frontend, backend, indexer, database, dan alerting berada di repository lain dan hanya
dicatat sebagai kebutuhan integrasi, bukan task repository ini.

## Task Aktif

Tidak ada. Jangan membuka kembali keputusan selesai kecuali perubahan baru melanggar invariant yang
tercatat.

## Catatan Integrasi di Luar Repository

Catatan berikut bukan task implementasi repository smart contract ini.

### P2-04 Reconciliation indexer dan alerting

Backend/indexer perlu menggabungkan `MessageSent`, status CCIP, dan `MessageReceived` per
`(documentId, version, destinationChainSelector)`. Status source `DISPATCHED` tidak membuktikan
delivery destination.

Repository backend/indexer perlu menangani:

- status off-chain sekurangnya `PENDING`, `FAILED`, dan `RECEIVED`;
- block/transaction/log/message reference yang dapat di-backfill dan direkonsiliasi setelah reorg;
- duplicate atau out-of-order log serta partial success antar-lane;
- alert pending melewati SLA, failed/manual execution, saldo LINK rendah, CCIP success tanpa
  receipt Etherdoc, dan drift remote config.

Kontrak sudah menyediakan event dan getter yang diperlukan. Jika integrator menemukan data yang
belum dapat diamati secara deterministik, buat task kontrak baru dengan kebutuhan event/getter yang
spesifik; jangan menambahkan logic status global off-chain ke kontrak.

### Dokumentasi dan operasi

Dokumen arsitektur lintas sistem, threat model produk, incident response terpadu, penyimpanan
manifest production, dan audit independen tetap diperlukan sebelum production, tetapi bukan
perubahan logic smart contract. Sumber operasional yang sudah ada tercantum di bagian akhir.

### Keputusan topologi produk

Pemilihan canonical registry + indexer, selected replicas, atau full replication merupakan
keputusan produk/arsitektur. Buat task kontrak baru hanya jika keputusan tersebut membutuhkan
perubahan storage, payload, atau routing. Full replication tidak otomatis menambah authenticity
jika seluruh replica berasal dari issuer yang sama.

## Invariant Kontrak yang Sudah Selesai

- [x] Registrasi dan dispatch dipisahkan. Satu document version dapat dikirim ke banyak destination;
  kegagalan satu lane tidak mengubah lane lain.
- [x] Source `DISPATCHED` hanya membuktikan Router menerima pesan. Destination `RECEIVED` dibuktikan
  oleh receipt/event receiver.
- [x] Record mengikat content digest, CID canonical, issuer, provenance, schema/version, lifecycle,
  dan supersession. EIP-712 nonce/deadline mendukung relayer.
- [x] Trusted remote adalah pasangan atomic `(sourceChainSelector, sender)`.
- [x] Dispatch memakai `RemoteConfig` governance-controlled; receiver arbitrary dari caller ditolak.
- [x] Payload tervalidasi terhadap schema, operation, document ID, version, dan provenance. Replay
  serta versi stale ditangani idempotent tanpa mengaktifkan kembali state terminal.
- [x] Callback invalid sengaja revert agar pesan yang sama dapat di-manual-execute setelah perbaikan.
- [x] Fee dibayar treasury dalam LINK dan dibatasi caller `maximumFee`; withdrawal hanya governance.
- [x] Governance two-step dan role issuer/operator/pauser dipisahkan.
- [x] Constructor sender menolak Router/LINK zero atau tanpa bytecode; receiver juga menolak Router
  zero atau tanpa bytecode, independen dari preflight deployment script.
- [x] CCIP 2.0 memakai ExtraArgs V3, full finality, default CommitteeVerifier, dan default executor.
  FTF, custom CCV/executor, token transfer, serta compatibility deployment/pesan lama tidak
  didukung.
- [x] Gas limit adalah remote policy bertipe `uint32` dan diuji bersama fee quote serta codec.
- [x] Schema payload v3 memakai ABI fixed 448 byte dan CID compact yang direkonstruksi receiver;
  benchmark terhadap schema v2, known-answer, negative, fuzz, dan integration test tercatat di
  `docs/PAYLOAD_SCHEMA.md`.
- [x] Kontrak non-upgradeable; perubahan logic menggunakan deployment baru dan remote rotation.

## Gate Perubahan Smart Contract

Jalankan gate yang relevan sebelum task ditandai selesai:

```shell
forge fmt --check
forge lint --deny warnings src script test
forge test -vv
FOUNDRY_PROFILE=ci forge test -vv
bash script/check-coverage.sh
bash script/check-contract-sizes.sh
bash script/check-gas-snapshot.sh
bash script/ci-deployment-dry-run.sh
bash script/test-deployment-workflow.sh
```

Untuk perubahan dependency, schema, atau network, ikuti `docs/DEPENDENCY_POLICY.md`, jalankan fork
lane yang relevan, dan revalidasi CCIP Directory. Jangan menyalin snapshot jumlah test, coverage,
gas, atau ukuran bytecode ke dokumen ini karena cepat stale.

## Sumber Kebenaran Repository

- Model kontrak dan developer entry point: `README.md`
- Deployment dan verification: `docs/DEPLOYMENT.md`
- Dependency/toolchain pin: `docs/DEPENDENCY_POLICY.md`
- Governance dan emergency controls: `docs/GOVERNANCE_RUNBOOK.md`
- CCIP failure/manual execution: `docs/CCIP_RECOVERY_RUNBOOK.md`
- CID, hashing, dan verifier: `docs/IPFS_POLICY.md`
- Schema dan benchmark payload: `docs/PAYLOAD_SCHEMA.md`
- Test strategy dan command: `docs/TESTING.md`
