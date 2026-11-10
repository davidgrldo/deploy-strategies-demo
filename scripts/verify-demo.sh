#!/usr/bin/env bash
# Uji integrasi pada cluster demo lokal. Mengubah/reset workload demo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LOG_DIR="${LOG_DIR:-$(mktemp -d /tmp/deploy-demo-check.XXXXXX)}"
mkdir -p "${LOG_DIR}"
echo "Log pengujian: ${LOG_DIR}"

run() {
  local target="$1"
  echo "TEST ${target}"
  if ! make "${target}" >"${LOG_DIR}/${target}.log" 2>&1; then
    tail -60 "${LOG_DIR}/${target}.log"
    return 1
  fi
}

expect_version() {
  local expected="$1" deadline=$((SECONDS + 30)) body
  while :; do
    body="$(curl -fsS --max-time 3 http://localhost:8080/version 2>/dev/null)" || body=""
    if [ "${body}" = "${expected}" ]; then
      echo "PASS HTTP 200 /version = ${expected}"
      return
    fi
    [ "${SECONDS}" -lt "${deadline}" ] || { echo "FAIL expected ${expected}, got ${body}"; return 1; }
    sleep 1
  done
}

run cluster
for strategy in recreate rolling rolling-naive bluegreen; do
  run "${strategy}"
  expect_version v2
done
run bluegreen-rollback
expect_version v1

run canary
grep -q 'PROMOTED' "${LOG_DIR}/canary.log"
stable="$(kubectl get deployment app-stable -o jsonpath='{.spec.template.spec.containers[0].image}')"
canary="$(kubectl get deployment app-canary -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "${stable}" = "${canary}" ]
echo 'PASS canary promoted with the same digest'
expect_version v2

echo 'TEST canary-bad (expected nonzero exit and rollback)'
if make canary-bad >"${LOG_DIR}/canary-bad.log" 2>&1; then
  echo 'FAIL bad canary unexpectedly succeeded'
  exit 1
fi
grep -q 'ROLLBACK' "${LOG_DIR}/canary-bad.log"
[ "$(kubectl get deployment app-canary -o jsonpath='{.spec.replicas}')" = 0 ]
expect_version v1

run demo-shutdown
grep -q 'graceful : 200 OK' "${LOG_DIR}/demo-shutdown.log"
grep -q '\[shutdown\]' "${LOG_DIR}/demo-shutdown.log"
if grep -q 'tidak putus?\|GAGAL' "${LOG_DIR}/demo-shutdown.log"; then
  cat "${LOG_DIR}/demo-shutdown.log"
  exit 1
fi

echo 'TEST watch panel'
timeout --signal=TERM --kill-after=3 8 bash scripts/watch.sh --compact >"${LOG_DIR}/watch.log" 2>&1 || [ "$?" = 124 ]
grep -q 'v1 100%' "${LOG_DIR}/watch.log"
summaries="$(grep -c 'err ' "${LOG_DIR}/watch.log")"
[ "${summaries}" -ge 2 ] && [ "${summaries}" -le 5 ]
echo 'PASS watch panel'

# Tinggalkan aplikasi versi baru siap dicoba pengguna.
run rolling
expect_version v2
echo 'PASS all demo scenarios'
