#!/usr/bin/env bash
# =============================================================
# generate-aro-tokens.sh
#
# Creates a read-only service account in ONE ARO cluster and
# generates a non-expiring Secret-based token.
# Run once per environment (DEV, then SIT separately).
#
# Why Secret-based tokens (not "oc create token")?
#   • "oc create token --duration=8760h" is capped by the cluster's
#     --service-account-max-token-expiration (default 24h in ARO).
#   • Secrets of type kubernetes.io/service-account-token have NO
#     expiry; they are valid until the secret is deleted.
#
# What access is granted?
#   ClusterRole "capacity-collector-role":
#     • nodes          — list, get, watch  (node capacity & labels)
#     • pods           — list, get         (pod counts per namespace)
#     • namespaces     — list, get         (ns enumeration)
#     • resourcequotas — list, get         (quota reporting)
#     • metrics.k8s.io nodes/pods — get    (actual usage)
#     • machineset / machine (openshift)   (pool / instance types)
#
# Usage:
#   # Run for DEV cluster (interactive login)
#   ./generate-aro-tokens.sh --env DEV
#
#   # Run for SIT cluster (interactive login)
#   ./generate-aro-tokens.sh --env SIT
#
#   # Non-interactive (already logged in via oc login)
#   ./generate-aro-tokens.sh --env DEV --no-login
#
#   # Push token directly to Key Vault after generation
#   ./generate-aro-tokens.sh --env DEV --push-to-kv
#   ./generate-aro-tokens.sh --env SIT --push-to-kv
#
# Output:
#   Token is printed at the end. Use --push-to-kv to store it
#   in bab-core-kv-ghcpdash-01 automatically.
# =============================================================

set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────
# Fixed values — match deploy-aro-live-dashboard.sh
# ─────────────────────────────────────────────────────────────
readonly DEV_API="${DEV_API:-https://api.babdevaro.albtests.com:6443}"
readonly SIT_API="${SIT_API:-https://api.babsitaro.albtests.com:6443}"

readonly SA_NAMESPACE="kube-system"
readonly SA_NAME="capacity-collector"
readonly SECRET_NAME="capacity-collector-token"
readonly ROLE_NAME="capacity-collector-role"

readonly KV_NAME="bab-core-kv-ghcpdash-01"
readonly SUBSCRIPTION_ID="d88f0b5b-6660-4607-8c6a-395820400912"

TARGET_ENV=""      # DEV or SIT — required
NO_LOGIN=false
PUSH_TO_KV=false
PUSH_EXISTING=""   # if set, skip OCP steps and push this value straight to KV

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
banner() { echo ""; echo "╔══════════════════════════════════════════════════════════╗"; printf "║  %-56s║\n" "$*"; echo "╚══════════════════════════════════════════════════════════╝"; echo ""; }
info()  { echo "  [INFO]  $*"; }
ok()    { echo "  [OK]    $*"; }
warn()  { echo "  [WARN]  $*" >&2; }
die()   { echo "  [ERROR] $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            TARGET_ENV="${2^^}"   # uppercase: dev→DEV, sit→SIT
            shift 2
            ;;
        --env=*)
            TARGET_ENV="${1#--env=}"
            TARGET_ENV="${TARGET_ENV^^}"
            shift
            ;;
        --no-login)   NO_LOGIN=true;   shift ;;
        --push-to-kv) PUSH_TO_KV=true; shift ;;
        --push-existing)
            # Push a pre-existing token to KV without running OCP steps.
            # Usage: --env DEV --push-existing 'sha256~...'
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                die "--push-existing requires a token value: --push-existing 'sha256~<token>'"
            fi
            PUSH_EXISTING="$2"
            PUSH_TO_KV=true
            shift 2
            ;;
        --push-existing=*)
            PUSH_EXISTING="${1#--push-existing=}"
            [[ -z "${PUSH_EXISTING}" ]] && die "--push-existing= requires a token value"
            PUSH_TO_KV=true
            shift
            ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \?//' | head -60
            exit 0
            ;;
        *)
            die "Unknown argument: $1  (use --env DEV or --env SIT)"
            ;;
    esac
done

# --env is mandatory
if [[ -z "${TARGET_ENV}" ]]; then
    echo ""
    echo "  Usage: $0 --env DEV [--no-login] [--push-to-kv]"
    echo "         $0 --env SIT [--no-login] [--push-to-kv]"
    echo ""
    echo "  Run once per environment. Both envs need separate logins because"
    echo "  each ARO cluster has its own API server and kubeconfig context."
    echo ""
    die "--env is required (DEV or SIT)"
fi

if [[ "${TARGET_ENV}" != "DEV" && "${TARGET_ENV}" != "SIT" ]]; then
    die "Invalid --env value '${TARGET_ENV}'. Must be DEV or SIT."
fi

# Resolve API server for the chosen env
if [[ "${TARGET_ENV}" == "DEV" ]]; then
    TARGET_API="${DEV_API}"
    KV_SECRET_NAME="aro-dev-token"
else
    TARGET_API="${SIT_API}"
    KV_SECRET_NAME="aro-sit-token"
fi

# ─────────────────────────────────────────────────────────────
# Prereq check
# ─────────────────────────────────────────────────────────────
banner "Prereq check — ${TARGET_ENV} cluster"
command -v oc &>/dev/null || die "'oc' CLI not found. Install: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"

if [[ "${PUSH_TO_KV}" == "true" ]]; then
    command -v az &>/dev/null || die "'az' CLI not found (required for --push-to-kv)"
    CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")
    if [[ "${CURRENT_SUB}" != "${SUBSCRIPTION_ID}" ]]; then
        info "Switching to subscription ${SUBSCRIPTION_ID}"
        az account set --subscription "${SUBSCRIPTION_ID}"
    fi
    ok "Azure CLI: subscription ${SUBSCRIPTION_ID}"
fi

# ─────────────────────────────────────────────────────────────
# Helper: ensure Azure CLI auth is fresh before any KV operation
# ─────────────────────────────────────────────────────────────
az_ensure_auth() {
    if ! az account show --query id -o tsv &>/dev/null; then
        warn "Azure CLI session expired — re-authenticating…"
        az login --output none
        az account set --subscription "${SUBSCRIPTION_ID}"
        ok "Re-authenticated to Azure"
    fi
}

# ─────────────────────────────────────────────────────────────
# Short-circuit: --push-existing skips all OCP steps
# ─────────────────────────────────────────────────────────────
if [[ -n "${PUSH_EXISTING}" ]]; then
    banner "Push existing token → Key Vault"
    info "Env        : ${TARGET_ENV}"
    info "KV secret  : ${KV_SECRET_NAME}"
    info "Vault      : ${KV_NAME}"

    command -v az &>/dev/null || die "'az' CLI not found"
    az_ensure_auth

    az keyvault secret set \
        --vault-name "${KV_NAME}" \
        --name "${KV_SECRET_NAME}" \
        --value "${PUSH_EXISTING}" \
        --output none
    ok "${KV_SECRET_NAME} stored in Key Vault"

    unset PUSH_EXISTING
    ok "Token cleared from shell memory."

    banner "Done — ${TARGET_ENV} token in Key Vault"
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# ClusterRole YAML (identical for both clusters)
# ─────────────────────────────────────────────────────────────
CLUSTER_ROLE_YAML=$(cat <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: capacity-collector-role
  annotations:
    description: "Read-only access for the ARO Ops capacity collector"
rules:
  # Core node/pod/namespace/quota data
  - apiGroups: [""]
    resources:
      - nodes
      - pods
      - namespaces
      - resourcequotas
      - persistentvolumes
      - persistentvolumeclaims
    verbs: ["get", "list", "watch"]

  # Metrics (actual CPU/memory usage)
  - apiGroups: ["metrics.k8s.io"]
    resources:
      - nodes
      - pods
    verbs: ["get", "list"]

  # OpenShift Machine API (node pool / instance type info)
  - apiGroups: ["machine.openshift.io"]
    resources:
      - machines
      - machinesets
    verbs: ["get", "list", "watch"]

  # OpenShift cluster version / infrastructure
  - apiGroups: ["config.openshift.io"]
    resources:
      - clusterversions
      - infrastructures
    verbs: ["get", "list"]

    - apiGroups: ["storage.k8s.io"]
        resources:
            - storageclasses
            - volumeattachments
        verbs: ["get", "list", "watch"]

    - apiGroups: ["apps"]
        resources:
            - deployments
            - replicasets
            - daemonsets
            - statefulsets
        verbs: ["get", "list", "watch"]

    - apiGroups: ["batch"]
        resources:
            - cronjobs
            - jobs
        verbs: ["get", "list", "watch"]

    - apiGroups: ["route.openshift.io"]
        resources:
            - routes
        verbs: ["get", "list"]
YAML
)

# ─────────────────────────────────────────────────────────────
# Function: provision SA + token for one cluster
# ─────────────────────────────────────────────────────────────
provision_token() {
    local env_label="$1"     # DEV or SIT
    local api_server="$2"    # https://api.xxx:6443

    banner "${env_label} — ${api_server}"

    # ── Login ──────────────────────────────────────────────────
    # Check if already logged into the correct cluster
    local current_server
    current_server=$(oc whoami --show-server 2>/dev/null || echo "")
    # Normalize: strip trailing slash for comparison
    local target_norm="${api_server%/}"
    local current_norm="${current_server%/}"

    if [[ "${current_norm}" == "${target_norm}" ]]; then
        info "Already logged in to ${api_server} — skipping oc login"
        info "Authenticated as: $(oc whoami 2>/dev/null || echo 'unknown')"
    elif [[ "${NO_LOGIN}" == "true" ]]; then
        info "Skipping interactive login (--no-login)"
        info "Current server: ${current_server:-none}"
        warn "Current server does not match target. Proceeding anyway."
    else
        echo ""
        echo "  Log in to the ${env_label} cluster."
        echo "  API server: ${api_server}"
        echo "  (Use a cluster-admin or account with RBAC to create"
        echo "   ClusterRoles, ClusterRoleBindings, ServiceAccounts, Secrets)"
        echo "  Tip: if already logged in, re-run with --no-login"
        echo ""
        oc login "${api_server}" --insecure-skip-tls-verify=false
    fi

    # Verify connected to the right cluster
    ACTUAL_API=$(oc whoami --show-server 2>/dev/null || echo "unknown")
    info "Connected to: ${ACTUAL_API}"

    # ── ClusterRole ────────────────────────────────────────────
    info "Applying ClusterRole: ${ROLE_NAME}"
    echo "${CLUSTER_ROLE_YAML}" | oc apply -f -
    ok "ClusterRole applied"

    # ── ServiceAccount ─────────────────────────────────────────
    info "Ensuring ServiceAccount: ${SA_NAME} in ${SA_NAMESPACE}"
    if ! oc get sa "${SA_NAME}" -n "${SA_NAMESPACE}" &>/dev/null; then
        oc create serviceaccount "${SA_NAME}" -n "${SA_NAMESPACE}"
        ok "ServiceAccount created"
    else
        info "ServiceAccount already exists"
    fi

    # ── ClusterRoleBinding ─────────────────────────────────────
    local binding_name="capacity-collector-binding"
    info "Reconciling ClusterRoleBinding: ${binding_name}"
    oc create clusterrolebinding "${binding_name}" \
        --clusterrole="${ROLE_NAME}" \
        --serviceaccount="${SA_NAMESPACE}:${SA_NAME}" \
        --dry-run=client -o yaml | oc apply -f -
    ok "ClusterRoleBinding reconciled"

    local monitoring_binding="capacity-collector-monitoring-view-binding"
    info "Reconciling monitoring binding: ${monitoring_binding}"
    oc create clusterrolebinding "${monitoring_binding}" \
        --clusterrole="cluster-monitoring-view" \
        --serviceaccount="${SA_NAMESPACE}:${SA_NAME}" \
        --dry-run=client -o yaml | oc apply -f -
    ok "Monitoring ClusterRoleBinding reconciled"

    # ── Secret-based long-lived token ──────────────────────────
    info "Ensuring token Secret: ${SECRET_NAME} in ${SA_NAMESPACE}"

    if oc get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" &>/dev/null; then
        warn "Secret already exists — rotating (delete + recreate)"
        oc delete secret "${SECRET_NAME}" -n "${SA_NAMESPACE}"
    fi

    oc apply -f - <<SECRET_YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: "${SA_NAME}"
type: kubernetes.io/service-account-token
SECRET_YAML

    ok "Secret created — waiting for token controller to populate it…"

    local token=""
    local attempts=0
    while [[ -z "${token}" && ${attempts} -lt 30 ]]; do
        token=$(oc get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        [[ -z "${token}" ]] && { sleep 1; ((attempts++)); }
    done

    [[ -z "${token}" ]] && die "Token not populated after 30s. Check OpenShift token controller logs."

    ok "Token populated (${#token} chars)"

    # ── Print summary box ──────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    printf  "  │  %-55s│\n" "${env_label} SERVICE ACCOUNT TOKEN"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf  "  │  SA        : %-43s│\n" "${SA_NAME} (ns: ${SA_NAMESPACE})"
    printf  "  │  Secret    : %-43s│\n" "${SECRET_NAME}"
    printf  "  │  Expiry    : %-43s│\n" "NONE — valid indefinitely"
    printf  "  │  Cluster   : %-43s│\n" "${ACTUAL_API}"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf  "  │  Token (first 40 chars): %.40s…   │\n" "${token}"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    GENERATED_TOKEN="${token}"

    # ── Verify token works ─────────────────────────────────────
    info "Verifying token — listing nodes:"
    oc get nodes --token="${token}" --server="${api_server}" \
        --insecure-skip-tls-verify=false \
        -o custom-columns='NAME:.metadata.name,ROLES:.metadata.labels.node-roles\.kubernetes\.io/worker,STATUS:.status.conditions[-1].type' \
        2>/dev/null | head -12 || warn "Node listing failed — check RBAC"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# Main — single environment
# ─────────────────────────────────────────────────────────────
GENERATED_TOKEN=""

provision_token "${TARGET_ENV}" "${TARGET_API}"

# ─────────────────────────────────────────────────────────────
# Summary + optional Key Vault push
# ─────────────────────────────────────────────────────────────
banner "${TARGET_ENV} Token — Summary"

echo "  Environment : ${TARGET_ENV}"
echo "  API server  : ${TARGET_API}"
echo "  KV secret   : ${KV_SECRET_NAME}"
echo ""
echo "  ── To use immediately ──────────────────────────────────────"
if [[ "${TARGET_ENV}" == "DEV" ]]; then
    echo "  export ARO_DEV_TOKEN='${GENERATED_TOKEN}'"
else
    echo "  export ARO_SIT_TOKEN='${GENERATED_TOKEN}'"
fi
echo ""
echo "  ── Or store in Key Vault manually ──────────────────────────"
echo "  az keyvault secret set \\"
echo "    --vault-name ${KV_NAME} \\"
echo "    --name ${KV_SECRET_NAME} \\"
echo "    --value '<paste-token-here>'"

# ── Push to Key Vault if requested ────────────────────────────
if [[ "${PUSH_TO_KV}" == "true" ]]; then
    banner "Pushing to Key Vault: ${KV_NAME} → ${KV_SECRET_NAME}"

    az_ensure_auth   # refresh Azure CLI session if expired

    az keyvault secret set \
        --vault-name "${KV_NAME}" \
        --name "${KV_SECRET_NAME}" \
        --value "${GENERATED_TOKEN}" \
        --output none
    ok "${KV_SECRET_NAME} stored in Key Vault"

    unset GENERATED_TOKEN
    ok "Token cleared from shell memory."
fi

banner "Done — ${TARGET_ENV}"
echo "  To REVOKE ${TARGET_ENV} access at any time (run while logged in to ${TARGET_ENV}):"
echo "  oc delete secret ${SECRET_NAME} -n ${SA_NAMESPACE}"
echo "  oc delete clusterrolebinding ${ROLE_NAME}-binding"
echo "  oc delete clusterrole ${ROLE_NAME}"
echo ""
echo "  Next step — generate SIT token (if not done yet):"
if [[ "${TARGET_ENV}" == "DEV" ]]; then
    echo "  ./generate-aro-tokens.sh --env SIT --push-to-kv"
else
    echo "  ./generate-aro-tokens.sh --env DEV --push-to-kv  (if not done)"
fi
echo ""
