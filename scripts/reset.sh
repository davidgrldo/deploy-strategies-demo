#!/usr/bin/env bash
# scripts/reset.sh <strategy> — kembalikan cluster ke KONDISI AWAL strategi
# tsb, selalu mulai dari v1. Boleh dijalankan berulang (converge ke state
# awal yang sama). Strategi: recreate | rolling | bluegreen | canary.
#
#   ./scripts/reset.sh canary
#   APP=naive ./scripts/reset.sh rolling    # varian naive sebagai v1
#
# Image v1 awal dibangun lewat jalur build yang sama dengan pipeline tahap
# 1–3 (test → build sekali → push digest) — jadi image awal pun ter-pin
# by digest, sama seperti semua image berikutnya.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

STRATEGY="${1:-}"
V1_VERSION="${V1_VERSION:-v1}"

usage() {
  echo "usage: $0 <recreate|rolling|bluegreen|canary>" >&2
  exit 2
}
case "${STRATEGY}" in
  recreate | rolling | bluegreen | canary) ;;
  *) usage ;;
esac

need_cmd kubectl "kubectl — jalankan make cluster dulu"
need_cmd envsubst "envsubst (bagian dari gettext; macOS: brew install gettext)"

# --- 1/3 Build & push v1 (jalur build bersama) ------------------------------
stage "1/3" "Test & build v1 (${APP:-main}) via jalur build bersama"
DIGEST="$(build_and_push "${V1_VERSION}")"
echo "image v1: ${REGISTRY_CLUSTER}/app@sha256:${DIGEST}"
stage_done

# --- 2/3 Bersihkan sisa demo, lalu pasang bentuk awal strategi ---------------
stage "2/3" "Bentuk awal strategi: ${STRATEGY}"
# hapus objek demo dari reset sebelumnya (workload lain, route lama);
# label yang sama dipakai semua manifest di deploy/
kubectl delete deployment,service,httproute \
  -l app.kubernetes.io/part-of=deploy-strategies-demo \
  --ignore-not-found --timeout=120s

case "${STRATEGY}" in
  recreate)
    apply_workload base/deployment-recreate.yaml app 3 "${DIGEST}"
    set_route_single app
    ;;
  rolling)
    apply_workload base/deployment.yaml app 3 "${DIGEST}"
    set_route_single app
    ;;
  bluegreen)
    apply_workload base/deployment.yaml app-blue 3 "${DIGEST}"
    apply_workload base/deployment.yaml app-green 0 "${DIGEST}"
    set_weights app-blue 100 app-green 0
    set_active_slot blue
    ;;
  canary)
    apply_workload base/deployment.yaml app-stable 3 "${DIGEST}"
    apply_workload base/deployment.yaml app-canary 0 "${DIGEST}"
    set_weights app-stable 100 app-canary 0
    ;;
esac
stage_done

# --- 3/3 Tunggu workload aktif siap ------------------------------------------
stage "3/3" "Tunggu v1 siap"
case "${STRATEGY}" in
  recreate | rolling) wait_rollout app ;;
  bluegreen) wait_rollout app-blue ;;
  canary) wait_rollout app-stable ;;
esac
stage_done

echo ""
printf "${C_GREEN}${C_BOLD}✅ Reset %s siap — v1 aktif (digest %.12s…)${C_RESET}\n" \
  "${STRATEGY}" "${DIGEST}"
printf "   Jalankan ${C_CYAN}make watch${C_RESET} di terminal lain, lalu ${C_CYAN}./scripts/pipeline.sh %s${C_RESET}\n" "${STRATEGY}"
