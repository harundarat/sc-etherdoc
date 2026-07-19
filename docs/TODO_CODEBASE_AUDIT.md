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
  - `dispatchDocument(documentId, destinationChainSelector, maximumFee)` untuk setiap lane.
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

### [x] P0-04 Migrasikan deployment dari Holesky dan hapus konfigurasi jaringan hardcoded

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

### [x] P1-01 Allowlist pasangan `(sourceChainSelector, sender)`, bukan dua daftar independen

**Bukti:** `src/EtherdocReceiver.sol:17-18` dan `49-55`.

Source chain dan sender divalidasi melalui dua mapping terpisah. Jika beberapa chain dan sender
diaktifkan, kombinasi silang semuanya ikut lolos walaupun hanya pasangan tertentu yang dimaksud.

**TODO:**

- Gunakan `mapping(uint64 => mapping(address => bool)) trustedRemote`.
- Sediakan satu fungsi konfigurasi remote yang mengubah chain dan sender secara atomic.
- Emit event untuk setiap perubahan trusted remote.
- Tolak zero address dan selector invalid.

**Selesai jika:** test matriks A/X dan B/Y membuktikan A/Y serta B/X ditolak.

### [x] P1-02 Bind destination chain ke receiver yang dikonfigurasi

**Bukti terkini:** `src/EtherdocSender.sol:49-53`, `140`, `297-346`, dan `398-421`;
`script/ConfigureEtherdocSender.s.sol:13-24`; serta `test/EtherdocSender.t.sol:142-177` dan
`322-359`.

Bukti awal sudah stale karena refactor P0 sebelumnya telah menghapus parameter receiver dari
`dispatchDocument`, tetapi gas limit masih berupa konstanta global dan binding tersebut belum diuji
secara langsung. Implementasi sekarang menyimpan `RemoteConfig` atomic berisi receiver, gas limit,
dan status allowlist untuk setiap selector. Dispatch hanya membaca config tersebut, menyimpan
receiver/gas limit yang dipakai ke record, dan memancarkannya pada event.

Rotasi dilakukan eksplisit melalui fungsi governance-only `configureRemote` dan event
`RemoteConfigUpdated`; zero selector, zero receiver, serta zero gas limit ditolak. Script konfigurasi
memvalidasi bytecode receiver melalui RPC destination sebelum mengirim perubahan config. Validasi ini
hanya snapshot saat konfigurasi karena bytecode destination tetap dapat berubah sesudahnya.
Governance production dan pemisahan role dicakup P1-06; timelock tetap tidak ditambahkan karena
kontrak sengaja non-upgradeable dan perubahan config sudah melalui multisig.

**TODO:**

- Simpan `RemoteConfig` per destination selector, termasuk receiver dan gas limit.
- Jangan terima receiver arbitrary di fungsi dispatch normal.
- Untuk rotasi receiver, gunakan perubahan config eksplisit, event, dan bila perlu timelock.
- Validasi code size receiver pada script/fork test; pahami bahwa code destination tetap dapat berubah
  setelah validasi.

### [x] P1-03 Tambahkan payload schema, versioning, validation, dan idempotency

**Bukti terkini:** bukti awal sudah stale karena refactor provenance telah mengganti payload string
polos dengan `DocumentRecord`, tetapi record tersebut masih dikirim tanpa envelope operation/version,
CID hanya diperiksa kosong di source, dan receiver belum menyimpan processed `messageId`.
`src/EtherdocTypes.sol:5-45`, `src/EtherdocSender.sol:243-328` dan `450-490`, serta
`src/EtherdocReceiver.sol:102-175` dan `216-280` sekarang menggunakan `DocumentPayload` schema v1
yang mengikat operation, document ID, version, dan provenance. Source dan destination membatasi CID
sampai 256 byte dan encoded payload sampai 1.024 byte serta memvalidasi schema, commitment, field
envelope, timestamp, operation/status, dan transisi versi.

Aturan duplicate dipilih idempotent: replay `messageId` dan pesan berbeda dengan versi equal/stale
tidak mengubah receipt, ditandai processed, dan memancarkan `MessageIgnored`. Payload invalid,
provenance/state yang konflik, atau transisi baru setelah state terminal tetap revert. ExtraArgs V3
tidak memiliki toggle `allowOutOfOrderExecution`; schema 2 tetap membatasi `REGISTER` ke version 1
dan `REVOKE`/`SUPERSEDE` ke terminal version 2. Test mengirim revocation lebih dulu lalu registration
lama dan membuktikan dokumen tidak aktif kembali
(`EtherdocLifecycleTest.test_outOfOrderOlderMessageCannotReactivateRevokedDocument`).

**TODO:**

- Gunakan payload struct dengan `schemaVersion`, `documentId`, provenance, version/nonce, dan operation
  (`REGISTER`, `REVOKE`, `SUPERSEDE`).
- Validasi panjang/format sebelum send dan setelah receive.
- Tolak CID kosong serta payload yang melebihi batas aplikasi.
- Decode sender dan data sekali saja.
- Simpan processed `messageId` untuk idempotency dan observability.
- Putuskan aturan duplicate document: ignore idempotently atau revert secara eksplisit.
- Pastikan version/nonce monoton dan pesan lama tidak dapat mengaktifkan kembali dokumen yang sudah
  revoked, terlepas dari urutan eksekusi permissionless CCIP 2.0.

### [x] P1-04 Rancang recovery untuk receiver failure dan retry dispatch

**Bukti terkini:** bukti awal sudah stale karena registrasi dan dispatch telah dipisah. Router source
yang revert tidak meninggalkan dispatch record sehingga lane/version yang sama dapat dipanggil lagi
(`src/EtherdocSender.sol:235-291`; `test/EtherdocSender.t.sol:181-202`). Setelah Router menerima
pesan, strategi yang dipilih adalah receiver tetap revert dan operator melakukan manual CCIP
execution dengan message ID yang sama. Receiver hanya menandai pesan processed setelah sukses;
autentikasi, payload, dan transisi invalid tidak menghasilkan receipt.

`EtherdocLifecycleTest.test_failedDestinationExecutionCanRetrySameMessage` memodelkan status
eksekusi Router `FAILURE`, menyimpan return data custom error untuk monitoring, membuktikan
kegagalan autentikasi tidak tertelan, lalu mengeksekusi ulang message ID yang sama setelah
konfigurasi diperbaiki hingga status `SUCCESS`.
Runbook `docs/CCIP_RECOVERY_RUNBOOK.md` mendokumentasikan monitoring, perbedaan retry source dengan
manual execution destination, gas override, pause/resume lane, validasi setelah recovery, dan
incident evidence. Event receiver tidak dipakai sebagai failure signal karena event ikut di-revert;
status dan return data CCIP adalah bukti gagal yang persisten.

**TODO:**

- Pilih dan dokumentasikan satu strategi:
  - revert dan operasikan manual CCIP execution; atau
  - defensive receiver yang menyimpan failed message dan menyediakan controlled retry.
- Tambahkan status/event kegagalan aplikasi yang dapat dimonitor.
- Jangan menelan kegagalan autentikasi sebagai pesan valid.
- Tambahkan runbook untuk manual execution, retry, pause, dan incident response.
- Uji receiver yang sengaja gagal, kemudian recovery tanpa duplicate state.

### [x] P1-05 Amankan fee approval dan pengelolaan dana

**Bukti terkini:** bukti awal masih relevan untuk approval dan withdrawal, tetapi Router serta LINK
sebenarnya sudah `immutable`. Sender sekarang memakai `SafeERC20.forceApprove`, membaca balance satu
kali, dan mewajibkan `maximumFee` pada setiap `dispatchDocument`. `quoteFee` membangun pesan yang sama
dengan dispatch sehingga orchestrator dapat menetapkan batas, sementara kenaikan fee antara quote
dan mining menghasilkan `FeeExceedsMaximum` tanpa menulis dispatch record.

Model biaya yang dipilih adalah treasury-funded LINK; contract tidak menarik dana dari issuer atau
relayer dan native fee belum didukung. `withdrawToken` dapat mengembalikan LINK berlebih atau rescue
ERC-20 lain, hanya dapat dipanggil governance, menolak zero token/recipient, memakai `safeTransfer`,
dan memancarkan `TokenWithdrawn`. README mendokumentasikan funding, slippage/toleransi, race quote
dengan mining, requote, dan withdrawal.

Test `EtherdocSenderTest.test_quoteFeeAndMaximumProtectAgainstFeeIncrease` mencakup fee race dan
max-fee guard. Test mock juga mencakup balance tidak cukup, token yang mensyaratkan reset allowance,
approval gagal, transfer gagal, otorisasi withdrawal, validasi alamat, dan event. Penambahan ini
awalnya melewati EIP-170 karena sender sebelumnya hanya memiliki margin 851 byte; optimizer Solidity
diaktifkan eksplisit dengan 200 runs dan ukuran deployment kembali diverifikasi.

**TODO:**

- Gunakan `SafeERC20.forceApprove`/mekanisme approval yang kompatibel dengan versi dependency yang
  dipilih.
- Jadikan Router dan fee token immutable jika memang tidak dapat diubah.
- Tambahkan `quoteFee` agar caller/orchestrator dapat memperkirakan biaya.
- Tambahkan governance-only withdrawal/rescue dengan event dan zero-address validation.
- Putuskan model biaya: treasury-funded LINK, native fee, atau user-funded; dokumentasikan slippage
  fee dan race antara quote dan mining.
- Cache hasil `balanceOf` dan cek approval/transfer failure pada test mock.
- Pertimbangkan batas fee maksimum dari caller agar dispatch tidak membayar fee yang melonjak tanpa
  batas.

### [x] P1-06 Ganti single hot-key owner dengan model issuer/governance yang sesuai

**Bukti terkini:** bukti awal sudah stale. `OwnerIsCreator` telah diganti dengan
`EtherdocGovernance` berbasis `ConfirmedOwner`, sehingga alamat governance diberikan eksplisit pada
constructor dan rotasi berikutnya tetap memakai `transferOwnership` + `acceptOwnership`.
`src/EtherdocGovernance.sol:10-47`, `src/EtherdocSender.sol:146-177` dan `297-300`, serta
`src/EtherdocReceiver.sol:76-113`.

Governance production ditetapkan sebagai multisig dan hanya governance yang dapat mengubah issuer,
operator/pauser, remote config, treasury, atau melakukan unpause. Issuer tetap registry terpisah;
`OPERATOR_ROLE` hanya melakukan dispatch; `PAUSER_ROLE` hanya dapat menghentikan registration,
dispatch, atau receive. Relayer sengaja permissionless tanpa privileged role karena setiap operasi
relayed tetap memerlukan signature EIP-712 issuer. Constructor deployment menerima governance,
issuer, operator, dan pauser secara eksplisit sehingga broadcaster tidak otomatis memperoleh
otoritas. `script/EtherdocSenderScript.s.sol:13-32`,
`script/EtherdocReceiverScript.s.sol:13-27`, dan `docs/GOVERNANCE_RUNBOOK.md`.

Pause registration mencakup registration langsung/signed dan supersession, tetapi revocation tetap
tersedia sebagai jalur invalidasi darurat. Pause dispatch mencegah message baru. Pause receive
membuat eksekusi CCIP revert tanpa receipt/processed marker sehingga message ID yang sama dapat
di-retry. Kebijakan recovery mewajibkan governance multisig melakukan unpause setelah incident
review, dengan receive dibuka sebelum dispatch. Test role, zero account, two-step ownership,
pause/unpause, pembatasan pauser, dan retry receiver tercakup di
`test/EtherdocSender.t.sol:179-283` dan `test/EtherdocLifecycle.t.sol:229-267`.

Proxy tidak ditambahkan. Kebijakan yang dipilih adalah immutable deployment, lalu redeploy dan rotasi
remote eksplisit jika logic berubah. Timelock dapat dievaluasi terpisah bila cadence perubahan
governance membutuhkannya.

**TODO:**

- Gunakan multisig untuk admin production.
- Pisahkan role admin, issuer, pauser, dan operator/relayer sesuai kebutuhan.
- Tambahkan emergency pause untuk registration/dispatch/receive dengan kebijakan unpause jelas.
- Pertahankan two-step ownership transfer.
- Hindari proxy upgradeability kecuali kebutuhan upgrade dan governance benar-benar didefinisikan;
  redeploy + remote rotation sering lebih sederhana dan memiliki trust surface lebih kecil.

### [x] P1-07 Definisikan canonical hashing/CID dan kebijakan IPFS

**Bukti terkini:** bukti awal sudah stale sebagian karena `bytes32 documentId` telah digunakan, tetapi
identitas konten masih berupa `keccak256` atas teks CID dan source hanya memeriksa string tidak kosong
serta panjang maksimum. Implementasi schema v2 sekarang menetapkan SHA-256 byte file mentah sebagai
`contentDigest` utama dan `documentId = keccak256(abi.encode(issuer, contentDigest))`.
`src/EtherdocTypes.sol`, `src/EtherdocSender.sol`, dan `src/EtherdocReceiver.sol`.

CID retrieval dibatasi ke CIDv1 canonical: bare lowercase unpadded base32, codec `raw` atau `dag-pb`,
dan multihash SHA2-256 32 byte. Kedua endpoint mendecode dan memvalidasi CID serta menyimpan
`cidCodec`/`cidDigest`; raw CID juga harus memiliki multihash yang sama dengan digest file. Signature
EIP-712 version 2 mengikat digest file dan metadata CID, sementara payload CCIP schema v2 menolak
record legacy atau inkonsisten. Test mencakup fixture CID known-answer, URI/prefix/karakter/padding
non-canonical, codec unsupported, raw digest mismatch, dag-pb, metadata receiver yang diubah, serta
alur signature dan cross-chain.

Canonicalization, upload gate, minimal dua pin lintas failure domain, full retrieval health check,
retention, backup/CAR recovery, privacy/encryption, dan langkah verifier ditetapkan di
`docs/IPFS_POLICY.md` serta dirujuk README. Kode uploader/pinning/frontend tetap tidak berada dalam
repo smart contract ini; policy tersebut menjadi requirement wajib bagi integrasi off-chain dan
secara eksplisit melarang registrasi sebelum pin/retrieval gate lulus.

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
| Solidity | pragma/config exact `0.8.36`; EVM `paris` | `0.8.36` | Current dan reproducible |
| Foundry | `.foundry-version` dan CI exact `1.7.1` | `1.7.1` | Lokal/CI selaras |
| `forge-std` | commit `bf647bd...`, versi `1.16.2` | `1.16.2` | Current dan dipin |
| `@chainlink/contracts-ccip` | commit `c2c125c...`, versi `2.0.0` | `2.0.0` | Migrasi selesai; direct root submodule |
| `@chainlink/local` | dihapus | `0.2.9` | Simulator 1.x dan nested CCIP 1.6.2 tidak dipakai |
| `@chainlink/contracts` | commit `86aa5a1...`, versi `1.5.0` | `1.5.0` | Selaras dengan matrix CCIP 2.0 |
| `@openzeppelin/contracts` | commit `e4f7021...`, versi `5.3.0` | `5.3.0` | Direct root submodule |
| `actions/checkout` | commit `34e1148...` (`v4.3.1`) | `v7.0.0` | Major lama, tetapi supply-chain ref immutable |
| `foundry-toolchain` action | commit `b00af27...` (`v1.9.0`); Foundry `v1.7.1` | action `v1.9.0` | Action dan binary immutable |

### [x] P1-08 Hilangkan version skew Chainlink

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

**Implementasi final (2026-07-19):**

- CCIP menjadi direct root submodule pada release 2.0.0, Contracts tetap 1.5.0, dan OpenZeppelin
  menjadi direct root submodule 5.3.0; semuanya dipin ke full commit.
- Chainlink Local, nested CCIP 1.6.2, dan seluruh remapping ambigu dihapus.
- Import aplikasi menggunakan alias versioned `@openzeppelin/contracts@5.3.0`.
- Versi, full commit, remapping, prosedur verifikasi, dan update gate dicatat di
  `docs/DEPENDENCY_POLICY.md`.
- Regression lane aplikasi memakai Router harness CCIP 2.0, bukan simulator CCIP 1.x.

### [x] P1-09 Evaluasi CCIP 2.0 sebagai migration project terpisah

CCIP 2.0 adalah major release dengan konsep CCV, executor, finality, message format, dan receiver
interface baru. Jangan mengubah dependency lalu menganggap kontrak lama setara.

**TODO:**

- Bandingkan API `IRouterClient`, `Client`, `CCIPReceiver`, extra args, fee, dan finality.
- Verifikasi lane/router deployment dan fitur 2.0 di CCIP Directory untuk semua target.
- Tentukan backward compatibility untuk receiver v1 dan message yang masih pending.
- Buat branch migration dan suite fork/E2E khusus.
- Deploy kontrak baru dan lakukan remote rotation terkontrol bila storage/interface tidak kompatibel.

**Implementasi (2026-07-19):**

- Clean cutover dilakukan tanpa kompatibilitas deployment atau pesan lama karena Etherdoc belum
  pernah mainnet.
- Sender memakai `ExtraArgsCodec.GenericExtraArgsV3`: `uint32 gasLimit`,
  `WAIT_FOR_FINALITY_FLAG`, daftar CCV kosong untuk CommitteeVerifier default, dan executor
  `address(0)` untuk executor default. FTF, custom CCV/executor, `NO_EXECUTION_TAG`, dan token
  transfer tidak diaktifkan.
- Receiver memakai `CCIPReceiver` 2.0, mendukung interface receiver V1 dan V2, serta mengekspos
  default policy melalui `getCCVsAndFinalityConfig`.
- Router/getFee/approval/fee ceiling/ccipSend tetap dipakai melalui public Router interface yang
  kompatibel. Replay protection, trusted remote, lifecycle, pause, dan receiver-revert/manual
  execution tetap dipertahankan.
- Config contoh diganti menjadi Mantle Sepolia → Ink Sepolia. Router, LINK, selector, explorer, dan
  RPC alias diverifikasi terhadap Directory; fork test membuktikan kedua Router memiliki bytecode,
  mendukung selector lawan, dan menerima quote ExtraArgs V3. Directory yang diperiksa ulang pada
  2026-07-19 melabeli Mantle → Ink sebagai lane 1.6.0 dan Ink → Mantle sebagai 2.0.0; versi package
  kontrak, kemampuan Router, dan versi lane tidak lagi disamakan dalam dokumentasi.
- Known-answer codec, overflow gas, V1/V2 interface, policy receiver, lifecycle, failure/retry,
  Router harness E2E, dan optional fork coverage ditambahkan.

### [x] P1-10 Pin compiler, EVM target, optimizer, dan Foundry secara eksplisit

**Bukti awal (sudah stale):** `foundry.toml` hanya mengaktifkan optimizer dengan 200 runs tanpa
compiler atau EVM version. EVM target efektif bergantung pada versi Foundry dan CI mengambil
floating Foundry stable melalui `foundry-rs/foundry-toolchain@v1`.

**TODO:**

- Tetapkan `solc_version` dan `evm_version`; review serta pertahankan nilai `optimizer` dan
  `optimizer_runs` secara eksplisit.
- Pin Foundry CI ke release exact dan pin GitHub Action ke full commit SHA.
- Samakan versi developer lokal dan CI, misalnya melalui dokumentasi/tool version file.
- Tambahkan `[profile.ci]` yang nyata atau hapus `FOUNDRY_PROFILE=ci` yang menyesatkan.
- Setelah upgrade compiler, jalankan seluruh test, bytecode-size diff, gas diff, dan deployment
  simulation.

**Implementasi (2026-07-19):**

- Seluruh source aplikasi, script, dan test dinaikkan ke pragma exact Solidity `0.8.36`;
  `foundry.toml` memaksa compiler yang sama, target EVM `paris`, optimizer aktif, dan 200 runs.
  Target Paris mengikuti konfigurasi upstream CCIP 2.0 dan mencegah compiler mengeluarkan opcode
  hardfork baru secara tidak sengaja pada lane lintas EVM yang heterogen.
- Foundry dipin ke `v1.7.1` melalui `.foundry-version`. CI memasang release exact tersebut memakai
  `foundry-toolchain` `v1.9.0` pada full commit SHA dan memverifikasi versi hasil instalasi.
  `actions/checkout` juga dipin ke full SHA `v4.3.1`.
- Profile `ci` sekarang nyata: tetap mewarisi seluruh build setting production, dengan fuzz runs
  1.024 serta invariant runs/depth 512/500. `FOUNDRY_PROFILE=ci` tidak lagi sekadar label kosong.
- `forge-std` dinaikkan ke `v1.16.2` karena compiler baru memperlihatkan warning kompatibilitas pada
  versi 1.9.7. Warning dari dependency `lib/` yang dipin dipisahkan, sedangkan warning Etherdoc tetap
  terlihat.
- `forge fmt --check`, build bersih, dan 57 test lulus (0 gagal, 1 optional fork skip tanpa RPC)
  pada profile default maupun `ci`. Fork Mantle live juga lulus untuk support Ink dan quote V3.
- Runtime sender berubah 18.601 → 19.007 byte (+406; margin EIP-170 5.569 byte), sedangkan receiver
  11.585 → 11.827 byte (+242). Deployment gas report berubah 4.198.779 → 4.281.280 untuk sender dan
  2.617.714 → 2.667.117 untuk receiver. Average dispatch hanya berubah 425.787 → 425.919 gas.
- Dry-run `EtherdocSenderScript` terhadap RPC Mantle Sepolia chain ID 5003 berhasil melakukan
  preflight serta simulasi deployment tanpa broadcast; estimasi total script 5.611.953 gas.

---

## P2 — Test, CI, Deployment, dan Observability

### [x] P2-01 Tambahkan unit, negative, fuzz, invariant, dan multichain tests

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

**Implementasi (2026-07-19):**

- Mock Router dipisahkan dari test contract dan menyediakan failure injection untuk `getFee`,
  `ccipSend`, deferred delivery, arbitrary source/sender encoding, serta manual retry.
- Suite negative mencakup seluruh setter/admin boundary, issuer ownership, pause state machine,
  remote pair cross-product, zero/malformed envelope, payload/schema/operation/document validation,
  duplicate/replay, provenance/state conflict, fee/token/Router failure, recovery, withdrawal, serta
  field event lengkap dengan indexed document ID.
- Sebelas fuzz properties mencakup raw/dag-pb CID, duplicate CID lintas issuer yang tetap memiliki
  provenance berbeda, `uint32` gas/selector/fee bounds, EIP-712 signer dan tamper resistance,
  payload di dalam/di luar bound, serta 2–8 lane independen.
- Handler-based invariant suite mengacak delivery/replay register dan revoke. Pada profile default,
  masing-masing dari tiga invariant menjalankan 128.000 call tanpa revert; ghost state membuktikan
  version/status receiver tidak mundur, dispatch per versi immutable, dan processed message selalu
  menunjuk canonical document ID. Profile CI menaikkannya menjadi 256.000 call per invariant dan
  fuzz menjadi 1.024 run per property.
- Local Router harness tetap menguji pengiriman sinkron dan deferred multichain. Optional fork test
  untuk Mantle dan Ink memverifikasi Router/LINK bytecode, `isChainSupported`, dan quote ExtraArgs V3
  dua arah; masing-masing skip eksplisit bila RPC tidak tersedia.
- Workflow `testnet-e2e.yml` terpisah dari PR CI, disabled by default, dan hanya aktif dengan
  protected environment plus `CCIP_E2E_ENABLED=true`. Workflow mendaftarkan CID unik, dispatch,
  mengambil indexed `messageId`, lalu polling receipt destination sampai document ID cocok.
- Guard yang terbukti tidak mungkin dicapai di schema v2 dihapus: payload sender selalu fixed-size
  di bawah batas karena CID canonical 59 byte, lifecycle hanya menerima version 1/2, dan decoder CID
  sudah dibatasi panjang input. Precondition registration pause dipindah dari modifier overload ke
  private check agar source mapping coverage akurat tanpa perubahan semantik.
- `forge coverage --report summary --no-match-test 'invariant_' --no-match-coverage
  '(script|test|lib)'` menghasilkan 100% line (410/410), statement (416/416), branch (73/73), dan
  function (72/72) untuk seluruh `src/`.
- Suite default dan CI masing-masing lulus 90 test dengan 0 failure dan 2 fork skip tanpa RPC.
  Eksekusi fork menggunakan RPC publik resmi lulus 2/2. `forge build --sizes` mencatat runtime
  sender 18.820 byte (margin EIP-170 5.756 byte) dan receiver 11.522 byte.

### [x] P2-02 Perketat CI

**TODO:**

- Perbaiki `forge fmt --check` dan normalisasi line ending melalui `.gitattributes`.
- Jalankan `forge lint --deny warnings` setelah 13 catatan penamaan dibersihkan.
- Tambahkan coverage Etherdoc dengan threshold.
- Tambahkan static analyzer yang versinya dipin dan exclude `lib/` dari scope.
- Pin `actions/checkout`, Foundry action, Foundry binary, dan runner OS secara sadar.
- Tambahkan dependency update automation yang membuat PR, bukan auto-merge.
- Tambahkan gas snapshot/contract size regression check.
- Uji deployment script dengan dry-run.

**Implementasi (2026-07-19):**

- `.gitattributes` menormalisasi seluruh source/text ke LF. CI menjalankan `forge fmt --check` dan
  `forge lint --deny warnings src script test`; runner dipin ke `ubuntu-24.04`, sedangkan checkout
  action, Foundry action, Foundry v1.7.1, Solc 0.8.36, Paris EVM, dan optimizer tetap diverifikasi.
- `script/check-coverage.sh` menjadikan 100% line, statement, branch, dan function coverage untuk
  `src/` sebagai hard threshold. Invariant tetap berjalan pada full suite, tetapi dikecualikan dari
  instrumentasi coverage yang redundan.
- Slither action dipin ke commit `b52cc1cbfee9ca3e8722dd5224299d16c9a6b80f` dan analyzer ke
  0.11.5. Dependency, script, serta test tetap dikompilasi tetapi finding-nya difilter; severity
  medium ke atas menggagalkan CI. Detector strict equality ditriase karena equality enum/digest/ID
  adalah validasi yang disengaja.
- Temuan Slither tentang callback Router ditangani dengan `ReentrancyGuard` pada dispatch dan test
  adversarial ketika Router sendiri diberi operator role. Callback kedua ditolak dan outer dispatch
  tetap menghasilkan tepat satu record.
- Dependabot membuat PR mingguan terpisah untuk GitHub Actions dan git submodule, tanpa workflow
  auto-approve atau auto-merge.
- `.gas-snapshot` melacak registrasi, fee-protected dispatch, dan local end-to-end delivery dengan
  toleransi 5%. Budget size machine-readable membatasi sender pada 19.500/21.500 byte dan receiver
  pada 12.000/12.800 byte untuk runtime/initcode, sekaligus memverifikasi hard limit EIP.
- `script/ci-deployment-dry-run.sh` menjalankan deploy sender dan receiver terhadap Anvil chain
  31337 dengan Router/LINK stub. Kedua simulasi lulus dan nonce broadcaster dipastikan tidak berubah,
  sehingga gate ini membuktikan tidak ada transaksi yang dibroadcast.
- Verifikasi final lulus: fmt dan lint tanpa warning; suite default serta CI masing-masing 91 pass,
  0 fail, 2 optional fork skip; profile CI menjalankan 1.024 fuzz case/property dan 256.000
  call/invariant. Coverage tetap 100% untuk 410 line, 416 statement, 73 branch, dan 72 function.
  Slither medium gate lulus; output tersisa hanya detector timestamp low-severity yang juga
  mengelompokkan field enum pada struct bertimestamp. Runtime/initcode aktual adalah
  18.880/20.826 byte untuk sender dan 11.522/12.321 byte untuk receiver.

### [x] P2-03 Buat deployment/configuration scripts yang idempotent

**TODO:**

- Satu script deploy per role, satu script configure remotes, satu script fund/withdraw.
- Gunakan `vm.env*` atau config JSON; jangan hardcode address.
- Pastikan rerun tidak diam-diam deploy/configure duplikat.
- Emit dan simpan deployment manifest berisi chain ID, selector, address, tx hash, git commit, compiler,
  constructor args, dan timestamp.
- Tambahkan contract verification command.
- Gunakan multisig/timelock untuk production config changes.

**Implementasi (2026-07-19):**

- Deployment tetap dipisah per role melalui `EtherdocSenderScript` dan `EtherdocReceiverScript`.
  Keduanya membaca address book, memverifikasi bytecode serta dependency Router/LINK melalui getter
  on-chain, lalu memakai kembali deployment yang cocok. Address tanpa code atau dependency berbeda
  gagal eksplisit dan tidak memicu deployment pengganti.
- Dua configurator lama digabung menjadi satu `ConfigureEtherdocRemotesScript` dengan target
  `SENDER`/`RECEIVER`. Script membandingkan selector, receiver, gas limit, allowlist, dan trusted
  remote pair sebelum write. `ManageEtherdocTreasuryScript` memakai target saldo LINK untuk funding
  dan retained balance untuk withdrawal, sehingga seluruh rerun menjadi no-op berbasis desired
  state.
- Network JSON sekarang mewajibkan `governanceMode` dan `production`. Kombinasi production +
  `DIRECT` ditolak, sedangkan mode `MULTISIG` juga mewajibkan `GOVERNANCE` memiliki bytecode.
  Configure/withdraw pada mode tersebut menghasilkan JSON Safe Transaction Builder yang dapat
  direview dan dieksekusi threshold multisig; proposal identik dipertahankan tanpa rewrite.
- `script/deploy-contract.sh` menolak source dirty secara default, merekonsiliasi address dengan
  broadcast receipt dan runtime code, lalu menyimpan manifest per role berisi chain ID/selector,
  address, transaction hash, block/timestamp, deployer, runtime code hash, git commit, compiler/EVM/
  optimizer, serta constructor args decoded dan ABI-encoded. Existing address tanpa manifest ditolak
  agar history transaksi tidak direka ulang.
- `script/verify-contract.sh` merakit `forge verify-contract --watch` dari manifest, termasuk exact
  compiler setting, constructor args, dan creation transaction hash. Mode `VERIFY_DRY_RUN=1`
  memvalidasi chain/code dan mencetak command tanpa mengirim request verifier.
- Preflight remote `eth_getCode` diperbaiki setelah workflow nyata menemukan double ABI-decode:
  `vm.rpc` sudah mengembalikan runtime bytecode sebagai `bytes`. `docs/DEPLOYMENT.md`, governance
  runbook, README, dan `.env-example` sekarang mendokumentasikan keseluruhan alur.
- Unit test baru mencakup reuse/mismatch deployment, config drift/no-op, treasury target arithmetic,
  nama network aman, production governance, dan proposal Safe yang idempotent. Workflow Anvil
  membroadcast kedua role, configure kedua endpoint lane, fund, withdraw, dan kemudian membuktikan semua rerun
  tidak mengubah nonce. Manifest serta dry verification command juga divalidasi di CI.
- Verifikasi final lulus: fmt/lint, Slither 0.11.5 medium gate, size/gas gate, dry-run tanpa broadcast,
  dan workflow idempotent. Suite default/CI lulus 102 test, 0 gagal, 2 optional fork skip; CI
  menjalankan 1.024 fuzz case/property dan 256.000 call/invariant. Coverage tetap 100% untuk 414
  line, 418 statement, 73 branch, dan 74 function. Runtime/initcode akhir adalah 18.988/20.948 byte
  untuk sender dan 11.522/12.321 byte untuk receiver.

### [ ] P2-04 Tambahkan events dan query yang dapat diindeks

**TODO:**

- Event terpisah untuk registration, dispatch, receive, revoke, retry, remote config, pause, withdrawal,
  dan ownership/role changes.
- Gunakan `bytes32 indexed documentId`; string CID tetap dapat menjadi non-indexed data bila perlu.
- Simpan message ID ke record agar state dan event dapat direkonsiliasi.
- Buat indexer/reconciliation job yang membandingkan target chains dengan receive events.
- Alert untuk pending terlalu lama, failed execution, fee balance rendah, dan config drift.

### [x] P2-05 Jadikan gas limit dan kebijakan eksekusi bagian dari remote config

**Bukti:** gas limit selalu `200_000` dan out-of-order selalu `true`.

**TODO:**

- Benchmark receive path dan tetapkan gas limit per destination.
- Sediakan batas minimum/maksimum admin.
- Dokumentasikan alasan penggunaan out-of-order.
- Jika revocation/versioning ditambahkan, enforce monotonic version agar pesan lama aman.
- Tambahkan fee quote dan gas regression test.

**Implementasi (2026-07-19):**

- Gas limit disimpan per remote sebagai `uint32`, divalidasi saat config JSON diparsing, dicatat pada
  dispatch record/event, dan diuji untuk zero serta overflow ABI.
- ExtraArgs V3 menghapus toggle out-of-order V2. Etherdoc memilih full finality dan default
  CCV/executor; monotonic document version tetap mencegah state mundur.
- Quote, maximum fee, destination-specific gas, dan known-answer V3 diuji.

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
- [x] Implementasikan trusted remote pair.

### Milestone 2 — Recovery dan operasional

- [ ] Pilih ACK vs indexer reconciliation.
- [ ] Implementasikan failure/retry strategy.
- [x] Tambahkan fee quote, max fee, withdrawal, pause, dan events.
- [x] Migrasikan owner production ke multisig/roles.

### Milestone 3 — Test dan config

- [x] Selesaikan negative/fuzz/invariant test matrix.
- [x] Hapus hardcoded network config dan Holesky.
- [x] Tambahkan optional fork config + local E2E test.
- [x] Perketat CI dan format.

### Milestone 4 — Upgrade versi secara koheren

- [x] Selaraskan dependency Chainlink tanpa version skew.
- [x] Hapus Chainlink Local dan simulator CCIP 1.x.
- [x] Pin Foundry/compiler/EVM/optimizer.
- [x] Evaluasi dan migrasikan CCIP 2.0.
- [x] Review gas, bytecode, ABI, dan deployment migration.

### Milestone 5 — Dokumentasi dan production readiness

- [ ] Tulis ulang README.
- [ ] Tambahkan threat model, runbook, version policy, dan deployment manifest.
- [ ] Jalankan audit keamanan independen setelah code freeze.

---

## Referensi Resmi

- [Chainlink CCIP Directory — Testnet](https://docs.chain.link/ccip/directory/testnet)
- [CCIP contracts 2.0.0 release](https://github.com/smartcontractkit/chainlink-ccip/releases/tag/contracts-ccip-v2.0.0)
- [Mantle Sepolia CCIP Directory](https://docs.chain.link/ccip/directory/testnet/chain/ethereum-testnet-sepolia-mantle-1)
- [Ink Sepolia CCIP Directory](https://docs.chain.link/ccip/directory/testnet/chain/ink-testnet-sepolia)
- [Foundry 1.7.1 release](https://github.com/foundry-rs/foundry/releases/tag/v1.7.1)
- [forge-std 1.16.2 release](https://github.com/foundry-rs/forge-std/releases/tag/v1.16.2)
- [Solidity 0.8.36 release](https://github.com/argotorg/solidity/releases/tag/v0.8.36)
- [Ethereum Foundation: Holesky shutdown](https://blog.ethereum.org/2025/09/01/holesky-shutdown-announcement)
