# CCIP Recovery Runbook

Dokumen ini adalah prosedur operasional untuk dispatch Etherdoc yang gagal sebelum atau sesudah
Router source menerima pesan. Strategi Etherdoc adalah **receiver revert + CCIP manual execution**.
Receiver tidak menyimpan payload gagal atau menganggapnya sudah diproses.

## Invariant recovery

- `DISPATCHED` pada source hanya berarti Router source menerima pesan.
- Sukses destination memerlukan status eksekusi CCIP `SUCCESS`, event `MessageReceived`, dan
  `isMessageProcessed(messageId) == true`.
- Revert autentikasi, schema, payload, provenance, atau transisi state harus tetap menghasilkan
  status CCIP `FAILURE`. Tidak boleh dibuat receipt atau processed marker.
- Setelah Router source menerima pesan, recovery normal menggunakan **message ID yang sama** melalui
  manual execution. Jangan mengirim ulang payload dengan `dispatchDocument`.
- Jika transaksi `dispatchDocument` sendiri revert, tidak ada dispatch record. Setelah akar masalah
  diperbaiki, panggil kembali `dispatchDocument` untuk lane dan document version tersebut.

Event receiver tidak dapat menjadi failure signal karena seluruh event ikut di-revert. Signal gagal
yang persisten adalah execution state dan return data milik CCIP. Custom error Etherdoc pada return
data menjelaskan kegagalan aplikasi.

## Model eksekusi CCIP 2.0

Etherdoc mengirim ExtraArgs V3 dengan full finality, CommitteeVerifier default, dan executor default.
FTF, custom CCV, dan custom executor tidak diaktifkan. Executor CCIP 2.0 bersifat permissionless:
executor default menyediakan jalur otomatis, tetapi siapa pun tetap dapat mengeksekusi pesan yang
sudah terverifikasi. Etherdoc tidak menggunakan `NO_EXECUTION_TAG`, karena tag tersebut hanya
menonaktifkan pembayaran/otomasi executor dan bukan jaminan bahwa pesan tidak dapat dieksekusi.

Kebijakan receiver dapat diaudit melalui inherited
`getCCVsAndFinalityConfig(sourceChainSelector, sender)`: dua daftar CCV kosong dan threshold nol
memilih default CCV, sedangkan `WAIT_FOR_FINALITY_FLAG` berarti receiver hanya menerima pesan
full-finality. Recovery manual tidak boleh digunakan untuk melewati verifikasi CCV, finality,
trusted-remote, atau validasi payload aplikasi.

## Monitoring

Indexer atau alerting service harus:

1. Menangkap `MessageSent` dan menyimpan source transaction hash, `messageId`, document ID, version,
   selector, receiver, gas limit, dan timestamp.
2. Melacak message ID dengan
   [CCIP Explorer](https://ccip.chain.link/) atau `ccip-cli show`.
3. Menganggap workflow selesai hanya jika status CCIP `SUCCESS` dan receipt destination cocok dengan
   message ID tersebut.
4. Memberi alert jika status menjadi `FAILURE`, tetap `UNTOUCHED` melewati SLA lane, atau status
   `SUCCESS` tidak memiliki receipt Etherdoc yang cocok.
5. Menyimpan return data dari execution yang gagal. Decode dengan `ccip-cli parse` dan cocokkan
   selector dengan custom error di `EtherdocReceiver`.

Contoh read-only:

```shell
npx @chainlink/ccip-cli show "$MESSAGE_ID" --rpcs-file ./.env
npx @chainlink/ccip-cli parse "$RETURN_DATA"
```

Gunakan versi CLI yang telah diuji dan dipin oleh lingkungan operator. Dokumentasi command resmi
tersedia pada
[Debugging Failed Messages](https://docs.chain.link/ccip/tools/cli/guides/debugging-workflow).

## Triage dan recovery

### 1. Transaksi source gagal

1. Pastikan transaksi `dispatchDocument` revert dan `getDispatchAtVersion` tetap
   `NOT_DISPATCHED`.
2. Periksa LINK balance, allowance/Router error, remote config, lane health, dan fee.
3. Perbaiki penyebabnya.
4. Operator memanggil `quoteFee(documentId, selector)`, menentukan toleransi fee, lalu memanggil
   kembali `dispatchDocument(documentId, selector, maximumFee)`.
5. Mulai monitoring untuk message ID baru dari `MessageSent`.

Kegagalan transaksi source tidak dapat menghasilkan event persisten dari sender karena transaksi
revert. Transaction receipt dan revert data adalah failure evidence.

### 2. Eksekusi destination gagal

1. Jangan memanggil ulang `dispatchDocument`; dispatch record lama tetap menjadi korelasi utama.
2. Jalankan `ccip-cli show` dan simpan state serta return data.
3. Perbaiki penyebab yang aman diperbaiki:
   - `UntrustedRemote`: verifikasi chain selector dan address sender dari deployment artifact, lalu
     konfigurasi pasangan yang benar;
   - out-of-gas/return data kosong: profil receiver dan gunakan gas override saat manual execution;
   - lane/config pause: pastikan incident sudah ditutup sebelum membuka lane;
   - payload/provenance/state invalid: jangan bypass validasi. Payload CCIP immutable; eskalasi
     sebagai defect atau pesan berbahaya.
4. Setelah remediation dan verifikasi CCV/finality selesai, jalankan manual execution pada
   destination:

```shell
npx @chainlink/ccip-cli manual-exec "$MESSAGE_ID" \
  --rpcs-file ./.env \
  --wallet ledger
```

Untuk kegagalan gas saja, operator dapat memakai `--estimate-gas-limit <margin-percent>` atau
`--gas-limit <value>` setelah profiling. Jangan menaikkan gas secara buta untuk error logika.

5. Verifikasi ulang:

```shell
npx @chainlink/ccip-cli show "$MESSAGE_ID" --rpcs-file ./.env
```

Status harus `SUCCESS`; `isMessageProcessed(messageId)` harus `true`; `getMessageDocument(messageId)`
dan `getReceipt(documentId).messageId` harus menunjuk pasangan yang sama.

### 3. Manual execution kembali gagal

- Hentikan retry otomatis.
- Bandingkan return data baru dengan percobaan sebelumnya.
- Untuk error autentikasi atau payload invalid, pertahankan pesan sebagai gagal; jangan mengubah
  trusted remote hanya agar pesan lolos.
- Untuk pesan berurutan, pulihkan pesan gagal sebelumnya terlebih dahulu bila CCIP lane menerapkan
  ordering.
- Eskalasi ke maintainer kontrak dan operator lane dengan source transaction hash, message ID,
  selector, sender, receiver, payload hash, seluruh return data, dan transaction hash percobaan.

## Pause dan resume

Pauser dapat menghentikan alur tanpa memperoleh hak konfigurasi governance:

1. Hentikan dispatch baru di source dengan `pauseDispatch()`.
2. Inventarisasi semua message ID in-flight dan tunggu/triage satu per satu.
3. Jika destination juga harus ditutup, panggil `pauseReceive()`. Pesan in-flight akan revert tanpa
   receipt/processed marker dan perlu manual execution setelah receive dibuka kembali.
4. Bila insiden menyangkut issuance, panggil `pauseRegistration()`. Revocation tetap tersedia agar
   issuer dapat membatalkan dokumen yang terdampak.

Urutan resume adalah destination lebih dahulu, lalu source:

1. Governance memastikan akar masalah ditutup, role yang terdampak sudah dirotasi, dan remote config
   benar.
2. Governance memanggil `unpauseReceive()`.
3. Manual execute semua pesan gagal/in-flight yang sah dan verifikasi receipt.
4. Governance memanggil `unpauseDispatch()` dan, bila relevan, `unpauseRegistration()`.
5. Lanjutkan dispatch baru.

Perubahan remote khusus lane melalui `configureRemote(..., false)` atau
`configureTrustedRemote(..., false)` tetap dapat dipakai sebagai tindakan governance tambahan.
Setiap unpause/config change harus menggunakan deployment artifact terverifikasi, multisig resmi,
dan change record incident. Lihat juga [governance runbook](GOVERNANCE_RUNBOOK.md).

## Incident evidence

Simpan sekurangnya:

- environment, source/destination chain, selector, Router, sender, dan receiver;
- document ID/version tanpa memasukkan PII plaintext;
- source transaction hash, message ID, destination execution transaction hash;
- status timeline (`UNTOUCHED`, `FAILURE`, `SUCCESS`) dan return data;
- perubahan konfigurasi, signer/operator, waktu, dan alasan;
- hasil query receipt serta processed marker setelah recovery.
