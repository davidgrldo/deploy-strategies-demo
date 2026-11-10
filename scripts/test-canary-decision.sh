#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check() {
  local expected="$1" actual
  shift
  actual="$(canary_decision "$@")"
  [ "${actual}" = "${expected}" ] || { echo "expected ${expected}, got ${actual}" >&2; exit 1; }
}
check healthy 100 1 20 0.01
check error-rate 100 2 20 0.01
check insufficient-samples 0 0 20 0.01
check insufficient-samples 0 0 0 0.01
check insufficient-samples 19 0 20 0.01
# Early catastrophic errors must not be mislabeled as merely too few samples.
check error-rate 10 3 20 0.01
check healthy 20 0 20 0.01
echo 'PASS canary decision: healthy, error rate, insufficient evidence'
