#!/usr/bin/env bash
# scripts/watch.sh — panel traffic live (§7).
# Beberapa worker paralel mencurl /version terus-menerus; setiap respons
# dicetak satu baris (HH:MM:SS  STATUS  VERSI), tiap ±2 detik ada baris
# ringkasan campuran versi, dan saat traffic pulih setelah rentang error
# berturut-turut, durasi downtime dicetak: "⛔ downtime 3.4s".
#
#   WORKERS=12 ./scripts/watch.sh           # lebih banyak worker (default 6)
#   ./scripts/watch.sh --compact            # hanya baris ringkasan
#
# Panel ini TIDAK boleh crash walau gateway mati: error dicetak merah lalu
# loop lanjut — downtime-nya justru yang mau ditonton.
set -u

URL="${URL:-http://localhost:8080/version}"
WORKERS="${WORKERS:-6}"
TIMEOUT="${TIMEOUT:-2}"   # detik; pendek supaya pod mati cepat terlihat
COMPACT=0
[ "${1:-}" = "--compact" ] && COMPACT=1

C_RESET='\033[0m'; C_BOLD='\033[1m'
C_RED='\033[1;31m'; C_CYAN='\033[36m'; C_YELLOW='\033[33m'; C_GREY='\033[90m'

now_ms() {
  local t nanos
  # Potong nanodetik secara eksplisit: sebagian implementasi date tidak
  # memotong %3N, sehingga timestamp dan perhitungan downtime salah.
  t="$(date '+%s %N' 2>/dev/null)"
  case "${t}" in
    *N*|'') echo "$(date +%s)000" ;;
    *) nanos="${t#* }"; printf '%s%s\n' "${t%% *}" "${nanos:0:3}" ;;
  esac
}

# --- worker: loop curl, append "epoch_ms status versi" ke file bersama ------
TMP="$(mktemp /tmp/watch.XXXXXX)"
PIDS=""

worker() {
  local idx="$1" body_f hdrs code ver
  body_f="${TMP}.body${idx}"
  while :; do
    hdrs="$(curl -sS -m "${TIMEOUT}" -D - -o "${body_f}" -w '%{http_code}' "${URL}" 2>/dev/null)" || hdrs=""
    if [ -z "${hdrs}" ]; then
      printf '%s ERR -\n' "$(now_ms)" >> "${TMP}"
    else
      code="${hdrs##*$'\n'}"
      # versi dari header X-Version (selalu ada, bahkan pada respons 500);
      # fallback ke body untuk server lain yang tak mengirim header itu
      ver="$(printf '%s' "${hdrs}" | tr -d '\r' | sed -n 's/^[Xx]-[Vv]ersion:[[:space:]]*//p' | head -1)"
      [ -n "${ver}" ] || ver="$(head -1 "${body_f}" 2>/dev/null)"
      printf '%s %s %s\n' "$(now_ms)" "${code:-ERR}" "${ver:--}" >> "${TMP}"
    fi
    sleep 0.3
  done
}

cleanup() {
  for p in ${PIDS}; do kill "${p}" 2>/dev/null; done
  rm -f "${TMP}" "${TMP}".body*
}
trap cleanup EXIT INT TERM

printf "${C_BOLD}panel traffic → %s (%s worker)${C_RESET}\n" "${URL}" "${WORKERS}"
i=0
while [ "${i}" -lt "${WORKERS}" ]; do
  worker "${i}" &
  PIDS="${PIDS} $!"
  i=$((i + 1))
done

# --- agregator: cetak per-respons + ringkasan ±2s + deteksi downtime --------
win_t0="$(now_ms)"
win_total=0; win_v1=0; win_v2=0; win_other=0; win_err=0
err_start=""   # epoch_ms awal rentang error berturut-turut

version_color() { # v1 abu-abu · v2 cyan · versi lain kuning
  case "$1" in
    v1) printf '%s' "${C_GREY}" ;;
    v2) printf '%s' "${C_CYAN}" ;;
    *)  printf '%s' "${C_YELLOW}" ;;
  esac
}

while read -r ts status ver; do
  [ -n "${ts}" ] || continue

  # --- baris per-respons (dilewati saat --compact) --------------------------
  if [ "${COMPACT}" -eq 0 ]; then
    clock="$(date -d @$((ts / 1000)) +%H:%M:%S 2>/dev/null || date +%H:%M:%S)"
    case "${status}" in
      ERR|5*)
        printf "${C_RED}%s  %s  %s${C_RESET}\n" "${clock}" "${status}" "${ver}"
        ;;
      *)
        printf "$(version_color "${ver}")%s  %s  %s${C_RESET}\n" "${clock}" "${status}" "${ver}"
        ;;
    esac
  fi

  # --- hitung jendela ringkasan ---------------------------------------------
  win_total=$((win_total + 1))
  is_err=0
  case "${status}" in ERR|5*) is_err=1; win_err=$((win_err + 1)) ;;
    *) case "${ver}" in
         v1) win_v1=$((win_v1 + 1)) ;;
         v2) win_v2=$((win_v2 + 1)) ;;
         *)  win_other=$((win_other + 1)) ;;
       esac
       # pulih: kalau barusan rentang error, cetak durasi downtime-nya
       if [ -n "${err_start}" ]; then
        printf "${C_RED}${C_BOLD}⛔ downtime %ss${C_RESET}\n" \
          "$(awk -v a="${err_start}" -v b="${ts}" 'BEGIN{printf "%.1f", (b-a)/1000}')"
        err_start=""
      fi
       ;;
  esac
  if [ "${is_err}" -eq 1 ] && [ -z "${err_start}" ]; then
    err_start="${ts}"   # awal rentang error berturut-turut
  fi

  # --- ringkasan tiap ±2 detik ----------------------------------------------
  now="$(now_ms)"
  if [ $((now - win_t0)) -ge 2000 ] && [ "${win_total}" -gt 0 ]; then
    nonerr=$((win_total - win_err))
    if [ "${nonerr}" -gt 0 ]; then
      line="$(awk -v a="${win_v1}" -v b="${win_v2}" -v c="${win_other}" -v n="${nonerr}" 'BEGIN{
        printf "v1 %d%% · v2 %d%%", (a*100+n/2)/n, (b*100+n/2)/n
        if (c > 0) printf " · lain %d%%", (c*100+n/2)/n
      }')"
    else
      line="v1 —% · v2 —%"
    fi
    printf "${C_BOLD}%s · err %d${C_RESET}\n" "${line}" "${win_err}"
    win_t0="${now}"; win_total=0; win_v1=0; win_v2=0; win_other=0; win_err=0
  fi
done < <(tail -n +1 -f "${TMP}")
