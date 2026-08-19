#!/usr/bin/env bash
# =============================================================
# configure-custom-domain.sh
#
# Run AFTER DNS records have been created.
# Binds the custom domain + managed certificate to the
# dashboard Container App.
#
# Usage:
#   ./configure-custom-domain.sh
# =============================================================
set -Eeuo pipefail

readonly RESOURCE_GROUP="bab-core-ghcp-dashboard-01"
readonly APP_DASHBOARD="bab-aro-ops-dashboard-01"
readonly CUSTOM_DOMAIN="aro-ops-dashboard.albtests.com"

echo "[INFO] Binding custom domain: ${CUSTOM_DOMAIN}"

# Add custom domain with Azure-managed free certificate
az containerapp hostname add \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_DASHBOARD}" \
    --hostname "${CUSTOM_DOMAIN}" \
    --output table

echo "[INFO] Binding managed TLS certificate"
az containerapp ssl upload \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_DASHBOARD}" \
    --environment "bab-core-azcpenv-ghcp-dashboard" \
    --hostname "${CUSTOM_DOMAIN}" \
    --certificate-file "$(dirname "$0")/certs/${CUSTOM_DOMAIN}.pfx" \
    2>/dev/null || \
az containerapp hostname bind \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_DASHBOARD}" \
    --hostname "${CUSTOM_DOMAIN}" \
    --environment "bab-core-azcpenv-ghcp-dashboard" \
    --validation-method CNAME \
    --output table

echo ""
echo "[OK] Custom domain bound: https://${CUSTOM_DOMAIN}"
echo ""
echo "Verify with:"
echo "  curl -I https://${CUSTOM_DOMAIN}/healthz"
