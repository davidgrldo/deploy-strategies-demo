# deploy/ — Manifest Kubernetes Demo

Semua manifest di sini sengaja minimal supaya mudah dibaca saat live demo.
Penggantian nilai dilakukan lewat `envsubst` saat deploy (lihat
`scripts/lib.sh`), jadi tidak ada nilai hasil build yang tertanam di repo.

## gateway.yaml

`GatewayClass` + `Gateway` untuk Envoy Gateway. Listener HTTP port 80;
`scripts/setup-cluster.sh` mengeksposnya ke host sebagai
`http://localhost:8080`. Tidak ada route aplikasi di file ini — route
didefinisikan lewat HTTPRoute di bawah.

## base/deployment.yaml dan base/deployment-recreate.yaml

Template Deployment generik (di-substitusi `${NAME}`, `${REPLICAS}`,
`${REGISTRY}`, `${DIGEST}`) plus template Service-nya
(`base/service.yaml`, port 80 → container 8080). Dua hal yang penting
buat demo:

- **Probe cepat** — `livenessProbe` ke `/healthz` dan `readinessProbe` ke
  `/readyz`, keduanya `periodSeconds: 2`, supaya perpindahan pod terlihat
  cepat di panel.
- **Grace period eksplisit** — `terminationGracePeriodSeconds: 30` dengan
  komentar `# 5 + 20 = 25 < 30`: drain 5 detik + penyelesaian request
  maksimal 20 detik harus muat di bawah grace period, kalau tidak
  Kubernetes mengirim SIGKILL.
- **Latensi demo** — env `RESPONSE_DELAY_MS=300` (untuk semua strategi)
  membuat setiap request ke `/` dan `/version` makan ±300 ms, jadi selalu
  ada request yang sedang berjalan saat pod dimatikan. Tanpa ini, celah
  terlalu singkat untuk tertangkap panel.
- **Image selalu by digest** — bentuk barisnya tetap
  `image: ${REGISTRY}/app@sha256:${DIGEST}`; digest diisi pipeline saat
  deploy, tidak pernah pakai tag yang bisa bergeser.

`deployment-recreate.yaml` hanya beda satu blok: `strategy.type: Recreate`
(pod lama mati dulu, pod baru jalan belakangan → downtime nyata).
`deployment.yaml` memakai `RollingUpdate` dengan `maxSurge: 1` dan
`maxUnavailable: 0` (pod baru naik dulu, tidak ada slot kosong).

## httproute.yaml

Template HTTPRoute pembagian traffic dua backend (di-substitusi
`${BACKEND_1}` `${WEIGHT_1}` `${BACKEND_2}` `${WEIGHT_2}`). Dipakai
blue-green (`app-blue`/`app-green`) dan canary (`app-stable`/`app-canary`).
Contoh hasil render untuk canary 90/10 persis seperti di spec:

```yaml
backendRefs:
  - name: app-stable
    port: 80
    weight: 90
  - name: app-canary
    port: 80
    weight: 10
```

## httproute-single.yaml

Varian satu backend untuk strategi `recreate` dan `rolling` yang hanya
punya satu Deployment `app` (weight 100). Dibuat terpisah karena Gateway
API tidak menerima dua backendRef identik, dan backend weight-0 tanpa
Service yang ada membuat route tidak sehat.

## Bentuk awal per strategi (dibuat scripts/reset.sh)

| Strategi  | Deployment                                        | HTTPRoute          |
| --------- | ------------------------------------------------- | ------------------ |
| recreate  | `app` (Recreate)                                  | `app` 100          |
| rolling   | `app` (RollingUpdate 1/0)                         | `app` 100          |
| bluegreen | `app-blue` aktif + `app-green` 0 replika          | blue 100 / green 0 |
| canary    | `app-stable` aktif + `app-canary` 0 replika       | stable 100 / canary 0 |

Slot aktif blue-green diingat lewat annotation `active-slot` pada HTTPRoute,
jadi pemanggilan `pipeline.sh bluegreen` berikutnya bergantian slot.
