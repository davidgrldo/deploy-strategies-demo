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

# push_image <version> — push ke registry lokal; output-nya DIGEST.
# Mulai sini hanya digest yang dipakai (tidak ada referensi tag lagi).
push_image() {
  local version="$1" digest
  docker push "${REGISTRY_HOST}/app:${version}" 2>&1 | tee /dev/stderr | \
    sed -n 's/.*digest: \(sha256:[a-f0-9]\{64\}\).*/\1/p' | head -1 > /tmp/.demo-digest
  digest="$(cat /tmp/.demo-digest)"
  if [ -z "${digest}" ]; then
    # fallback: tanya langsung ke docker setelah push
    digest="$(docker image inspect "${REGISTRY_HOST}/app:${version}" \
      --format '{{index .RepoDigests 0}}' | sed 's/.*@//')"
  fi
  [ -n "${digest}" ] || die "gagal menangkap digest dari docker push"
  rm -f /tmp/.demo-digest
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
