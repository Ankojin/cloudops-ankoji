#!/usr/bin/env bash
# =============================================================
# deploy-aro-live-dashboard.sh
#
# Deploys the ARO Ops Live Dashboard stack to the existing
# Azure Container Apps environment.
#
# Architecture deployed:
#
#   ACR (azcrghcpdashboard01)
#     ├── aro-ops/capacity-planner:latest   (base scripts image)
#     ├── aro-ops/api:latest                (FastAPI backend)
#     ├── aro-ops/dashboard:latest          (nginx SPA)
#     └── aro-ops/collector:latest          (cron data collector)
#
#   All Dockerfiles and source live under live-dashboard/:
#     live-dashboard/capacity-planner/   (base image)
#     live-dashboard/api/
#     live-dashboard/dashboard/
#     live-dashboard/collector/
#
#   Container Apps Environment (bab-core-azcpenv-ghcp-dashboard)
#     ├── bab-aro-ops-api-01        (internal, :8000)
#     ├── bab-aro-ops-dashboard-01  (external HTTPS, :80)
#     └── bab-aro-ops-collector-01  (Job, */5 * * * *)
#
#   PostgreSQL Flexible Server
#     └── pgdb-aro-ops-dashboard-01  (VNet-integrated)
#
#   Key Vault (bab-core-kv-ghcpdash-01)
#     ├── aro-db-password   → Postgres password
#     ├── aro-dev-token     → DEV cluster service account token
#     └── aro-sit-token     → SIT cluster service account token
#
# Prerequisites:
#   az login && az account set -s <subscription-id>
#   Sufficient RBAC on the RG, ACR, Key Vault, Container Apps Env
#
# Usage:
#   # Minimal — secrets prompted interactively
#   ./deploy-aro-live-dashboard.sh
#    --rebuild-images     rebuild all 4 + update all Container Apps
#   --rebuild-planner    rebuild capacity-planner base image only
#   --rebuild-api        rebuild API image + update bab-aro-ops-api-01
#   --rebuild-dashboard  rebuild dashboard image + update bab-aro-ops-dashboard-01
#   --rebuild-collector  rebuild collector image + update bab-aro-ops-collector-01
#   # Non-interactive (CI / pipeline)
#   export ARO_DB_PASSWORD="..." ARO_DEV_TOKEN="..." ARO_SIT_TOKEN="..."
#   ./deploy-aro-live-dashboard.sh --no-prompt
# =============================================================

set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────
# Fixed infrastructure values (from the existing environment)
# ─────────────────────────────────────────────────────────────
readonly SUBSCRIPTION_ID="d88f0b5b-6660-4607-8c6a-395820400912"
readonly RESOURCE_GROUP="bab-core-ghcp-dashboard-01"
readonly LOCATION="westeurope"

readonly ACR_NAME="azcrghcpdashboard01"
readonly ACR_ENDPOINT="${ACR_NAME}.azurecr.io"
readonly IMAGE_PREFIX="aro-ops"

readonly CONTAINER_APP_ENV="bab-core-azcpenv-ghcp-dashboard"
readonly APP_API="bab-aro-ops-api-01"
readonly APP_DASHBOARD="bab-aro-ops-dashboard-01"
readonly APP_COLLECTOR="bab-aro-ops-collector-01"
readonly APP_SUBNET="snet-core-weeu-shared-appcont-01"

readonly KV_NAME="bab-core-kv-ghcpdash-01"
readonly MANAGED_IDENTITY_NAME="bab-aro-ops-mi-01"

readonly PG_SERVER="pgdb-aro-ops-dashboard-01"
readonly PG_DB="pgdb_aro_ops"          # PostgreSQL database name
readonly PG_ADMIN_USER="pgadmin"
readonly PG_SUBNET="snet-core-weeu-shared-pgdb-01"
readonly VNET_NAME="bab-core-nw-weeu-vnet-shared-01"
readonly VNET_RG="bab-core-nw-weeu-rg-01"

readonly CUSTOM_DOMAIN="aro-ops-dashboard.albtests.com"

# ARO cluster endpoints (override via env if different)
readonly DEV_API="${DEV_API:-https://api.babdevaro.albtests.com:6443}"
readonly SIT_API="${SIT_API:-https://api.babsitaro.albtests.com:6443}"
readonly DEV_ENV_LABEL="${DEV_ENV_LABEL:-DEV}"
readonly SIT_ENV_LABEL="${SIT_ENV_LABEL:-SIT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER_ROOT="${SCRIPT_DIR}/.."          # live-dashboard/ → planner root
NO_PROMPT=false
SKIP_BUILDS=false
FORCE_SECRETS=false    # --force-secrets: overwrite KV secrets even if they already exist

# Resolve the Container Apps environment DNS suffix — used to build the full
# internal FQDN for service-to-service proxying (nginx → API).
# e.g. jollysmoke-83e3687c.westeurope.azurecontainerapps.io
ENV_DEFAULT_DOMAIN="$(az containerapp env show \
    -n "${CONTAINER_APP_ENV}" -g "${RESOURCE_GROUP}" \
    --query "properties.defaultDomain" -o tsv 2>/dev/null)"

# Per-component rebuild flags (set by --rebuild-* args)
# --rebuild-images sets all four; individual flags rebuild only that component.
REBUILD_PLANNER=false
REBUILD_API=false
REBUILD_DASHBOARD=false
REBUILD_COLLECTOR=false

# Image version tag: YYYYMMDD-HHmmss[-<git-sha>]
# Allows rolling back to any specific build via ACR tag history.
_ts="$(date -u '+%Y%m%d-%H%M%S')"
_sha="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo '')"
IMAGE_TAG="${_ts}${_sha:+-${_sha}}"
readonly IMAGE_TAG

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
banner() {
    local msg="$*"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    printf  "║  %-56s║\n" "$msg"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

info()  { echo "  [INFO]  $*" >&2; }
ok()    { echo "  [OK]    $*" >&2; }
warn()  { echo "  [WARN]  $*" >&2; }
die()   { echo "  [ERROR] $*" >&2; exit 1; }

read_secret() {
    local name="$1" prompt="$2"

    # 1. Env var already exported — use it directly
    if [[ -n "${!name:-}" ]]; then
        info "Using ${name} from environment"
        echo "${!name}"
        return
    fi

    # 2. Try Key Vault (secrets may already be stored from a previous run)
    local kv_name_map=""
    case "${name}" in
        ARO_DB_PASSWORD) kv_name_map="aro-db-password"  ;;
        ARO_DEV_TOKEN)   kv_name_map="aro-dev-token"    ;;
        ARO_SIT_TOKEN)   kv_name_map="aro-sit-token"    ;;
    esac
    if [[ -n "${kv_name_map}" ]]; then
        local kv_val=""
        kv_val=$(az keyvault secret show \
            --vault-name "${KV_NAME}" \
            --name "${kv_name_map}" \
            --query value -o tsv 2>/dev/null || echo "")
        if [[ -n "${kv_val}" ]]; then
            info "Using ${name} from Key Vault (${kv_name_map})"
            echo "${kv_val}"
            return
        fi
    fi

    # 3. Interactive prompt (or die in --no-prompt mode)
    if [[ "${NO_PROMPT}" == "true" ]]; then
        die "${name} not found in environment or Key Vault (${KV_NAME}/${kv_name_map:-unknown})"
    fi
    local val=""
    while [[ -z "${val}" ]]; do
        read -r -s -p "  Enter ${prompt}: " val
        echo ""
    done
    echo "${val}"
}

# ─────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "${arg}" in
        --no-prompt)          NO_PROMPT=true ;;
        --skip-builds)        SKIP_BUILDS=true ;;
        --force-secrets)      FORCE_SECRETS=true ;;
        # Rebuild all 4 images + update all Container Apps
        --rebuild-images)     REBUILD_PLANNER=true; REBUILD_API=true; REBUILD_DASHBOARD=true; REBUILD_COLLECTOR=true ;;
        # Rebuild individual components only
        --rebuild-planner)    REBUILD_PLANNER=true ;;    # base image only, no CA update
        --rebuild-api)        REBUILD_API=true ;;
        --rebuild-dashboard)  REBUILD_DASHBOARD=true ;;
        --rebuild-collector)  REBUILD_COLLECTOR=true ;;  # uses existing :latest planner
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//' | head -40
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# --rebuild-* short-circuit:
# Rebuilds the requested component images and updates the running
# Container Apps without touching infra (PG, KV, networking).
#
#   --rebuild-images     rebuild all 4 + update all Container Apps
#   --rebuild-planner    rebuild capacity-planner base image only
#   --rebuild-api        rebuild API image + update bab-aro-ops-api-01
#   --rebuild-dashboard  rebuild dashboard image + update bab-aro-ops-dashboard-01
#   --rebuild-collector  rebuild collector image + update bab-aro-ops-collector-01
# ─────────────────────────────────────────────────────────────
if [[ "${REBUILD_PLANNER}" == "true" || "${REBUILD_API}" == "true" || \
      "${REBUILD_DASHBOARD}" == "true" || "${REBUILD_COLLECTOR}" == "true" ]]; then

    banner "Selective image rebuild & Container App update"
    command -v az &>/dev/null || die "Azure CLI (az) not found."
    az account set --subscription "${SUBSCRIPTION_ID}" --output none

    # ── capacity-planner (base image — no Container App to update) ────
    if [[ "${REBUILD_PLANNER}" == "true" ]]; then
        info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/capacity-planner:${IMAGE_TAG}"
        az acr build --registry "${ACR_NAME}" \
            --image "${IMAGE_PREFIX}/capacity-planner:latest" \
            --image "${IMAGE_PREFIX}/capacity-planner:${IMAGE_TAG}" \
            --file "${SCRIPT_DIR}/capacity-planner/Dockerfile" "${PLANNER_ROOT}" --output table
        ok "capacity-planner built (${IMAGE_TAG})"
    fi

    # ── API ───────────────────────────────────────────────────────────
    if [[ "${REBUILD_API}" == "true" ]]; then
        info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/api:${IMAGE_TAG}"
        az acr build --registry "${ACR_NAME}" \
            --image "${IMAGE_PREFIX}/api:latest" \
            --image "${IMAGE_PREFIX}/api:${IMAGE_TAG}" \
            --file "${SCRIPT_DIR}/api/Dockerfile" "${SCRIPT_DIR}/api" --output table
        info "Updating Container App: ${APP_API}"
        az containerapp update \
            --name "${APP_API}" --resource-group "${RESOURCE_GROUP}" \
            --image "${ACR_ENDPOINT}/${IMAGE_PREFIX}/api:${IMAGE_TAG}" --output table
        ok "API rebuilt and updated (${IMAGE_TAG})"
    fi

    # ── Dashboard ─────────────────────────────────────────────────────
    if [[ "${REBUILD_DASHBOARD}" == "true" ]]; then
        info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/dashboard:${IMAGE_TAG}"
        az acr build --registry "${ACR_NAME}" \
            --image "${IMAGE_PREFIX}/dashboard:latest" \
            --image "${IMAGE_PREFIX}/dashboard:${IMAGE_TAG}" \
            --file "${SCRIPT_DIR}/dashboard/Dockerfile" "${SCRIPT_DIR}/dashboard" --output table
        info "Updating Container App: ${APP_DASHBOARD}"
        az containerapp update \
            --name "${APP_DASHBOARD}" --resource-group "${RESOURCE_GROUP}" \
            --image "${ACR_ENDPOINT}/${IMAGE_PREFIX}/dashboard:${IMAGE_TAG}" --output table
        ok "Dashboard rebuilt and updated (${IMAGE_TAG})"
    fi

    # ── Collector ─────────────────────────────────────────────────────
    # Uses the planner tag just built (if --rebuild-planner was also set),
    # otherwise uses the existing :latest planner from ACR.
    if [[ "${REBUILD_COLLECTOR}" == "true" ]]; then
        if [[ "${REBUILD_PLANNER}" == "true" ]]; then
            PLANNER_TAG="${IMAGE_TAG}"
        else
            PLANNER_TAG="latest"
        fi
        info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/collector:${IMAGE_TAG} (planner base: ${PLANNER_TAG})"
        az acr build --registry "${ACR_NAME}" \
            --image "${IMAGE_PREFIX}/collector:latest" \
            --image "${IMAGE_PREFIX}/collector:${IMAGE_TAG}" \
            --file "${SCRIPT_DIR}/collector/Dockerfile" "${PLANNER_ROOT}" \
            --build-arg "BASE_IMAGE=${ACR_ENDPOINT}/${IMAGE_PREFIX}/capacity-planner:${PLANNER_TAG}" --output table
        info "Updating Container App Job: ${APP_COLLECTOR}"
        az containerapp job update \
            --name "${APP_COLLECTOR}" --resource-group "${RESOURCE_GROUP}" \
            --image "${ACR_ENDPOINT}/${IMAGE_PREFIX}/collector:${IMAGE_TAG}" --output table
        ok "Collector rebuilt and updated (${IMAGE_TAG})"
    fi

    ok "Done. Tag: ${IMAGE_TAG}"
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# 0. Validate prerequisites
# ─────────────────────────────────────────────────────────────
banner "Step 0 — Validating prerequisites"

command -v az   &>/dev/null || die "Azure CLI (az) not found. Install: https://aka.ms/installazurecli"
command -v jq   &>/dev/null || die "jq not found. Install: apk/apt/brew install jq"

CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [[ "${CURRENT_SUB}" != "${SUBSCRIPTION_ID}" ]]; then
    info "Switching to subscription ${SUBSCRIPTION_ID}"
    az account set --subscription "${SUBSCRIPTION_ID}"
fi
ok "Subscription: ${SUBSCRIPTION_ID}"

# ─────────────────────────────────────────────────────────────
# 1. Collect secrets (never logged, stored only in Key Vault)
# ─────────────────────────────────────────────────────────────
banner "Step 1 — Collecting secrets"

# Helper: returns true if the secret already exists in Key Vault
kv_exists() {
    az keyvault secret show \
        --vault-name "${KV_NAME}" --name "$1" \
        --query name -o tsv 2>/dev/null | grep -q .
}

# Only collect a secret when it is not already stored in Key Vault
# (or when --force-secrets is set to allow rotation).
if [[ "${FORCE_SECRETS}" == "true" ]] || ! kv_exists "aro-db-password"; then
    ARO_DB_PASSWORD=$(read_secret "ARO_DB_PASSWORD" "PostgreSQL password for ${PG_ADMIN_USER}")
else
    info "aro-db-password already in Key Vault — skipping collection"
    ARO_DB_PASSWORD=""
fi

if [[ "${FORCE_SECRETS}" == "true" ]] || ! kv_exists "aro-dev-token"; then
    ARO_DEV_TOKEN=$(read_secret "ARO_DEV_TOKEN" "DEV cluster service-account token (sha256~...)")
else
    info "aro-dev-token already in Key Vault — skipping collection"
    ARO_DEV_TOKEN=""
fi

if [[ "${FORCE_SECRETS}" == "true" ]] || ! kv_exists "aro-sit-token"; then
    ARO_SIT_TOKEN=$(read_secret "ARO_SIT_TOKEN" "SIT cluster service-account token (sha256~...)")
else
    info "aro-sit-token already in Key Vault — skipping collection"
    ARO_SIT_TOKEN=""
fi

ok "Secrets collected (not logged)"

# ─────────────────────────────────────────────────────────────
# 2. Create User-Assigned Managed Identity
# ─────────────────────────────────────────────────────────────
banner "Step 2 — Managed Identity"

EXISTING_MI=$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${MANAGED_IDENTITY_NAME}" \
    --query id -o tsv 2>/dev/null || echo "")

if [[ -z "${EXISTING_MI}" ]]; then
    info "Creating managed identity: ${MANAGED_IDENTITY_NAME}"
    az identity create \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${MANAGED_IDENTITY_NAME}" \
        --location "${LOCATION}" \
        --output table
else
    info "Managed identity already exists: ${MANAGED_IDENTITY_NAME}"
fi

MI_CLIENT_ID=$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${MANAGED_IDENTITY_NAME}" \
    --query clientId -o tsv)

MI_PRINCIPAL_ID=$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${MANAGED_IDENTITY_NAME}" \
    --query principalId -o tsv)

MI_RESOURCE_ID=$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${MANAGED_IDENTITY_NAME}" \
    --query id -o tsv)

ok "MI client ID: ${MI_CLIENT_ID}"

# Grant AcrPull on the registry
info "Assigning AcrPull role to managed identity on ACR"
ACR_ID=$(az acr show --name "${ACR_NAME}" --query id -o tsv)
az role assignment create \
    --assignee-object-id "${MI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "AcrPull" \
    --scope "${ACR_ID}" \
    --output none 2>/dev/null || info "AcrPull already assigned"

# Grant Key Vault Secrets User
info "Assigning Key Vault Secrets User role to managed identity"
KV_ID=$(az keyvault show --name "${KV_NAME}" --query id -o tsv)
az role assignment create \
    --assignee-object-id "${MI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Key Vault Secrets User" \
    --scope "${KV_ID}" \
    --output none 2>/dev/null || info "KV Secrets User already assigned"

ok "RBAC assignments complete"

# ─────────────────────────────────────────────────────────────
# 3. Store secrets in Key Vault
# ─────────────────────────────────────────────────────────────
banner "Step 3 — Key Vault secrets"

kv_set() {
    local name="$1" value="$2"
    # Only write if the secret doesn't already exist in Key Vault.
    # Pass --force to overwrite an existing secret intentionally.
    local existing=""
    existing=$(az keyvault secret show \
        --vault-name "${KV_NAME}" --name "${name}" \
        --query value -o tsv 2>/dev/null || echo "")
    if [[ -n "${existing}" ]]; then
        if [[ "${FORCE_SECRETS}" == "true" ]]; then
            info "KV secret exists but --force-secrets set, overwriting: ${name}"
        else
            info "KV secret already exists, skipping: ${name} (use --force-secrets to overwrite)"
            return
        fi
    fi
    az keyvault secret set \
        --vault-name "${KV_NAME}" \
        --name "${name}" \
        --value "${value}" \
        --output none
    ok "KV secret set: ${name}"
}

# Helper: create-or-update a Container App (idempotent)
upsert_app() {
    local app_name="$1"; shift
    local exists
    exists=$(az containerapp show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${app_name}" \
        --query name -o tsv 2>/dev/null || echo "")
    if [[ -z "${exists}" ]]; then
        info "Creating Container App: ${app_name}"
        az containerapp create --name "${app_name}" --resource-group "${RESOURCE_GROUP}" "$@" --output table
    else
        info "Updating Container App: ${app_name} (already exists — image + sizing only)"
        # On update: only image, replicas, and resource sizing are changed.
        # Secrets and env-vars are set at create time and persist — no need to re-pass.
        local img="" cpu="" mem="" minr="" maxr=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --image)         img="$2";  shift 2 ;;
                --cpu)           cpu="$2";  shift 2 ;;
                --memory)        mem="$2";  shift 2 ;;
                --min-replicas)  minr="$2"; shift 2 ;;
                --max-replicas)  maxr="$2"; shift 2 ;;
                *)               shift ;;
            esac
        done
        local uargs=()
        [[ -n "${img}"  ]] && uargs+=(--image  "${img}")
        [[ -n "${cpu}"  ]] && uargs+=(--cpu    "${cpu}")
        [[ -n "${mem}"  ]] && uargs+=(--memory "${mem}")
        [[ -n "${minr}" ]] && uargs+=(--min-replicas "${minr}")
        [[ -n "${maxr}" ]] && uargs+=(--max-replicas "${maxr}")
        az containerapp update --name "${app_name}" --resource-group "${RESOURCE_GROUP}" "${uargs[@]}" --output table
    fi
}

# Helper: create-or-update a Container App Job (idempotent)
upsert_job() {
    local job_name="$1"; shift
    local exists
    exists=$(az containerapp job show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${job_name}" \
        --query name -o tsv 2>/dev/null || echo "")
    if [[ -z "${exists}" ]]; then
        info "Creating Container App Job: ${job_name}"
        az containerapp job create --name "${job_name}" --resource-group "${RESOURCE_GROUP}" "$@" --output table
    else
        info "Updating Container App Job: ${job_name} (image, sizing, env-vars)"
        local img="" cpu="" mem=""
        local -a envvars=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --image)     img="$2";            shift 2 ;;
                --cpu)       cpu="$2";            shift 2 ;;
                --memory)    mem="$2";            shift 2 ;;
                --env-vars)
                    # Consume ALL positional values until the next --flag
                    shift
                    while [[ $# -gt 0 && "${1}" != --* ]]; do
                        envvars+=("$1"); shift
                    done
                    ;;
                # secrets and create-only flags are skipped on update
                --secrets|--environment|--registry-server|--registry-identity|\
                --mi-user-assigned|--trigger-type|--cron-expression|\
                --replica-timeout|--replica-retry-limit|\
                --replica-completion-count|--parallelism|\
                --user-assigned|--ingress|--target-port|\
                --min-replicas|--max-replicas|--tags)
                    shift 2 ;;
                *) shift ;;
            esac
        done
        local uargs=()
        [[ -n "${img}" ]] && uargs+=(--image  "${img}")
        [[ -n "${cpu}" ]] && uargs+=(--cpu    "${cpu}")
        [[ -n "${mem}" ]] && uargs+=(--memory "${mem}")
        # Re-apply env vars using --set-env-vars (merges, does not remove others)
        for e in "${envvars[@]:-}"; do
            [[ -n "${e}" ]] && uargs+=(--set-env-vars "${e}")
        done
        az containerapp job update --name "${job_name}" --resource-group "${RESOURCE_GROUP}" "${uargs[@]}" --output table
    fi
}

[[ -n "${ARO_DB_PASSWORD}" ]] && kv_set "aro-db-password" "${ARO_DB_PASSWORD}"
[[ -n "${ARO_DEV_TOKEN}"   ]] && kv_set "aro-dev-token"   "${ARO_DEV_TOKEN}"
[[ -n "${ARO_SIT_TOKEN}"   ]] && kv_set "aro-sit-token"   "${ARO_SIT_TOKEN}"

# Clear from local variables — no longer needed in memory
unset ARO_DB_PASSWORD ARO_DEV_TOKEN ARO_SIT_TOKEN

ok "Secrets stored in Key Vault: ${KV_NAME}"

# ─────────────────────────────────────────────────────────────
# 4. Build & push images to ACR (cloud build — no local Docker)
# ─────────────────────────────────────────────────────────────
banner "Step 4 — Build and push container images"

if [[ "${SKIP_BUILDS}" == "true" ]]; then
    info "Skipping ACR builds (--skip-builds)"
else

# 4a. Base capacity-planner image (needed by collector)
info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/capacity-planner:${IMAGE_TAG}"
az acr build \
    --registry "${ACR_NAME}" \
    --image "${IMAGE_PREFIX}/capacity-planner:latest" \
    --image "${IMAGE_PREFIX}/capacity-planner:${IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/capacity-planner/Dockerfile" \
    "${PLANNER_ROOT}" \
    --output table

# 4b. FastAPI backend
info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/api:${IMAGE_TAG}"
az acr build \
    --registry "${ACR_NAME}" \
    --image "${IMAGE_PREFIX}/api:latest" \
    --image "${IMAGE_PREFIX}/api:${IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/api/Dockerfile" \
    "${SCRIPT_DIR}/api" \
    --output table

# 4c. nginx dashboard SPA
info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/dashboard:${IMAGE_TAG}"
az acr build \
    --registry "${ACR_NAME}" \
    --image "${IMAGE_PREFIX}/dashboard:latest" \
    --image "${IMAGE_PREFIX}/dashboard:${IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/dashboard/Dockerfile" \
    "${SCRIPT_DIR}/dashboard" \
    --output table

# 4d. Collector (needs full planner root context for scripts)
info "Building: ${ACR_ENDPOINT}/${IMAGE_PREFIX}/collector:${IMAGE_TAG}"
az acr build \
    --registry "${ACR_NAME}" \
    --image "${IMAGE_PREFIX}/collector:latest" \
    --image "${IMAGE_PREFIX}/collector:${IMAGE_TAG}" \
    --file "${SCRIPT_DIR}/collector/Dockerfile" \
    "${PLANNER_ROOT}" \
    --build-arg "BASE_IMAGE=${ACR_ENDPOINT}/${IMAGE_PREFIX}/capacity-planner:${IMAGE_TAG}" \
    --output table

ok "All images pushed to ${ACR_ENDPOINT} (tag: ${IMAGE_TAG})"
DEPLOY_TAG="${IMAGE_TAG}"
fi  # end SKIP_BUILDS

# When builds are skipped, query ACR for the most recently pushed versioned tag.
# This avoids deploying :latest when the actual latest versioned tag is known.
if [[ "${SKIP_BUILDS}" == "true" ]]; then
    DEPLOY_TAG=$(az acr repository show-tags \
        --name "${ACR_NAME}" \
        --repository "${IMAGE_PREFIX}/api" \
        --orderby time_desc --top 5 \
        --output tsv 2>/dev/null | grep -v '^latest$' | head -1 || echo "")
    if [[ -z "${DEPLOY_TAG}" ]]; then
        warn "Could not query ACR for latest tag — falling back to :latest"
        DEPLOY_TAG="latest"
    else
        info "--skip-builds active: using latest ACR tag :${DEPLOY_TAG}"
    fi
fi

# ─────────────────────────────────────────────────────────────
# 5. PostgreSQL Flexible Server
# ─────────────────────────────────────────────────────────────
banner "Step 5 — PostgreSQL Flexible Server"

# Resolve the subnet resource ID
PG_SUBNET_ID=$(az network vnet subnet show \
    --resource-group "${VNET_RG}" \
    --vnet-name "${VNET_NAME}" \
    --name "${PG_SUBNET}" \
    --query id -o tsv)

info "PG subnet: ${PG_SUBNET_ID}"

# Check if server already exists
PG_EXISTS=$(az postgres flexible-server show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PG_SERVER}" \
    --query name -o tsv 2>/dev/null || echo "")

if [[ -z "${PG_EXISTS}" ]]; then
    info "Creating PostgreSQL Flexible Server: ${PG_SERVER}"

    # Read password from Key Vault (never in clear text in script after this point)
    PG_PASS=$(az keyvault secret show \
        --vault-name "${KV_NAME}" --name "aro-db-password" \
        --query value -o tsv)

    az postgres flexible-server create \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${PG_SERVER}" \
        --location "${LOCATION}" \
        --admin-user "${PG_ADMIN_USER}" \
        --admin-password "${PG_PASS}" \
        --sku-name "Standard_D2s_v3" \
        --tier "GeneralPurpose" \
        --storage-size 32 \
        --version 15 \
        --subnet "${PG_SUBNET_ID}" \
        --private-dns-zone "${PG_SERVER}.private.postgres.database.azure.com" \
        --yes \
        --output table

    unset PG_PASS

    info "Creating database: ${PG_DB}"
    az postgres flexible-server db create \
        --resource-group "${RESOURCE_GROUP}" \
        --server-name "${PG_SERVER}" \
        --database-name "${PG_DB}" \
        --output table
else
    info "PostgreSQL server already exists: ${PG_SERVER}"
fi

PG_FQDN="${PG_SERVER}.postgres.database.azure.com"
ok "PostgreSQL: ${PG_FQDN}"

# ── 5b. Apply database schema (idempotent — uses CREATE IF NOT EXISTS) ────
banner "Step 5b — Apply database schema"

INIT_SQL="${SCRIPT_DIR}/db/init.sql"
if [[ -f "${INIT_SQL}" ]]; then
    info "Applying schema from ${INIT_SQL}"
    PG_PASS=$(az keyvault secret show \
        --vault-name "${KV_NAME}" --name "aro-db-password" \
        --query value -o tsv | tr -d '\r\n\t ')
    # Use individual psql env vars (not a connection URL) to avoid
    # special-character encoding issues with the password.
    PGHOST="${PG_FQDN}" \
    PGUSER="${PG_ADMIN_USER}" \
    PGPORT="5432" \
    PGDATABASE="${PG_DB}" \
    PGSSLMODE="require" \
    PGPASSWORD="${PG_PASS}" \
        psql -f "${INIT_SQL}" --set ON_ERROR_STOP=1
    unset PG_PASS
    ok "Schema applied"
else
    warn "db/init.sql not found — skipping schema init"
fi

# ─────────────────────────────────────────────────────────────
# 6. Deploy Container Apps
# ─────────────────────────────────────────────────────────────
banner "Step 6 — Container Apps deployment"

# ── 6a. API (internal ingress) ────────────────────────────────
info "Deploying Container App: ${APP_API}"

upsert_app "${APP_API}" \
    --environment "${CONTAINER_APP_ENV}" \
    --image "${ACR_ENDPOINT}/${IMAGE_PREFIX}/api:${DEPLOY_TAG}" \
    --registry-server "${ACR_ENDPOINT}" \
    --registry-identity "${MI_RESOURCE_ID}" \
    --user-assigned "${MI_RESOURCE_ID}" \
    --target-port 8000 \
    --ingress internal \
    --min-replicas 1 \
    --max-replicas 3 \
    --cpu 0.5 \
    --memory 1.0Gi \
    --secrets \
        "db-password=keyvaultref:https://${KV_NAME}.vault.azure.net/secrets/aro-db-password,identityref:${MI_RESOURCE_ID}" \
    --env-vars \
        "DB_HOST=${PG_FQDN}" \
        "DB_PORT=5432" \
        "DB_USER=${PG_ADMIN_USER}" \
        "DB_PASSWORD=secretref:db-password" \
        "DB_NAME=${PG_DB}" \
    --tags \
        "app=aro-ops-dashboard" \
        "component=api" \
        "environment=prod"

ok "API deployed: ${APP_API}"

# ── 6b. Dashboard (external ingress + custom domain) ──────────
info "Deploying Container App: ${APP_DASHBOARD}"

# Resolve the internal API FQDN for the dashboard's proxy config
API_FQDN=$(az containerapp show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_API}" \
    --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "")

upsert_app "${APP_DASHBOARD}" \
    --environment "${CONTAINER_APP_ENV}" \
    --image "${ACR_ENDPOINT}/${IMAGE_PREFIX}/dashboard:${DEPLOY_TAG}" \
    --registry-server "${ACR_ENDPOINT}" \
    --registry-identity "${MI_RESOURCE_ID}" \
    --user-assigned "${MI_RESOURCE_ID}" \
    --target-port 80 \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 2 \
    --cpu 0.25 \
    --memory 0.5Gi \
    --env-vars \
        "API_UPSTREAM_HOST=${APP_API}.internal.${ENV_DEFAULT_DOMAIN}" \
    --tags \
        "app=aro-ops-dashboard" \
        "component=dashboard" \
        "environment=prod"

ok "Dashboard deployed: ${APP_DASHBOARD}"

# ── 6c. Collector (Container App Job — cron schedule) ─────────
info "Deploying Container App Job: ${APP_COLLECTOR} (every 5 min)"

upsert_job "${APP_COLLECTOR}" \
    --environment "${CONTAINER_APP_ENV}" \
    --image "${ACR_ENDPOINT}/${IMAGE_PREFIX}/collector:${DEPLOY_TAG}" \
    --registry-server "${ACR_ENDPOINT}" \
    --registry-identity "${MI_RESOURCE_ID}" \
    --mi-user-assigned "${MI_RESOURCE_ID}" \
    --trigger-type Schedule \
    --cron-expression "*/5 * * * *" \
    --replica-timeout 240 \
    --replica-retry-limit 1 \
    --replica-completion-count 1 \
    --parallelism 1 \
    --cpu 2.0 \
    --memory 4.0Gi \
    --secrets "db-password=keyvaultref:https://${KV_NAME}.vault.azure.net/secrets/aro-db-password,identityref:${MI_RESOURCE_ID}" \
    --secrets "dev-token=keyvaultref:https://${KV_NAME}.vault.azure.net/secrets/aro-dev-token,identityref:${MI_RESOURCE_ID}" \
    --secrets "sit-token=keyvaultref:https://${KV_NAME}.vault.azure.net/secrets/aro-sit-token,identityref:${MI_RESOURCE_ID}" \
    --env-vars "DB_HOST=${PG_FQDN}" "DB_PORT=5432" "DB_USER=${PG_ADMIN_USER}" "DB_PASSWORD=secretref:db-password" "DB_NAME=${PG_DB}" \
    --env-vars "DEV_API=${DEV_API}" "DEV_TOKEN=secretref:dev-token" "DEV_ENV_LABEL=${DEV_ENV_LABEL}" \
    --env-vars "SIT_API=${SIT_API}" "SIT_TOKEN=secretref:sit-token" "SIT_ENV_LABEL=${SIT_ENV_LABEL}"

ok "Collector job deployed: ${APP_COLLECTOR}"

# ─────────────────────────────────────────────────────────────
# 7. Custom domain
# ─────────────────────────────────────────────────────────────
banner "Step 7 — Custom domain: ${CUSTOM_DOMAIN}"

DASHBOARD_FQDN=$(az containerapp show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${APP_DASHBOARD}" \
    --query "properties.configuration.ingress.fqdn" -o tsv)

warn "============================================================"
warn "ACTION REQUIRED — DNS configuration"
warn "Add the following DNS records to albtests.com before binding"
warn "the custom domain:"
warn ""
warn "  CNAME  aro-ops-dashboard  →  ${DASHBOARD_FQDN}"
warn "  TXT    asuid.aro-ops-dashboard  →  <domain verification ID>"
warn ""
warn "Get the verification ID with:"
warn "  az containerapp show -g ${RESOURCE_GROUP} -n ${APP_DASHBOARD}"
warn "    --query properties.customDomainVerificationId -o tsv"
warn ""
warn "Once DNS is propagated, run:"
warn "  ./configure-custom-domain.sh"
warn "============================================================"

# ─────────────────────────────────────────────────────────────
# 8. Summary
# ─────────────────────────────────────────────────────────────
banner "Deployment complete"

echo ""
echo "  Resource Group   : ${RESOURCE_GROUP}"
echo "  ACR              : ${ACR_ENDPOINT}"
echo "  PostgreSQL FQDN  : ${PG_FQDN}"
echo "  Database         : ${PG_DB}"
echo "  Key Vault        : ${KV_NAME}"
echo ""
echo "  Container Apps:"
printf "    %-35s %s\n" "${APP_API}"       "internal → http://${APP_API}:8000"
printf "    %-35s %s\n" "${APP_DASHBOARD}" "external → https://${DASHBOARD_FQDN}"
printf "    %-35s %s\n" "${APP_COLLECTOR}" "job      → every 5 min"
echo ""
echo "  Custom domain target : ${CUSTOM_DOMAIN}"
echo "  See DNS instructions above (Step 7)"
echo ""
echo "  Monitor collector:"
echo "    az containerapp job execution list \\"
echo "      -g ${RESOURCE_GROUP} -n ${APP_COLLECTOR} --output table"
echo ""
echo "  Stream API logs:"
echo "    az containerapp logs show \\"
echo "      -g ${RESOURCE_GROUP} -n ${APP_API} --follow"
echo ""
