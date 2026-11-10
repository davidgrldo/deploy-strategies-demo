# Spec Demo: Empat Strategi Deployment untuk Aplikasi Go

> Input untuk AI coding harness. Bangun repo demo yang dipakai di sharing session **"Deploy Tanpa Deg-degan"** (topik Deployment Strategies, seri *Building a Custom CI/CD for Go*).
> Audiens: siswa SMK, mahasiswa, profesional. Repo ini akan dibagikan ke publik, jadi kodenya harus mudah dibaca, README-nya dalam Bahasa Indonesia, dan bisa dijalankan di laptop.

---

## 1. Tujuan

Satu pipeline yang **tahap deploy-nya sama**, tapi **tahap release-nya bisa ditukar**:

```bash
./scripts/pipeline.sh recreate
./scripts/pipeline.sh rolling
./scripts/pipeline.sh bluegreen
./scripts/pipeline.sh canary
```

Ini memperkuat pesan dari slide: *deploy = memasang versi baru, release = memindahkan traffic ke versi itu*. Strateginya hanya beda di cara release.

Yang harus terlihat jelas di panel traffic untuk tiap strategi:

| Strategi | Yang harus terlihat |
|---|---|
| Recreate | Ada jeda **ERR/5xx** (downtime) di antara v1 dan v2. Durasi downtime dicetak. |
| Rolling | v1 dan v2 **bercampur bertahap**, **0 error** (karena graceful shutdown). |
| Blue-green | Pindah **seketika** dari 100% v1 ke 100% v2, lalu rollback seketika ke v1. |
| Canary | ~10% v2 → diamati → promote ke 100%. Skenario versi rusak → **rollback otomatis**. |

Bonus (paling kuat untuk mendukung slide "Celah"): **rolling dengan app naive** (tanpa graceful shutdown) → muncul 502 di tengah rollout. Bandingkan dengan rolling versi graceful → 0 error.

## 2. Batasan penting

- Kode aplikasi **harus konsisten dengan slide** (lihat §4). Audiens akan mencocokkan repo dengan slide.
- Pembagian traffic memakai **Gateway API standar (`HTTPRoute` dengan `backendRefs.weight`)**, tanpa service mesh, tanpa Argo Rollouts/Flagger.
- Analisis canary **tanpa Prometheus**: pipeline sendiri mengirim traffic dan menghitung error rate dari respons versi canary (§6). Sengaja sederhana supaya mudah dipahami.
- Semua jalan lokal, tanpa cloud: Docker + k3d (K3s di dalam Docker) + Envoy Gateway.
- Pipeline berupa **bash script** (bukan GitHub Actions) supaya bisa dijalankan dan direkam di laptop. Tiap tahap adalah fungsi bash yang jelas namanya; tiap strategi adalah satu fungsi `release_<strategy>`.

## 3. Struktur repo

```
.
├── main.go                  # aplikasi (sesuai slide)
├── main_test.go             # test /healthz, /readyz, /version
├── go.mod
├── Dockerfile               # multi-stage, binary statis, distroless/scratch; ARG APP=main|naive
├── Makefile
├── naive/
│   └── main.go              # versi TANPA graceful shutdown (pembanding)
├── deploy/
│   ├── gateway.yaml         # GatewayClass + Gateway
│   ├── base/                # Deployment + Service generik (template, di-substitusi envsubst)
│   ├── httproute.yaml       # HTTPRoute (template, weight di-substitusi)
│   └── README.md            # penjelasan singkat tiap manifest
├── scripts/
│   ├── setup-cluster.sh     # k3d + registry lokal + Envoy Gateway
│   ├── lib.sh               # fungsi bersama: log berwarna, set_weights, wait_rollout, dll.
│   ├── pipeline.sh          # entrypoint: test → build → push → release_<strategy>
│   ├── reset.sh             # kembalikan cluster ke kondisi awal untuk strategi tertentu
│   └── watch.sh             # panel traffic (§7)
└── README.md                # Bahasa Indonesia, langkah demi langkah
```

## 4. Aplikasi Go (`main.go`)

Go 1.22+ (pola route `"GET /path"` di `http.ServeMux`). Hanya standard library.

| Endpoint | Perilaku |
|---|---|
| `GET /` | `200`, body `hello from <version>` |
| `GET /version` | `200`, body = `version` |
| `GET /healthz` | Liveness. Selalu `200` selama proses hidup. **Jangan** cek dependensi apa pun. |
| `GET /readyz` | Readiness. `503` kalau `ready` false; kalau true tidak menulis apa pun (net/http otomatis `200`). |
| `GET /slow` | Tidur 3 detik lalu `200`. Dipakai untuk demo `docker stop` (§8). |

Semua respons menyertakan header `X-Version: <version>`.

Versi diisi saat build:

```go
// go build -ldflags "-X main.version=$(git rev-parse --short HEAD)"
var version = "dev"
```

Simulasi versi rusak lewat env `FAIL_RATE` (float 0–1, default 0): `/` dan `/version` mengembalikan `500` dengan probabilitas tersebut (tetap dengan header `X-Version`). `/healthz` dan `/readyz` **tidak** terpengaruh. Itulah poinnya: health check lolos, tapi user tetap kena error, sehingga canary perlu analisis.

Latensi buatan lewat env `RESPONSE_DELAY_MS` (default 0): `/` dan `/version` menunggu selama itu sebelum menjawab. Di manifest demo, set ±300 ms untuk semua strategi, supaya selalu ada request yang sedang berjalan saat pod dimatikan. Versi naive akan memutusnya (error), versi graceful menyelesaikannya. Tanpa ini, celahnya bisa terlalu singkat untuk tertangkap di rekaman.

Graceful shutdown **harus mengikuti urutan di slide persis**:

```go
ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
defer stop()

go srv.ListenAndServe()   // versi repo: cek errors.Is(err, http.ErrServerClosed), log fatal kalau error lain
ready.Store(true)

<-ctx.Done()                // 1. SIGTERM masuk
ready.Store(false)          // 2. /readyz → 503
time.Sleep(5 * time.Second) // 3. tunggu LB mencabut pod
sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
defer cancel()
srv.Shutdown(sctx)          // 4. selesaikan request yang sedang jalan
```

- `ready` bertipe `atomic.Bool`.
- Delay 5 detik dan timeout 20 detik boleh konfigurable lewat env (`SHUTDOWN_DELAY`, `SHUTDOWN_TIMEOUT`), default sesuai slide.
- Log tiap langkah (`[shutdown] 1. signal received`, dst.).
- Port dari env `PORT`, default `8080`.

`naive/main.go`: endpoint sama (termasuk `RESPONSE_DELAY_MS` dan `FAIL_RATE`), tapi `http.ListenAndServe` polos tanpa penanganan sinyal dan `/readyz` selalu `200`. Pastikan prosesnya benar-benar langsung exit saat menerima SIGTERM di dalam container (sebagai PID 1).

## 5. Kubernetes

**Cluster** (`scripts/setup-cluster.sh`, idempotent):

- k3d cluster dengan registry lokal (mis. `localhost:5001`) supaya image bisa direferensikan **by digest**.
- Perhatikan beda nama registry dari host (untuk `docker push`) dan dari dalam cluster (untuk `image:` di manifest); di k3d keduanya bisa berbeda. Digest-nya tetap sama, jadi pipeline cukup mengganti prefix registry.
- Matikan Traefik bawaan K3s, install Envoy Gateway (versi stable terbaru, Gateway API v1 standard channel).
- Expose Gateway ke host di `http://localhost:8080`.

**Manifest umum:**

- Image selalu di-pin **by digest** (`registry/app@sha256:...`), bukan tag.
- `livenessProbe` → `/healthz`, `readinessProbe` → `/readyz` (`periodSeconds: 2` supaya demo cepat).
- `terminationGracePeriodSeconds: 30` ditulis eksplisit, dengan komentar `# 5 + 20 = 25 < 30`.
- Replika default 3 (canary 1).

**Bentuk cluster per strategi** (dibuat oleh `reset.sh <strategy>`, selalu mulai dari v1):

| Strategi | Workload | HTTPRoute |
|---|---|---|
| recreate | 1 Deployment `app`, `strategy.type: Recreate` | `app` 100 |
| rolling | 1 Deployment `app`, `RollingUpdate` (`maxSurge: 1`, `maxUnavailable: 0`) | `app` 100 |
| bluegreen | `app-blue` (v1, aktif) + `app-green` (kosong/0 replika) | blue 100 / green 0 |
| canary | `app-stable` (v1) + `app-canary` (0 replika) | stable 100 / canary 0 |

Contoh weight canary:

```yaml
backendRefs:
  - name: app-stable
    port: 80
    weight: 90
  - name: app-canary
    port: 80
    weight: 10
```

## 6. Pipeline (`scripts/pipeline.sh <strategy>`)

Tahap bersama (tiap tahap mencetak header berwarna, mis. `▶ [2/5] Build sekali`, dan durasinya):

1. **Test:** `go test ./...`
2. **Build sekali:** `docker build` dengan `-ldflags "-X main.version=<short-sha>"`. Versi bisa di-override lewat env `VERSION` (mis. `v2`) supaya rekaman mudah dibaca. Env `APP=naive` membangun versi naive.
3. **Push & ambil digest:** push ke registry lokal, cetak `image: …@sha256:…`. Mulai tahap ini **hanya digest yang dipakai**.
4. **Release** (`release_<strategy>`):
   - **recreate:** update image Deployment `app`, tunggu rollout. Cetak peringatan `⚠ downtime diharapkan`.
   - **rolling:** update image Deployment `app`, tunggu `rollout status`. Cetak progres pod (`updated 1/3 … 3/3`).
   - **bluegreen:** deploy digest ke slot non-aktif (green), tunggu semua pod ready, cetak `green siap, belum terima traffic`, jeda `SWITCH_PAUSE` detik (default 5), lalu set weight `0/100`. Cetak `🔀 SWITCH blue → green`. Simpan slot aktif (mis. di annotation HTTPRoute) supaya pemanggilan berikutnya bergantian.
   - **canary:** deploy digest ke `app-canary` (+ `FAIL_RATE` kalau di-set), tunggu ready, set weight `100-CANARY_WEIGHT / CANARY_WEIGHT` (default 10), lalu **analisis**: selama `OBSERVE_SECONDS` (default 120) kirim request ke `localhost:8080/version` dan hitung hanya respons dengan `X-Version` = versi canary. Tiap ±10 detik cetak `canary: 42 req, 1 error (2.4%)`.
     - Error rate ≤ `MAX_ERROR_RATE` (default `0.01`) dan sampel ≥ `MIN_SAMPLES` (default 20) → **promote**: update `app-stable` ke digest yang sama, tunggu rollout, weight `100/0`, scale canary ke 0. Cetak `✅ PROMOTED <version> → 100%`.
     - Melebihi ambang → **rollback**: weight `100/0`, scale canary ke 0, exit non-zero. Cetak `❌ ROLLBACK: error rate X% > Y%`. Boleh berhenti lebih awal begitu jelas gagal.
5. **Ringkasan:** strategi, versi, digest, durasi total.

Perintah tambahan:

```bash
./scripts/pipeline.sh bluegreen-rollback   # set weight kembali ke slot sebelumnya, seketika
```

Semua angka (`OBSERVE_SECONDS`, `MAX_ERROR_RATE`, `MIN_SAMPLES`, `CANARY_WEIGHT`, `SWITCH_PAUSE`) bisa di-override lewat env.

## 7. Panel traffic (`scripts/watch.sh`)

- Beberapa worker paralel (env `WORKERS`, default 6) yang masing-masing loop `curl` ke `localhost:8080/version` (total ±20 req/detik dengan delay 300 ms, timeout pendek mis. 2 detik). Request paralel memperbesar peluang menangkap celah saat pod dimatikan.
- Satu baris per respons: `HH:MM:SS  200  v1`. Warna: v1 abu-abu/putih, v2 cyan, versi lain kuning, 5xx/`ERR` merah tebal.
- Setiap ~2 detik baris ringkasan: `v1 62% · v2 38% · err 0`.
- Hitung dan cetak **durasi downtime**: kalau ada rentang error berturut-turut, cetak `⛔ downtime 3.4s` saat traffic pulih. Ini angka kunci untuk recreate dan rolling-naive.
- Tidak boleh crash kalau gateway tidak menjawab; tampilkan `ERR` lalu lanjut.
- Flag `--compact` untuk menampilkan hanya ringkasan (berguna kalau layar rekaman sempit).

## 8. Demo `docker stop` (bonus, tanpa Kubernetes)

Target `make demo-shutdown`:

1. Jalankan container versi naive, panggil `/slow`, `docker stop` di tengah request → request **putus**.
2. Ulangi dengan versi graceful → request **selesai** (`200`), log menunjukkan langkah shutdown 1–4.

Output membandingkan keduanya dengan jelas (mis. `naive: curl: (52) Empty reply` vs `graceful: 200 OK after 3s`).

## 9. Makefile

```
make cluster                  # setup-cluster.sh
make watch                    # panel traffic
make reset S=<strategy>       # siapkan kondisi awal v1 untuk strategi tsb
make recreate                 # reset + pipeline recreate (VERSION=v2)
make rolling                  # reset + pipeline rolling
make rolling-naive            # reset dengan app naive, lalu rolling ke naive v2 → terlihat 502
make bluegreen                # reset + switch ke green
make bluegreen-rollback       # switch balik seketika
make canary                   # reset + canary sukses
make canary-bad               # reset + canary dengan FAIL_RATE=0.3 → rollback
make demo-shutdown            # §8
make clean                    # hapus cluster k3d
```

## 10. Rencana rekaman (total ±2 menit)

Layout tmux: **kiri** `make watch`, **kanan** perintah `make …`. Rekam tiap klip terpisah, percepat bagian menunggu saat editing.

| # | Klip | Durasi akhir | Poin yang diucapkan |
|---|---|---|---|
| 1 | `make recreate` | ±15 dtk | "Tutup toko: lihat merahnya, downtime X detik." |
| 2 | `make rolling-naive` lalu `make rolling` | ±25 dtk | "Rolling tanpa graceful shutdown: tetap bocor. Dengan graceful: nol error." (menjawab slide Celah) |
| 3 | `make bluegreen` + `make bluegreen-rollback` | ±20 dtk | "Pindah seketika, mundur juga seketika." |
| 4 | `make canary` | ±30 dtk | "10% dulu, diamati, lalu 100%." (`OBSERVE_SECONDS=30`) |
| 5 | `make canary-bad` | ±30 dtk | "Versi rusak, health check tetap hijau, tapi pipeline mundur sendiri." |

Kalau waktu mepet, klip 1 dan 3 bisa dipotong; klip 2 dan 5 yang paling penting.

## 11. README (Bahasa Indonesia)

- Satu paragraf per strategi dengan analogi yang sama seperti slide: tutup toko (recreate), ganti kasir satu-satu (rolling), toko kembar (blue-green), menu baru ke 10% tamu (canary).
- Untuk tiap strategi, sertakan "pakai kalau…" yang sama dengan slide: recreate kalau v1 & v2 tidak bisa jalan bersamaan; rolling sebagai default untuk service stateless; blue-green kalau butuh rollback instan; canary kalau traffic besar dan metrik bisa dipercaya.
- Prasyarat: Docker, k3d, kubectl, Go 1.22+ (beserta cara cek versinya). Script bash berjalan di Linux, macOS, atau Windows lewat WSL2.
- Langkah: `make cluster` → buka dua terminal (`make watch` dan `make <strategy>`).
- Bagian "Kenapa kodenya begini?": 4 langkah graceful shutdown, liveness vs readiness, `-ldflags` untuk versi, kenapa pakai digest.
- Bagian "Tanpa Kubernetes?": cukup `make demo-shutdown` dengan Docker.
- Troubleshooting singkat (port 8080 dipakai, Envoy Gateway belum ready, dsb.).

## 12. Kriteria selesai

- [ ] `make cluster` sukses dari nol di laptop bersih; tiap `make reset S=…` bisa diulang.
- [ ] `make recreate`: panel menampilkan downtime > 0 detik.
- [ ] `make rolling`: v1 dan v2 bercampur selama rollout, **0 error**.
- [ ] `make rolling-naive`: muncul 5xx/ERR selama rollout, konsisten di 3 kali percobaan berturut-turut (kalau tidak, naikkan `WORKERS` atau `RESPONSE_DELAY_MS`).
- [ ] `make bluegreen`: 100% v1 → 100% v2 dalam ≤ 2 detik; `make bluegreen-rollback` kembali ke v1 dalam ≤ 2 detik; 0 error.
- [ ] `make canary`: ~10% v2 selama observasi, berakhir `PROMOTED`, 0 error selama promote.
- [ ] `make canary-bad`: berakhir `ROLLBACK` (exit code ≠ 0), panel kembali 100% ke v1.
- [ ] `make demo-shutdown` menunjukkan perbedaan naive vs graceful.
- [ ] `go vet ./...` dan `go test ./...` bersih.
- [ ] Logika `main.go` identik dengan slide (urutan 1–4, nama variabel `ready`, `version`, `srv`, `stop`, `sctx`, `cancel`).
