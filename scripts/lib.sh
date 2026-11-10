#!/usr/bin/env bash
# scripts/lib.sh — fungsi bersama untuk setup-cluster.sh, reset.sh,
# pipeline.sh, dan helper demo. Sumberkan file ini; jangan jalankan langsung
# (kecuali untuk helper demo: ./scripts/lib.sh demo-shutdown).
#
# Konvensi registry (perilaku k3d — nama beda, digest sama):
#   REGISTRY_HOST    = prefix untuk docker build/push dari host
#   REGISTRY_CLUSTER = prefix untuk image: di manifest dalam cluster
# Pipeline hanya menukar prefix (registry_prefix_swap); digest-nya identik.

# --- Konfigurasi (bisa di-override lewat env) ------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-demo}"
REGISTRY_HOST="${REGISTRY_HOST:-localhost:5001}"
REGISTRY_CLUSTER="${REGISTRY_CLUSTER:-k3d-demo-registry:5001}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"        # detik
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${REPO_DIR}/deploy"

# --- Warna -----------------------------------------------------------------
C_RESET='\033[0m'; C_BOLD='\033[1m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
C_CYAN='\033[36m'; C_GREY='\033[90m'

# --- Log & tahap -----------------------------------------------------------
_stage_t0="${SECONDS}"

# stage "2/5" "Build sekali" — header tahap bernomor, seperti di §6 pipeline.
stage() {
  _stage_t0="${SECONDS}"
  printf "\n${C_BOLD}${C_CYAN}▶ [%s] %s${C_RESET}\n" "$1" "$2"
}

# stage_done — tutup tahap terakhir dengan durasinya.
stage_done() {
  printf "${C_GREY}✓ selesai dalam %ss${C_RESET}\n" "$((SECONDS - _stage_t0))"
}

die() {
  printf "\n${C_BOLD}${C_RED}✗ %s${C_RESET}\n" "$1" >&2
  exit 1
}

need_cmd() { # need_cmd <binary> <hint instalasi>
  command -v "$1" >/dev/null 2>&1 || die "butuh binary '$1'. $2"
}

# --- Build path bersama (dipakai pipeline tahap 1–3 dan reset untuk v1) -----

go_test() {
  (cd "${REPO_DIR}" && go test ./...)
}

# build_image <version> — build SEKALI; APP=main|naive memilih program.
build_image() {
  local version="$1" app="${APP:-main}"
  (cd "${REPO_DIR}" && docker build \
    --build-arg "APP=${app}" \
    --build-arg "VERSION=${version}" \
    -t "${REGISTRY_HOST}/app:${version}" .)
}

# push_image <version> — push ke registry lokal; output-nya DIGEST dalam
# bentuk HEX MURNI (64 karakter, TANPA prefix "sha256:"). Semua pemakai
# menambahkan prefix-nya sendiri (template ${REGISTRY}/app@sha256:${DIGEST},
# cluster_image_ref, cetakan pipeline/reset) — prefix di sini akan
# menghasilkan referensi ganda "sha256:sha256:".
push_image() {
  local version="$1" digest
  docker push "${REGISTRY_HOST}/app:${version}" 2>&1 | tee /dev/stderr | \
    sed -n 's/.*digest: sha256:\([a-f0-9]\{64\}\).*/\1/p' | head -1 > /tmp/.demo-digest
  digest="$(cat /tmp/.demo-digest)"
  rm -f /tmp/.demo-digest
  if [ -z "${digest}" ]; then
    # fallback: tanya langsung ke docker setelah push
    digest="$(docker image inspect "${REGISTRY_HOST}/app:${version}" \
      --format '{{index .RepoDigests 0}}' | sed 's/.*@sha256://')"
  fi
  # validasi: harus hex 64 karakter tanpa prefix. Referensi ganda
  # "sha256:sha256:" ditolak cluster (InvalidImageName) dan semua strategi
  # macet di rollout — lebih baik gagal cepat di sini dengan pesan jelas.
  if ! [[ "${digest}" =~ ^[a-f0-9]{64}$ ]]; then
    die "digest tidak valid (harap 64 karakter hex tanpa prefix 'sha256:'): '${digest}'"
  fi
  echo "${digest}"
}

# build_and_push <version> — test → build sekali → push → digest.
# Jalur yang sama dipakai pipeline (tahap 1–3) dan reset (image v1 awal),
# jadi image awal pun ter-pin digest seperti semua image berikutnya.
build_and_push() {
  local version="$1" digest
  go_test
  build_image "${version}"
  digest="$(push_image "${version}")"
  echo "${digest}"
}

# --- Registry prefix -------------------------------------------------------

# registry_prefix_swap <image-ref> — ganti prefix host → prefix cluster.
# Digest tetap sama; hanya prefix yang berbeda (perilaku k3d registry).
registry_prefix_swap() {
  local ref="$1"
  echo "${ref}" | sed "s|^${REGISTRY_HOST}/|${REGISTRY_CLUSTER}/|"
}

# cluster_image_ref <digest> — referensi image dalam cluster, pin by digest.
cluster_image_ref() {
  echo "${REGISTRY_CLUSTER}/app@sha256:$1"
}

# --- Kubernetes helpers ----------------------------------------------------

wait_rollout() { # wait_rollout <deployment>
  kubectl rollout status "deployment/$1" "--timeout=${ROLLOUT_TIMEOUT}s"
}

# rollout_progress <deployment> — tunggu sambil mencetak progres pod
# ("updated 1/3 · ready 0/3" … "updated 3/3 · ready 3/3").
rollout_progress() {
  local name="$1" desired updated ready gen ogen last="" deadline=$((SECONDS + ROLLOUT_TIMEOUT))
  desired="$(kubectl get deployment "${name}" -o jsonpath='{.spec.replicas}')"
  while :; do
    updated="$(kubectl get deployment "${name}" -o jsonpath='{.status.updatedReplicas}')"; updated="${updated:-0}"
    ready="$(kubectl get deployment "${name}" -o jsonpath='{.status.readyReplicas}')"; ready="${ready:-0}"
    gen="$(kubectl get deployment "${name}" -o jsonpath='{.metadata.generation}')"
    ogen="$(kubectl get deployment "${name}" -o jsonpath='{.status.observedGeneration}')"; ogen="${ogen:-0}"
    local line="updated ${updated}/${desired} · ready ${ready}/${desired}"
    if [ "${line}" != "${last}" ]; then
      printf "  ${C_GREY}%s${C_RESET}\n" "${line}"
      last="${line}"
    fi
    if [ "${ogen}" = "${gen}" ] && [ "${updated}" = "${desired}" ] && [ "${ready}" = "${desired}" ]; then
      return 0
    fi
    [ "${SECONDS}" -lt "${deadline}" ] || die "rollout ${name} timeout setelah ${ROLLOUT_TIMEOUT}s"
    sleep 1
  done
}

# apply_service <name> — Service generik port 80 → container 8080.
apply_service() {
  NAME="$1" envsubst '${NAME}' < "${DEPLOY_DIR}/base/service.yaml" | kubectl apply -f -
}

# apply_workload <template-relpath> <name> <replicas> <digest>
# Render template Deployment via envsubst lalu apply (+ Service-nya).
apply_workload() {
  local tpl="${DEPLOY_DIR}/$1" name="$2" replicas="$3" digest="$4"
  NAME="${name}" REPLICAS="${replicas}" DIGEST="${digest}" REGISTRY="${REGISTRY_CLUSTER}" \
    envsubst '${NAME} ${REPLICAS} ${DIGEST} ${REGISTRY}' < "${tpl}" | kubectl apply -f -
  apply_service "${name}"
}

# set_image <deployment> <digest> — update image by digest (tanpa tag).
set_image() {
  kubectl set image "deployment/$1" "app=$(cluster_image_ref "$2")"
}

scale_workload() { # scale_workload <deployment> <replicas>
  kubectl scale "deployment/$1" --replicas="$2"
}

# set_route_single <backend> — route satu backend, weight 100.
set_route_single() {
  BACKEND_1="$1" WEIGHT_1=100 \
    envsubst '${BACKEND_1} ${WEIGHT_1}' < "${DEPLOY_DIR}/httproute-single.yaml" | kubectl apply -f -
}

# set_weights <backend1> <weight1> <backend2> <weight2> — ganti pembagian
# traffic dengan re-render template HTTPRoute + apply (legibel untuk audiens:
# YAML berubah di layar, bukan patch tersembunyi).
set_weights() {
  BACKEND_1="$1" WEIGHT_1="$2" BACKEND_2="$3" WEIGHT_2="$4" \
    envsubst '${BACKEND_1} ${WEIGHT_1} ${BACKEND_2} ${WEIGHT_2}' < "${DEPLOY_DIR}/httproute.yaml" \
    | kubectl apply -f -
}

# --- Memori slot blue-green (annotation di HTTPRoute) ----------------------

get_active_slot() { # blue (default) atau green — slot yang sedang menerima traffic
  local slot
  slot="$(kubectl get httproute app \
    -o go-template='{{if .metadata.annotations}}{{index .metadata.annotations "active-slot"}}{{end}}' 2>/dev/null)"
  echo "${slot:-blue}"
}

set_active_slot() { # set_active_slot <blue|green>
  kubectl annotate --overwrite httproute app "active-slot=$1" >/dev/null
}

# --- Demo docker stop: naive vs graceful (§8, tanpa Kubernetes) -------------

wait_http_ok() { # wait_http_ok <url> <timeout_s> — tunggu sampai menjawab 200
  local deadline=$((SECONDS + $2))
  until curl -sf -o /dev/null --max-time 2 "$1" 2>/dev/null; do
    [ "${SECONDS}" -lt "${deadline}" ] || die "timeout menunggu $1"
    sleep 0.5
  done
}

# run_slow_leg <container> <stop_timeout_s> — nembak /slow, satu detik kemudian
# docker stop container-nya, lalu tunggu request-nya selesai (atau putus).
# Hasil via variabel LEG_CODE (http code), LEG_RC (exit curl), LEG_ERR
# (pesan error curl), LEG_REQ_SECS (berapa detik request berjalan).
run_slow_leg() {
  local container="$1" stop_t="$2" cf ef rf tf cpid t0
  cf="$(mktemp)"; ef="$(mktemp)"; rf="$(mktemp)"; tf="$(mktemp)"
  t0="$(date +%s)"
  (
    curl -sS -m 20 -o /dev/null -w '%{http_code}' \
      "http://localhost:${DEMO_SHUTDOWN_PORT:-18080}/slow" >"${cf}" 2>"${ef}"
    echo "$?" >"${rf}"
    date +%s >"${tf}"
  ) &
  cpid=$!
  sleep 1 # request sudah mendarat dan sedang berjalan (sleep 3s di server)
  docker stop -t "${stop_t}" "${container}" >/dev/null
  wait "${cpid}" 2>/dev/null
  LEG_CODE="$(cat "${cf}" 2>/dev/null)"
  LEG_RC="$(cat "${rf}" 2>/dev/null)"
  LEG_ERR="$(head -1 "${ef}" 2>/dev/null)"
  LEG_REQ_SECS="$(( $(cat "${tf}" 2>/dev/null || echo "${t0}") - t0 ))"
  rm -f "${cf}" "${ef}" "${rf}" "${tf}"
}

# demo_shutdown — perbandingan dua kaki (Docker saja, tanpa Kubernetes):
#   kaki 1: container naive, request /slow ditembak, docker stop di tengah
#           jalan → request PUTUS (curl: Empty reply / connection reset)
#   kaki 2: container graceful, sama persis → request SELESAI 200 setelah
#           ±3 detiknya, dan log memperlihatkan langkah shutdown 1–4
demo_shutdown() {
  need_cmd docker "Docker — instal dulu (satu-satunya prasyarat demo ini)"
  local port="${DEMO_SHUTDOWN_PORT:-18080}"
  local name_naive="demo-shutdown-naive" name_graceful="demo-shutdown-graceful"
  trap "docker rm -f ${name_naive} ${name_graceful} >/dev/null 2>&1 || true" EXIT

  stage "1/4" "Build dua image (naive & graceful)"
  APP=naive build_image "demo-shutdown-naive"
  APP=main build_image "demo-shutdown-graceful"
  stage_done

  stage "2/4" "Kaki 1 — naive: docker stop di tengah request /slow"
  docker run -d --rm --name "${name_naive}" -p "${port}:8080" \
    "${REGISTRY_HOST}/app:demo-shutdown-naive" >/dev/null
  wait_http_ok "http://localhost:${port}/healthz" 30
  run_slow_leg "${name_naive}" 10
  local naive_line
  if [ -n "${LEG_CODE:-}" ] && [ "${LEG_CODE}" != "000" ] && [ "${LEG_CODE}" != "" ]; then
    naive_line="${LEG_CODE} setelah ${LEG_REQ_SECS}s (tidak putus? coba lagi)"
  else
    naive_line="${LEG_ERR:-request putus} setelah ${LEG_REQ_SECS}s"
  fi
  printf "  ${C_RED}${C_BOLD}naive    : %s${C_RESET}\n" "${naive_line}"
  stage_done

  stage "3/4" "Kaki 2 — graceful: request yang sama, dibiarkan selesai"
  docker run -d --rm --name "${name_graceful}" -p "${port}:8080" \
    "${REGISTRY_HOST}/app:demo-shutdown-graceful" >/dev/null
  wait_http_ok "http://localhost:${port}/healthz" 30
  run_slow_leg "${name_graceful}" 30
  local graceful_line
  if [ "${LEG_CODE:-}" = "200" ]; then
    graceful_line="200 OK setelah ${LEG_REQ_SECS}s — request selesai"
  else
    graceful_line="GAGAL (code ${LEG_CODE:-000}) — padahal harusnya selesai"
  fi
  printf "  ${C_GREEN}${C_BOLD}graceful : %s${C_RESET}\n" "${graceful_line}"
  echo "  langkah shutdown di log container:"
  docker logs "${name_graceful}" 2>&1 | grep '\[shutdown\]' | sed 's/^/    /' || true
  stage_done

  stage "4/4" "Perbandingan"
  printf "  %-8s : %s\n" "naive" "${naive_line}"
  printf "  %-8s : %s\n" "graceful" "${graceful_line}"
  echo "  Bedanya: naive mati seketika dan memutus request yang sedang berjalan;"
  echo "  graceful menyelesaikannya dulu (lihat [shutdown] 1–4 di atas)."
  stage_done
  docker rm -f "${name_naive}" "${name_graceful}" >/dev/null 2>&1 || true
}

# Jalankan langsung untuk helper demo: ./scripts/lib.sh demo-shutdown
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "demo-shutdown" ]; then
  demo_shutdown
fi
