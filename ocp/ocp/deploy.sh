#!/usr/bin/env bash
# =============================================================
# deploy.sh — One-shot deployment to an ARO cluster
#
# Prerequisites:
#   oc login <cluster> with cluster-admin or project-admin
#   Images already pushed to registry
#
# Usage:
#   ./deploy.sh [--namespace capacity-monitor] [--registry your-registry.azurecr.io]
# =============================================================
set -Eeuo pipefail

NS="capacity-monitor"
REGISTRY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --registry)  REGISTRY="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCP_DIR="${SCRIPT_DIR}"

echo "=== Deploying ARO Capacity Monitor to namespace: ${NS} ==="

# ── Create namespace ──────────────────────────────────────────
oc get namespace "${NS}" &>/dev/null || oc new-project "${NS}"

# ── Secret — MUST exist before applying other manifests ──────
echo ""
echo "INFO: Apply secret manually if not done yet:"
echo "  oc create secret generic capacity-secrets \\"
echo "    --from-literal=DB_PASSWORD='\$(read -sp DB_PASSWORD: p; echo \$p)' \\"
echo "    --from-literal=DEV_TOKEN='sha256~...' \\"
echo "    --from-literal=SIT_TOKEN='sha256~...' \\"
echo "    --from-literal=DATABASE_URL='postgresql://planner:PASSWORD@postgres:5432/capacity' \\"
echo "    -n ${NS}"
echo ""
read -p "Press ENTER once the secret is created…"

# ── Patch image registry if supplied ─────────────────────────
if [[ -n "${REGISTRY}" ]]; then
  sed -i "s|your-registry|${REGISTRY}|g" \
    "${OCP_DIR}/api.yaml" \
    "${OCP_DIR}/dashboard.yaml" \
    "${OCP_DIR}/collector.yaml"
fi

# ── Apply manifests in order ──────────────────────────────────
oc apply -n "${NS}" -f "${OCP_DIR}/postgres.yaml"
oc apply -n "${NS}" -f "${OCP_DIR}/api.yaml"
oc apply -n "${NS}" -f "${OCP_DIR}/dashboard.yaml"
oc apply -n "${NS}" -f "${OCP_DIR}/collector.yaml"

# ── Wait for pods ─────────────────────────────────────────────
echo "Waiting for postgres…"
oc rollout status statefulset/postgres -n "${NS}" --timeout=120s

echo "Waiting for API…"
oc rollout status deployment/capacity-api -n "${NS}" --timeout=120s

echo "Waiting for dashboard…"
oc rollout status deployment/capacity-dashboard -n "${NS}" --timeout=120s

# ── Print URL ─────────────────────────────────────────────────
ROUTE_URL=$(oc get route capacity-monitor -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo ""
echo "==================================================="
echo " Dashboard URL:"
echo "   https://${ROUTE_URL}"
echo "==================================================="
echo " API health:   https://${ROUTE_URL}/api/v1/health"
echo " API status:   https://${ROUTE_URL}/api/v1/status"
echo "==================================================="
