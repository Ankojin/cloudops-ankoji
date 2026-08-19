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
_dev_tok_len=${#DEV_TOKEN}; echo "DEBUG: DEV_TOKEN length=${_dev_tok_len}, prefix=${DEV_TOKEN:0:12}..."
_sit_tok_len=${#SIT_TOKEN}; echo "DEBUG: SIT_TOKEN length=${_sit_tok_len}, prefix=${SIT_TOKEN:0:12}..."
echo "DEBUG: DB_HOST=${DB_HOST:-<not set>}, DB_NAME=${DB_NAME:-<not set>}, DB_USER=${DB_USER:-<not set>}"

# ── Step 1: Run collection + report generation ────────────────
ARGS=()

if [[ -n "${DEV_API:-}" && -n "${DEV_TOKEN:-}" ]]; then
  ARGS+=(--dev-api "${DEV_API}" --dev-token "${DEV_TOKEN}")
else
  ARGS+=(--skip-dev)
  echo "INFO: Skipping DEV (no credentials)"
fi

if [[ -n "${SIT_API:-}" && -n "${SIT_TOKEN:-}" ]]; then
  ARGS+=(--sit-api "${SIT_API}" --sit-token "${SIT_TOKEN}")
else
  ARGS+=(--skip-sit)
  echo "INFO: Skipping SIT (no credentials)"
fi

if [[ -n "${DEV_ENV_LABEL:-}" ]]; then ARGS+=(--dev-env "${DEV_ENV_LABEL}"); fi
if [[ -n "${SIT_ENV_LABEL:-}" ]]; then ARGS+=(--sit-env "${SIT_ENV_LABEL}"); fi

# Run collection — allow partial failure (one env down shouldn't kill the job)
if bash "${PLANNER_DIR}/run-multi-env.sh" "${ARGS[@]}"; then
    echo "INFO: Collection completed successfully"
else
    echo "WARN: run-multi-env.sh exited non-zero — partial data may exist; continuing to DB insert"
fi

# ── Step 2: Find latest output dirs and insert to DB ─────────
OUTPUT_BASE="${PLANNER_DIR}/output"

# run-multi-env.sh creates timestamped dirs: DEV_YYYYMMDD_HHMMSS
for ENV in DEV SIT; do
  LATEST_DIR=$(find "${OUTPUT_BASE}" -maxdepth 1 -type d -name "${ENV}_*" \
    | sort | tail -1)

  if [[ -n "${LATEST_DIR}" ]]; then
    echo "INFO: Inserting ${ENV} from ${LATEST_DIR}"
    bash "${DB_INSERT_SCRIPT}" --env "${ENV}" --output-dir "${LATEST_DIR}" || \
      echo "WARN: DB insert failed for ${ENV} — collection data preserved"
  else
    echo "INFO: No output directory found for ${ENV} — skipping DB insert"
  fi
done

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) — Collection complete ==="
