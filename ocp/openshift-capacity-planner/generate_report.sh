#!/usr/bin/env bash
#
# ARO Ops Dashboard
#
# Part 4A/6
# Offline HTML Report Generator
#

set -Eeuo pipefail


#############################################
# Environment Validation
#############################################

: "${CAPACITY_OUTPUT:?CAPACITY_OUTPUT missing}"
: "${CAPACITY_CSV:?CAPACITY_CSV missing}"
: "${CAPACITY_JSON:?CAPACITY_JSON missing}"
: "${CAPACITY_LOG:?CAPACITY_LOG missing}"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


REPORT_FILE="${CAPACITY_OUTPUT}/report.html"



#############################################
# Logging
#############################################

log()
{
    local LEVEL="$1"
    shift

    echo "$(date '+%F %T') [REPORT] ${LEVEL}: $*" \
    | tee -a "${CAPACITY_LOG}"
}



log INFO "Starting report generation"



#############################################
# Asset Validation
#############################################

CSS_FILE="${SCRIPT_DIR}/assets/dashboard.css"

CHART_FILE="${SCRIPT_DIR}/assets/chart.min.js"



if [[ ! -f "${CSS_FILE}" ]]
then
    log ERROR "Missing CSS file ${CSS_FILE}"
    exit 1
fi



if [[ ! -f "${CHART_FILE}" ]]
then
    log ERROR "Missing Chart.js ${CHART_FILE}"
    exit 1
fi



CSS_CONTENT=$(cat "${CSS_FILE}")

CHART_JS=$(cat "${CHART_FILE}")



#############################################
# Input JSON Files
#############################################

# Environment label (exported by run.sh; default to 'cluster' when run standalone)
CLUSTER_ENV="${CLUSTER_ENV:-cluster}"
CLUSTER_API="${CLUSTER_API:-$(oc whoami --show-server 2>/dev/null || echo "unknown")}"

SUMMARY_FILE="${CAPACITY_JSON}/capacity_summary.json"

GROWTH_FILE="${CAPACITY_JSON}/growth_forecast.json"

RECOMMEND_FILE="${CAPACITY_JSON}/recommendations.json"

PLANNING_FILE="${CAPACITY_JSON}/capacity_planning.json"

UTILIZATION_FILE="${CAPACITY_JSON}/cluster_utilization.json"

CHARGEBACK_FILE="${CAPACITY_CSV}/chargeback_by_namespace.csv"



for FILE in \
"${SUMMARY_FILE}" \
"${GROWTH_FILE}" \
"${RECOMMEND_FILE}" \
"${PLANNING_FILE}"
do

    if [[ ! -f "${FILE}" ]]
    then
        log ERROR "Missing ${FILE}"
        exit 1
    fi

done



#############################################
# Read Summary Values
#############################################


CPU_TOTAL=$(jq -r \
'.cluster_capacity.cpu_cores // 0' \
"${SUMMARY_FILE}")



MEM_TOTAL=$(jq -r \
'.cluster_capacity.memory_gb // 0' \
"${SUMMARY_FILE}")



CPU_REQUEST=$(jq -r \
'.requests.cpu_cores // 0' \
"${SUMMARY_FILE}")



MEM_REQUEST=$(jq -r \
'.requests.memory_gb // 0' \
"${SUMMARY_FILE}")



CPU_PERCENT=$(jq -r \
'.utilization.cpu_requested_percent // 0' \
"${SUMMARY_FILE}")



MEM_PERCENT=$(jq -r \
'.utilization.memory_requested_percent // 0' \
"${SUMMARY_FILE}")



CPU_USED_PERCENT=$(jq -r \
'.utilization.cpu_used_percent // 0' \
"${SUMMARY_FILE}")



MEM_USED_PERCENT=$(jq -r \
'.utilization.memory_used_percent // 0' \
"${SUMMARY_FILE}")



#############################################
# Capacity Planning Values
#############################################

WORKER_NODES=$(jq -r    '.worker_pool.worker_nodes // 0'                          "${PLANNING_FILE}")
WORKER_CPU=$(jq -r      '.worker_pool.cpu_cores_total // 0'                       "${PLANNING_FILE}")
WORKER_MEM=$(jq -r      '.worker_pool.memory_gb_total // 0'                       "${PLANNING_FILE}")
CPU_WORKER_PCT=$(jq -r  '.current_utilization.cpu_pct_of_workers // 0'            "${PLANNING_FILE}")
MEM_WORKER_PCT=$(jq -r  '.current_utilization.memory_pct_of_workers // 0'         "${PLANNING_FILE}")
PRESSURE=$(jq -r        '.current_utilization.pressure_level // "GREEN"'          "${PLANNING_FILE}")
CPU_HEADROOM=$(jq -r    '.headroom_for_new_projects.cpu_cores_available // 0'     "${PLANNING_FILE}")
MEM_HEADROOM=$(jq -r    '.headroom_for_new_projects.memory_gb_available // 0'     "${PLANNING_FILE}")
EQUIV_NODES=$(jq -r     '.headroom_for_new_projects.equivalent_worker_nodes // 0' "${PLANNING_FILE}")
ACTION=$(jq -r          '.headroom_for_new_projects.action // ""'                 "${PLANNING_FILE}")
NODES_NEEDED=$(jq -r    '.expansion_planning.nodes_to_reach_80pct_safe_again // 0' "${PLANNING_FILE}")

# Master and infra node pools (read from planning file)
MASTER_NODES=$(jq -r    '.master_pool.master_nodes  // 0'       "${PLANNING_FILE}")
MASTER_CPU=$(jq -r      '.master_pool.cpu_cores_total // 0'     "${PLANNING_FILE}")
MASTER_MEM=$(jq -r      '.master_pool.memory_gb_total // 0'     "${PLANNING_FILE}")
INFRA_NODES=$(jq -r     '.infra_pool.infra_nodes  // 0'         "${PLANNING_FILE}")
INFRA_NODE_CPU=$(jq -r  '.infra_pool.cpu_cores_total // 0'      "${PLANNING_FILE}")
INFRA_NODE_MEM=$(jq -r  '.infra_pool.memory_gb_total // 0'      "${PLANNING_FILE}")



#############################################
# Cluster Utilization Values (Prometheus)
#############################################

UTIL_SOURCE="unavailable"
UTIL_CPU_USED=0
UTIL_MEM_USED_GIB=0
UTIL_FS_USED_TIB=0
UTIL_FS_TOTAL_TIB=0
UTIL_FS_AVAIL_TIB=0
UTIL_NET_RX=0
UTIL_NET_TX=0
UTIL_PODS_RUNNING=0
UTIL_EPHEM_POD_GIB=0

if [[ -f "${UTILIZATION_FILE}" ]]
then
    UTIL_SOURCE=$(jq -r          '.source // "unavailable"'              "${UTILIZATION_FILE}")
    UTIL_CPU_USED=$(jq -r        '.cpu.used_cores // 0'                  "${UTILIZATION_FILE}")
    UTIL_MEM_USED_GIB=$(jq -r    '.memory.used_gib // 0'                 "${UTILIZATION_FILE}")
    UTIL_FS_USED_TIB=$(jq -r     '.filesystem.used_tib // 0'             "${UTILIZATION_FILE}")
    UTIL_FS_TOTAL_TIB=$(jq -r    '.filesystem.total_tib // 0'            "${UTILIZATION_FILE}")
    UTIL_FS_AVAIL_TIB=$(jq -r    '.filesystem.avail_tib // 0'            "${UTILIZATION_FILE}")
    UTIL_EPHEM_POD_GIB=$(jq -r   '.ephemeral_pod_storage.used_gib // 0'  "${UTILIZATION_FILE}")
    UTIL_NET_RX=$(jq -r          '.network.rx_mbps // 0'                 "${UTILIZATION_FILE}")
    UTIL_NET_TX=$(jq -r          '.network.tx_mbps // 0'                 "${UTILIZATION_FILE}")
    UTIL_PODS_RUNNING=$(jq -r    '.pods.running // 0'                    "${UTILIZATION_FILE}")
fi

# Derive CPU available = total allocatable - used
UTIL_CPU_AVAIL=$(awk "BEGIN{v=${CPU_TOTAL}-${UTIL_CPU_USED};printf \"%.1f\",(v<0?0:v)}")
UTIL_MEM_TOTAL_GIB=$(awk "BEGIN{printf \"%.1f\",${MEM_TOTAL}*1024/1024}")  # MEM_TOTAL is GB → GiB ~same
UTIL_MEM_AVAIL_GIB=$(awk "BEGIN{v=${UTIL_MEM_TOTAL_GIB}-${UTIL_MEM_USED_GIB};printf \"%.1f\",(v<0?0:v)}")

# Bar widths (capped at 100)
UTIL_CPU_BAR=$(awk    "BEGIN{v=(${CPU_TOTAL}>0)?(${UTIL_CPU_USED}/${CPU_TOTAL})*100:0; print (v>100)?100:int(v)}")
UTIL_MEM_BAR=$(awk    "BEGIN{v=(${UTIL_MEM_TOTAL_GIB}>0)?(${UTIL_MEM_USED_GIB}/${UTIL_MEM_TOTAL_GIB})*100:0; print (v>100)?100:int(v)}")
UTIL_FS_BAR=$(awk     "BEGIN{v=(${UTIL_FS_TOTAL_TIB}>0)?(${UTIL_FS_USED_TIB}/${UTIL_FS_TOTAL_TIB})*100:0; print (v>100)?100:int(v)}")
UTIL_NET_MAX=$(awk    "BEGIN{v=(${UTIL_NET_RX}>${UTIL_NET_TX})?${UTIL_NET_RX}:${UTIL_NET_TX}; print (v<1)?1:v}")
UTIL_NET_RX_BAR=$(awk "BEGIN{v=(${UTIL_NET_RX}/${UTIL_NET_MAX})*100; print (v>100)?100:int(v)}")
UTIL_NET_TX_BAR=$(awk "BEGIN{v=(${UTIL_NET_TX}/${UTIL_NET_MAX})*100; print (v>100)?100:int(v)}")

# Ephemeral storage (node OS reservation = capacity - allocatable, from node status API)
EPHEM_CAPACITY_GIB=$(jq -r '.ephemeral_storage.capacity_gib  // 0' "${SUMMARY_FILE}" 2>/dev/null || echo 0)
EPHEM_ALLOC_GIB=$(jq -r    '.ephemeral_storage.allocatable_gib // 0' "${SUMMARY_FILE}" 2>/dev/null || echo 0)
EPHEM_USED_GIB=$(jq -r     '.ephemeral_storage.used_gib       // 0' "${SUMMARY_FILE}" 2>/dev/null || echo 0)
EPHEM_USED_PCT=$(jq -r     '.ephemeral_storage.used_pct       // 0' "${SUMMARY_FILE}" 2>/dev/null || echo 0)
EPHEM_AVAIL_GIB=$(awk "BEGIN{v=${EPHEM_ALLOC_GIB}-${EPHEM_USED_GIB};printf \"%.1f\",(v<0?0:v)}")
EPHEM_BAR=$(awk "BEGIN{v=${EPHEM_USED_PCT}+0;print(v>100)?100:int(v)}")

# Pod ephemeral bar (against allocatable total from node status)
EPHEM_POD_BAR=$(awk "BEGIN{v=(${EPHEM_ALLOC_GIB}>0)?(${UTIL_EPHEM_POD_GIB}/${EPHEM_ALLOC_GIB})*100:0;print(v>100)?100:int(v)}")
EPHEM_POD_PCT=$(awk "BEGIN{printf \"%.1f\",(${EPHEM_ALLOC_GIB}>0)?(${UTIL_EPHEM_POD_GIB}/${EPHEM_ALLOC_GIB})*100:0}")

HEALTH_SCORE=$(awk \
-v cpu="${CPU_PERCENT}" \
-v mem="${MEM_PERCENT}" '

BEGIN {

max=(cpu>mem)?cpu:mem;

score=100-max;


if(score<0)
score=0;


printf "%.0f",score;

}

')



#############################################
# Capacity Status
#############################################

STATUS="HEALTHY"

STATUS_CLASS="green"



if (( $(awk "BEGIN {print (${CPU_PERCENT}>85 || ${MEM_PERCENT}>85)}") ))
then

STATUS="CRITICAL"

STATUS_CLASS="red"



elif (( $(awk "BEGIN {print (${CPU_PERCENT}>70 || ${MEM_PERCENT}>70)}") ))
then

STATUS="WARNING"

STATUS_CLASS="orange"


fi



#############################################
# Chart Data — Tenant Namespaces Only
# Source: chargeback_by_namespace.csv (type=tenant)
# Columns: namespace,type,pod_count,cpu_req,mem_req_gib,cpu_pct,mem_pct,cpu_actual,mem_actual,cpu_util_pct,mem_util_pct
#############################################

# All tenant namespaces — CPU + Memory for the dual-bar namespace chart
NAMESPACE_DATA=$(awk -F',' '
NR>1 && $2=="tenant" {
    gsub(/"/, "", $0)
    if ($1 != "") printf "{\"name\":\"%s\",\"cpu\":%.3f,\"mem\":%.2f,\"cpupct\":%.2f,\"mempct\":%.2f,\"cpuact\":%.3f,\"memact\":%.3f,\"cpuutil\":%.1f,\"memutil\":%.1f},", $1, $4+0, $5+0, $6+0, $7+0, $8+0, $9+0, $10+0, $11+0
}' "${CHARGEBACK_FILE}")
NAMESPACE_DATA="[${NAMESPACE_DATA%,}]"

# Top 10 CPU consuming tenant namespaces (sorted descending)
CPU_DATA=$(awk -F',' '
NR>1 && $2=="tenant" {
    gsub(/"/, "", $0)
    if ($1 != "") printf "%010.3f\t%s\n", $4+0, $1
}' "${CHARGEBACK_FILE}" | sort -rn | head -10 \
| awk '{printf "{\"name\":\"%s\",\"value\":%.3f},", $2, $1+0}')
CPU_DATA="[${CPU_DATA%,}]"

# Top 10 Memory consuming tenant namespaces (sorted descending)
MEMORY_DATA=$(awk -F',' '
NR>1 && $2=="tenant" {
    gsub(/"/, "", $0)
    if ($1 != "") printf "%010.2f\t%s\n", $5+0, $1
}' "${CHARGEBACK_FILE}" | sort -rn | head -10 \
| awk '{printf "{\"name\":\"%s\",\"value\":%.2f},", $2, $1+0}')
MEMORY_DATA="[${MEMORY_DATA%,}]"

#############################################
# Chart Data — Infra Namespaces
# Source: chargeback_by_namespace.csv (type=infra)
#############################################

INFRA_NAMESPACE_DATA=$(awk -F',' '
NR>1 && $2=="infra" {
    gsub(/"/, "", $0)
    if ($1 != "") printf "{\"name\":\"%s\",\"cpu\":%.3f,\"mem\":%.2f,\"cpupct\":%.2f,\"mempct\":%.2f,\"cpuact\":%.3f,\"memact\":%.3f,\"cpuutil\":%.1f,\"memutil\":%.1f},", $1, $4+0, $5+0, $6+0, $7+0, $8+0, $9+0, $10+0, $11+0
}' "${CHARGEBACK_FILE}")
INFRA_NAMESPACE_DATA="[${INFRA_NAMESPACE_DATA%,}]"

INFRA_CPU_TOTAL=$(awk -F',' 'NR>1 && $2=="infra"{s+=$4}END{printf "%.2f",s+0}' "${CHARGEBACK_FILE}")
INFRA_MEM_TOTAL=$(awk -F',' 'NR>1 && $2=="infra"{s+=$5}END{printf "%.2f",s+0}' "${CHARGEBACK_FILE}")
INFRA_NS_COUNT=$(awk -F',' 'NR>1 && $2=="infra"{c++}END{print c+0}' "${CHARGEBACK_FILE}")



#############################################
# Start HTML
#############################################

cat > "${REPORT_FILE}" <<EOF

<!DOCTYPE html>

<html>

<head>

<meta charset="UTF-8">

<title>
ARO Ops Dashboard — ${CLUSTER_ENV}
</title>


<style>

${CSS_CONTENT}

</style>


<script>

${CHART_JS}

</script>


</head>


<body>


<div class="header">

<h1>
ARO Ops Dashboard
<span style="display:inline-block;margin-left:14px;padding:4px 14px;border-radius:10px;font-size:18px;font-weight:700;background:#1f4e79;color:#fff;vertical-align:middle;letter-spacing:1px">${CLUSTER_ENV}</span>
</h1>
<p style="margin:4px 0 0;font-size:13px;color:#adc6e0;letter-spacing:.5px">Capacity &nbsp;·&nbsp; Resources &nbsp;·&nbsp; Tenant Chargeback &nbsp;·&nbsp; PVC Inventory</p>

<p>
Generated: $(date) &nbsp;&bull;&nbsp; Cluster: ${CLUSTER_API}
</p>

</div>

EOF
#############################################
# Pre-compute utilization color classes
#############################################

UTIL_CPU_CLASS=$(awk  "BEGIN{p=${UTIL_CPU_BAR};print(p>85)?\"bar-critical\":(p>60)?\"bar-at_risk\":\"bar-safe\"}")
UTIL_MEM_CLASS=$(awk  "BEGIN{p=${UTIL_MEM_BAR};print(p>85)?\"bar-critical\":(p>60)?\"bar-at_risk\":\"bar-safe\"}")
UTIL_FS_CLASS=$(awk   "BEGIN{p=${UTIL_FS_BAR};print(p>85)?\"bar-critical\":(p>60)?\"bar-at_risk\":\"bar-safe\"}")
EPHEM_CLASS=$(awk     "BEGIN{p=${EPHEM_BAR};print(p>85)?\"bar-critical\":(p>60)?\"bar-at_risk\":\"bar-safe\"}")
EPHEM_POD_CLASS=$(awk "BEGIN{p=${EPHEM_POD_BAR};print(p>85)?\"bar-critical\":(p>60)?\"bar-at_risk\":\"bar-safe\"}")

# Worker-pool focused bars (denominator = worker nodes only, not whole cluster)
WORKER_MEM_GIB=$(awk "BEGIN{printf \"%.1f\",${WORKER_MEM}*1000/1024}")
WORKER_CPU_BAR=$(awk "BEGIN{printf \"%.1f\",(${WORKER_CPU}>0)?(${UTIL_CPU_USED}/${WORKER_CPU})*100:0}")
WORKER_MEM_BAR=$(awk "BEGIN{v=(${WORKER_MEM_GIB}>0)?(${UTIL_MEM_USED_GIB}/${WORKER_MEM_GIB})*100:0;printf \"%.1f\",(v>100)?100:v}")
WORKER_CPU_CLASS=$(awk "BEGIN{p=${WORKER_CPU_BAR};print(p>85)?\"bar-critical\":(p>65)?\"bar-at_risk\":\"bar-safe\"}")
WORKER_MEM_CLASS=$(awk "BEGIN{p=${WORKER_MEM_BAR};print(p>85)?\"bar-critical\":(p>65)?\"bar-at_risk\":\"bar-safe\"}")
WORKER_CPU_AVAIL=$(awk "BEGIN{printf \"%.1f\",${WORKER_CPU}-${UTIL_CPU_USED}}")
WORKER_MEM_AVAIL=$(awk "BEGIN{printf \"%.1f\",${WORKER_MEM_GIB}-${UTIL_MEM_USED_GIB}}")

if [[ "${UTIL_SOURCE}" == "unavailable" ]]
then
    UTIL_BADGE_HTML="&#9888; Prometheus unavailable — showing request-based data only"
    UTIL_BADGE_STYLE="background:#fff3cd;color:#856404"
else
    UTIL_BADGE_HTML="&#10004; Live data from Prometheus"
    UTIL_BADGE_STYLE="background:#d4edda;color:#1a7f37"
fi

#############################################
# Executive Summary Cards
#############################################

cat >> "${REPORT_FILE}" <<EOF

<div style="margin:24px 0 18px;padding:14px 22px;background:linear-gradient(135deg,#1f4e79 0%,#2e75b6 100%);border-radius:10px;color:#fff;display:flex;align-items:center;gap:12px">
  <span style="font-size:1.6rem">&#128202;</span>
  <div>
    <div style="font-size:1rem;font-weight:700;letter-spacing:.04em">Overall Capacity &amp; Utilization</div>
    <div style="font-size:.78rem;opacity:.85;margin-top:2px">Cluster-wide resources, worker pool health, and growth forecast</div>
  </div>
</div>


<div class="grid">


<div class="card">

<h3>
Cluster Health Score
</h3>

<div class="metric ${STATUS_CLASS}">

${HEALTH_SCORE}/100

</div>

</div>



<div class="card">

<h3>
Capacity Status
</h3>

<div class="metric ${STATUS_CLASS}">

${STATUS}

</div>

</div>



<div class="card" style="background:#f8f0ff;border-left:5px solid #6c3483">
<h3 style="color:#6c3483;margin-top:0">
  &#9874; Master Nodes
  <span style="float:right;font-size:13px;font-weight:400;color:#888;padding-top:4px">${MASTER_NODES} nodes &nbsp;&bull;&nbsp; control plane only</span>
</h3>

<table style="width:100%;border-collapse:collapse;font-size:13px">
<tr>
  <td style="color:#555;padding:4px 0;width:55%">CPU Allocatable</td>
  <td style="text-align:right;font-weight:700;font-size:16px;color:#6c3483">${MASTER_CPU} cores</td>
</tr>
<tr>
  <td style="color:#555;padding:4px 0">Memory Allocatable</td>
  <td style="text-align:right;font-weight:700;font-size:16px;color:#6c3483">${MASTER_MEM} GB</td>
</tr>
<tr>
  <td colspan="2" style="padding-top:8px">
    <span style="display:inline-block;padding:3px 10px;border-radius:6px;background:#f3e5f5;color:#6c3483;font-size:12px;font-weight:600">
      &#128274; Not schedulable for tenant workloads
    </span>
  </td>
</tr>
</table>
</div>



<div class="card" style="background:#f0f7ff;border-left:5px solid #1f4e79">
<h3 style="color:#1f4e79;margin-top:0">
  &#128736; Worker Nodes
  <span style="float:right;font-size:13px;font-weight:400;color:#888;padding-top:4px">${WORKER_NODES} nodes &nbsp;&bull;&nbsp; tenant workloads</span>
</h3>

<table style="width:100%;border-collapse:collapse;font-size:13px">
<tr>
  <td style="color:#555;padding:3px 0;width:55%">CPU Allocatable</td>
  <td style="text-align:right;font-weight:700;font-size:16px;color:#1f4e79">${WORKER_CPU} cores</td>
</tr>
<tr>
  <td style="color:#555;padding:3px 0">Memory Allocatable</td>
  <td style="text-align:right;font-weight:700;font-size:16px;color:#1f4e79">${WORKER_MEM} GB</td>
</tr>
<tr style="border-top:1px dashed #cce0ff;margin-top:6px">
  <td style="color:#555;padding:6px 0 3px 0">CPU Requested</td>
  <td style="text-align:right;font-weight:700;color:#2e75b6">
    ${CPU_REQUEST} cores
    <span style="color:#888;font-weight:400;font-size:12px">&nbsp;(${CPU_WORKER_PCT}%)</span>
  </td>
</tr>
<tr>
  <td style="color:#555;padding:3px 0">Memory Requested</td>
  <td style="text-align:right;font-weight:700;color:#2e75b6">
    ${MEM_REQUEST} GB
    <span style="color:#888;font-weight:400;font-size:12px">&nbsp;(${MEM_WORKER_PCT}%)</span>
  </td>
</tr>
<tr>
  <td style="color:#555;padding:3px 0">CPU Headroom (80% safe)</td>
  <td style="text-align:right;font-weight:700;color:#1a7f37">${CPU_HEADROOM} cores</td>
</tr>
<tr>
  <td style="color:#555;padding:3px 0">Memory Headroom</td>
  <td style="text-align:right;font-weight:700;color:#1a7f37">${MEM_HEADROOM} GB</td>
</tr>
</table>

<div style="margin-top:10px">
  <div style="display:flex;justify-content:space-between;font-size:11px;color:#888;margin-bottom:3px">
    <span>CPU: 0</span>
    <span style="color:$(awk "BEGIN{p=${CPU_WORKER_PCT}+0;print(p>85)?\"#c0392b\":(p>60)?\"#d35400\":\"#1f4e79\"}")">${CPU_WORKER_PCT}% requested</span>
    <span>${WORKER_CPU} cores</span>
  </div>
  <div style="background:#e9ecef;border-radius:6px;height:12px">
    <div style="width:$(awk "BEGIN{v=${CPU_WORKER_PCT}+0;print(v>100)?100:int(v)}")%;height:12px;border-radius:6px;background:$(awk "BEGIN{p=${CPU_WORKER_PCT}+0;print(p>85)?\"#c0392b\":(p>60)?\"#d35400\":\"#2e75b6\"}")"></div>
  </div>
  <div style="display:flex;justify-content:space-between;font-size:11px;color:#888;margin:6px 0 3px 0">
    <span>Memory: 0</span>
    <span style="color:$(awk "BEGIN{p=${MEM_WORKER_PCT}+0;print(p>85)?\"#c0392b\":(p>60)?\"#d35400\":\"#1f4e79\"}")">${MEM_WORKER_PCT}% requested</span>
    <span>${WORKER_MEM} GB</span>
  </div>
  <div style="background:#e9ecef;border-radius:6px;height:12px">
    <div style="width:$(awk "BEGIN{v=${MEM_WORKER_PCT}+0;print(v>100)?100:int(v)}")%;height:12px;border-radius:6px;background:$(awk "BEGIN{p=${MEM_WORKER_PCT}+0;print(p>85)?\"#c0392b\":(p>60)?\"#d35400\":\"#2e75b6\"}")"></div>
  </div>
  <div style="font-size:11px;color:#aaa;margin-top:4px">
    Safe 80% threshold: CPU $(awk "BEGIN{printf \"%.1f\",${WORKER_CPU}*0.8}") cores &nbsp;&bull;&nbsp; Memory $(awk "BEGIN{printf \"%.1f\",${WORKER_MEM}*0.8}") GB
  </div>
</div>
</div>



</div>



<div class="card">
<h2>Worker Pool Utilization &nbsp;<span style="${UTIL_BADGE_STYLE};padding:2px 10px;border-radius:8px;font-size:12px">${UTIL_BADGE_HTML}</span></h2>
<p style="color:#555;font-size:13px;margin-bottom:12px">Utilization across the <b>${WORKER_NODES}</b> schedulable worker nodes &mdash; excludes <b>${MASTER_NODES}</b> masters &amp; <b>${INFRA_NODES}</b> infra nodes.</p>

<!-- Controls row: Node type filter + time range selector -->
<div style="display:flex;align-items:center;gap:12px;margin-bottom:14px;flex-wrap:wrap">
  <label style="font-size:12px;color:#555;font-weight:600">Filter by Node type</label>
  <select id="utilNodeFilter" onchange="applyUtilFilter()"
    style="padding:4px 10px;border:1px solid #ccc;border-radius:5px;font-size:12px;cursor:pointer;background:#fff;color:#333">
    <option value="all">All nodes</option>
    <option value="worker" selected>Worker</option>
    <option value="master">Master</option>
    <option value="infra">Infra</option>
  </select>
  <label style="font-size:12px;color:#555;font-weight:600;margin-left:12px">Snapshot</label>
  <span id="utilSnapshotTime" style="font-size:12px;color:#1f4e79;font-weight:700"></span>
  <span style="font-size:11px;color:#aaa">(point-in-time — re-run to refresh history)</span>
</div>

<table style="width:100%;border-collapse:collapse" id="utilTable">
<thead>
<tr style="border-bottom:2px solid #1f4e79">
  <th style="text-align:left;padding:10px;width:200px;background:#f8f9fa;color:#1f4e79">Resource</th>
  <th style="text-align:left;padding:10px;width:220px;background:#f8f9fa;color:#1f4e79">Used &nbsp;<small style="font-weight:400;color:#888">/ Available of Total</small></th>
  <th style="text-align:left;padding:10px;background:#f8f9fa;color:#1f4e79">Usage &nbsp;<small style="font-weight:400;color:#888">% of pool &mdash; spike = current snapshot</small></th>
</tr>
</thead>
<tbody>
<tr style="border-bottom:1px solid #eee" data-role="worker">
  <td style="padding:12px 10px"><b>CPU</b><br><small style="color:#888;font-size:11px">${WORKER_NODES} worker nodes</small></td>
  <td style="padding:12px 10px">
    <div style="font-size:20px;color:#2e75b6;font-weight:700">${UTIL_CPU_USED} cores</div>
    <div style="font-size:11px;color:#555;margin-top:3px">${WORKER_CPU_AVAIL} cores free &nbsp;&bull;&nbsp; <b>${WORKER_CPU}</b> total worker</div>
  </td>
  <td style="padding:12px 10px">
    <canvas id="sparkCpu" height="50" style="width:100%;display:block"></canvas>
    <div style="font-size:11px;color:#555;margin-top:2px">${WORKER_CPU_BAR}% utilized</div>
  </td>
</tr>
<tr style="border-bottom:1px solid #eee" data-role="worker">
  <td style="padding:12px 10px"><b>Memory</b><br><small style="color:#888;font-size:11px">${WORKER_NODES} worker nodes</small></td>
  <td style="padding:12px 10px">
    <div style="font-size:20px;color:#2e75b6;font-weight:700">${UTIL_MEM_USED_GIB} GiB</div>
    <div style="font-size:11px;color:#555;margin-top:3px">${WORKER_MEM_AVAIL} GiB free &nbsp;&bull;&nbsp; <b>${WORKER_MEM_GIB}</b> GiB total</div>
  </td>
  <td style="padding:12px 10px">
    <canvas id="sparkMem" height="50" style="width:100%;display:block"></canvas>
    <div style="font-size:11px;color:#555;margin-top:2px">${WORKER_MEM_BAR}% utilized</div>
  </td>
</tr>
<tr style="border-bottom:1px solid #eee" data-role="all">
  <td style="padding:12px 10px"><b>Filesystem</b><br><small style="color:#888;font-size:11px">node root disk (OS + images + pods)</small></td>
  <td style="padding:12px 10px">
    <div style="font-size:20px;color:#2e75b6;font-weight:700">${UTIL_FS_USED_TIB} TiB</div>
    <div style="font-size:11px;color:#555;margin-top:3px">${UTIL_FS_AVAIL_TIB} TiB free &nbsp;&bull;&nbsp; <b>${UTIL_FS_TOTAL_TIB}</b> TiB total</div>
  </td>
  <td style="padding:12px 10px">
    <canvas id="sparkFs" height="50" style="width:100%;display:block"></canvas>
    <div style="font-size:11px;color:#555;margin-top:2px">${UTIL_FS_BAR}% utilized</div>
  </td>
</tr>
<tr style="border-bottom:1px solid #eee" data-role="worker">
  <td style="padding:12px 10px"><b>Pod Ephemeral Storage</b><br><small style="color:#888;font-size:11px">disk used by pods (emptyDir, logs, overlayfs)</small></td>
  <td style="padding:12px 10px">
    <div style="font-size:20px;color:#2e75b6;font-weight:700">${UTIL_EPHEM_POD_GIB} GiB</div>
    <div style="font-size:11px;color:#555;margin-top:3px">${EPHEM_ALLOC_GIB} GiB allocatable &nbsp;&bull;&nbsp; OS: ${EPHEM_USED_GIB} GiB reserved</div>
  </td>
  <td style="padding:12px 10px">
    <canvas id="sparkEphem" height="50" style="width:100%;display:block"></canvas>
    <div style="font-size:11px;color:#555;margin-top:2px">${EPHEM_POD_PCT}% utilized</div>
  </td>
</tr>
<tr style="border-bottom:1px solid #eee" data-role="all">
  <td style="padding:12px 10px"><b>Network transfer</b></td>
  <td style="padding:12px 10px">
    <div style="font-size:15px;color:#2e75b6;font-weight:700">&#8593; ${UTIL_NET_TX} MBps out</div>
    <div style="font-size:15px;color:#2e75b6;font-weight:700;margin-top:4px">&#8595; ${UTIL_NET_RX} MBps in</div>
  </td>
  <td style="padding:12px 10px">
    <canvas id="sparkNet" height="50" style="width:100%;display:block"></canvas>
    <div style="font-size:11px;color:#555;margin-top:2px">TX&nbsp;<b>${UTIL_NET_TX}</b> / RX&nbsp;<b>${UTIL_NET_RX}</b> MBps</div>
  </td>
</tr>
<tr data-role="all">
  <td style="padding:12px 10px"><b>Pod count</b></td>
  <td style="padding:12px 10px">
    <div style="font-size:20px;color:#2e75b6;font-weight:700">${UTIL_PODS_RUNNING}</div>
    <div style="font-size:11px;color:#555;margin-top:3px">running pods across all namespaces</div>
  </td>
  <td style="padding:12px 10px">
    <canvas id="sparkPods" height="50" style="width:100%;display:block"></canvas>
  </td>
</tr>
</tbody>
</table>

<script>
/* ── Sparkline helper ── draws a spike chart with a single data point ── */
(function(){
  const snap = new Date().toLocaleString();
  const el = document.getElementById('utilSnapshotTime');
  if(el) el.textContent = snap;

  function sparkline(id, pct, color, maxLabel) {
    const canvas = document.getElementById(id);
    if (!canvas) return;
    canvas.width = canvas.offsetWidth || 400;
    const W = canvas.width, H = 50;
    const ctx = canvas.getContext('2d');

    /* background */
    ctx.fillStyle = '#f8f9fa';
    ctx.fillRect(0,0,W,H);

    /* simulate a few historical noise points around the current value */
    const noise = [0.85,0.90,0.88,0.92,0.87,0.91,0.89,0.93,0.90,1.0];
    const pts = noise.map((n,i) => ({
      x: Math.round(i * (W-1) / (noise.length-1)),
      y: Math.round(H - (pct * n / 100) * (H - 6) - 3)
    }));

    /* filled area */
    ctx.beginPath();
    ctx.moveTo(pts[0].x, H);
    pts.forEach(p => ctx.lineTo(p.x, p.y));
    ctx.lineTo(pts[pts.length-1].x, H);
    ctx.closePath();
    ctx.fillStyle = color + '33';
    ctx.fill();

    /* line */
    ctx.beginPath();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    pts.forEach((p,i) => i===0 ? ctx.moveTo(p.x,p.y) : ctx.lineTo(p.x,p.y));
    ctx.stroke();

    /* spike marker at current (last) point */
    const last = pts[pts.length-1];
    ctx.beginPath();
    ctx.arc(last.x, last.y, 4, 0, 2*Math.PI);
    ctx.fillStyle = color;
    ctx.fill();

    /* dotted threshold line at 80% */
    const thresh = Math.round(H - 0.80 * (H-6) - 3);
    ctx.setLineDash([4,3]);
    ctx.strokeStyle = '#e67e22';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, thresh);
    ctx.lineTo(W, thresh);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  /* draw after layout is done */
  window.addEventListener('load', function(){
    sparkline('sparkCpu',   ${WORKER_CPU_BAR},  '#2e75b6');
    sparkline('sparkMem',   ${WORKER_MEM_BAR},  '#16a085');
    sparkline('sparkFs',    ${UTIL_FS_BAR},     '#7d3c98');
    sparkline('sparkEphem', ${EPHEM_POD_PCT},   '#d35400');
    sparkline('sparkNet',   ${UTIL_NET_TX_BAR}, '#2e75b6');
    sparkline('sparkPods',  Math.min(${UTIL_PODS_RUNNING}/10, 100), '#5ba4cf');
  });
})();

function applyUtilFilter() {
  const sel = document.getElementById('utilNodeFilter').value;
  const rows = document.querySelectorAll('#utilTable tbody tr[data-role]');
  rows.forEach(function(r){
    const role = r.getAttribute('data-role');
    r.style.display = (sel === 'all' || role === 'all' || role === sel) ? '' : 'none';
  });
}
</script>
</div>




<div class="card">

<h2>Growth Forecast (vs Worker Pool)</h2>
<p style="color:#555;font-size:13px">Safe threshold = 80% of worker capacity (<b>${WORKER_CPU}</b> cores across <b>${WORKER_NODES}</b> workers)</p>

<table>
<tr>
<th>Scenario</th>
<th>CPU % of Workers</th>
<th>Memory % of Workers</th>
<th>Status</th>
</tr>

EOF




#############################################
# Growth Forecast Table
#############################################


for SCENARIO in \
current \
growth_25 \
growth_50 \
growth_75 \
growth_100

do


if [[ "${SCENARIO}" == "current" ]]
then
    DISPLAY="Current (now)"
else
    DISPLAY=$(echo "${SCENARIO}" | sed 's/growth_/+/')
    DISPLAY="${DISPLAY}% growth"
fi



CPU_VALUE=$(jq -r  ".${SCENARIO}.cpu_pct_of_workers  // 0" "${GROWTH_FILE}")
MEM_VALUE=$(jq -r  ".${SCENARIO}.memory_pct_of_workers // 0" "${GROWTH_FILE}")
STATUS=$(jq -r     ".${SCENARIO}.status // \"safe\""       "${GROWTH_FILE}")
CPU_REQ=$(jq -r    ".${SCENARIO}.cpu_request // 0"         "${GROWTH_FILE}")
MEM_REQ=$(jq -r    ".${SCENARIO}.memory_request_gb // 0"   "${GROWTH_FILE}")

# Cap bar width at 100%
CPU_BAR=$(awk "BEGIN{v=${CPU_VALUE};print (v>100)?100:v}")

cat >> "${REPORT_FILE}" <<EOF

<tr class="row-${STATUS}">

<td><b>${DISPLAY}</b></td>

<td>
<div style="display:flex;align-items:center;gap:8px;">
  <div class="bar-wrap" style="flex:1">
    <div class="bar-fill bar-${STATUS}" style="width:${CPU_BAR}%"></div>
  </div>
  <span>${CPU_VALUE}%</span>
</div>
<small style="color:#888">${CPU_REQ} cores</small>
</td>

<td>${MEM_VALUE}%
<small style="color:#888">(${MEM_REQ} GB)</small>
</td>

<td><span class="badge-${STATUS}">${STATUS}</span></td>

</tr>

EOF


done




cat >> "${REPORT_FILE}" <<EOF


</table>


</div>





<div class="card">
<h2>Capacity Planning — Worker Pool</h2>

<div class="pressure-box pressure-${PRESSURE}">
  Pressure Level: ${PRESSURE} &nbsp;|&nbsp; ${ACTION}
</div>

<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>Worker Nodes</td><td><b>${WORKER_NODES}</b> nodes</td></tr>
<tr><td>Worker CPU Capacity</td><td><b>${WORKER_CPU}</b> cores</td></tr>
<tr><td>Worker Memory Capacity</td><td><b>${WORKER_MEM}</b> GB</td></tr>
<tr><td>CPU Requested (% of workers)</td><td><b>${CPU_WORKER_PCT}%</b>
  <div class="bar-wrap"><div class="bar-fill bar-$(
    awk "BEGIN{
      p=${CPU_WORKER_PCT}
      if(p>90) print \"critical\"
      else if(p>80) print \"at_risk\"
      else print \"safe\"
    }")" style="width:$(awk "BEGIN{v=${CPU_WORKER_PCT};print (v>100)?100:v}")%"></div></div>
</td></tr>
<tr><td>Memory Requested (% of workers)</td><td><b>${MEM_WORKER_PCT}%</b></td></tr>
<tr><td><b>CPU Headroom (safe threshold)</b></td><td><b>${CPU_HEADROOM} cores</b> &nbsp;≈ ${EQUIV_NODES} nodes</td></tr>
<tr><td>Memory Headroom</td><td>${MEM_HEADROOM} GB</td></tr>
<tr><td>Worker Nodes Needed Now</td><td>${NODES_NEEDED}</td></tr>
</table>

</div>



EOF

cat >> "${REPORT_FILE}" <<EOF

<div style="margin:28px 0 18px;padding:14px 22px;background:linear-gradient(135deg,#4a235a,#6c3483);border-radius:10px;color:#fff;display:flex;align-items:center;gap:12px">
  <span style="font-size:1.6rem">&#9881;</span>
  <div>
    <div style="font-size:1rem;font-weight:700;letter-spacing:.04em">Infrastructure Overview</div>
    <div style="font-size:.78rem;opacity:.85;margin-top:2px">Platform namespace resource requests &amp; utilization &mdash; openshift-*, kube-*, and other system namespaces</div>
  </div>
</div>

<!-- Infra Summary Pills -->
<div style="display:flex;flex-wrap:wrap;gap:12px;margin-bottom:18px">
  <div style="background:#f5eef8;border:1px solid #d2b4de;border-radius:8px;padding:10px 18px;text-align:center;min-width:130px">
    <div style="font-size:22px;font-weight:700;color:#6c3483">${INFRA_NS_COUNT}</div>
    <div style="font-size:11px;color:#7d3c98;margin-top:2px;font-weight:600">Infra Namespaces</div>
  </div>
  <div style="background:#f5eef8;border:1px solid #d2b4de;border-radius:8px;padding:10px 18px;text-align:center;min-width:130px">
    <div style="font-size:22px;font-weight:700;color:#6c3483">${INFRA_CPU_TOTAL}</div>
    <div style="font-size:11px;color:#7d3c98;margin-top:2px;font-weight:600">CPU Cores Requested</div>
  </div>
  <div style="background:#f5eef8;border:1px solid #d2b4de;border-radius:8px;padding:10px 18px;text-align:center;min-width:130px">
    <div style="font-size:22px;font-weight:700;color:#6c3483">${INFRA_MEM_TOTAL}</div>
    <div style="font-size:11px;color:#7d3c98;margin-top:2px;font-weight:600">Memory GiB Requested</div>
  </div>
</div>

<!-- Infra Chart Card -->
<div class="card">
  <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:10px">
    <div>
      <h2 style="margin:0">Infra Namespace CPU &amp; Memory</h2>
      <p style="color:#555;font-size:12px;margin:4px 0 0">CPU cores (purple) and Memory GiB (indigo) requested per infra namespace. Filter to zoom in.</p>
    </div>
    <div style="display:flex;align-items:center;gap:8px">
      <label style="font-size:12px;font-weight:600;color:#4a235a" for="infraFilter">&#128269; Filter namespace:</label>
      <input id="infraFilter" type="text" placeholder="e.g. openshift-monitoring"
        style="padding:5px 10px;border:1px solid #d2b4de;border-radius:6px;font-size:12px;width:200px;outline:none"
        oninput="filterInfraChart(this.value)">
      <button onclick="filterInfraChart('');document.getElementById('infraFilter').value=''"
        style="padding:5px 10px;border:1px solid #d2b4de;border-radius:6px;font-size:12px;background:#f5eef8;color:#6c3483;cursor:pointer">Reset</button>
    </div>
  </div>
  <div id="infraDetailPanel" style="display:none;margin-bottom:12px;padding:12px 18px;background:#f5eef8;border:1px solid #d2b4de;border-radius:8px"></div>
  <canvas id="infraChart" style="max-height:340px"></canvas>
</div>

EOF

cat >> "${REPORT_FILE}" <<'TENANT_CHARTS'

<div style="margin:28px 0 18px;padding:14px 22px;background:linear-gradient(135deg,#1a5276,#117a65);border-radius:10px;color:#fff;display:flex;align-items:center;gap:12px">
  <span style="font-size:1.6rem">&#127970;</span>
  <div>
    <div style="font-size:1rem;font-weight:700;letter-spacing:.04em">Tenant Workload Analysis</div>
    <div style="font-size:.78rem;opacity:.85;margin-top:2px">Resource consumption, chargeback and PVC usage &mdash; tenant namespaces only</div>
  </div>
</div>

<!-- ── Tenant namespace filter controls ── -->
<div class="card" style="margin:0 0 16px;padding:14px 18px;background:#f0f7ff;border:1px solid #bcd4f0">
  <div style="display:flex;flex-wrap:wrap;align-items:center;gap:14px">
    <div style="display:flex;align-items:center;gap:8px">
      <label style="font-size:12px;font-weight:700;color:#1f4e79" for="tenantNsFilter">&#128269; Namespace:</label>
      <select id="tenantNsFilter" onchange="filterTenantNs(this.value)"
        style="padding:5px 10px;border:1px solid #bcd4f0;border-radius:6px;font-size:12px;min-width:220px;background:#fff">
        <option value="">All Namespaces</option>
      </select>
    </div>
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <span style="font-size:12px;color:#444">
        <span style="color:#2e75b6;font-weight:600">&#9646; CPU Requested</span> &nbsp;vs&nbsp;
        <span style="color:#e67e22;font-weight:600">&#9646; CPU Actual</span> &nbsp;&nbsp;
        <span style="color:#16a085;font-weight:600">&#9646; Mem Requested</span> &nbsp;vs&nbsp;
        <span style="color:#e74c3c;font-weight:600">&#9646; Mem Actual</span>
        &nbsp;&mdash;&nbsp; Utilization = Actual &divide; Requested &times; 100
      </span>
    </div>
  </div>
</div>

<!-- ── Namespace detail stats panel (shown when a namespace is selected) ── -->
<div id="nsDetailPanel" style="display:none;margin-bottom:16px;padding:14px 20px;background:#fff8e1;border:1px solid #ffe082;border-radius:8px">
  <div style="display:flex;flex-wrap:wrap;gap:24px;align-items:flex-start">
    <div style="min-width:180px">
      <div><span style="font-size:13px;font-weight:700;color:#5d4037">&#9432; Namespace: </span><span id="nsDetailName" style="font-size:14px;font-weight:700;color:#1f4e79"></span></div>
      <!-- Calculation legend -->
      <div style="margin-top:10px;padding:8px 10px;background:#fff3cd;border-left:3px solid #ffc107;border-radius:0 4px 4px 0;font-size:11px;color:#5d4037;line-height:1.7">
        <div><b>% util</b> = Actual Used &divide; Requested &times; 100</div>
        <div style="margin-top:1px;color:#888;font-style:italic">How efficiently the namespace uses what it reserved</div>
        <div style="margin-top:6px"><b>% of pool</b> = Namespace Requests &divide; Total Worker Capacity &times; 100</div>
        <div style="margin-top:1px;color:#888;font-style:italic">This namespace&apos;s share of the entire cluster</div>
        <div style="margin-top:6px;border-top:1px dashed #e0c060;padding-top:5px">
          <span style="color:#1a7f37;font-weight:700">&#9646; green</span> 50&ndash;90% util &nbsp;
          <span style="color:#d35400;font-weight:700">&#9646; amber</span> &lt;50% over-provisioned &nbsp;
          <span style="color:#c0392b;font-weight:700">&#9646; red</span> &gt;90% tight
        </div>
      </div>
    </div>
    <div style="display:flex;gap:24px;flex-wrap:wrap">
      <div>
        <div style="font-size:11px;color:#666;margin-bottom:3px" title="Total CPU cores reserved via pod requests in this namespace">CPU Requested</div>
        <div style="font-size:16px;font-weight:700;color:#2e75b6"><span id="nsDetailCpu"></span> cores</div>
        <div style="display:flex;align-items:center;gap:6px;margin-top:4px">
          <div style="width:120px;height:8px;background:#e0e0e0;border-radius:4px"><div id="nsDetailCpuBar" style="height:8px;border-radius:4px;background:#d35400;transition:width .4s,background .4s"></div></div>
          <span id="nsDetailCpuPct" style="font-size:11px;font-weight:700" title="Bar = % util (actual/requested). Text shows both utilization and pool share."></span>
        </div>
      </div>
      <div>
        <div style="font-size:11px;color:#666;margin-bottom:3px" title="Total memory GiB reserved via pod requests in this namespace">Memory Requested</div>
        <div style="font-size:16px;font-weight:700;color:#16a085"><span id="nsDetailMem"></span> GiB</div>
        <div style="display:flex;align-items:center;gap:6px;margin-top:4px">
          <div style="width:120px;height:8px;background:#e0e0e0;border-radius:4px"><div id="nsDetailMemBar" style="height:8px;border-radius:4px;background:#d35400;transition:width .4s,background .4s"></div></div>
          <span id="nsDetailMemPct" style="font-size:11px;font-weight:700" title="Bar = % util (actual/requested). Text shows both utilization and pool share."></span>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ── Tenant Namespace: Requested vs Actual Used (full width) ── -->
<div class="card" style="margin-bottom:20px">
  <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:6px;flex-wrap:wrap;gap:8px">
    <div>
      <h2 style="margin:0">Tenant Namespace CPU &amp; Memory</h2>
      <p style="color:#555;font-size:12px;margin:4px 0 0" id="nsChartSubtitle">
        All tenant namespaces &mdash;
        <span style="color:#2e75b6;font-weight:600">&#9646; CPU Reserved</span>
        vs <span style="color:#e67e22;font-weight:600">&#9646; CPU Actual Used</span> &nbsp;&nbsp;
        <span style="color:#16a085;font-weight:600">&#9646; Mem Reserved</span>
        vs <span style="color:#e74c3c;font-weight:600">&#9646; Mem Actual Used</span>
        &mdash; Utilization = Actual &divide; Reserved &times; 100
      </p>
    </div>
  </div>
  <canvas id="namespaceChart" style="max-height:400px"></canvas>
</div>

<!-- ── Row 2: Top CPU Consumers  |  Top Memory Consumers ── -->
<div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:20px">
<div class="card" style="margin:0">
  <h2>Top 10 CPU Consumers (Tenant)</h2>
  <p style="color:#555;font-size:12px;margin-bottom:8px">CPU cores requested &mdash; tenant namespaces only, color-coded by intensity</p>
  <canvas id="cpuChart" style="max-height:240px"></canvas>
</div>
<div class="card" style="margin:0">
  <h2>Top 10 Memory Consumers (Tenant)</h2>
  <p style="color:#555;font-size:12px;margin-bottom:8px">Memory GiB requested &mdash; tenant namespaces only, color-coded by intensity</p>
  <canvas id="memoryChart" style="max-height:240px"></canvas>
</div>
</div>

TENANT_CHARTS




#############################################
# Chargeback by Namespace
#############################################

if [[ -f "${CHARGEBACK_FILE}" ]]
then

CHARGEBACK_ROWS=$(awk -F',' '
NR>1 {
    type=$2
    badge=(type=="tenant") ? "type-tenant" : "type-infra"
    pct=$6
    cpu_util = $10+0
    mem_util = $11+0
    util_color = (cpu_util>90)?"#c0392b":(cpu_util>50)?"#1a7f37":"#d35400"

    # Row background: infra = soft lavender; tenant alternates white / pale blue
    if (type == "infra") {
        row_bg = "#f3e8ff"   # light purple for infra rows
    } else {
        tenant_row++
        row_bg = (tenant_row % 2 == 0) ? "#eaf4fb" : "#ffffff"
    }

    printf "<tr style=\"background:%s;border-bottom:1px solid #e0e0e0\"><td style=\"padding:8px 10px\">%s</td><td style=\"padding:8px 10px\"><span class=\"%s\">%s</span></td><td style=\"padding:8px 10px\">%s</td><td style=\"padding:8px 10px\">%.3f</td><td style=\"padding:8px 10px\">%.3f</td><td style=\"padding:8px 10px\"><b style=\"color:%s\">%.1f%%</b></td><td style=\"padding:8px 10px\">%.2f</td><td style=\"padding:8px 10px\">%.3f</td><td style=\"padding:8px 10px\"><b style=\"color:%s\">%.1f%%</b></td></tr>\n",
        row_bg, $1, badge, type, $3, $4+0, $8+0, util_color, cpu_util, $5+0, $9+0, util_color, mem_util
}
' "${CHARGEBACK_FILE}")

cat >> "${REPORT_FILE}" <<EOF

<div class="card">
<h2>Chargeback by Namespace</h2>
<p style="color:#555;font-size:13px">Chargeback unit = CPU cores reserved (requests &times; running replicas). Infra namespaces are platform overhead &mdash; not billed to individual teams.</p>
<!-- Calculation legend -->
<div style="display:flex;flex-wrap:wrap;gap:10px;margin:10px 0 14px;font-size:12px">
  <div style="padding:8px 14px;background:#eaf4fb;border-left:3px solid #2e75b6;border-radius:0 4px 4px 0;line-height:1.7">
    <b>CPU / Mem Reserved</b><br>
    <span style="color:#555">= Sum of all pod <code>requests</code> in the namespace<br>(each running replica counted individually)</span>
  </div>
  <div style="padding:8px 14px;background:#eafaf1;border-left:3px solid #1a7f37;border-radius:0 4px 4px 0;line-height:1.7">
    <b>CPU / Mem Actual</b><br>
    <span style="color:#555">= Real-time usage from Metrics Server<br>(0 if Prometheus / metrics-server unavailable)</span>
  </div>
  <div style="padding:8px 14px;background:#fef9e7;border-left:3px solid #f39c12;border-radius:0 4px 4px 0;line-height:1.7">
    <b>% Util</b> = Actual &divide; Reserved &times; 100<br>
    <span style="color:#555">Efficiency: 100% = using exactly what was reserved</span><br>
    <span style="color:#1a7f37;font-weight:600">&#9646; 50&ndash;90%</span> healthy &nbsp;
    <span style="color:#d35400;font-weight:600">&#9646; &lt;50%</span> over-provisioned &nbsp;
    <span style="color:#c0392b;font-weight:600">&#9646; &gt;90%</span> tight / throttle risk
  </div>
  <div style="padding:8px 14px;background:#f3e8ff;border-left:3px solid #7d3c98;border-radius:0 4px 4px 0;line-height:1.7">
    <b>Row colors</b><br>
    <span style="display:inline-block;width:12px;height:12px;background:#f3e8ff;border:1px solid #d2b4de;vertical-align:middle;margin-right:4px"></span>Lavender = infra (platform overhead)<br>
    <span style="display:inline-block;width:12px;height:12px;background:#eaf4fb;border:1px solid #bce0f5;vertical-align:middle;margin-right:4px"></span>Blue stripe = tenant (even rows)<br>
    <span style="display:inline-block;width:12px;height:12px;background:#fff;border:1px solid #ddd;vertical-align:middle;margin-right:4px"></span>White = tenant (odd rows)
  </div>
</div>

<table>
<tr>
<th>Namespace</th>
<th>Type</th>
<th>Pods</th>
<th>CPU Reserved</th>
<th>CPU Actual</th>
<th>CPU Util %</th>
<th>Mem Reserved (GB)</th>
<th>Mem Actual (GB)</th>
<th>Mem Util %</th>
</tr>
${CHARGEBACK_ROWS}
</table>

</div>

EOF

fi



#############################################
# Tenant Project Cards
#############################################

if [[ -f "${CHARGEBACK_FILE}" ]]
then

# Count tenant namespaces
TENANT_NS_COUNT=$(awk -F',' 'NR>1 && $2=="tenant" {c++} END{print c+0}' "${CHARGEBACK_FILE}")

if [[ "${TENANT_NS_COUNT}" -gt 0 ]]; then

cat >> "${REPORT_FILE}" <<EOF

<div class="card">
<h2>Tenant Projects</h2>
<p style="color:#555;font-size:13px">
  <b>${TENANT_NS_COUNT}</b> tenant namespace(s) &nbsp;&bull;&nbsp;
  <b>Utilization = Actual CPU Used &divide; CPU Reserved &times; 100</b>
  (from Metrics Server / Prometheus).
  Card border: <span style="color:#1a7f37;font-weight:600">green</span> = 50&ndash;90% util (healthy) &nbsp;
  <span style="color:#d35400;font-weight:600">amber</span> = &lt;50% (over-provisioned) &nbsp;
  <span style="color:#c0392b;font-weight:600">red</span> = &gt;90% (tight, risk of throttling) &nbsp;
  <span style="color:#2e75b6;font-weight:600">blue</span> = Prometheus unavailable.
</p>
<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px;margin-top:12px">
EOF

awk -F',' '
NR>1 && $2=="tenant" {
    ns       = $1; gsub(/"/, "", ns)
    pods     = $3+0
    cpu_req  = $4+0
    mem_req  = $5+0
    cpu_act  = $8+0
    mem_act  = $9+0
    cpu_util = $10+0   # actual / requested × 100
    mem_util = $11+0
    has_actual = (cpu_act > 0 || mem_act > 0)

    # Utilization-based color thresholds:
    # >90% = tight (risk of throttling)   → red
    # 50-90% = healthy                    → green
    # <50% = over-provisioned             → amber (wasting reserved quota)
    if (has_actual) {
        if (cpu_util > 90)      color = "#c0392b"
        else if (cpu_util > 50) color = "#1a7f37"
        else                    color = "#d35400"
    } else {
        color = "#2e75b6"   # blue = no Prometheus data
    }

    # Bar width for util% (capped at 100)
    cpu_bar = (cpu_util > 100) ? 100 : cpu_util
    mem_bar = (mem_util > 100) ? 100 : mem_util

    printf "<div style=\"background:#fff;border:1px solid #e0e0e0;border-top:4px solid %s;border-radius:8px;padding:14px;\">\n", color
    printf "  <div style=\"display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:10px\">\n"
    printf "    <span style=\"font-weight:700;font-size:14px;color:#1f4e79;word-break:break-all\">%s</span>\n", ns
    printf "    <span style=\"font-size:11px;padding:2px 8px;border-radius:8px;background:#dbeafe;color:#1e40af;white-space:nowrap;margin-left:6px\">%d pods</span>\n", pods
    printf "  </div>\n"

    printf "  <table style=\"width:100%%;font-size:12px;border-collapse:collapse\">\n"

    # ── CPU block ──
    printf "  <tr><td style=\"color:#555;padding:2px 0\">CPU Reserved</td>"
    printf "      <td style=\"text-align:right;font-weight:700;color:#2e75b6\">%.3f cores</td></tr>\n", cpu_req
    if (has_actual) {
        printf "  <tr><td style=\"color:#555;padding:2px 0\">CPU Actual Used</td>"
        printf "      <td style=\"text-align:right;font-weight:700;color:#e67e22\">%.3f cores</td></tr>\n", cpu_act
        printf "  <tr><td colspan=\"2\" style=\"padding-bottom:6px\">\n"
        printf "    <div style=\"display:flex;align-items:center;gap:6px\">\n"
        printf "      <div style=\"flex:1;background:#e9ecef;border-radius:4px;height:8px\">\n"
        printf "        <div style=\"width:%.1f%%;height:8px;border-radius:4px;background:%s\"></div>\n", cpu_bar, color
        printf "      </div>\n"
        printf "      <span style=\"font-size:11px;color:%s;font-weight:700;min-width:48px\">%.1f%% util</span>\n", color, cpu_util
        printf "    </div>\n"
        printf "  </td></tr>\n"
    } else {
        printf "  <tr><td colspan=\"2\" style=\"color:#888;font-size:11px;padding-bottom:6px\">Actual: Prometheus unavailable</td></tr>\n"
    }

    # ── Memory block ──
    printf "  <tr><td style=\"color:#555;padding:2px 0\">Mem Reserved</td>"
    printf "      <td style=\"text-align:right;font-weight:700;color:#16a085\">%.2f GB</td></tr>\n", mem_req
    if (has_actual) {
        printf "  <tr><td style=\"color:#555;padding:2px 0\">Mem Actual Used</td>"
        printf "      <td style=\"text-align:right;font-weight:700;color:#e74c3c\">%.2f GB</td></tr>\n", mem_act
        if (mem_util > 90)      mem_color = "#c0392b"
        else if (mem_util > 50) mem_color = "#1a7f37"
        else                    mem_color = "#d35400"
        printf "  <tr><td colspan=\"2\">\n"
        printf "    <div style=\"display:flex;align-items:center;gap:6px\">\n"
        printf "      <div style=\"flex:1;background:#e9ecef;border-radius:4px;height:8px\">\n"
        printf "        <div style=\"width:%.1f%%;height:8px;border-radius:4px;background:%s\"></div>\n", mem_bar, mem_color
        printf "      </div>\n"
        printf "      <span style=\"font-size:11px;color:%s;font-weight:700;min-width:48px\">%.1f%% util</span>\n", mem_color, mem_util
        printf "    </div>\n"
        printf "  </td></tr>\n"
    } else {
        printf "  <tr><td colspan=\"2\" style=\"color:#888;font-size:11px\">Actual: Prometheus unavailable</td></tr>\n"
    }

    printf "  </table>\n"
    printf "</div>\n"
}
' "${CHARGEBACK_FILE}" >> "${REPORT_FILE}"

cat >> "${REPORT_FILE}" <<EOF
</div>
</div>

EOF

fi
fi



#############################################
# Dedicated Node Pools
# Reads node_pools.json — generated by analyze_capacity.sh
# Only worker nodes with custom taints (e.g. app=sas:NoSchedule) are
# flagged as "dedicated"; untainted workers show as "standard-worker".
#############################################

NODE_POOLS_FILE="${CAPACITY_JSON}/node_pools.json"

if [[ -f "${NODE_POOLS_FILE}" ]]; then
    POOL_COUNT=$(jq 'length' "${NODE_POOLS_FILE}" 2>/dev/null || echo 0)
    DEDICATED_COUNT=$(jq '[.[] | select(.dedicated == true)] | length' "${NODE_POOLS_FILE}" 2>/dev/null || echo 0)
else
    DEDICATED_COUNT=0
    POOL_COUNT=0
fi

if [[ "${POOL_COUNT}" -gt 0 ]]; then

cat >> "${REPORT_FILE}" <<EOF

<div class="card">
<h2>Dedicated Worker Node Pools</h2>
<p style="color:#555;font-size:13px">
  Worker nodes are considered <b>dedicated</b> when they carry a custom taint
  (e.g. <code>app=sas:NoSchedule</code>). Only pods with a matching toleration
  can be scheduled onto those nodes, effectively reserving them for a specific workload.
  <br>
  <b>Tenant projects only</b> are shown in the last column — platform/infra namespaces
  (openshift-*, kube-*, etc.) are excluded as their DaemonSet pods run on every node.
  <br>
  <b>${DEDICATED_COUNT}</b> dedicated pool(s) &nbsp;|&nbsp;
  <b>$(( POOL_COUNT - DEDICATED_COUNT ))</b> standard worker pool(s) &nbsp;|&nbsp;
  <b>${POOL_COUNT}</b> total
</p>

<table style="width:100%;border-collapse:collapse">
<thead>
<tr style="border-bottom:2px solid #1f4e79">
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79;min-width:160px">Taint (Key=Value)</th>
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79">Effect</th>
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79">Nodes</th>
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79">CPU (cores)</th>
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79">Memory (GiB)</th>
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79">Node Names</th>
  <th style="text-align:left;padding:10px 14px;background:#f0f4f8;color:#1f4e79">Tenant Projects on Pool</th>
</tr>
</thead>
<tbody>
EOF

jq -r '
.[] |
. as $p |
# Row background: dedicated pools get a subtle blue tint; standard workers grey
(if $p.dedicated then
  "<tr style=\"border-bottom:1px solid #dbeafe;background:#f5f9ff\">"
else
  "<tr style=\"border-bottom:1px solid #eee;background:#fafafa\">"
end) +

# Column 1 — Taint / pool name
"<td style=\"padding:10px 14px\">" +
(if $p.dedicated then
  "<span style=\"display:inline-flex;align-items:center;gap:6px\">" +
  "<span style=\"display:inline-block;width:10px;height:10px;border-radius:50%;background:#2e75b6\"></span>" +
  "<b style=\"color:#1f4e79\">" + $p.taint_key + "</b>" +
  (if $p.taint_value != "" then "<span style=\"color:#555\">=</span><b style=\"color:#c0392b\">" + $p.taint_value + "</b>" else "" end) +
  "</span>" +
  "<br><small style=\"color:#888;font-size:11px;font-family:monospace\">" + $p.taint + "</small>"
else
  "<span style=\"color:#888\">&#9744; standard-worker</span>" +
  "<br><small style=\"color:#aaa;font-size:11px\">no custom taints</small>"
end) +
"</td>" +

# Column 2 — Effect badge
"<td style=\"padding:10px 14px\">" +
(if $p.effect == "NoSchedule" then
  "<span style=\"display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:700;background:#fff3cd;color:#856404\">" + $p.effect + "</span>"
elif $p.effect == "NoExecute" then
  "<span style=\"display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:700;background:#f8d7da;color:#842029\">" + $p.effect + "</span>"
elif $p.effect == "PreferNoSchedule" then
  "<span style=\"display:inline-block;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:700;background:#d4edda;color:#155724\">" + $p.effect + "</span>"
else
  "<span style=\"color:#aaa\">—</span>"
end) +
"</td>" +

# Column 3 — Node count
"<td style=\"padding:10px 14px;font-size:20px;font-weight:700;color:#2e75b6\">" +
($p.node_count | tostring) +
"</td>" +

# Column 4 — CPU
"<td style=\"padding:10px 14px\">" + ($p.cpu_cores | tostring) + "</td>" +

# Column 5 — Memory
"<td style=\"padding:10px 14px\">" + ($p.memory_gib | tostring) + " GiB</td>" +

# Column 6 — Node names (compact)
"<td style=\"padding:10px 14px;font-size:11px;font-family:monospace;color:#555\">" +
($p.nodes | map("<div>" + . + "</div>") | join("")) +
"</td>" +

# Column 7 — Projects / namespaces
"<td style=\"padding:10px 14px;font-size:12px\">" +
(if ($p.namespaces | length) > 0 then
  ($p.namespaces[:12] |
    map(
      "<span style=\"display:inline-block;margin:2px 3px;padding:2px 8px;border-radius:8px;" +
      (if .pod_count > 50 then "background:#fee2e2;color:#991b1b"
       elif .pod_count > 10 then "background:#dbeafe;color:#1e40af"
       else "background:#d1fae5;color:#065f46" end) +
      "\">" + .namespace + "&nbsp;(" + (.pod_count|tostring) + ")</span>"
    ) | join("")) +
  (if ($p.namespaces | length) > 12 then
    "<br><small style=\"color:#888\">+" + (($p.namespaces | length) - 12 | tostring) + " more namespaces</small>"
  else "" end)
else
  "<span style=\"color:#aaa\">no pods scheduled</span>"
end) +
"</td></tr>"
' "${NODE_POOLS_FILE}" >> "${REPORT_FILE}"

cat >> "${REPORT_FILE}" <<EOF
</tbody>
</table>
</div>

EOF

fi

#############################################
# PVC Inventory Section
#############################################

PVC_INVENTORY_FILE="${CAPACITY_CSV}/pvc_inventory.csv"
TOP_PVC_FILE="${CAPACITY_CSV}/top_pvc_consumers.csv"

if [[ -f "${PVC_INVENTORY_FILE}" ]]; then

# ── Summary stats (total count, total GiB, by-status counts) ──
PVC_STATS=$(awk -F',' '
NR==1 { next }
{
    gsub(/"/, "", $0)
    ns=$1; pvc=$2; status=$3; cap=$4; sc=$5
    count++
    # Convert K8s capacity to GiB
    if      (cap ~ /Ti$/) { sub(/Ti$/, "", cap); gib = cap * 1024 }
    else if (cap ~ /Gi$/) { sub(/Gi$/, "", cap); gib = cap        }
    else if (cap ~ /Mi$/) { sub(/Mi$/, "", cap); gib = cap / 1024 }
    else if (cap ~ /G$/ ) { sub(/G$/,  "", cap); gib = cap * 1000 / 1024 }
    else if (cap ~ /M$/ ) { sub(/M$/,  "", cap); gib = cap * 1000 / 1048576 }
    else                  { gib = 0 }
    total_gib += gib
    status_count[status]++
    sc_count[sc]++
    sc_gib[sc] += gib
}
END {
    printf "COUNT=%d\n", count
    printf "TOTAL_GIB=%.1f\n", total_gib
    for (s in status_count) printf "STATUS_%s=%d\n", s, status_count[s]
    for (c in sc_count)     printf "SC_COUNT_%s=%d SC_GIB_%s=%.1f\n", c, sc_count[c], c, sc_gib[c]
}' "${PVC_INVENTORY_FILE}")

# Parse summary into shell vars
PVC_COUNT_TOTAL=$(echo "${PVC_STATS}" | awk -F= '/^COUNT/{print $2}')
PVC_TOTAL_GIB=$(  echo "${PVC_STATS}" | awk -F= '/^TOTAL_GIB/{print $2}')
PVC_BOUND=$(      echo "${PVC_STATS}" | awk -F= '/^STATUS_Bound/{print $2}')
PVC_PENDING=$(    echo "${PVC_STATS}" | awk -F= '/^STATUS_Pending/{print $2}')
PVC_LOST=$(       echo "${PVC_STATS}" | awk -F= '/^STATUS_Lost/{print $2}')
PVC_RELEASED=$(   echo "${PVC_STATS}" | awk -F= '/^STATUS_Released/{print $2}')

PVC_BOUND="${PVC_BOUND:-0}"
PVC_PENDING="${PVC_PENDING:-0}"
PVC_LOST="${PVC_LOST:-0}"
PVC_RELEASED="${PVC_RELEASED:-0}"
PVC_COUNT_TOTAL="${PVC_COUNT_TOTAL:-0}"
PVC_TOTAL_GIB="${PVC_TOTAL_GIB:-0}"

# ── Storage class summary rows ──
SC_ROWS=$(awk -F',' '
NR==1 { next }
{
    gsub(/"/, "", $0)
    cap=$4; sc=$5
    if      (cap ~ /Ti$/) { sub(/Ti$/, "", cap); gib = cap * 1024 }
    else if (cap ~ /Gi$/) { sub(/Gi$/, "", cap); gib = cap        }
    else if (cap ~ /Mi$/) { sub(/Mi$/, "", cap); gib = cap / 1024 }
    else if (cap ~ /G$/ ) { sub(/G$/,  "", cap); gib = cap * 1000 / 1024 }
    else                  { gib = 0 }
    sc_count[sc]++; sc_gib[sc]  += gib
}
END {
    # Sort by total GiB descending
    n = 0
    for (c in sc_count) { keys[++n] = c }
    for (i=1; i<=n; i++) for (j=i+1; j<=n; j++)
        if (sc_gib[keys[i]] < sc_gib[keys[j]]) { t=keys[i]; keys[i]=keys[j]; keys[j]=t }
    for (i=1; i<=n; i++)
        printf "<tr><td class=\"mono\">%s</td><td>%d</td><td>%.1f GiB</td></tr>\n",
               keys[i], sc_count[keys[i]], sc_gib[keys[i]]
}' "${PVC_INVENTORY_FILE}")

# ── Top PVC consumers rows ──
TOP_PVC_ROWS=""
if [[ -f "${TOP_PVC_FILE}" ]]; then
TOP_PVC_ROWS=$(awk -F',' '
NR==1 { next }
{
    gsub(/"/, "", $0)
    ns=$1; pvc=$2; cap=$3
    printf "<tr><td>%s</td><td class=\"mono\">%s</td><td><b>%s</b></td></tr>\n",
           ns, pvc, cap
}' "${TOP_PVC_FILE}")
fi

# ── Full PVC inventory rows (grouped by namespace) ──
PVC_ROWS=$(awk -F',' '
NR==1 { next }
{
    gsub(/"/, "", $0)
    ns=$1; pvc=$2; status=$3; cap=$4; sc=$5
    color=(status=="Bound")?"#1e6823":(status=="Pending")?"#9a6700":(status=="Lost")?"#b31d28":"#555"
    badge_bg=(status=="Bound")?"#dcffe4":(status=="Pending")?"#fff3cd":(status=="Lost")?"#ffeef0":"#f1f1f1"
    printf "<tr><td>%s</td><td class=\"mono\">%s</td><td><span style=\"padding:1px 7px;border-radius:4px;font-size:11px;font-weight:600;background:%s;color:%s\">%s</span></td><td><b>%s</b></td><td class=\"mono\" style=\"font-size:12px\">%s</td></tr>\n",
           ns, pvc, badge_bg, color, status, cap, sc
}' "${PVC_INVENTORY_FILE}")

cat >> "${REPORT_FILE}" <<EOF

<div class="card">
<h2>Persistent Volume Claims (PVC) Inventory</h2>
<p style="color:#555;font-size:13px">All PVCs collected across namespaces. Capacity shown as requested by the PVC spec.</p>

<!-- Summary pills -->
<div style="display:flex;flex-wrap:wrap;gap:10px;margin-bottom:16px">
  <div style="background:#f0f4ff;border:1px solid #c9d6f5;border-radius:8px;padding:10px 18px;text-align:center">
    <div style="font-size:22px;font-weight:700;color:#1f4e79">${PVC_COUNT_TOTAL}</div>
    <div style="font-size:12px;color:#555;margin-top:2px">Total PVCs</div>
  </div>
  <div style="background:#f0f4ff;border:1px solid #c9d6f5;border-radius:8px;padding:10px 18px;text-align:center">
    <div style="font-size:22px;font-weight:700;color:#1f4e79">${PVC_TOTAL_GIB} GiB</div>
    <div style="font-size:12px;color:#555;margin-top:2px">Total Requested</div>
  </div>
  <div style="background:#dcffe4;border:1px solid #a3d9a5;border-radius:8px;padding:10px 18px;text-align:center">
    <div style="font-size:22px;font-weight:700;color:#1e6823">${PVC_BOUND}</div>
    <div style="font-size:12px;color:#555;margin-top:2px">Bound</div>
  </div>
  <div style="background:#fff3cd;border:1px solid #f5d87a;border-radius:8px;padding:10px 18px;text-align:center">
    <div style="font-size:22px;font-weight:700;color:#9a6700">${PVC_PENDING}</div>
    <div style="font-size:12px;color:#555;margin-top:2px">Pending</div>
  </div>
  <div style="background:#ffeef0;border:1px solid #f5b8be;border-radius:8px;padding:10px 18px;text-align:center">
    <div style="font-size:22px;font-weight:700;color:#b31d28">${PVC_LOST}</div>
    <div style="font-size:12px;color:#555;margin-top:2px">Lost</div>
  </div>
  <div style="background:#f1f1f1;border:1px solid #ccc;border-radius:8px;padding:10px 18px;text-align:center">
    <div style="font-size:22px;font-weight:700;color:#555">${PVC_RELEASED}</div>
    <div style="font-size:12px;color:#555;margin-top:2px">Released</div>
  </div>
</div>

<!-- Two-column: Storage Classes | Top Consumers -->
<div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:20px">

  <div>
  <h3 style="font-size:14px;margin-bottom:8px;color:#1f4e79">By Storage Class</h3>
  <table>
  <tr><th>Storage Class</th><th>PVC Count</th><th>Total Capacity</th></tr>
  ${SC_ROWS}
  </table>
  </div>

  <div>
  <h3 style="font-size:14px;margin-bottom:8px;color:#1f4e79">Top 10 PVC Consumers (by size)</h3>
  <table>
  <tr><th>Namespace</th><th>PVC Name</th><th>Size</th></tr>
  ${TOP_PVC_ROWS}
  </table>
  </div>

</div>

<!-- Full inventory table -->
<details>
<summary style="cursor:pointer;font-weight:600;color:#1f4e79;margin-bottom:10px;font-size:14px">
  ▶ Full PVC Inventory (${PVC_COUNT_TOTAL} PVCs)
</summary>
<table>
<tr>
  <th>Namespace</th>
  <th>PVC Name</th>
  <th>Status</th>
  <th>Capacity</th>
  <th>Storage Class</th>
</tr>
${PVC_ROWS}
</table>
</details>

</div>

EOF

fi

#############################################
# Dedicated Capacity (from analyze_dedicated_capacity.sh)
#############################################

DED_SUMMARY="${CAPACITY_JSON}/dedicated_capacity_summary.json"
DED_RECS_CSV="${CAPACITY_CSV}/dedicated_node_recommendations.csv"
DED_POOL_CSV="${CAPACITY_CSV}/dedicated_pool_capacity.csv"
DED_MISPLACED_CSV="${CAPACITY_CSV}/misplaced_dedicated_workloads.csv"
DED_GROWTH_CSV="${CAPACITY_CSV}/dedicated_growth_simulation.csv"

if [[ -f "${DED_SUMMARY}" ]]
then
  log INFO "Embedding dedicated capacity section"

  DED_WORKERS=$(jq -r '.workers.total // 0' "${DED_SUMMARY}")
  DED_DED=$(jq -r '.workers.dedicated // 0' "${DED_SUMMARY}")
  DED_SHR=$(jq -r '.workers.shared // 0' "${DED_SUMMARY}")
  DED_MISP=$(jq -r '.misplaced_dedicated_pods // 0' "${DED_SUMMARY}")
  DED_DS_CPU=$(jq -r '.daemonsets.avg_cpu_per_worker_node // 0' "${DED_SUMMARY}")
  DED_DS_MEM=$(jq -r '.daemonsets.avg_memory_gib_per_worker_node // 0' "${DED_SUMMARY}")
  DED_TGT=$(jq -r '.methodology.target_utilization_pct // 80' "${DED_SUMMARY}")

  DED_ADD_D=$(jq -r '.recommendations.desired_replicas.DEDICATED.Recommended_Nodes_To_Add // "0"' "${DED_SUMMARY}")
  DED_ADD_S=$(jq -r '.recommendations.desired_replicas.SHARED.Recommended_Nodes_To_Add // "0"' "${DED_SUMMARY}")
  DED_ADD_D_A=$(jq -r '.recommendations.actual_running.DEDICATED.Recommended_Nodes_To_Add // "0"' "${DED_SUMMARY}")
  DED_ADD_S_A=$(jq -r '.recommendations.actual_running.SHARED.Recommended_Nodes_To_Add // "0"' "${DED_SUMMARY}")
  DED_STAT_D=$(jq -r '.recommendations.desired_replicas.DEDICATED.Status // ""' "${DED_SUMMARY}")
  DED_STAT_S=$(jq -r '.recommendations.desired_replicas.SHARED.Status // ""' "${DED_SUMMARY}")
  DED_BIND_D=$(jq -r '.recommendations.desired_replicas.DEDICATED.Binding_Constraint // "—"' "${DED_SUMMARY}")
  DED_BIND_S=$(jq -r '.recommendations.desired_replicas.SHARED.Binding_Constraint // "—"' "${DED_SUMMARY}")

  DED_P_CPU=$(jq -r '.pools.DEDICATED.CPU_Request_Pct // "0"' "${DED_SUMMARY}")
  DED_P_MEM=$(jq -r '.pools.DEDICATED.Memory_Request_Pct // "0"' "${DED_SUMMARY}")
  SHR_P_CPU=$(jq -r '.pools.SHARED.CPU_Request_Pct // "0"' "${DED_SUMMARY}")
  SHR_P_MEM=$(jq -r '.pools.SHARED.Memory_Request_Pct // "0"' "${DED_SUMMARY}")
  DED_P_CREQ=$(jq -r '.pools.DEDICATED.CPU_Requests_Cores // "0"' "${DED_SUMMARY}")
  DED_P_ALLOC=$(jq -r '.pools.DEDICATED.Allocatable_CPU_Cores // "0"' "${DED_SUMMARY}")
  SHR_P_CREQ=$(jq -r '.pools.SHARED.CPU_Requests_Cores // "0"' "${DED_SUMMARY}")
  SHR_P_ALLOC=$(jq -r '.pools.SHARED.Allocatable_CPU_Cores // "0"' "${DED_SUMMARY}")

  # Recommendation table rows
  DED_REC_ROWS=""
  if [[ -f "${DED_RECS_CSV}" ]]; then
    DED_REC_ROWS=$(awk -F',' 'NR>1 {
      gsub(/"/,"");
      printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><b>%s</b></td><td>%s</td><td>%s</td></tr>\n",
        $1,$2,$3,$10,$11,$17,$18,$19
    }' "${DED_RECS_CSV}")
  fi

  DED_GROWTH_ROWS=""
  if [[ -f "${DED_GROWTH_CSV}" ]]; then
    DED_GROWTH_ROWS=$(awk -F',' 'NR>1 {
      gsub(/"/,"");
      printf "<tr><td>%s</td><td>+%s%%</td><td>%s</td><td>%s</td><td><b>%s</b></td><td>%s</td><td>%s</td></tr>\n",
        $1,$2,$3,$4,$5,$6,$7
    }' "${DED_GROWTH_CSV}")
  fi

  DED_MISP_ROWS=""
  if [[ -f "${DED_MISPLACED_CSV}" ]]; then
    DED_MISP_ROWS=$(awk -F',' 'NR>1 {
      gsub(/"/,"");
      printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",
        $1,$2,$3,$5,$6,$8
    }' "${DED_MISPLACED_CSV}" | head -50)
  fi

  DED_ADD_TOTAL=$(awk -v a="${DED_ADD_D}" -v b="${DED_ADD_S}" 'BEGIN{print (a+0)+(b+0)}')
  DED_ADD_COLOR=$(awk -v t="${DED_ADD_TOTAL}" 'BEGIN{print (t>0)?"#c0392b":"#1a7f37"}')
  MISP_COLOR=$(awk -v t="${DED_MISP}" 'BEGIN{print (t>0)?"#c0392b":"#1a7f37"}')

  cat >> "${REPORT_FILE}" <<DEDEOF

<div style="margin:24px 0 18px;padding:14px 22px;background:linear-gradient(135deg,#0f3d2e 0%,#1a7f37 100%);border-radius:10px;color:#fff;display:flex;align-items:center;gap:12px">
  <span style="font-size:1.6rem">&#128736;</span>
  <div>
    <div style="font-size:1rem;font-weight:700;letter-spacing:.04em">Dedicated Node Pools &amp; Capacity Planning</div>
    <div style="font-size:.78rem;opacity:.85;margin-top:2px">Taint-based pools · Requests vs Allocatable @ ${DED_TGT}% · DaemonSet-aware · Desired replicas</div>
  </div>
</div>

<div class="grid">
  <div class="card">
    <h3>Worker nodes</h3>
    <div class="metric" style="color:#1f4e79">${DED_WORKERS}</div>
    <p style="font-size:13px;color:#555">Dedicated ${DED_DED} · Shared ${DED_SHR}</p>
  </div>
  <div class="card">
    <h3>Add nodes (desired scale)</h3>
    <div class="metric" style="color:${DED_ADD_COLOR}">+${DED_ADD_TOTAL}</div>
    <p style="font-size:13px;color:#555">Dedicated +${DED_ADD_D} · Shared +${DED_ADD_S}</p>
  </div>
  <div class="card">
    <h3>Add nodes (running now)</h3>
    <div class="metric" style="color:#1a7f37">+$(awk -v a="${DED_ADD_D_A}" -v b="${DED_ADD_S_A}" 'BEGIN{print (a+0)+(b+0)}')</div>
    <p style="font-size:13px;color:#555">Dedicated +${DED_ADD_D_A} · Shared +${DED_ADD_S_A}</p>
  </div>
  <div class="card">
    <h3>Misplaced dedicated</h3>
    <div class="metric" style="color:${MISP_COLOR}">${DED_MISP}</div>
    <p style="font-size:13px;color:#555">Pods targeting dedicated keys on shared nodes</p>
  </div>
</div>

<div class="card">
  <h2>Request / Allocatable by pool</h2>
  <p style="color:#555;font-size:13px">Scheduler pressure. Net capacity per new node subtracts DaemonSet avg (${DED_DS_CPU} CPU, ${DED_DS_MEM} GiB per worker). Target utilization ${DED_TGT}%.</p>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
    <div style="background:#f8f0ff;border-left:4px solid #6c3483;border-radius:8px;padding:14px">
      <h3 style="margin:0 0 8px;color:#6c3483">Dedicated</h3>
      <div style="font-size:13px;margin-bottom:4px">CPU requests <b>${DED_P_CPU}%</b> (${DED_P_CREQ} / ${DED_P_ALLOC} cores)</div>
      <div style="background:#e9ecef;border-radius:6px;height:12px;margin-bottom:10px"><div style="width:$(awk "BEGIN{v=${DED_P_CPU}+0;print(v>100)?100:int(v)}")%;height:12px;border-radius:6px;background:#6c3483"></div></div>
      <div style="font-size:13px;margin-bottom:4px">Memory requests <b>${DED_P_MEM}%</b></div>
      <div style="background:#e9ecef;border-radius:6px;height:12px"><div style="width:$(awk "BEGIN{v=${DED_P_MEM}+0;print(v>100)?100:int(v)}")%;height:12px;border-radius:6px;background:#8e44ad"></div></div>
      <p style="font-size:12px;color:#666;margin-top:10px">Desired: ${DED_STAT_D} (binding: ${DED_BIND_D})</p>
    </div>
    <div style="background:#f0f7ff;border-left:4px solid #1f4e79;border-radius:8px;padding:14px">
      <h3 style="margin:0 0 8px;color:#1f4e79">Shared</h3>
      <div style="font-size:13px;margin-bottom:4px">CPU requests <b>${SHR_P_CPU}%</b> (${SHR_P_CREQ} / ${SHR_P_ALLOC} cores)</div>
      <div style="background:#e9ecef;border-radius:6px;height:12px;margin-bottom:10px"><div style="width:$(awk "BEGIN{v=${SHR_P_CPU}+0;print(v>100)?100:int(v)}")%;height:12px;border-radius:6px;background:#1f4e79"></div></div>
      <div style="font-size:13px;margin-bottom:4px">Memory requests <b>${SHR_P_MEM}%</b></div>
      <div style="background:#e9ecef;border-radius:6px;height:12px"><div style="width:$(awk "BEGIN{v=${SHR_P_MEM}+0;print(v>100)?100:int(v)}")%;height:12px;border-radius:6px;background:#2e75b6"></div></div>
      <p style="font-size:12px;color:#666;margin-top:10px">Desired: ${DED_STAT_S} (binding: ${DED_BIND_S})</p>
    </div>
  </div>
</div>

<div class="card">
  <h2>Node recommendations</h2>
  <p style="color:#555;font-size:13px"><b>Desired_Replicas</b> = Deployment/STS replicas × template Requests (planning). <b>Actual_Running</b> = current Running pod Requests.</p>
  <table>
  <tr><th>Pool</th><th>Basis</th><th>Nodes</th><th>CPU Req</th><th>Mem Req</th><th>Add</th><th>Binding</th><th>Status</th></tr>
  ${DED_REC_ROWS}
  </table>
</div>

<div class="card">
  <h2>Growth scenarios (from Running)</h2>
  <table>
  <tr><th>Pool</th><th>Growth</th><th>Projected CPU</th><th>Projected Mem</th><th>Add</th><th>Binding</th><th>Status</th></tr>
  ${DED_GROWTH_ROWS}
  </table>
</div>

<div class="card">
  <h2>Misplaced dedicated workloads</h2>
  <p style="color:#555;font-size:13px">Pods with nodeSelector/affinity targeting a dedicated taint key but Running on SHARED nodes. Toleration alone is ignored.</p>
DEDEOF

  if [[ "${DED_MISP}" -gt 0 ]]; then
    cat >> "${REPORT_FILE}" <<DEDEOF2
  <p style="color:#c0392b;font-weight:600">${DED_MISP} pod(s) appear misplaced (sample up to 50):</p>
  <table>
  <tr><th>Namespace</th><th>Pod</th><th>Node</th><th>Target Keys</th><th>CPU</th><th>Controller</th></tr>
  ${DED_MISP_ROWS}
  </table>
  <p style="font-size:12px;color:#888">Full list: <a href="csv/misplaced_dedicated_workloads.csv">misplaced_dedicated_workloads.csv</a></p>
DEDEOF2
  else
    cat >> "${REPORT_FILE}" <<'DEDEOF3'
  <p style="color:#1a7f37;font-weight:600">None detected — dedicated-targeted workloads are on dedicated nodes.</p>
DEDEOF3
  fi

  cat >> "${REPORT_FILE}" <<'DEDEOF4'
  <p style="font-size:12px;color:#888;margin-top:12px">
    Detail CSVs: dedicated_node_inventory.csv · dedicated_pool_capacity.csv · dedicated_node_recommendations.csv ·
    desired_replica_detail.csv · dedicated_growth_simulation.csv ·
    JSON: <a href="json/dedicated_capacity_summary.json">dedicated_capacity_summary.json</a>
  </p>
</div>

DEDEOF4

else
  log INFO "No dedicated_capacity_summary.json — skipping dedicated section"
fi


cat >> "${REPORT_FILE}" <<EOF

<div class="card">


<h2>
Generated Files
</h2>


<ul>


<li><a href="json/capacity_summary.json">Capacity Summary JSON</a></li>
<li><a href="json/capacity_planning.json">Capacity Planning JSON</a></li>
<li><a href="json/growth_forecast.json">Growth Forecast JSON</a></li>
<li><a href="json/chargeback.json">Chargeback JSON</a></li>
<li><a href="json/node_pools.json">Dedicated Node Pools JSON</a></li>
<li><a href="json/dedicated_capacity_summary.json">Dedicated Capacity Summary JSON</a></li>
<li><a href="json/recommendations.json">Recommendations JSON</a></li>
<li>CSV reports: <b><a href="csv/chargeback_by_namespace.csv">chargeback_by_namespace.csv</a></b> &nbsp;|&nbsp; <b><a href="csv/dedicated_node_recommendations.csv">dedicated_node_recommendations.csv</a></b> &nbsp;|&nbsp; <b><a href="csv/misplaced_dedicated_workloads.csv">misplaced_dedicated_workloads.csv</a></b> &nbsp;|&nbsp; <a href="csv/">csv/</a></li>
<li>Scheduling inventory: <a href="csv/node_inventory_detailed.csv">node inventory</a> &nbsp;|&nbsp; <a href="csv/node_taints.csv">node taints</a> &nbsp;|&nbsp; <a href="csv/pod_effective_requests.csv">effective pod requests</a> &nbsp;|&nbsp; <a href="csv/pod_tolerations.csv">pod tolerations</a> &nbsp;|&nbsp; <a href="csv/pool_capacity_detail.csv">pool capacity</a></li>


</ul>


</div>




<script>
/* ── ARO Ops Dashboard – Chart.js colour palette ── */
const PALETTE = [
  '#2e75b6','#c0392b','#27ae60','#8e44ad','#d35400',
  '#16a085','#f39c12','#2980b9','#e74c3c','#1abc9c',
  '#9b59b6','#f1c40f','#e67e22','#3498db','#95a5a6'
];

const namespaceData = ${NAMESPACE_DATA};
const infraData     = ${INFRA_NAMESPACE_DATA};


const cpuData       = ${CPU_DATA};
const memoryData    = ${MEMORY_DATA};

/* helpers */
function paletteColors(n) {
  return Array.from({length:n}, (_,i) => PALETTE[i % PALETTE.length]);
}
function alphaColors(n) {
  return Array.from({length:n}, (_,i) => PALETTE[i % PALETTE.length] + 'aa');
}

/* ── namespaceChart : Requested vs Actual Used — CPU (blue/orange) + Mem (teal/red) ── */
let nsChartInstance = null;

function buildNamespaceChart(data) {
  const ctx = document.getElementById('namespaceChart');
  if (!ctx || !data.length) return;
  if (nsChartInstance) nsChartInstance.destroy();
  const sub = document.getElementById('nsChartSubtitle');
  const hasActual = data.some(x => (x.cpuact || 0) > 0);

  if (data.length === 1) {
    /* ── Single namespace: vertical bars — CPU Req/Act + Mem Req/Act ── */
    const d = data[0];
    const util_note = hasActual
      ? ' — CPU util: ' + d.cpuutil.toFixed(1) + '% | Mem util: ' + d.memutil.toFixed(1) + '%'
      : '';
    if (sub) sub.textContent = d.name + util_note;
    nsChartInstance = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: ['CPU (cores)', 'Memory (GiB)'],
        datasets: [
          { label: 'Requested',
            data: [d.cpu, d.mem],
            backgroundColor: ['#2e75b6cc', '#16a085cc'],
            borderColor: ['#2e75b6', '#16a085'], borderWidth: 1 },
          { label: 'Actual Used',
            data: [d.cpuact || 0, d.memact || 0],
            backgroundColor: ['#e67e22cc', '#e74c3ccc'],
            borderColor: ['#e67e22', '#e74c3c'], borderWidth: 1 }
        ]
      },
      options: {
        responsive: true,
        plugins: {
          legend: { position: 'top' },
          tooltip: { callbacks: {
            footer: items => {
              if (!hasActual) return 'Actual: Prometheus unavailable';
              const i = items[0].dataIndex;
              const pct = i === 0 ? d.cpuutil : d.memutil;
              return 'Utilization: ' + pct.toFixed(1) + '% of requested';
            }
          }}
        },
        scales: {
          y: { beginAtZero: true, title: { display: true, text: 'Cores / GiB' } }
        }
      }
    });
  } else {
    /* ── Multi namespace: horizontal grouped bar — Req vs Actual ── */
    if (sub) sub.textContent = 'All tenant namespaces — '
      + 'CPU Requested (blue) vs Actual (orange) · '
      + 'Mem Requested (teal) vs Actual (red)'
      + (hasActual ? '' : ' — ⚠ Actual = 0 (Prometheus unavailable)');
    nsChartInstance = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: data.map(x => x.name),
        datasets: [
          { label: 'CPU Requested (cores)',
            data: data.map(x => x.cpu),
            backgroundColor: '#2e75b6bb', borderColor: '#2e75b6', borderWidth: 1 },
          { label: 'CPU Actual Used',
            data: data.map(x => x.cpuact || 0),
            backgroundColor: '#e67e2299', borderColor: '#e67e22', borderWidth: 1 },
          { label: 'Mem Requested (GiB)',
            data: data.map(x => x.mem),
            backgroundColor: '#16a08599', borderColor: '#16a085', borderWidth: 1 },
          { label: 'Mem Actual Used (GiB)',
            data: data.map(x => x.memact || 0),
            backgroundColor: '#e74c3c99', borderColor: '#e74c3c', borderWidth: 1 }
        ]
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        plugins: {
          legend: { position: 'top' },
          tooltip: { callbacks: {
            footer: items => {
              const idx = items[0].dataIndex;
              const d   = data[idx];
              if (!hasActual) return 'Actual: Prometheus unavailable';
              return 'CPU util: ' + (d.cpuutil||0).toFixed(1) + '% of requested'
                   + '  |  Mem util: ' + (d.memutil||0).toFixed(1) + '% of requested';
            }
          }}
        },
        scales: {
          x: { beginAtZero: true, title: { display: true, text: 'Cores / GiB' } }
        }
      }
    });
  }
}

function populateTenantDropdown() {
  const sel = document.getElementById('tenantNsFilter');
  if (!sel || !namespaceData.length) return;
  namespaceData.forEach(x => {
    const opt = document.createElement('option');
    opt.value = x.name; opt.textContent = x.name;
    sel.appendChild(opt);
  });
}

function showNsDetail(ns) {
  const panel = document.getElementById('nsDetailPanel');
  if (!ns) { if (panel) panel.style.display = 'none'; return; }
  const d = namespaceData.find(x => x.name === ns);
  if (!d || !panel) return;
  panel.style.display = 'block';
  document.getElementById('nsDetailName').textContent = ns;
  document.getElementById('nsDetailCpu').textContent  = d.cpu.toFixed(3);
  document.getElementById('nsDetailMem').textContent  = d.mem.toFixed(2);
  const cpuUtilColor = (d.cpuutil > 90) ? '#c0392b' : (d.cpuutil > 50) ? '#1a7f37' : '#d35400';
  const memUtilColor = (d.memutil > 90) ? '#c0392b' : (d.memutil > 50) ? '#1a7f37' : '#d35400';
  document.getElementById('nsDetailCpuPct').textContent = d.cpuutil.toFixed(1) + '% util  (' + d.cpupct.toFixed(2) + '% of pool)';
  document.getElementById('nsDetailCpuPct').style.color = cpuUtilColor;
  document.getElementById('nsDetailMemPct').textContent = d.memutil.toFixed(1) + '% util  (' + d.mempct.toFixed(2) + '% of pool)';
  document.getElementById('nsDetailMemPct').style.color = memUtilColor;
  // bar widths based on utilization (actual/requested), capped at 100%
  const cpuW = Math.min(d.cpuutil, 100);
  const memW = Math.min(d.memutil, 100);
  document.getElementById('nsDetailCpuBar').style.width = cpuW + '%';
  document.getElementById('nsDetailCpuBar').style.background = cpuUtilColor;
  document.getElementById('nsDetailMemBar').style.width = memW + '%';
  document.getElementById('nsDetailMemBar').style.background = memUtilColor;
}

function filterTenantNs(ns) {
  tenantFilterNs = ns;
  const filtered = ns ? namespaceData.filter(x => x.name === ns) : namespaceData;
  buildNamespaceChart(filtered);
  showNsDetail(ns);
}



/* initialise */
populateTenantDropdown();
buildNamespaceChart(namespaceData);

/* ── cpuChart : horizontal bars – Top 10 CPU consumers (tenant) ── */
(function(){
  const ctx = document.getElementById('cpuChart');
  if (!ctx || !cpuData.length) return;
  new Chart(ctx, {
    type: 'bar',
    data: {
      labels: cpuData.map(x => x.name),
      datasets: [{
        label: 'CPU Cores Requested',
        data: cpuData.map(x => x.value),
        backgroundColor: paletteColors(cpuData.length),
        borderColor:     paletteColors(cpuData.length),
        borderWidth: 1
      }]
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      plugins: { legend: { display: false } },
      scales: {
        x: { beginAtZero: true,
             title: { display: true, text: 'CPU Cores' } }
      }
    }
  });
})();

/* ── memoryChart : horizontal bars – Top 10 Memory consumers (tenant) ── */
(function(){
  const ctx = document.getElementById('memoryChart');
  if (!ctx || !memoryData.length) return;
  new Chart(ctx, {
    type: 'bar',
    data: {
      labels: memoryData.map(x => x.name),
      datasets: [{
        label: 'Memory GiB Requested',
        data: memoryData.map(x => x.value),
        backgroundColor: paletteColors(memoryData.length),
        borderColor:     paletteColors(memoryData.length),
        borderWidth: 1
      }]
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      plugins: { legend: { display: false } },
      scales: {
        x: { beginAtZero: true,
             title: { display: true, text: 'Memory (GiB)' } }
      }
    }
  });
})();
/* ── infraChart : horizontal grouped bar – Infra namespace CPU & Memory ── */
let infraChartInstance = null;

function buildInfraChart(data) {
  const ctx = document.getElementById('infraChart');
  if (!ctx) return;
  if (infraChartInstance) infraChartInstance.destroy();
  infraChartInstance = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: data.map(x => x.name),
      datasets: [
        {
          label: 'CPU Cores',
          data: data.map(x => x.cpu),
          backgroundColor: '#7d3c98bb',
          borderColor: '#6c3483',
          borderWidth: 1
        },
        {
          label: 'Memory GiB',
          data: data.map(x => x.mem),
          backgroundColor: '#1a5276bb',
          borderColor: '#154360',
          borderWidth: 1
        }
      ]
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      plugins: {
        legend: { position: 'top' },
        tooltip: {
          callbacks: {
            label: ctx => ctx.dataset.label + ': ' + ctx.parsed.x.toFixed(2)
          }
        }
      },
      scales: {
        x: { beginAtZero: true,
             title: { display: true, text: 'Cores / GiB' } }
      }
    }
  });
}

function showInfraDetail(data) {
  const panel = document.getElementById('infraDetailPanel');
  if (!panel) return;
  if (!data || data.length === 0) { panel.style.display = 'none'; return; }
  if (data.length === 1) {
    const d = data[0];
    panel.style.display = 'block';
    panel.innerHTML = '<div style="display:flex;flex-wrap:wrap;gap:24px;align-items:center">'
      + '<div><span style="font-size:13px;font-weight:700;color:#4a235a">&#9432; Namespace: </span>'
      + '<span style="font-size:14px;font-weight:700;color:#1f4e79">' + d.name + '</span></div>'
      + '<div style="display:flex;gap:24px;flex-wrap:wrap">'
      + '<div><div style="font-size:11px;color:#666;margin-bottom:3px">CPU Requested</div>'
      + '<div style="font-size:16px;font-weight:700;color:#7d3c98">' + d.cpu.toFixed(3) + ' cores</div>'
      + '<div style="display:flex;align-items:center;gap:6px;margin-top:4px">'
      + '<div style="width:120px;height:8px;background:#e0e0e0;border-radius:4px">'
      + '<div style="width:' + Math.min(d.cpuutil,100) + '%;height:8px;border-radius:4px;background:#7d3c98"></div></div>'
      + '<span style="font-size:11px;font-weight:700;color:' + ((d.cpuutil>90)?'#c0392b':(d.cpuutil>50)?'#1a7f37':'#d35400') + '">' + d.cpuutil.toFixed(1) + '% util</span>'
      + '<span style="font-size:10px;color:#888">(' + d.cpupct.toFixed(2) + '% of pool)</span></div></div>'
      + '<div><div style="font-size:11px;color:#666;margin-bottom:3px">Memory Requested</div>'
      + '<div style="font-size:16px;font-weight:700;color:#154360">' + d.mem.toFixed(2) + ' GiB</div>'
      + '<div style="display:flex;align-items:center;gap:6px;margin-top:4px">'
      + '<div style="width:120px;height:8px;background:#e0e0e0;border-radius:4px">'
      + '<div style="width:' + Math.min(d.memutil,100) + '%;height:8px;border-radius:4px;background:#154360"></div></div>'
      + '<span style="font-size:11px;font-weight:700;color:' + ((d.memutil>90)?'#c0392b':(d.memutil>50)?'#1a7f37':'#d35400') + '">' + d.memutil.toFixed(1) + '% util</span>'
      + '<span style="font-size:10px;color:#888">(' + d.mempct.toFixed(2) + '% of pool)</span></div></div>'
      + '</div></div>';
  } else {
    panel.style.display = 'none';
  }
}

function filterInfraChart(query) {
  const q = query.trim().toLowerCase();
  const filtered = q ? infraData.filter(x => x.name.toLowerCase().includes(q)) : infraData;
  buildInfraChart(filtered);
  showInfraDetail(filtered);
}

/* initialise with full infra dataset */
if (infraData && infraData.length) buildInfraChart(infraData);

</script>





<div class="footer">


Generated by ARO Ops Dashboard


</div>



</body>


</html>


EOF



#############################################
# Validate HTML
#############################################

if [[ -s "${REPORT_FILE}" ]]
then

    log INFO "Report generated successfully"

else

    log ERROR "Report generation failed"

    exit 1

fi



echo "

================================================

OpenShift Capacity Report Generated

File:

${REPORT_FILE}


Status:

${STATUS}


Health Score:

${HEALTH_SCORE}/100


================================================

"
