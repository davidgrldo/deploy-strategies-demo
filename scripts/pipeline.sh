#!/usr/bin/env bash
# scripts/pipeline.sh <strategy> — SATU pipeline dengan tahap release yang
# bisa ditukar (§6). Deploy-nya sama (test → build sekali → push digest);
# yang beda hanya cara RELEASE-nya. Itu inti pesan sesi ini:
# deploy = memasang versi baru, release = memindahkan traffic ke situ.
#
#   ./scripts/pipeline.sh recreate
#   ./scripts/pipeline.sh rolling
#   ./scripts/pipeline.sh bluegreen
#   ./scripts/pipeline.sh canary
#   ./scripts/pipeline.sh bluegreen-rollback   # berat saja, tanpa build
#
# Env yang bisa di-override (default dalam kurung):
#   VERSION=v2            string versi; default short SHA git (build-time)
#   APP=naive             bangun varian naive, bukan main
#   FAIL_RATE=0.3         diteruskan ke workload canary (canary saja)
#   SWITCH_PAUSE=5        jeda blue-green sebelum pindah weight (detik)
#   CANARY_WEIGHT=10      persentase traffic awal ke canary
#   OBSERVE_SECONDS=120   lama window analisis canary
#   MAX_ERROR_RATE=0.01   ambang error rate untuk promote
#   MIN_SAMPLES=20        sampel minimum sebelum keputusan promote
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

STRATEGY="${1:-}"
PIPELINE_T0="${SECONDS}"

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}" >&2
  exit 2
}

need_cmd kubectl "kubectl — jalankan make cluster dulu"

# ===========================================================================
# Tahap release per strategi — dipanggil tahap 4/5. Argumen: versi, digest.
# ===========================================================================

# release_recreate: pod lama dimatikan SEMUA dulu, baru pod baru dibuat.
# Sisanya: downtime nyata — itu poin demo-nya.
release_recreate() {
  local version="$1" digest="$2"
  printf "${C_YELLOW}${C_BOLD}⚠ downtime diharapkan${C_RESET}\n"
  echo "  update image Deployment app → digest baru"
  set_image app "${digest}"
  wait_rollout app
}

# release_rolling: pod baru naik satu-satu (maxSurge 1, maxUnavailable 0),
# pod lama turun setelah penggantinya siap — versi tercampur, nol error.
release_rolling() {
  local version="$1" digest="$2"
  echo "  update image Deployment app → digest baru"
  set_image app "${digest}"
  echo "  progres pod:"
  rollout_progress app
}

# release_bluegreen: deploy digest ke slot NON-AKTIF, tunggu semua pod-nya
# siap, jeda SWITCH_PAUSE detik, lalu pindahkan 100% traffic seketika —
# weight saja, pod lama tidak disentuh. Slot aktif diingat di annotation
# HTTPRoute (active-slot), jadi pemanggilan berikutnya bergantian slot:
# blue → green → blue → …
release_bluegreen() {
  local version="$1" digest="$2"
  local active inactive
  active="$(get_active_slot)"
  if [ "${active}" = "blue" ]; then inactive="green"; else inactive="blue"; fi

  echo "  slot aktif: ${active} — deploy ${version} ke slot non-aktif: ${inactive}"
  set_image "app-${inactive}" "${digest}"
  scale_workload "app-${inactive}" "${BG_REPLICAS:-3}"
  wait_rollout "app-${inactive}"
  printf "${C_CYAN}${C_BOLD}%s siap, belum terima traffic${C_RESET}\n" "${inactive}"

  echo "  jeda ${SWITCH_PAUSE:-5}s (SWITCH_PAUSE) — masih sempat batalkan"
  sleep "${SWITCH_PAUSE:-5}"

  echo "  pindahkan traffic: ${active} 0 / ${inactive} 100"
  set_weights "app-${active}" 0 "app-${inactive}" 100
  printf "${C_BOLD}${C_YELLOW}🔀 SWITCH %s → %s${C_RESET}\n" "${active}" "${inactive}"
  set_active_slot "${inactive}"
  echo "  slot lama (${active}) dibiarkan hidup — sumber rollback instan"
}

# do_bluegreen_rollback: kembalikan traffic ke slot sebelumnya SEKETIKA —
# operasi weight saja: tanpa test, tanpa build, tanpa deploy ulang.
do_bluegreen_rollback() {
  local active inactive
  active="$(get_active_slot)"
  if [ "${active}" = "blue" ]; then inactive="green"; else inactive="blue"; fi

  echo "  slot aktif: ${active} — kembalikan traffic ke ${inactive}"
  set_weights "app-${active}" 0 "app-${inactive}" 100
  printf "${C_BOLD}${C_YELLOW}🔀 SWITCH %s → %s (rollback, seketika)${C_RESET}\n" "${active}" "${inactive}"
  set_active_slot "${inactive}"
}

need_active_bluegreen() {
  kubectl get httproute app >/dev/null 2>&1 \
    || die "HTTPRoute 'app' belum ada — jalankan make reset S=bluegreen dulu"
}

# ===========================================================================
# Pipeline utama
# ===========================================================================

case "${STRATEGY}" in
  recreate | rolling | bluegreen | canary) ;;
  bluegreen-rollback)
    # rollback = operasi weight saja: tanpa test, tanpa build, tanpa deploy.
    need_active_bluegreen
    do_bluegreen_rollback
    exit 0
    ;;
  *)
    usage
    ;;
esac

VERSION="${VERSION:-$(cd "${REPO_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo dev)}"

# --- 1/5 Test ----------------------------------------------------------------
stage "1/5" "Test"
go_test
stage_done

# --- 2/5 Build sekali ----------------------------------------------------------
stage "2/5" "Build sekali (${APP:-main} @ ${VERSION})"
build_image "${VERSION}"
stage_done

# --- 3/5 Push & ambil digest ---------------------------------------------------
stage "3/5" "Push & ambil digest"
DIGEST="$(push_image "${VERSION}")"
echo "image: ${REGISTRY_CLUSTER}/app@sha256:${DIGEST}"
stage_done

# --- 4/5 Release (satu fungsi per strategi) -------------------------------------
stage "4/5" "Release: ${STRATEGY}"
"release_${STRATEGY}" "${VERSION}" "${DIGEST}"
stage_done

# --- 5/5 Ringkasan ----------------------------------------------------------------
stage "5/5" "Ringkasan"
printf "  strategi : %s\n" "${STRATEGY}"
printf "  versi    : %s\n" "${VERSION}"
printf "  digest   : sha256:%s\n" "${DIGEST}"
printf "  durasi   : %ss\n" "$((SECONDS - PIPELINE_T0))"
stage_done
