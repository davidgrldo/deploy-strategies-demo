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

# release_canary: versi baru dapat persentase kecil traffic dulu, lalu
# pipeline SENDIRI yang menganalisis (§6 — sengaja tanpa alat metrik
# eksternal): kirim request ke /version lewat gateway, hitung HANYA respons
# yang X-Version-nya sama dengan versi canary, lalu putuskan promote atau
# rollback otomatis. Health check tidak akan menangkap versi rusak —
# /healthz lolos walau user kena 500 — jadi traffic-lah buktinya.
release_canary() {
  local version="$1" digest="$2"
  local canary_weight="${CANARY_WEIGHT:-10}" observe="${OBSERVE_SECONDS:-120}"
  local max_rate="${MAX_ERROR_RATE:-0.01}" min_samples="${MIN_SAMPLES:-20}"

  echo "  deploy ${version} ke app-canary (${canary_weight}% traffic setelah siap)"
  set_image app-canary "${digest}"
  scale_workload app-canary 1
  if [ -n "${FAIL_RATE:-}" ]; then
    echo "  FAIL_RATE=${FAIL_RATE} diteruskan ke workload canary (simulasi versi rusak)"
    kubectl set env deployment/app-canary "FAIL_RATE=${FAIL_RATE}"
  else
    kubectl set env deployment/app-canary FAIL_RATE- >/dev/null 2>&1 || true
  fi
  wait_rollout app-canary

  echo "  set weight: app-stable $((100 - canary_weight)) / app-canary ${canary_weight}"
  set_weights app-stable "$((100 - canary_weight))" app-canary "${canary_weight}"

  canary_analyze "${version}" "${observe}" "${max_rate}" "${min_samples}"
  local samples="${CANARY_SAMPLES}" errors="${CANARY_ERRORS}"

  if [ "${samples}" -ge "${min_samples}" ] \
    && [ "$(awk -v e="${errors}" -v s="${samples}" -v m="${max_rate}" 'BEGIN{print (e/s<=m)?1:0}')" = "1" ]; then
    # promote: update app-stable ke DIGEST YANG SAMA — build cukup sekali
    echo "  promote: app-stable → digest yang sama (tanpa build ulang)"
    set_image app-stable "${digest}"
    wait_rollout app-stable
    set_weights app-stable 100 app-canary 0
    scale_workload app-canary 0
    printf "${C_GREEN}${C_BOLD}✅ PROMOTED %s → 100%%${C_RESET}\n" "${version}"
  else
    set_weights app-stable 100 app-canary 0
    scale_workload app-canary 0
    printf "${C_BOLD}${C_RED}❌ ROLLBACK: error rate %s%% > %s%%${C_RESET}\n" \
      "$(awk -v e="${errors}" -v s="${samples}" 'BEGIN{printf "%.1f", (s>0)?(e*100/s):0}')" \
      "$(awk -v m="${max_rate}" 'BEGIN{printf "%g", m*100}')"
    exit 1
  fi
}

# canary_analyze <version> <observe_s> <max_rate> <min_samples>
# Loop analisis: beberapa pengirim paralel menulis "code versi" per request;
# kolektor menghitung sampel & error versi canary, mencetak progres tiap
# ±10 detik ("canary: 42 req, 1 error (2.4%)") dan bisa berhenti lebih awal
# begitu jelas gagal. Hasil lewat CANARY_SAMPLES / CANARY_ERRORS.
canary_analyze() {
  local version="$1" observe="$2" max_rate="$3" min_samples="$4"
  local out stopfile code ver pids="" i elapsed
  out="$(mktemp /tmp/canary.XXXXXX)"
  stopfile="${out}.stop"
  # pengirim berhenti saat file stop muncul — termasuk saat pipeline exit
  trap 's="${stopfile:-}"; [ -n "${s}" ] && touch "${s}" 2>/dev/null' RETURN INT TERM EXIT

  # pengirim traffic paralel — pipeline-nya sendiri load generator + analis
  for i in 1 2 3 4; do
    (
      while [ ! -f "${stopfile}" ]; do
        hdrs="$(curl -sS -m 2 -D - -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/version" 2>/dev/null)" || hdrs=""
        if [ -n "${hdrs}" ]; then
          code="${hdrs##*$'\n'}"
          ver="$(printf '%s' "${hdrs}" | tr -d '\r' | sed -n 's/^[Xx]-[Vv]ersion:[[:space:]]*//p' | head -1)"
          printf '%s %s\n' "${code}" "${ver}" >> "${out}"
        fi
        sleep 0.1
      done
    ) &
    pids="${pids} $!"
  done

  local t0="${SECONDS}" samples=0 errors=0 last_print="${SECONDS}"
  # window minimal observe_s; kalau sampel belum cukup, lanjut sampai hard
  # cap 2× observe_s — MIN_SAMPLES itu syarat keputusan, bukan formalitas
  while :; do
    sleep 1
    samples="$(awk -v v="${version}" '$2==v' "${out}" | wc -l | tr -d ' ')"
    errors="$(awk -v v="${version}" '$2==v && $1 !~ /^2/' "${out}" | wc -l | tr -d ' ')"
    if [ $((SECONDS - last_print)) -ge 10 ]; then
      printf "  ${C_GREY}canary: %s req, %s error (%s%%)${C_RESET}\n" "${samples}" "${errors}" \
        "$(awk -v e="${errors}" -v s="${samples}" 'BEGIN{printf "%.1f", (s>0)?(e*100/s):0}')"
      last_print="${SECONDS}"
    fi
    # berhenti lebih awal begitu jelas gagal: sampel cukup & di atas ambang,
    # atau bencana (≥10 sampel, error rate > 5× ambang)
    if [ "${samples}" -ge "${min_samples}" ] \
      && [ "$(awk -v e="${errors}" -v s="${samples}" -v m="${max_rate}" 'BEGIN{print (e/s>m)?1:0}')" = "1" ]; then
      break
    fi
    if [ "${samples}" -ge 10 ] \
      && [ "$(awk -v e="${errors}" -v s="${samples}" -v m="${max_rate}" 'BEGIN{print (e/s>m*5)?1:0}')" = "1" ]; then
      break
    fi
    elapsed=$((SECONDS - t0))
    [ "${elapsed}" -ge "${observe}" ] && [ "${samples}" -ge "${min_samples}" ] && break
    [ "${elapsed}" -ge "$((observe * 2))" ] && break
  done

  printf "  ${C_GREY}canary: %s req, %s error (%s%%) — window selesai${C_RESET}\n" "${samples}" "${errors}" \
    "$(awk -v e="${errors}" -v s="${samples}" 'BEGIN{printf "%.1f", (s>0)?(e*100/s):0}')"

  touch "${stopfile}"
  for i in ${pids}; do wait "${i}" 2>/dev/null; done
  rm -f "${out}" "${stopfile}"
  CANARY_SAMPLES="${samples}"
  CANARY_ERRORS="${errors}"
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
