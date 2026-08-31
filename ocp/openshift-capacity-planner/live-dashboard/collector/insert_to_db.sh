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
  jq -e . "${f}" >/dev/null || { echo "ERROR: invalid JSON in ${f} — skipping ${ENV}"; exit 1; }
done

jq -e '.cluster_capacity.cpu_cores | numbers' "${SUMMARY_FILE}" >/dev/null || {
  echo "ERROR: capacity_summary.json has no numeric cluster CPU capacity — skipping ${ENV}"; exit 1;
}
jq -e '.standard_worker_pool.cpu_cores_total | numbers' "${PLANNING_FILE}" >/dev/null || {
  echo "ERROR: capacity_planning.json has no numeric standard worker capacity — skipping ${ENV}"; exit 1;
}
jq -e '.nodes | numbers' "${COLLECT_FILE}" >/dev/null || {
  echo "ERROR: collection_summary.json has no numeric node count — skipping ${ENV}"; exit 1;
}

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
PVC_COUNT=$(    jqr '.pvcs'       "0" "${COLLECT_FILE}")

# Total provisioned PVC capacity — sum of all PVC capacities in GiB.
# pvc_inventory.csv columns: namespace,pvc,status,capacity,storageclass
# capacity field is raw Kubernetes notation (e.g. "10Gi", "500Mi").
PVC_CSV="${CSV_DIR}/pvc_inventory.csv"
PVC_CAPACITY_GIB=0
if [[ -f "${PVC_CSV}" ]]; then
  PVC_CAPACITY_GIB=$(tail -n +2 "${PVC_CSV}" | awk -F',' '
  {
    gsub(/"/, "", $4)
    v=$4
    if (v ~ /Gi$/) { sub(/Gi$/, "", v); sum += v+0 }
    else if (v ~ /Mi$/) { sub(/Mi$/, "", v); sum += (v+0)/1024 }
    else if (v ~ /Ti$/) { sub(/Ti$/, "", v); sum += (v+0)*1024 }
    else if (v ~ /Ki$/) { sub(/Ki$/, "", v); sum += (v+0)/1048576 }
    else if (v+0 > 0)   { sum += (v+0)/1073741824 }
  }
  END { printf "%.1f", sum+0 }
  ')
fi

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

# Standard-worker-pool ACTUAL REQUESTED cores/GiB — needed so the Growth
# Forecast panel can grow a worker-pool-scoped baseline instead of the
# cluster-wide total_cpu*cpu_pct, which produced impossible >100% figures
# once worker_cpu above was correctly narrowed to standard-only.
WORKER_CPU_REQUESTED=$( jqr '.current_utilization.cpu_cores_requested'   "0" "${PLANNING_FILE}")
WORKER_MEM_REQUESTED=$( jqr '.current_utilization.memory_gb_requested'  "0" "${PLANNING_FILE}")

# ALL worker nodes, dedicated pools included — for the Overview cards and
# Worker Pool Utilization widget, which are meant to reflect total worker
# inventory, not just the standard/general-purpose pool.
ALL_WORKER_CPU=$( jqr '.worker_pool.cpu_cores_total'   "0" "${PLANNING_FILE}")
ALL_WORKER_MEM=$( jqr '.worker_pool.memory_gb_total'   "0" "${PLANNING_FILE}")

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

# Merge supplementary analysis outputs into raw_planning blob.
# Missing files degrade gracefully to empty defaults.
NODE_PRESSURE_JSON="${JSON_DIR}/node_pressure.json"
MISPLACED_JSON="${JSON_DIR}/misplaced_workloads.json"
DESIRED_DETAIL_JSON="${JSON_DIR}/desired_replica_detail.json"
POD_METRICS_TOP_JSON="${JSON_DIR}/pod_metrics_top.json"
STORAGE_PLANNING_JSON="${JSON_DIR}/storage_planning.json"
NODE_MACHINE_INVENTORY_JSON="${JSON_DIR}/node_machine_inventory.json"

[[ -f "${NODE_PRESSURE_JSON}"  ]] || echo '[]'  > "${NODE_PRESSURE_JSON}"
[[ -f "${MISPLACED_JSON}"      ]] || echo '{"misplaced_count":0,"controllers":[],"pod_sample":[]}' > "${MISPLACED_JSON}"
[[ -f "${DESIRED_DETAIL_JSON}" ]] || echo '[]'  > "${DESIRED_DETAIL_JSON}"
[[ -f "${POD_METRICS_TOP_JSON}" ]] || echo '[]' > "${POD_METRICS_TOP_JSON}"
[[ -f "${STORAGE_PLANNING_JSON}" ]] || echo '{"summary":{},"pvc_inventory":[],"pv_inventory":[],"zero_replica_controllers":[],"old_terminal_pods":[]}' > "${STORAGE_PLANNING_JSON}"
[[ -f "${NODE_MACHINE_INVENTORY_JSON}" ]] || echo '{"summary":{},"nodes":[],"machinesets":[]}' > "${NODE_MACHINE_INVENTORY_JSON}"

_rp_tmp=$(mktemp)
echo "${RAW_PLANNING}" > "${_rp_tmp}"
RAW_PLANNING=$(jq -c \
    --slurpfile np "${NODE_PRESSURE_JSON}" \
    --slurpfile mp "${MISPLACED_JSON}" \
    --slurpfile dd "${DESIRED_DETAIL_JSON}" \
    --slurpfile pm "${POD_METRICS_TOP_JSON}" \
    --slurpfile sp "${STORAGE_PLANNING_JSON}" \
    --slurpfile ni "${NODE_MACHINE_INVENTORY_JSON}" \
    '. + {
        node_pressure:          ($np[0] // []),
        misplaced_workloads:    ($mp[0] // {"misplaced_count":0,"controllers":[],"pod_sample":[]}),
      desired_replica_detail: ($dd[0] // []),
      pod_metrics_top:         ($pm[0] // []),
      storage_planning:        ($sp[0] // {"summary":{},"pvc_inventory":[],"pv_inventory":[],"zero_replica_controllers":[],"old_terminal_pods":[]}),
      node_machine_inventory:  ($ni[0] // {"summary":{},"nodes":[],"machinesets":[]})
    }' "${_rp_tmp}" 2>/dev/null \
    || cat "${_rp_tmp}")
rm -f "${_rp_tmp}" 

# ── INSERT main snapshot ──────────────────────────────────────
# Stream SQL over stdin: raw JSON snapshots can exceed the OS argument-size
# limit when passed through `psql -c`.
SNAP_ID=$(_psql -t -A <<SQL | grep -E '^[0-9]+$' | tail -1
INSERT INTO capacity_snapshots (
  env,
  total_cpu, total_mem_gib, cpu_pct, mem_pct,
  node_count, ns_count, pvc_count, pvc_capacity_gib_total,
  worker_nodes, worker_cpu, worker_mem_gib, worker_cpu_requested, worker_mem_gib_requested, pressure,
  all_worker_cpu, all_worker_mem_gib,
  master_nodes, master_cpu, master_mem_gib,
  infra_nodes,  infra_cpu,  infra_mem_gib,
  cpu_used, mem_used_gib, pods_running, ephem_pod_gib,
  raw_summary, raw_planning, raw_util
) VALUES (
  '${ENV}',
  ${TOTAL_CPU}, ${TOTAL_MEM}, ${CPU_PCT}, ${MEM_PCT},
  ${NODE_COUNT}, ${NS_COUNT}, ${PVC_COUNT}, ${PVC_CAPACITY_GIB},
  ${WORKER_NODES}, ${WORKER_CPU}, ${WORKER_MEM}, ${WORKER_CPU_REQUESTED}, ${WORKER_MEM_REQUESTED}, '${PRESSURE}',
  ${ALL_WORKER_CPU}, ${ALL_WORKER_MEM},
  ${MASTER_NODES}, ${MASTER_CPU}, ${MASTER_MEM},
  ${INFRA_NODES},  ${INFRA_CPU},  ${INFRA_MEM},
  ${CPU_USED}, ${MEM_USED}, ${PODS_RUNNING}, ${EPHEM_POD_GIB},
  \$\$${RAW_SUMMARY}\$\$::jsonb,
  \$\$${RAW_PLANNING}\$\$::jsonb,
  \$\$${RAW_UTIL}\$\$::jsonb
) RETURNING id;
SQL
)

if [[ -z "${SNAP_ID}" ]]; then
  echo "ERROR: Failed to insert capacity snapshot for ${ENV} — no id returned"
  exit 1
fi

echo "INFO: Created snapshot id=${SNAP_ID}"

cleanup_failed_snapshot() {
  local status=$?
  trap - ERR
  echo "ERROR: Snapshot id=${SNAP_ID} was incomplete — removing it"
  _psql -q -c "DELETE FROM capacity_snapshots WHERE id = ${SNAP_ID};" || true
  exit "${status}"
}
trap cleanup_failed_snapshot ERR

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
    CPU_REQ=$(    echo "${pool_json}" | jq -r '.cpu_cores_requested    // 0')
    MEM_REQ=$(    echo "${pool_json}" | jq -r '.memory_gib_requested   // 0')
    CPU_UTIL=$(   echo "${pool_json}" | jq -r '.cpu_utilization_pct    // 0')
    MEM_UTIL=$(   echo "${pool_json}" | jq -r '.memory_utilization_pct // 0')
    POOL_PRESSURE=$(echo "${pool_json}" | jq -r '.pressure_level       // "UNKNOWN"')
    NS_JSON=$(    echo "${pool_json}" | jq -c '.namespaces  // []')

    _psql -q -c "
INSERT INTO pool_snapshots
  (snapshot_id, env, collected_at,
   pool_name, taint_key, taint_value, effect,
   dedicated, node_count, cpu_cores, memory_gib,
   cpu_cores_requested, memory_gib_requested,
   cpu_utilization_pct, memory_utilization_pct, pressure_level,
   namespaces)
SELECT
  ${SNAP_ID}, env, collected_at,
  '${POOL_NAME}', '${TAINT_KEY}', '${TAINT_VAL}', '${EFFECT}',
  ${DEDICATED}, ${NODE_C}, ${CPU_C}, ${MEM_G},
  ${CPU_REQ}, ${MEM_REQ},
  ${CPU_UTIL}, ${MEM_UTIL}, '${POOL_PRESSURE}',
  \$\$${NS_JSON}\$\$::jsonb
FROM capacity_snapshots WHERE id = ${SNAP_ID};
"
  done
fi

# ── INSERT namespace rows from chargeback CSV ─────────────────
# CSV format: namespace,type,pod_count,cpu_cores_reserved,memory_gb_reserved,
#             cpu_pct_of_cluster,memory_pct_of_cluster,cpu_actual_cores,
#             mem_actual_gb,cpu_util_pct,mem_util_pct,cpu_overcommit_ratio,
#             no_cpu_limit,rightsizing_signal
if [[ -f "${CHARGEBACK_CSV}" ]]; then
  echo "INFO: Inserting namespace chargeback rows"
  tail -n +2 "${CHARGEBACK_CSV}" | while IFS=, read -r NS TYPE POD_C CPU_R MEM_R CPU_P MEM_P CPU_ACT MEM_ACT CPU_UTIL MEM_UTIL _OC _NCL SIGNAL _rest; do
    [[ -z "${NS}" ]] && continue
    _psql -q -c "
INSERT INTO namespace_snapshots
  (snapshot_id, env, collected_at,
   namespace, ns_type, pod_count, cpu_req, mem_req_gib, cpu_pct, mem_pct,
   cpu_used, mem_used_gib, cpu_util_pct, mem_util_pct, rightsizing_signal)
SELECT
  ${SNAP_ID}, env, collected_at,
  '${NS}', '${TYPE}',
  ${POD_C:-0}, ${CPU_R:-0}, ${MEM_R:-0}, ${CPU_P:-0}, ${MEM_P:-0},
  ${CPU_ACT:-0}, ${MEM_ACT:-0}, ${CPU_UTIL:-0}, ${MEM_UTIL:-0},
  '${SIGNAL:-UNKNOWN}'
FROM capacity_snapshots WHERE id = ${SNAP_ID};
"
  done
fi

# ── INSERT PVC rows from pvc_inventory.csv ────────────────────
# pvc_inventory.csv columns: namespace,pvc,status,capacity,storageclass
# This closes the longstanding gap: PVCs were collected from day 1 but
# never persisted to the database.
if [[ -f "${PVC_CSV}" ]]; then
  PVC_ROW_COUNT=$(tail -n +2 "${PVC_CSV}" | wc -l | tr -d ' ')
  echo "INFO: Inserting ${PVC_ROW_COUNT} PVC rows"
  tail -n +2 "${PVC_CSV}" | while IFS=, read -r NS PVC_NAME STATUS CAPACITY STORAGECLASS _rest; do
    # Strip any surrounding quotes from CSV fields
    NS=$(echo "${NS}" | tr -d '"')
    PVC_NAME=$(echo "${PVC_NAME}" | tr -d '"')
    STATUS=$(echo "${STATUS}" | tr -d '"')
    STORAGECLASS=$(echo "${STORAGECLASS}" | tr -d '"')
    CAPACITY_RAW=$(echo "${CAPACITY}" | tr -d '"')
    [[ -z "${NS}" || -z "${PVC_NAME}" ]] && continue

    # Convert raw Kubernetes capacity to GiB
    CAP_GIB=$(echo "${CAPACITY_RAW}" | awk '
    {
      v=$1
      if (v ~ /Gi$/) { sub(/Gi$/, "", v); printf "%.2f", v+0 }
      else if (v ~ /Mi$/) { sub(/Mi$/, "", v); printf "%.2f", (v+0)/1024 }
      else if (v ~ /Ti$/) { sub(/Ti$/, "", v); printf "%.2f", (v+0)*1024 }
      else if (v ~ /Ki$/) { sub(/Ki$/, "", v); printf "%.2f", (v+0)/1048576 }
      else if (v+0 > 0)   { printf "%.2f", (v+0)/1073741824 }
      else                 { printf "0.00" }
    }')

    _psql -q -c "
INSERT INTO pvc_snapshots
  (snapshot_id, env, collected_at,
   namespace, pvc_name, status, capacity_gib, storageclass)
SELECT
  ${SNAP_ID}, env, collected_at,
  '${NS}', '${PVC_NAME}', '${STATUS}', ${CAP_GIB}, '${STORAGECLASS}'
FROM capacity_snapshots WHERE id = ${SNAP_ID};
"
  done
fi

# ── Purge old snapshots (keep 365 days for historical analysis) ──
_psql -q -c "
DELETE FROM capacity_snapshots
WHERE collected_at < NOW() - INTERVAL '365 days';
"

trap - ERR
echo "INFO: ${ENV} snapshot inserted successfully (id=${SNAP_ID})"
