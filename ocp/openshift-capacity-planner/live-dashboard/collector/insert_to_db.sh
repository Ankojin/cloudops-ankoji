#!/usr/bin/env bash
# =============================================================
# insert_to_db.sh
# Called after run-multi-env.sh completes for one environment.
# Reads the JSON output files and INSERTs a snapshot row into
# the PostgreSQL capacity database.
#
# Usage:
#   insert_to_db.sh --env DEV --output-dir /planner/output/DEV_20260803_132515
#
# Env vars (from docker-compose / OCP secret):
#   DATABASE_URL   postgresql://user:pass@postgres:5432/capacity
# =============================================================
set -Eeuo pipefail

ENV=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV="${2^^}";    shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "${ENV}"        ]] && { echo "ERROR: --env required";        exit 1; }
[[ -z "${OUTPUT_DIR}" ]] && { echo "ERROR: --output-dir required"; exit 1; }
[[ -d "${OUTPUT_DIR}" ]] || { echo "ERROR: directory not found: ${OUTPUT_DIR}"; exit 1; }

DB_URL="${DATABASE_URL:-}"

# If no DATABASE_URL, construct from individual vars (avoids URL-encoding issues
# with special characters in passwords — PGPASSWORD is passed raw to libpq)
if [[ -z "${DB_URL}" ]]; then
    _host="${DB_HOST:-postgres}"
    _port="${DB_PORT:-5432}"
    _user="${DB_USER:-planner}"
    _name="${DB_NAME:-capacity}"
    # PGPASSWORD scoped to this subshell only — not exported to parent process
    DB_URL="postgresql://${_user}@${_host}:${_port}/${_name}?sslmode=require"
fi

# Wrapper so PGPASSWORD is only in scope for psql calls
_psql() { PGPASSWORD="${DB_PASSWORD:-planner}" psql "${DB_URL}" "$@"; }

# ── Helper: safe jq read with default ─────────────────────────
jqr() { jq -r "${1} // ${2}" "$3" 2>/dev/null || echo "${2//\"/}"; }

# ── Locate JSON files ─────────────────────────────────────────
# Output structure: ${OUTPUT_DIR}/json/*.json  and  ${OUTPUT_DIR}/csv/*.csv
JSON_DIR="${OUTPUT_DIR}/json"
CSV_DIR="${OUTPUT_DIR}/csv"

SUMMARY_FILE="${JSON_DIR}/capacity_summary.json"
PLANNING_FILE="${JSON_DIR}/capacity_planning.json"
UTIL_FILE="${JSON_DIR}/cluster_utilization.json"
COLLECT_FILE="${JSON_DIR}/collection_summary.json"
POOLS_FILE="${JSON_DIR}/node_pools.json"
CHARGEBACK_CSV="${CSV_DIR}/chargeback_by_namespace.csv"

for f in "${SUMMARY_FILE}" "${PLANNING_FILE}" "${COLLECT_FILE}"; do
  [[ -f "${f}" ]] || { echo "ERROR: missing required file ${f} — skipping ${ENV}"; exit 1; }
done

# cluster_utilization.json is optional (requires Prometheus; may not exist in all envs)
if [[ ! -f "${UTIL_FILE}" ]]; then
  echo "INFO: ${UTIL_FILE} not found — live utilization metrics will be zero for ${ENV}"
  UTIL_FILE=""
fi

echo "INFO: Inserting ${ENV} snapshot from ${OUTPUT_DIR}"

# ── Read summary ──────────────────────────────────────────────
TOTAL_CPU=$(    jqr '.cluster_capacity.cpu_cores'           "0" "${SUMMARY_FILE}")
# BUG FIX: analyze_capacity.sh writes this key as "memory_gb" (not
# "memory_gib") in capacity_summary.json — the mismatched key name meant
# this always silently defaulted to 0, while memory_requested_percent (a
# different, correctly-matched key) still showed a real percentage. That
# combination — a nonzero % of a 0.0 GiB total — is exactly the "24.3% of
# 0.0 GiB" seen on the dashboard.
TOTAL_MEM=$(    jqr '.cluster_capacity.memory_gb'           "0" "${SUMMARY_FILE}")
CPU_PCT=$(      jqr '.utilization.cpu_requested_percent'    "0" "${SUMMARY_FILE}")
MEM_PCT=$(      jqr '.utilization.memory_requested_percent' "0" "${SUMMARY_FILE}")

# ── Read collection summary ───────────────────────────────────
NODE_COUNT=$(   jqr '.nodes'      "0" "${COLLECT_FILE}")
NS_COUNT=$(     jqr '.namespaces' "0" "${COLLECT_FILE}")

# ── Read planning ─────────────────────────────────────────────
WORKER_NODES=$( jqr '.worker_pool.worker_nodes'         "0" "${PLANNING_FILE}")
# BUG FIX: worker_pool.cpu_cores_total/memory_gb_total are the BLENDED
# all-worker figures (dedicated/tainted pools included) — kept for
# inventory purposes. current_utilization's percentages and pressure_level
# are computed against standard_worker_pool (dedicated pools excluded), so
# the capacity figures shown alongside them must come from the same block
# or the dashboard shows a denominator that doesn't match the percentage
# next to it (this was the ~238.5-vs-~127-core discrepancy).
WORKER_CPU=$(   jqr '.standard_worker_pool.cpu_cores_total' "0" "${PLANNING_FILE}")
WORKER_MEM=$(   jqr '.standard_worker_pool.memory_gb_total' "0" "${PLANNING_FILE}")
PRESSURE=$(     jqr '.current_utilization.pressure_level' '"UNKNOWN"' "${PLANNING_FILE}")

MASTER_NODES=$( jqr '.master_pool.master_nodes'         "0" "${PLANNING_FILE}")
MASTER_CPU=$(   jqr '.master_pool.cpu_cores_total'      "0" "${PLANNING_FILE}")
MASTER_MEM=$(   jqr '.master_pool.memory_gb_total'      "0" "${PLANNING_FILE}")

INFRA_NODES=$(  jqr '.infra_pool.infra_nodes'           "0" "${PLANNING_FILE}")
INFRA_CPU=$(    jqr '.infra_pool.cpu_cores_total'       "0" "${PLANNING_FILE}")
INFRA_MEM=$(    jqr '.infra_pool.memory_gb_total'       "0" "${PLANNING_FILE}")

# ── Read utilization ──────────────────────────────────────────
if [[ -n "${UTIL_FILE}" ]]; then
  CPU_USED=$(     jqr '.cpu.used_cores'           "0" "${UTIL_FILE}")
  MEM_USED=$(     jqr '.memory.used_gib'          "0" "${UTIL_FILE}")
  PODS_RUNNING=$( jqr '.pods.running'             "0" "${UTIL_FILE}")
  EPHEM_POD_GIB=$(jqr '.ephemeral_pod_storage.used_gib' "0" "${UTIL_FILE}")
else
  CPU_USED=0; MEM_USED=0; PODS_RUNNING=0; EPHEM_POD_GIB=0
fi

# ── Read raw JSONs for full-blob columns ─────────────────────
RAW_SUMMARY=$(  cat "${SUMMARY_FILE}"  | jq -c '.')
RAW_PLANNING=$( cat "${PLANNING_FILE}" | jq -c '.')
RAW_UTIL=$(     [[ -n "${UTIL_FILE}" ]] && cat "${UTIL_FILE}" | jq -c '.' || echo 'null')

# ── INSERT main snapshot ──────────────────────────────────────
# grep filters out any psql command tags (e.g. "INSERT 0 1") leaving only the integer id
SNAP_ID=$(_psql -t -A -c "
INSERT INTO capacity_snapshots (
  env,
  total_cpu, total_mem_gib, cpu_pct, mem_pct,
  node_count, ns_count,
  worker_nodes, worker_cpu, worker_mem_gib, pressure,
  master_nodes, master_cpu, master_mem_gib,
  infra_nodes,  infra_cpu,  infra_mem_gib,
  cpu_used, mem_used_gib, pods_running, ephem_pod_gib,
  raw_summary, raw_planning, raw_util
) VALUES (
  '${ENV}',
  ${TOTAL_CPU}, ${TOTAL_MEM}, ${CPU_PCT}, ${MEM_PCT},
  ${NODE_COUNT}, ${NS_COUNT},
  ${WORKER_NODES}, ${WORKER_CPU}, ${WORKER_MEM}, '${PRESSURE}',
  ${MASTER_NODES}, ${MASTER_CPU}, ${MASTER_MEM},
  ${INFRA_NODES},  ${INFRA_CPU},  ${INFRA_MEM},
  ${CPU_USED}, ${MEM_USED}, ${PODS_RUNNING}, ${EPHEM_POD_GIB},
  \$\$${RAW_SUMMARY}\$\$::jsonb,
  \$\$${RAW_PLANNING}\$\$::jsonb,
  \$\$${RAW_UTIL}\$\$::jsonb
) RETURNING id;
" | grep -E '^[0-9]+$' | tail -1)

if [[ -z "${SNAP_ID}" ]]; then
  echo "ERROR: Failed to insert capacity snapshot for ${ENV} — no id returned"
  exit 1
fi

echo "INFO: Created snapshot id=${SNAP_ID}"

# ── INSERT pool rows ─────────────────────────────────────────
if [[ -f "${POOLS_FILE}" ]]; then
  POOL_COUNT=$(jq 'length' "${POOLS_FILE}")
  echo "INFO: Inserting ${POOL_COUNT} pool rows"

  jq -c '.[]' "${POOLS_FILE}" | while read -r pool_json; do
    POOL_NAME=$(  echo "${pool_json}" | jq -r '.pool_name   // ""')
    TAINT_KEY=$(  echo "${pool_json}" | jq -r '.taint_key   // ""')
    TAINT_VAL=$(  echo "${pool_json}" | jq -r '.taint_value // ""')
    EFFECT=$(     echo "${pool_json}" | jq -r '.effect      // ""')
    DEDICATED=$(  echo "${pool_json}" | jq -r '.dedicated   // false')
    NODE_C=$(     echo "${pool_json}" | jq -r '.node_count  // 0')
    CPU_C=$(      echo "${pool_json}" | jq -r '.cpu_cores   // 0')
    MEM_G=$(      echo "${pool_json}" | jq -r '.memory_gib  // 0')
    NS_JSON=$(    echo "${pool_json}" | jq -c '.namespaces  // []')

    _psql -q -c "
INSERT INTO pool_snapshots
  (snapshot_id, env, collected_at,
   pool_name, taint_key, taint_value, effect,
   dedicated, node_count, cpu_cores, memory_gib, namespaces)
SELECT
  ${SNAP_ID}, env, collected_at,
  '${POOL_NAME}', '${TAINT_KEY}', '${TAINT_VAL}', '${EFFECT}',
  ${DEDICATED}, ${NODE_C}, ${CPU_C}, ${MEM_G},
  \$\$${NS_JSON}\$\$::jsonb
FROM capacity_snapshots WHERE id = ${SNAP_ID};
"
  done
fi

# ── INSERT namespace rows from chargeback CSV ─────────────────
if [[ -f "${CHARGEBACK_CSV}" ]]; then
  echo "INFO: Inserting namespace chargeback rows"
  # CSV format: namespace,type,pod_count,cpu_req,mem_req_gib,cpu_pct,mem_pct
  tail -n +2 "${CHARGEBACK_CSV}" | while IFS=, read -r NS TYPE POD_C CPU_R MEM_R CPU_P MEM_P _rest; do
    [[ -z "${NS}" ]] && continue
    _psql -q -c "
INSERT INTO namespace_snapshots
  (snapshot_id, env, collected_at,
   namespace, ns_type, pod_count, cpu_req, mem_req_gib, cpu_pct, mem_pct)
SELECT
  ${SNAP_ID}, env, collected_at,
  '${NS}', '${TYPE}',
  ${POD_C:-0}, ${CPU_R:-0}, ${MEM_R:-0}, ${CPU_P:-0}, ${MEM_P:-0}
FROM capacity_snapshots WHERE id = ${SNAP_ID};
"
  done
fi

# ── Purge old snapshots (keep 365 days for historical analysis) ──
_psql -q -c "
DELETE FROM capacity_snapshots
WHERE collected_at < NOW() - INTERVAL '365 days';
"

echo "INFO: ${ENV} snapshot inserted successfully (id=${SNAP_ID})"
