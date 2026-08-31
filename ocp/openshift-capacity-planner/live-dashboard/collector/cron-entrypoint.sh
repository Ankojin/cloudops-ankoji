#!/usr/bin/env bash
# =============================================================
# cron-entrypoint.sh
# Runs inside the collector container on a cron schedule.
# 1. Runs the existing run-multi-env.sh (collects from DEV+SIT)
# 2. Calls insert_to_db.sh for each env to persist to PostgreSQL
#
# Runs every 5 minutes via crond (configured in Dockerfile.collector).
# =============================================================
set -Eeuo pipefail

PLANNER_DIR="/planner"
DB_INSERT_SCRIPT="/collector/insert_to_db.sh"

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) — Starting capacity collection ==="

OUTPUT_BASE="${PLANNER_DIR}/output"
DEV_SOURCE_LABEL="${DEV_ENV_LABEL:-DEV}"
SIT_SOURCE_LABEL="${SIT_ENV_LABEL:-SIT}"
DEV_PREVIOUS_DIR=$(find "${OUTPUT_BASE}" -maxdepth 1 -type d -name "${DEV_SOURCE_LABEL}_*" 2>/dev/null | sort | tail -1)
SIT_PREVIOUS_DIR=$(find "${OUTPUT_BASE}" -maxdepth 1 -type d -name "${SIT_SOURCE_LABEL}_*" 2>/dev/null | sort | tail -1)

# ── Static /etc/hosts injection (DNS workaround) ─────────────
# Set DEV_IP / SIT_IP env vars on the ACA Job to bypass DNS when
# the Container Apps VNet cannot resolve *.albtests.com hostnames.
# Example: DEV_IP=10.189.54.10  SIT_IP=10.189.55.10
if [[ -n "${DEV_IP:-}" ]]; then
    DEV_HOST="${DEV_API:-}"
    DEV_HOST="${DEV_HOST#https://}"   # strip https://
    DEV_HOST="${DEV_HOST%%:*}"        # strip :port
    if [[ -n "${DEV_HOST}" ]]; then
        # Remove any stale entry first, then add
        sed -i "/${DEV_HOST}/d" /etc/hosts 2>/dev/null || true
        echo "${DEV_IP}  ${DEV_HOST}" >> /etc/hosts
        echo "INFO: Injected /etc/hosts: ${DEV_IP}  ${DEV_HOST}"
    fi
fi

if [[ -n "${SIT_IP:-}" ]]; then
    SIT_HOST="${SIT_API:-}"
    SIT_HOST="${SIT_HOST#https://}"   # strip https://
    SIT_HOST="${SIT_HOST%%:*}"        # strip :port
    if [[ -n "${SIT_HOST}" ]]; then
        sed -i "/${SIT_HOST}/d" /etc/hosts 2>/dev/null || true
        echo "${SIT_IP}  ${SIT_HOST}" >> /etc/hosts
        echo "INFO: Injected /etc/hosts: ${SIT_IP}  ${SIT_HOST}"
    fi
fi

# ── Debug: show what env vars the container received ─────────
echo "DEBUG: DEV_API=${DEV_API:-<not set>}"
echo "DEBUG: SIT_API=${SIT_API:-<not set>}"
_dev_tok_len=${#DEV_TOKEN}; echo "DEBUG: DEV_TOKEN configured=$([[ ${_dev_tok_len} -gt 0 ]] && echo yes || echo no)"
_sit_tok_len=${#SIT_TOKEN}; echo "DEBUG: SIT_TOKEN configured=$([[ ${_sit_tok_len} -gt 0 ]] && echo yes || echo no)"
echo "DEBUG: DB_HOST=${DB_HOST:-<not set>}, DB_NAME=${DB_NAME:-<not set>}, DB_USER=${DB_USER:-<not set>}"

# ── Step 1: Run collection + report generation ────────────────
ARGS=()
EXPECTED_INSERTS=0

if [[ "${COLLECT_DEV:-true}" == "true" && -n "${DEV_API:-}" && -n "${DEV_TOKEN:-}" ]]; then
  ARGS+=(--dev-api "${DEV_API}" --dev-token "${DEV_TOKEN}")
  ((EXPECTED_INSERTS+=1))
else
  ARGS+=(--skip-dev)
  echo "INFO: Skipping DEV (disabled or no credentials)"
fi

if [[ "${COLLECT_SIT:-true}" == "true" && -n "${SIT_API:-}" && -n "${SIT_TOKEN:-}" ]]; then
  ARGS+=(--sit-api "${SIT_API}" --sit-token "${SIT_TOKEN}")
  ((EXPECTED_INSERTS+=1))
else
  ARGS+=(--skip-sit)
  echo "INFO: Skipping SIT (disabled or no credentials)"
fi

if [[ ${EXPECTED_INSERTS} -eq 0 ]]; then
  echo "ERROR: No environments enabled with complete API/token configuration"
  exit 1
fi

if [[ -n "${DEV_ENV_LABEL:-}" ]]; then ARGS+=(--dev-env "${DEV_ENV_LABEL}"); fi
if [[ -n "${SIT_ENV_LABEL:-}" ]]; then ARGS+=(--sit-env "${SIT_ENV_LABEL}"); fi

# Run collection — allow partial failure (one env down shouldn't kill the job)
COLLECTION_OK=true
if bash "${PLANNER_DIR}/run-multi-env.sh" "${ARGS[@]}"; then
    echo "INFO: Collection completed successfully"
else
  COLLECTION_OK=false
  echo "ERROR: run-multi-env.sh exited non-zero — checking for any fresh partial output"
fi

# ── Step 2: Find latest output dirs and insert to DB ─────────
SUCCESSFUL_INSERTS=0

# run-multi-env.sh creates timestamped dirs using the configured labels.
# Compare directory identity instead of mtimes because Azure Files can expose
# timestamp precision/caching behavior that makes `find -newer` unreliable.
for ENV in DEV SIT; do
  if [[ "${ENV}" == "DEV" ]]; then
    if [[ "${COLLECT_DEV:-true}" != "true" ]]; then
      echo "INFO: DEV collection disabled — no insert expected"
      continue
    fi
    SOURCE_LABEL="${DEV_SOURCE_LABEL}"
    PREVIOUS_DIR="${DEV_PREVIOUS_DIR}"
  else
    if [[ "${COLLECT_SIT:-true}" != "true" ]]; then
      echo "INFO: SIT collection disabled — no insert expected"
      continue
    fi
    SOURCE_LABEL="${SIT_SOURCE_LABEL}"
    PREVIOUS_DIR="${SIT_PREVIOUS_DIR}"
  fi

  LATEST_DIR=$(find "${OUTPUT_BASE}" -maxdepth 1 -type d -name "${SOURCE_LABEL}_*" 2>/dev/null | sort | tail -1)

  if [[ -n "${LATEST_DIR}" && "${LATEST_DIR}" != "${PREVIOUS_DIR}" ]]; then
    echo "INFO: Inserting ${ENV} from ${LATEST_DIR}"
    if bash "${DB_INSERT_SCRIPT}" --env "${ENV}" --output-dir "${LATEST_DIR}"; then
      ((SUCCESSFUL_INSERTS+=1))
    else
      echo "ERROR: DB insert failed for ${ENV} — collection data preserved"
    fi
  else
    echo "ERROR: No fresh output directory found for ${ENV} — skipping DB insert"
  fi
done

if [[ "${COLLECTION_OK}" != "true" || ${SUCCESSFUL_INSERTS} -ne ${EXPECTED_INSERTS} ]]; then
  echo "ERROR: Collection run incomplete — expected ${EXPECTED_INSERTS} fresh insert(s), completed ${SUCCESSFUL_INSERTS}"
  exit 1
fi

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) — Collection complete ==="
