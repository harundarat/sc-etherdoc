# Etherdoc Codebase Audit & Modernization TODO

Tanggal review: 2026-07-18
Scope repo: smart contract, integrasi CCIP, script deployment, konfigurasi Foundry/CI, test, dan dokumentasi.

> [!IMPORTANT]
> Ini adalah engineering review terhadap kode Etherdoc, bukan audit keamanan formal untuk produksi.
> Isi internal submodule Chainlink dan `forge-std` tidak diaudit karena berada di luar scope.
> Dependency tersebut hanya diperiksa dari sisi versi, pinning, kompatibilitas, dan cara Etherdoc
> menggunakannya.

## Ringkasan

Build saat ini berhasil dan satu happy-path integration test lulus. Namun, implementasi belum memenuhi
klaim inti "menyimpan satu dokumen di beberapa chain sekaligus":

- `addDocument` hanya menerima satu destination chain.
- CID langsung ditandai sudah ada secara global di source chain.
- Pemanggilan kedua untuk CID yang sama—termasuk ke destination chain lain—akan revert.
- Status source chain berubah menjadi `true` ketika pesan CCIP dikirim, bukan ketika pesan diterima.
- Tidak ada acknowledgement atau status per-chain, sehingga aplikasi tidak bisa membedakan
  `registered`, `sent`, `failed`, dan `received`.
- State hanya menyimpan `CID => bool`; ini membuktikan bahwa owner pernah mencatat sebuah CID, tetapi
  belum cukup untuk menjelaskan siapa issuer dokumen, status pencabutan, versi, atau provenance.

Prioritas pertama sebaiknya memperbaiki model state dan alur multichain sebelum menambah fitur UI atau
melakukan upgrade dependency mayor.

## Baseline yang Diverifikasi

Perintah dijalankan dengan Foundry lokal 1.5.1 dan commit dependency yang dipin repo:

| Pemeriksaan | Hasil |
|---|---|
| `forge build --sizes` | Lulus; Solc 0.8.24; 13 catatan lint penamaan |
| `forge test -vvv` | Lulus; 1 test, 0 gagal |
| `forge fmt --check` | Gagal; file Solidity perlu dinormalisasi/diformat |
| `forge coverage --report summary` | Source lines 29/36; branch coverage 0/6 |
| `forge lint src script test` | Lulus dengan 13 catatan `mixed-case-variable` |
| Contract size | `EtherdocSender` 5,580 B; `EtherdocReceiver` 5,351 B |

Coverage source terlihat cukup tinggi karena satu happy path melewati banyak baris, tetapi branch
coverage 0% menegaskan bahwa seluruh jalur error belum diuji.

## Definisi Prioritas

- **P0**: alur inti salah atau klaim produk dapat menyesatkan.
- **P1**: risiko keamanan, recovery, data integrity, atau operasional penting.
- **P2**: maintainability, observability, test quality, deployment, dan developer experience.
- **P3**: optimasi gas/kode dan penyempurnaan jangka panjang.

---

## P0 — Perbaiki Alur Inti

### [x] P0-01 Pisahkan registrasi dokumen dari pengiriman per destination chain

**Bukti:** `src/EtherdocSender.sol:55-70`.

`addDocument` menerima tepat satu `_destinationChainSelector`, lalu
`s_documents[_documentCID] = true`. Pemanggilan berikutnya untuk CID yang sama selalu revert dengan
`DocumentAlreadyExists`, sehingga CID tersebut tidak dapat direplikasi ke chain kedua.

**TODO:**

- Buat operasi terpisah:
  - `registerDocument(...)` untuk membuat canonical record satu kali.
  - `dispatchDocument(documentId, destinationChainSelector)` untuk setiap lane.
- Ganti flag global menjadi state per dokumen dan per chain, misalnya:
  - `DocumentRecord` untuk canonical metadata.
  - `mapping(documentId => mapping(chainSelector => DispatchRecord))`.
- Simpan sekurangnya `messageId`, destination, receiver, waktu pengiriman, dan status dispatch.
- Izinkan retry untuk lane yang gagal tanpa mendaftarkan ulang dokumen.
- Gunakan orchestrator off-chain untuk mengirim transaksi per destination jika dibutuhkan partial
  success. Satu loop on-chain membuat biaya tidak terprediksi dan dapat membuat semua dispatch source
  ikut revert bila satu lane gagal.
- Dokumentasikan bahwa cross-chain replication bersifat asynchronous dan tidak atomic. "Sekaligus"
  harus berarti satu workflow dengan status per-chain, bukan satu transaksi yang final secara serentak.

**Selesai jika:**

- Satu `documentId` dapat dikirim ke minimal dua destination chain.
- Kegagalan lane B tidak menghapus keberhasilan lane A.
- Lane yang gagal dapat dicoba ulang.
- Test membuktikan duplicate dispatch pada lane yang sama ditolak/idempotent, tetapi dispatch ke lane
  berbeda diperbolehkan.

### [x] P0-02 Gunakan lifecycle status; jangan samakan `sent` dengan `verified`

**Bukti:** `src/EtherdocSender.sol:70-89` dan `src/EtherdocReceiver.sol:57-64`.

Source menyimpan `true` sebelum `ccipSend` selesai dan tidak pernah menerima bukti delivery.
Transaksi source yang sukses hanya berarti Router menerima pesan. Eksekusi destination tetap dapat
tertunda atau gagal. Menurut API CCIP v1.6, receiver yang revert membuat message masuk status failed
dan tersedia untuk manual execution.

**TODO:**

- Definisikan lifecycle eksplisit, contoh:
  - source: `REGISTERED -> DISPATCHED`;
  - destination: `RECEIVED`;
  - global/off-chain: `PARTIAL -> COMPLETE` setelah semua target terkonfirmasi.
- Ubah API query agar tidak memakai satu `documentExists` untuk menjawab beberapa arti berbeda.
- Pilih mekanisme konfirmasi:
  - indexer membaca `MessageSent`, CCIP status, dan `MessageReceived`; atau
  - receiver mengirim ACK CCIP kembali ke source jika status on-chain dua arah benar-benar dibutuhkan.
- Jika memakai ACK, perhitungkan biaya tambahan, replay protection, dan kemungkinan ACK juga gagal.
- Frontend harus menampilkan status per-chain dan message ID, bukan satu badge "verified everywhere".

**Selesai jika:**

- UI/API tidak dapat menganggap dokumen sudah diterima hanya dari state source.
- Setiap destination memiliki status dan transaction/message reference.
- Skenario pending, failed, retry, dan complete memiliki test.

### [x] P0-03 Definisikan arti "keaslian dokumen" dan simpan provenance yang cukup

**Bukti:** kedua kontrak hanya menyimpan `mapping(string => bool)`.

CID yang tercatat membuktikan bahwa akun berizin pernah mencatat identifier tersebut. Itu belum
otomatis membuktikan identitas penerbit, validitas dokumen, atau bahwa dokumen belum dicabut.

**TODO:**

- Definisikan trust model di specification/README:
  - siapa yang boleh menerbitkan;
  - siapa yang dianggap issuer tepercaya;
  - apa yang diverifikasi pengguna;
  - bagaimana revocation dan supersession bekerja.
- Gunakan record terstruktur yang minimal memuat:
  - `documentId`;
  - content digest/CID commitment;
  - issuer;
  - source chain;
  - issued/registered timestamp;
  - schema version;
  - status `ACTIVE`, `REVOKED`, atau `SUPERSEDED`;
  - optional metadata commitment, tanpa menyimpan PII plaintext.
- Jika transaksi dikirim oleh relayer, gunakan signature issuer berformat EIP-712 dengan nonce dan
  deadline agar provenance tetap menunjuk issuer, bukan relayer.
- Tambahkan revocation dan supersession dengan version/nonce yang monoton.
- Pisahkan istilah:
  - **integrity**: file menghasilkan digest/CID yang sama;
  - **existence/timestamping**: commitment pernah tercatat;
  - **authenticity**: commitment ditandatangani issuer yang dipercaya;
  - **validity**: record aktif dan belum dicabut.

**Selesai jika:**

- Query verifikasi mengembalikan issuer, status, dan provenance, bukan hanya boolean.
- Dokumen dapat dicabut tanpa menghapus histori.
- Test membuktikan issuer yang tidak berizin/signature replay ditolak.

### [ ] P0-04 Migrasikan deployment dari Holesky dan hapus konfigurasi jaringan hardcoded

**Bukti:** `foundry.toml`, `.env-example`, dan kedua deployment script.

Konfigurasi source memakai Holesky, yang sudah deprecated sejak September 2025. Script juga menyimpan
Router, LINK token, selector, receiver, dan deployed sender langsung di source code. Comment
`Base Sepolia` pada selector source receiver tidak konsisten dengan peran selector tersebut.

**TODO:**

- Gunakan testnet aplikasi yang masih didukung dan lane yang tercantum di CCIP Directory saat deploy.
- Ambil seluruh network configuration dari environment/config file tervalidasi.
- Buat satu `NetworkConfig` per chain: chain ID, selector, Router, LINK, explorer, RPC alias, receiver,
  gas limit, dan fee mode.
- Validasi bahwa:
  - chain ID RPC sesuai config;
  - Router memiliki code;
  - destination didukung Router;
  - pasangan lane tersedia di CCIP Directory;
  - receiver memiliki code sebelum dispatch.
- Pisahkan deploy dan configure; simpan deployment artifact/address book per environment.
- Perbaiki `.env-example` dan hapus endpoint Holesky.

**Selesai jika:**

- Tidak ada alamat atau selector jaringan di source script.
- Dry-run script gagal dengan pesan jelas bila chain/config salah.
- README memuat contoh lane aktif dan tanggal terakhir diverifikasi.

---

## P1 — Security, Recovery, dan Data Integrity

### [ ] P1-01 Allowlist pasangan `(sourceChainSelector, sender)`, bukan dua daftar independen

**Bukti:** `src/EtherdocReceiver.sol:17-18` dan `49-55`.

Source chain dan sender divalidasi melalui dua mapping terpisah. Jika beberapa chain dan sender
diaktifkan, kombinasi silang semuanya ikut lolos walaupun hanya pasangan tertentu yang dimaksud.

**TODO:**

- Gunakan `mapping(uint64 => mapping(address => bool)) trustedRemote`.
- Sediakan satu fungsi konfigurasi remote yang mengubah chain dan sender secara atomic.
- Emit event untuk setiap perubahan trusted remote.
- Tolak zero address dan selector invalid.

**Selesai jika:** test matriks A/X dan B/Y membuktikan A/Y serta B/X ditolak.

### [ ] P1-02 Bind destination chain ke receiver yang dikonfigurasi

**Bukti:** `src/EtherdocSender.sol:55-64`.

Destination chain di-allowlist, tetapi receiver diberikan bebas pada setiap panggilan. Salah alamat,
EOA, atau receiver dari environment lain dapat menerima message dan biaya tetap terpakai.

**TODO:**

- Simpan `RemoteConfig` per destination selector, termasuk receiver dan gas limit.
- Jangan terima receiver arbitrary di fungsi dispatch normal.
- Untuk rotasi receiver, gunakan perubahan config eksplisit, event, dan bila perlu timelock.
- Validasi code size receiver pada script/fork test; pahami bahwa code destination tetap dapat berubah
  setelah validasi.

### [ ] P1-03 Tambahkan payload schema, versioning, validation, dan idempotency

**Bukti:** payload saat ini hanya `abi.encode(string)` dan di-decode berulang tanpa batas ukuran.

**TODO:**

- Gunakan payload struct dengan `schemaVersion`, `documentId`, provenance, version/nonce, dan operation
  (`REGISTER`, `REVOKE`, `SUPERSEDE`).
- Validasi panjang/format sebelum send dan setelah receive.
- Tolak CID kosong serta payload yang melebihi batas aplikasi.
- Decode sender dan data sekali saja.
- Simpan processed `messageId` untuk idempotency dan observability.
- Putuskan aturan duplicate document: ignore idempotently atau revert secara eksplisit.
- Jika `allowOutOfOrderExecution = true` dipertahankan, pastikan version/nonce monoton dan pesan lama
  tidak dapat mengaktifkan kembali dokumen yang sudah revoked.

### [ ] P1-04 Rancang recovery untuk receiver failure dan retry dispatch

**Bukti:** `_ccipReceive` selalu revert untuk source/sender/payload yang tidak sesuai; sender tidak
memiliki jalur retry setelah CID ditandai ada.

**TODO:**

- Pilih dan dokumentasikan satu strategi:
  - revert dan operasikan manual CCIP execution; atau
  - defensive receiver yang menyimpan failed message dan menyediakan controlled retry.
- Tambahkan status/event kegagalan aplikasi yang dapat dimonitor.
- Jangan menelan kegagalan autentikasi sebagai pesan valid.
- Tambahkan runbook untuk manual execution, retry, pause, dan incident response.
- Uji receiver yang sengaja gagal, kemudian recovery tanpa duplicate state.

### [ ] P1-05 Amankan fee approval dan pengelolaan dana

**Bukti:** `src/EtherdocSender.sol:80-87`.

Return value `LINK.approve` tidak diperiksa dan contract tidak memiliki fungsi withdrawal/rescue.
LINK yang dikirim berlebih dapat terkunci permanen.

**TODO:**

- Gunakan `SafeERC20.forceApprove`/mekanisme approval yang kompatibel dengan versi dependency yang
  dipilih.
- Jadikan Router dan fee token immutable jika memang tidak dapat diubah.
- Tambahkan `quoteFee` agar caller/orchestrator dapat memperkirakan biaya.
- Tambahkan owner-only withdrawal/rescue dengan event dan zero-address validation.
- Putuskan model biaya: treasury-funded LINK, native fee, atau user-funded; dokumentasikan slippage
  fee dan race antara quote dan mining.
- Cache hasil `balanceOf` dan cek approval/transfer failure pada test mock.
- Pertimbangkan batas fee maksimum dari caller agar dispatch tidak membayar fee yang melonjak tanpa
  batas.

### [ ] P1-06 Ganti single hot-key owner dengan model issuer/governance yang sesuai

**Bukti:** semua operasi penting memakai `OwnerIsCreator`.

**TODO:**

- Gunakan multisig untuk admin production.
- Pisahkan role admin, issuer, pauser, dan operator/relayer sesuai kebutuhan.
- Tambahkan emergency pause untuk registration/dispatch/receive dengan kebijakan unpause jelas.
- Pertahankan two-step ownership transfer.
- Hindari proxy upgradeability kecuali kebutuhan upgrade dan governance benar-benar didefinisikan;
  redeploy + remote rotation sering lebih sederhana dan memiliki trust surface lebih kecil.

### [ ] P1-07 Definisikan canonical hashing/CID dan kebijakan IPFS

Kode upload/IPFS tidak ada di repo ini, sehingga alur upload, pinning, dan frontend belum dapat
diaudit. Namun contract interface saat ini menerima string apa pun sebagai "CID".

**TODO:**

- Tentukan apakah identifier utama adalah:
  - CIDv1 canonical; atau
  - digest file mentah (misalnya SHA-256) plus codec/multihash metadata.
- Hash byte file yang tepat dan konsisten; dokumentasikan canonicalization agar perubahan metadata,
  line ending, atau encoding tidak menghasilkan kejutan.
- Pertimbangkan `bytes32 documentId` sebagai key on-chain dan simpan/emit representasi CID yang
  dibutuhkan untuk retrieval.
- Implementasikan pinning redundancy, health check, retention, dan recovery. CID tidak menjamin data
  akan tetap tersedia bila tidak ada node yang menyimpan/pin.
- Anggap CID dan event sebagai data publik. Enkripsi dokumen sensitif sebelum upload dan kelola kunci
  di luar chain; jangan menaruh PII atau encryption key on-chain.
- Verifier client harus mengunduh konten, menghitung ulang digest/CID, memeriksa issuer, dan memeriksa
  status revocation.

---

## P1 — Version dan Dependency Coherency

Versi "tersedia terbaru" berikut diverifikasi pada tanggal review; versi terbaru bukan otomatis target
yang aman. Upgrade harus mengikuti compatibility matrix, release notes, CCIP Directory, dan regression
test.

| Komponen | Kondisi repo/lokal | Versi tersedia saat review | Penilaian |
|---|---|---|---|
| Solidity | pragma exact `0.8.24` | `0.8.36` | Tertinggal; upgrade bertahap dan review breaking/compiler changes |
| Foundry | lokal `1.5.1`; CI tidak pin binary | `1.7.1` | Build lokal/CI tidak reproducible |
| `forge-std` | commit `77041d...`, versi `1.9.7` | `1.16.2` | Dipin dengan baik tetapi tertinggal |
| `@chainlink/contracts-ccip` | commit `2114b...`, versi `1.6.0` | `2.0.0` | Upgrade mayor; jangan dilakukan blind |
| `@chainlink/local` | `0.2.5-beta.0` | `0.2.9` | Repo memakai beta lama |
| `@chainlink/contracts` | copy vendored `1.3.0` | `1.5.0` | Tidak selaras dengan CCIP/local yang meminta 1.4.0 |
| `actions/checkout` | `@v4` | `v7.0.0` | Major lama dan hanya pin tag |
| `foundry-toolchain` action | `@v1`, tanpa input versi Foundry | action `v1.9.0` | Action dan binary Foundry sama-sama tidak immutable |

### [ ] P1-08 Hilangkan version skew Chainlink

**Bukti:**

- `lib/chainlink-brownie-contracts/version.txt` menyatakan 1.3.0.
- CCIP commit yang dipin memiliki package version 1.6.0 dan meminta
  `@chainlink/contracts = 1.4.0`.
- Chainlink Local yang dipin adalah 0.2.5-beta.0 dan meminta
  `@chainlink/contracts ^1.4.0` serta `@chainlink/contracts-ccip ^1.6.0`.
- Remapping root memaksa `@chainlink/contracts` ke copy 1.3.0.

Build saat ini kebetulan lulus, tetapi kombinasi ini berada di luar dependency declaration package.

**TODO:**

- Pilih satu compatibility matrix resmi dan gunakan versi exact/tag/commit.
- Low-risk candidate untuk dievaluasi lebih dahulu:
  - `@chainlink/local` 0.2.9;
  - `@chainlink/contracts` 1.5.0;
  - `@chainlink/contracts-ccip` yang selaras dengan simulator tersebut, kemudian test lane aplikasi.
- Hapus copy `chainlink-brownie-contracts` 1.3.0 setelah import/remapping dipindahkan ke dependency
  resmi yang dipin.
- Hindari dua copy CCIP/forge-std berbeda di root dan nested dependency bila resolusinya ambigu.
- Catat checksums/commit dan alasan versi dalam dependency policy.

### [ ] P1-09 Evaluasi CCIP 2.0 sebagai migration project terpisah

CCIP 2.0 adalah major release dengan konsep CCV, executor, finality, message format, dan receiver
interface baru. Jangan mengubah dependency lalu menganggap kontrak lama setara.

**TODO:**

- Bandingkan API `IRouterClient`, `Client`, `CCIPReceiver`, extra args, fee, dan finality.
- Verifikasi lane/router deployment dan fitur 2.0 di CCIP Directory untuk semua target.
- Tentukan backward compatibility untuk receiver v1 dan message yang masih pending.
- Buat branch migration dan suite fork/E2E khusus.
- Deploy kontrak baru dan lakukan remote rotation terkontrol bila storage/interface tidak kompatibel.

### [ ] P1-10 Pin compiler, EVM target, optimizer, dan Foundry secara eksplisit

**Bukti:** `foundry.toml` tidak menetapkan optimizer atau EVM version. EVM target efektif bergantung
pada versi Foundry; pada mesin review terbaca `prague`. CI menggunakan floating Foundry stable melalui
`foundry-rs/foundry-toolchain@v1`.

**TODO:**

- Tetapkan `solc_version`, `evm_version`, `optimizer`, dan `optimizer_runs`.
- Pin Foundry CI ke release exact dan pin GitHub Action ke full commit SHA.
- Samakan versi developer lokal dan CI, misalnya melalui dokumentasi/tool version file.
- Tambahkan `[profile.ci]` yang nyata atau hapus `FOUNDRY_PROFILE=ci` yang menyesatkan.
- Setelah upgrade compiler, jalankan seluruh test, bytecode-size diff, gas diff, dan deployment
  simulation.

---

## P2 — Test, CI, Deployment, dan Observability

### [ ] P2-01 Tambahkan unit, negative, fuzz, invariant, dan multichain tests

Minimal test matrix:

- access control untuk semua fungsi admin/issuer;
- destination/source/sender tidak di-allowlist;
- trusted remote pair cross-product;
- zero receiver, empty CID, oversized/malformed payload;
- duplicate registration dan duplicate dispatch;
- satu dokumen ke beberapa destination;
- saldo fee kurang, approval gagal, Router/getFee/ccipSend revert;
- replay message ID dan duplicate CID;
- out-of-order register/revoke/supersede;
- receiver failure dan retry/manual recovery;
- withdrawal/rescue hanya admin;
- event fields dan indexed document ID;
- fuzz payload bounds dan issuer signature;
- invariant bahwa versi/status tidak pernah mundur;
- fork test untuk config Router/LINK/selector aktif;
- periodic testnet E2E yang melacak message sampai destination, terpisah dari PR CI agar tidak flaky.

Target awal: 100% branch untuk contract milik Etherdoc, bukan untuk dependency.

### [ ] P2-02 Perketat CI

**TODO:**

- Perbaiki `forge fmt --check` dan normalisasi line ending melalui `.gitattributes`.
- Jalankan `forge lint --deny warnings` setelah 13 catatan penamaan dibersihkan.
- Tambahkan coverage Etherdoc dengan threshold.
- Tambahkan static analyzer yang versinya dipin dan exclude `lib/` dari scope.
- Pin `actions/checkout`, Foundry action, Foundry binary, dan runner OS secara sadar.
- Tambahkan dependency update automation yang membuat PR, bukan auto-merge.
- Tambahkan gas snapshot/contract size regression check.
- Uji deployment script dengan dry-run.

### [ ] P2-03 Buat deployment/configuration scripts yang idempotent

**TODO:**

- Satu script deploy per role, satu script configure remotes, satu script fund/withdraw.
- Gunakan `vm.env*` atau config JSON; jangan hardcode address.
- Pastikan rerun tidak diam-diam deploy/configure duplikat.
- Emit dan simpan deployment manifest berisi chain ID, selector, address, tx hash, git commit, compiler,
  constructor args, dan timestamp.
- Tambahkan contract verification command.
- Gunakan multisig/timelock untuk production config changes.

### [ ] P2-04 Tambahkan events dan query yang dapat diindeks

**TODO:**

- Event terpisah untuk registration, dispatch, receive, revoke, retry, remote config, pause, withdrawal,
  dan ownership/role changes.
- Gunakan `bytes32 indexed documentId`; string CID tetap dapat menjadi non-indexed data bila perlu.
- Simpan message ID ke record agar state dan event dapat direkonsiliasi.
- Buat indexer/reconciliation job yang membandingkan target chains dengan receive events.
- Alert untuk pending terlalu lama, failed execution, fee balance rendah, dan config drift.

### [ ] P2-05 Jadikan gas limit dan out-of-order policy bagian dari remote config

**Bukti:** gas limit selalu `200_000` dan out-of-order selalu `true`.

**TODO:**

- Benchmark receive path dan tetapkan gas limit per destination.
- Sediakan batas minimum/maksimum admin.
- Dokumentasikan alasan penggunaan out-of-order.
- Jika revocation/versioning ditambahkan, enforce monotonic version agar pesan lama aman.
- Tambahkan fee quote dan gas regression test.

### [ ] P2-06 Validasi constructor dan sederhanakan state

**TODO:**

- Validasi Router/LINK bukan zero address dan memiliki code pada deployment.
- Jadikan reference yang tidak berubah sebagai `immutable`.
- Decode `message.sender` dan `message.data` sekali.
- Gunakan custom errors yang membawa sender/selector/document ID untuk diagnosis.
- Emit event saat allowlist/config berubah.
- Konsistenkan nama `allowlistSourceChain` dan casing `CID/Cid`.

---

## P2 — README dan Dokumentasi

### [ ] P2-07 Ganti README template Foundry dengan dokumentasi Etherdoc

README saat ini masih template generik dan bahkan contoh deploy menunjuk `Counter.s.sol`.

README baru minimal harus memuat:

- tujuan dan batasan Etherdoc;
- definisi integrity, authenticity, validity, dan availability;
- diagram arsitektur source registry, CCIP dispatch, receiver replicas, IPFS, dan indexer;
- penjelasan bahwa CCIP asynchronous dan bukan transaksi atomic multichain;
- state machine dokumen dan status per-chain;
- threat/trust model: issuer, relayer, owner/multisig, Router, IPFS pinning;
- versi dependency/toolchain yang dipin;
- prerequisite Foundry dan `git clone --recurse-submodules`;
- install, build, fmt, lint, test, coverage;
- `.env.example` tanpa secret;
- deployment/configuration/verification langkah demi langkah;
- daftar network/address yang berasal dari generated deployment manifest, bukan angka copy-paste;
- cara funding fee, quote fee, monitoring message, retry/manual execution, dan withdrawal;
- cara memverifikasi file terhadap CID/digest serta status revocation;
- privacy warning untuk dokumen publik di IPFS;
- known limitations dan audit status;
- license dan contribution guide.

### [ ] P2-08 Tambahkan dokumen operasional

- `docs/ARCHITECTURE.md`
- `docs/THREAT_MODEL.md`
- `docs/DEPLOYMENT.md`
- `docs/INCIDENT_RESPONSE.md`
- `docs/VERSION_POLICY.md`
- generated deployment manifests per environment

---

## P3 — Optimasi Setelah Correctness

### [ ] P3-01 Gunakan identifier fixed-size untuk hot path

- Gunakan `bytes32 documentId` untuk mapping dan indexed event.
- Hindari mengirim string CID berulang bila digest + compact metadata cukup.
- Ukur biaya sebelum/sesudah; jangan mengorbankan kemampuan reconstruct/verify CID.

### [ ] P3-02 Pertimbangkan arsitektur registry tunggal vs full replication

Sebelum membayar storage dan CCIP untuk setiap chain, ukur kebutuhan produk:

- canonical registry + read/indexer lintas-chain;
- canonical registry + selected replicas;
- full replica pada semua chain.

Pilih berdasarkan trust, latency, availability, dan biaya. Full replication tidak otomatis memberi
keaslian lebih tinggi jika semua replica berasal dari issuer/admin yang sama.

### [ ] P3-03 Pertimbangkan upgradeability hanya setelah governance siap

Jika proxy benar-benar diperlukan, dokumentasikan storage layout, upgrade authorization, delay,
rollback, monitoring, dan test upgrade. Bila tidak, gunakan immutable deployments dengan remote
rotation yang eksplisit.

---

## Urutan Implementasi yang Disarankan

### Milestone 1 — Benarkan model

- [ ] Tulis specification keaslian/provenance.
- [ ] Implementasikan structured document record.
- [ ] Pisahkan register dan dispatch.
- [ ] Tambahkan state per destination dan retry.
- [ ] Implementasikan trusted remote pair.

### Milestone 2 — Recovery dan operasional

- [ ] Pilih ACK vs indexer reconciliation.
- [ ] Implementasikan failure/retry strategy.
- [ ] Tambahkan fee quote, max fee, withdrawal, pause, dan events.
- [ ] Migrasikan owner production ke multisig/roles.

### Milestone 3 — Test dan config

- [ ] Selesaikan negative/fuzz/invariant test matrix.
- [ ] Hapus hardcoded network config dan Holesky.
- [ ] Tambahkan fork + periodic E2E test.
- [ ] Perketat CI dan format.

### Milestone 4 — Upgrade versi secara koheren

- [ ] Selaraskan dependency Chainlink tanpa version skew.
- [ ] Upgrade Chainlink Local dari beta.
- [ ] Pin Foundry/compiler/EVM/optimizer.
- [ ] Evaluasi CCIP 2.0 di branch terpisah.
- [ ] Review gas, bytecode, ABI, dan deployment migration.

### Milestone 5 — Dokumentasi dan production readiness

- [ ] Tulis ulang README.
- [ ] Tambahkan threat model, runbook, version policy, dan deployment manifest.
- [ ] Jalankan audit keamanan independen setelah code freeze.

---

## Referensi Resmi

- [Chainlink CCIP Directory — Testnet](https://docs.chain.link/ccip/directory/testnet)
- [CCIPReceiver v1.6.0 API](https://docs.chain.link/ccip/api-reference/evm/v1.6.0/ccip-receiver)
- [CCIP contracts 2.0.0 release](https://github.com/smartcontractkit/chainlink-ccip/releases/tag/contracts-ccip-v2.0.0)
- [Chainlink Local 0.2.9 release](https://github.com/smartcontractkit/chainlink-local/releases/tag/v0.2.9)
- [Foundry 1.7.1 release](https://github.com/foundry-rs/foundry/releases/tag/v1.7.1)
- [forge-std 1.16.2 release](https://github.com/foundry-rs/forge-std/releases/tag/v1.16.2)
- [Solidity 0.8.36 release](https://github.com/argotorg/solidity/releases/tag/v0.8.36)
- [Ethereum Foundation: Holesky shutdown](https://blog.ethereum.org/2025/09/01/holesky-shutdown-announcement)
