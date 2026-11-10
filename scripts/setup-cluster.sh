#!/usr/bin/env bash
# scripts/setup-cluster.sh — siapkan cluster demo: k3d + registry lokal +
# Envoy Gateway, expose di http://localhost:8080.
#
# Idempoten: boleh dijalankan berulang; run kedua mendeteksi yang sudah ada
# dan langsung melanjutkan (converge), bukan gagal.
#
# Nama registry berbeda dari host vs dari dalam cluster (perilaku k3d):
#   - dari host (docker push/pull):  localhost:5001
#   - dari dalam cluster (manifest): k3d-demo-registry:5001
# Digest image sama persis — pipeline hanya menukar prefix registry
# (lihat scripts/lib.sh: registry_prefix_swap).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

CLUSTER_NAME="${CLUSTER_NAME:-demo}"
REGISTRY_NAME="${REGISTRY_NAME:-k3d-demo-registry}"   # nama di dalam jaringan docker
REGISTRY_PORT="${REGISTRY_PORT:-5001}"                # port yang terlihat dari host
# Versi dipin supaya demo reproducible; override lewat env kalau mau coba versi lain.
# install.yaml Envoy Gateway v1.10.0 sudah membawa CRD Gateway API v1
# (bundle-version v1.6.1, standard channel) — tidak perlu apply terpisah.
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.10.0}"
HOST_PORT="${HOST_PORT:-8080}"                        # gateway terlihat di host

need_cmd k3d "k3d (https://k3d.io) — instal dulu, lalu jalankan lagi"
need_cmd kubectl "kubectl — instal dulu, lalu jalankan lagi"
need_cmd curl "curl — instal dulu, lalu jalankan lagi"

# --- 1/5 Registry lokal ----------------------------------------------------
stage "1/5" "Registry lokal :${REGISTRY_PORT}"
if k3d registry list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${REGISTRY_NAME}"; then
  echo "↷ registry ${REGISTRY_NAME} sudah ada — pakai yang ada"
else
  k3d registry create "${REGISTRY_NAME#k3d-}" --port "${REGISTRY_PORT}"
fi

# --- 2/5 Cluster k3d (Traefik dimatikan) ------------------------------------
stage "2/5" "k3d cluster '${CLUSTER_NAME}' (Traefik dimatikan)"
if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  echo "↷ cluster ${CLUSTER_NAME} sudah ada — pakai yang ada"
else
  # --port memetakan host 8080 -> port 80 di load balancer k3d, tempat
  #   Service LoadBalancer Envoy Gateway terpasang.
  # --k3s-arg mematikan Traefik bawaan K3s (bentrok dengan Envoy Gateway).
  # --registry-use menghubungkan cluster ke registry lokal di atas.
  k3d cluster create "${CLUSTER_NAME}" \
    --registry-use "${REGISTRY_NAME}:${REGISTRY_PORT}" \
    --port "${HOST_PORT}:80@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0"
fi
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default --kubeconfig-switch-context

# --- 3/5 Envoy Gateway -------------------------------------------------------
stage "3/5" "Envoy Gateway ${ENVOY_GATEWAY_VERSION} (CRD Gateway API v1 ikut serta)"
# --server-side: install.yaml Envoy Gateway berisi CRD besar; client-side
# apply sering gagal dengan "metadata.annotations: Too long: must have at
# most 262144 bytes" (annotation last-applied-configuration melebihi batas).
# Dokumentasi resmi Envoy Gateway memakai server-side apply.
# --force-conflicts: idempoten saat dijalankan ulang (field manager sama).
kubectl apply --server-side --force-conflicts -f "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml"
echo "… menunggu controller Envoy Gateway siap"
kubectl -n envoy-gateway-system wait --for=condition=available deployment --all --timeout=300s

# --- 4/5 GatewayClass + Gateway ----------------------------------------------
stage "4/5" "apply deploy/gateway.yaml"
kubectl apply -f "${SCRIPT_DIR}/../deploy/gateway.yaml"
echo "… menunggu Gateway ter-program"
kubectl wait --for=condition=programmed gateway/demo --timeout=300s

# --- 5/5 Tunggu gateway terjangkau dari host ---------------------------------
stage "5/5" "Gateway di http://localhost:${HOST_PORT}"
echo "… menunggu service LoadBalancer Envoy muncul"
deadline=$((SECONDS + 120))
# Envoy membuat Service di namespace controller, bukan namespace Gateway.
until kubectl get service -A -l gateway.envoyproxy.io/owning-gateway-name=demo,gateway.envoyproxy.io/owning-gateway-namespace=default -o name 2>/dev/null | grep -q service; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    die "service Envoy belum muncul setelah 120s — cek: kubectl get services -A"
  fi
  sleep 2
done
deadline=$((SECONDS + 120))
until code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:${HOST_PORT}" 2>/dev/null) && [ "${code}" != "000" ]; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    die "gateway belum menjawab di :${HOST_PORT} setelah 120s — cek: kubectl get pods -A | grep envoy"
  fi
  sleep 2
done
stage_done

echo ""
printf "${C_GREEN}${C_BOLD}✅ Cluster siap.${C_RESET}\n"
echo "   Gateway   : http://localhost:${HOST_PORT} (menjawab ${code} — tanpa route, 404 itu normal)"
echo "   Registry  : localhost:${REGISTRY_PORT} (host) = ${REGISTRY_NAME}:${REGISTRY_PORT} (dalam cluster)"
printf "   Langkah 2 : buka dua terminal — ${C_CYAN}make watch${C_RESET} dan ${C_CYAN}make <strategi>${C_RESET}\n"
