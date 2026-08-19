#!/usr/bin/env bash
#
# Container entrypoint — reads tokens/API servers from environment variables
# injected by Azure Container Apps Job secrets, then delegates to run-multi-env.sh.
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Map environment variables to run-multi-env.sh arguments
ARGS=()

if [[ -n "${DEV_API:-}" && -n "${DEV_TOKEN:-}" ]]
then
    ARGS+=(--dev-api "${DEV_API}" --dev-token "${DEV_TOKEN}")
else
    ARGS+=(--skip-dev)
    echo "INFO: DEV_API or DEV_TOKEN not set — skipping DEV"
fi

if [[ -n "${SIT_API:-}" && -n "${SIT_TOKEN:-}" ]]
then
    ARGS+=(--sit-api "${SIT_API}" --sit-token "${SIT_TOKEN}")
else
    ARGS+=(--skip-sit)
    echo "INFO: SIT_API or SIT_TOKEN not set — skipping SIT"
fi

if [[ -n "${DEV_ENV_LABEL:-}" ]]; then ARGS+=(--dev-env "${DEV_ENV_LABEL}"); fi
if [[ -n "${SIT_ENV_LABEL:-}" ]]; then ARGS+=(--sit-env "${SIT_ENV_LABEL}"); fi

exec bash "${SCRIPT_DIR}/run-multi-env.sh" "${ARGS[@]}"
