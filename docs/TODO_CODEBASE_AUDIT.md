# Etherdoc Codebase Audit & Modernization TODO

Terakhir dirampingkan: 2026-07-19.

Dokumen ini adalah backlog engineering, bukan audit keamanan formal. Detail desain yang sudah stabil
berada di README dan dokumen khusus; bagian selesai di bawah hanya mempertahankan invariant penting
agar pekerjaan lama tidak diulang.

## Fokus Berikutnya

Kerjakan item terbuka dari atas ke bawah. Jangan membuka kembali P0–P2-03 kecuali perubahan baru
melanggar invariant yang dicatat pada bagian selesai.

### [ ] P2-04 Bangun reconciliation indexer dan alerting

Kontrak sudah menyediakan event serta query untuk registration, perubahan status, dispatch,
receive/ignore, remote config, role, pause, dan withdrawal. `documentId` dan `messageId` yang relevan
sudah indexed, sedangkan dispatch/receipt dapat direkonsiliasi melalui getter.

Sisa pekerjaan:

- Buat indexer yang menggabungkan `MessageSent`, status CCIP, dan `MessageReceived` per
  `(documentId, version, destinationChainSelector)`.
- Definisikan status off-chain sekurangnya `PENDING`, `FAILED`, dan `RECEIVED`; jangan menyimpulkan
  delivery hanya dari status source `DISPATCHED`.
- Tambahkan alert untuk pending terlalu lama, failed/manual execution, saldo LINK rendah, dan drift
  remote config.
- Simpan block/transaction/message reference agar hasil indexer dapat diaudit dan di-rebuild.
- Uji reorg, duplicate log, out-of-order log, restart/backfill, serta partial success multichain.

Selesai jika indexer dapat dibangun ulang secara deterministik dari chain data dan satu kegagalan
lane terlihat tanpa mengubah status lane lain.

### [ ] P2-06 Perkuat validasi dependency pada constructor

Sebagian besar item lama sudah selesai: dependency disimpan `immutable`, receiver mendecode sender
dan payload sekali, custom error membawa konteks, penamaan konsisten, serta perubahan config
memancarkan event. Deployment preflight juga memverifikasi bytecode Router dan LINK.

Sisa keputusan/implementasi:

- Tambahkan validasi on-chain pada constructor sender untuk Router dan LINK zero-address serta
  ketiadaan bytecode, sehingga deploy langsung yang melewati script tetap aman.
- Evaluasi validasi code pada Router receiver; base `CCIPReceiver` 2.0 sudah menolak zero-address
  tetapi belum memeriksa code.
- Tambahkan unit test constructor dan pastikan budget runtime/initcode tetap lulus.

### [ ] P2-08 Lengkapi dokumentasi operasional yang belum eksplisit

Dokumen deployment, governance, dependency/version, IPFS, testing, dan recovery CCIP sudah tersedia.
README juga sudah menjelaskan arsitektur, trust semantics, workflow, dan operasi utama.

Sisa pekerjaan:

- Tambahkan `docs/ARCHITECTURE.md` dengan diagram boundary source, Router/CCIP, receiver, IPFS, dan
  indexer serta aliran state per versi.
- Tambahkan `docs/THREAT_MODEL.md` berisi asset, trust boundary, attacker capability, mitigasi, dan
  residual risk.
- Konsolidasikan incident response lintas governance, CCIP, key compromise, treasury, dan IPFS;
  tautkan ke runbook yang sudah ada tanpa menduplikasi prosedur.
- Tentukan penyimpanan manifest deployment production yang immutable dan dapat diaudit. Jangan
  commit secret atau mengarang manifest deployment historis.
- Jalankan audit keamanan independen setelah code freeze dan sebelum deployment production.

### [ ] P3-01 Optimalkan identifier dan payload hanya berdasarkan pengukuran

`bytes32 documentId` sudah menjadi key storage dan indexed event. CID masih dikirim pada payload agar
receiver dapat melakukan retrieval dan verifikasi secara mandiri.

- Benchmark biaya string CID dibanding metadata CID compact yang tetap dapat direkonstruksi.
- Hindari mengirim data berulang hanya jika penghematan terukur dan verifier tetap sederhana.
- Pertahankan compatibility schema secara eksplisit; breaking schema memakai deployment baru dan
  remote rotation.

### [ ] P3-02 Putuskan topologi registry berdasarkan kebutuhan produk

Bandingkan canonical registry + indexer, selected replicas, dan full replication. Ukur biaya,
latency, availability, serta trust benefit sebelum menambah destination. Full replication tidak
otomatis meningkatkan authenticity jika semua replica berasal dari issuer yang sama.

## Keputusan Selesai yang Masih Berlaku

### P0 — Model inti

- [x] **P0-01 Registrasi dan dispatch dipisahkan.** Satu canonical document dapat dikirim per versi ke
  banyak destination. Setiap lane memiliki `DispatchRecord`; kegagalan satu lane tidak membatalkan
  lane lain dan Router revert dapat di-retry.
- [x] **P0-02 Lifecycle tidak memakai boolean global.** Source `DISPATCHED` hanya membuktikan Router
  menerima pesan; destination `RECEIVED` dibuktikan oleh receipt/event. Replication asynchronous dan
  non-atomic; status global merupakan tanggung jawab indexer.
- [x] **P0-03 Provenance terstruktur.** Record mengikat SHA-256 file, CIDv1 canonical, issuer,
  timestamp/source chain, schema/version, status, dan supersession. EIP-712 nonce/deadline mendukung
  relayer. Revocation/supersession terminal dan histori tidak dihapus.
- [x] **P0-04 Config jaringan tidak hardcoded di script.** Network JSON tervalidasi memuat chain ID,
  selector, Router, LINK, RPC alias, explorer, lane, dan gas. Contoh aktif adalah Mantle Sepolia ↔
  Ink Sepolia; revalidasi CCIP Directory wajib sebelum deployment.

### P1 — Security, recovery, dan data integrity

- [x] **P1-01 Trusted remote adalah pasangan atomic**
  `(sourceChainSelector, sender)`; cross-product sender/chain ditolak.
- [x] **P1-02 Destination terikat ke `RemoteConfig`.** Dispatch tidak menerima receiver arbitrary;
  governance mengatur receiver, `uint32 gasLimit`, dan allowlist per selector dengan event.
- [x] **P1-03 Payload memakai schema v2 tervalidasi.** Envelope mengikat operation, document ID,
  version, dan provenance. Replay message ID serta versi equal/stale di-ignore secara idempotent;
  payload konflik/invalid revert; versi lama tidak dapat mengaktifkan record terminal.
- [x] **P1-04 Recovery mempertahankan kegagalan receiver.** Callback invalid sengaja revert agar
  message yang sama dapat di-manual-execute setelah perbaikan; source retry hanya untuk Router call
  yang belum sukses. Prosedur ada di `docs/CCIP_RECOVERY_RUNBOOK.md`.
- [x] **P1-05 Fee memakai treasury-funded LINK.** Quote dan caller `maximumFee` membatasi fee race,
  approval memakai `SafeERC20.forceApprove`, serta withdrawal/rescue hanya governance dan tercatat
  event. Native fee belum didukung.
- [x] **P1-06 Governance dipisahkan dari role operasional.** Production memakai multisig, ownership
  two-step, issuer/operator/pauser terpisah, relayer permissionless hanya dengan signature issuer,
  dan pause/unpause mengikuti `docs/GOVERNANCE_RUNBOOK.md`.
- [x] **P1-07 Content identity canonical.** `documentId` berasal dari issuer dan content digest;
  `contentDigest` adalah SHA-256 exact file bytes.
  Kebijakan CIDv1, pinning, privacy, dan verifier ada di `docs/IPFS_POLICY.md`.
- [x] **P1-08 Dependency koheren dan dipin.** CCIP 2.0.0, Chainlink Contracts 1.5.0,
  OpenZeppelin 5.3.0, dan forge-std 1.16.2 adalah direct root submodule pada full commit. Chainlink
  Local/nested CCIP 1.x dihapus. Matrix dan update gate ada di `docs/DEPENDENCY_POLICY.md`.
- [x] **P1-09 Clean cutover ke CCIP 2.0.** Sender memakai ExtraArgs V3, full finality, default
  CommitteeVerifier, dan default executor. Receiver mendukung interface V1/V2. FTF, custom
  CCV/executor, token transfer, serta compatibility deployment/pesan lama tidak didukung.
- [x] **P1-10 Toolchain reproducible.** Solidity 0.8.36, EVM Paris, optimizer 200 runs, dan Foundry
  1.7.1 dipin serta sama di lokal/CI. Jangan mengubahnya tanpa menjalankan update gate dependency.

### P2 — Test, CI, deployment, dan dokumentasi

- [x] **P2-01 Test matrix lengkap.** Unit/negative, fuzz, invariant, local Router harness, optional
  Mantle/Ink fork, recovery, serta scheduled testnet E2E tersedia. Target coverage code Etherdoc
  adalah 100%; command dan scope ada di `docs/TESTING.md`.
- [x] **P2-02 CI memiliki hard gate.** Format/lint, full test, coverage, Slither medium+, gas
  snapshot, contract-size budget, dependency pinning, dan deployment dry-run dijalankan. Dependency
  update hanya membuat PR dan tidak auto-merge.
- [x] **P2-03 Deployment bersifat desired-state dan idempotent.** Script deploy per role,
  configurator remote terpadu, treasury manager, Safe proposal untuk multisig, receipt-backed
  manifest, dan verification command menolak mismatch serta no-op pada rerun. Alur lengkap ada di
  `docs/DEPLOYMENT.md`.
- [x] **P2-05 Gas/finality adalah remote policy.** Gas limit `uint32` disimpan per destination;
  ExtraArgs V3 meminta full finality dan default CCV/executor. Quote, maximum fee, codec, bounds, dan
  remote-specific gas diuji.
- [x] **P2-07 README sudah menjadi dokumentasi produk.** README menjelaskan semantics verifikasi,
  provenance, lifecycle, trust/governance, CCIP, development, dan deployment; bukan lagi template
  Foundry.

### P3 — Keputusan arsitektur

- [x] **P3-03 Kontrak sengaja non-upgradeable.** Perubahan logic menggunakan deployment baru dan
  remote rotation eksplisit. Proxy hanya boleh dipertimbangkan kembali dengan storage-layout test,
  upgrade authorization, delay, rollback, monitoring, dan kebutuhan produk yang jelas.

## Gate Wajib untuk Perubahan Berikutnya

Gunakan command berikut sebagai sumber kebenaran; jangan menyalin jumlah test, coverage, gas, atau
ukuran bytecode ke dokumen ini karena cepat stale.

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

Untuk dependency/schema/network change, ikuti update gate di `docs/DEPENDENCY_POLICY.md`, jalankan
fork lane yang relevan, lalu revalidasi CCIP Directory. Fork test harus skip dengan jelas bila RPC
tidak tersedia; deployment production tidak boleh memakai config Directory yang belum diverifikasi
ulang.

## Dokumen Sumber Kebenaran

- Product model dan developer entry point: `README.md`
- Deployment, manifest, Safe proposal, treasury, verification: `docs/DEPLOYMENT.md`
- Dependency, CCIP, compiler, dan Foundry pin: `docs/DEPENDENCY_POLICY.md`
- Governance dan emergency controls: `docs/GOVERNANCE_RUNBOOK.md`
- CCIP failure/manual execution: `docs/CCIP_RECOVERY_RUNBOOK.md`
- CID, hashing, availability, privacy, verifier: `docs/IPFS_POLICY.md`
- Test strategy dan command: `docs/TESTING.md`
