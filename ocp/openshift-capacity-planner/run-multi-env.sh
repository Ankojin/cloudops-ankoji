#!/usr/bin/env bash
#
# ARO Ops Dashboard — Multi-Environment Runner
#
# Runs the ARO Ops Dashboard collector against two ARO environments (DEV and SIT)
# in sequence, using separate bearer tokens for each.
# Generates an independent report per environment.
#
# Usage:
#   ./run-multi-env.sh \
#     --dev-api  https://api.dev.cluster.example.com:6443 \
#     --dev-token sha256~xxxxxxxxxxxxxxxxxxx \
#     --sit-api  https://api.sit.cluster.example.com:6443 \
#     --sit-token sha256~yyyyyyyyyyyyyyyyyyy
#
# You can skip an environment by omitting its --*-api and --*-token flags.
# In that case the script uses the currently active oc login context for
# that environment (or skips it if you pass --skip-dev / --skip-sit).
#
# Options:
#   --dev-api   URL      DEV cluster API server URL
#   --dev-token TOKEN    DEV cluster bearer token
#   --dev-env   LABEL    Label for DEV environment (default: DEV)
#   --sit-api   URL      SIT cluster API server URL
#   --sit-token TOKEN    SIT cluster bearer token
#   --sit-env   LABEL    Label for SIT environment (default: SIT)
#   --skip-dev           Skip DEV environment entirely
#   --skip-sit           Skip SIT environment entirely
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#############################################
# Defaults
#############################################

DEV_API=""
DEV_TOKEN=""
DEV_ENV="DEV"
SIT_API=""
SIT_TOKEN=""
SIT_ENV="SIT"
SKIP_DEV=false
SKIP_SIT=false


#############################################
# Argument Parsing
#############################################

while [[ $# -gt 0 ]]
do
    case "$1" in
        --dev-api)   DEV_API="${2:?--dev-api requires a value}";   shift 2 ;;
        --dev-token) DEV_TOKEN="${2:?--dev-token requires a value}"; shift 2 ;;
        --dev-env)   DEV_ENV="${2:?--dev-env requires a value}";   shift 2 ;;
        --sit-api)   SIT_API="${2:?--sit-api requires a value}";   shift 2 ;;
        --sit-token) SIT_TOKEN="${2:?--sit-token requires a value}"; shift 2 ;;
        --sit-env)   SIT_ENV="${2:?--sit-env requires a value}";   shift 2 ;;
        --skip-dev)  SKIP_DEV=true; shift ;;
        --skip-sit)  SKIP_SIT=true; shift ;;
        -h|--help)
            sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Run $0 --help for usage."
            exit 1
            ;;
    esac
done


#############################################
# Helpers
#############################################

banner()
{
    echo ""
    echo "============================================================"
    echo "  $*"
    echo "============================================================"
    echo ""
}

run_env()
{
    local ENV_LABEL="$1"
    local TOKEN="$2"
    local API="$3"

    banner "Running: ${ENV_LABEL}"

    local ARGS=(--env "${ENV_LABEL}")

    if [[ -n "${TOKEN}" && -n "${API}" ]]
    then
        ARGS+=(--token "${TOKEN}" --api "${API}")
    elif [[ -n "${TOKEN}" || -n "${API}" ]]
    then
        echo "ERROR: Both --token and --api must be provided together for ${ENV_LABEL}."
        echo "       Provide both or neither (to use the current oc login context)."
        exit 1
    fi

    bash "${SCRIPT_DIR}/run.sh" "${ARGS[@]}"
}


#############################################
# DEV Environment
#############################################

if [[ "${SKIP_DEV}" == "false" ]]
then
    run_env "${DEV_ENV}" "${DEV_TOKEN}" "${DEV_API}"
else
    echo "Skipping DEV environment (--skip-dev)"
fi


#############################################
# SIT Environment
#############################################

if [[ "${SKIP_SIT}" == "false" ]]
then
    run_env "${SIT_ENV}" "${SIT_TOKEN}" "${SIT_API}"
else
    echo "Skipping SIT environment (--skip-sit)"
fi


#############################################
# Summary + Combined Comparison Report
#############################################

banner "All environments completed"

LATEST_DEV=""
LATEST_SIT=""
if [[ "${SKIP_DEV}" == "false" ]]; then
  LATEST_DEV=$(ls -1dt "${SCRIPT_DIR}/output/${DEV_ENV}_"* 2>/dev/null | head -1 || echo "")
fi
if [[ "${SKIP_SIT}" == "false" ]]; then
  LATEST_SIT=$(ls -1dt "${SCRIPT_DIR}/output/${SIT_ENV}_"* 2>/dev/null | head -1 || echo "")
fi

echo "Individual reports:"
echo ""
[[ -n "${LATEST_DEV}" ]] && echo "  ${DEV_ENV}: ${LATEST_DEV}/report.html"
[[ -n "${LATEST_SIT}" ]] && echo "  ${SIT_ENV}: ${LATEST_SIT}/report.html"
echo ""


#############################################
# Single-env fallback index.html
# Generated whenever only one env ran so the
# team URL still works without a comparison.
#############################################

generate_single_index()
{
    local ENV_LABEL="$1"
    local ENV_DIR="$2"
    local INDEX_FILE="${SCRIPT_DIR}/output/index.html"
    local REPORT_REL="../$(basename "${ENV_DIR}")/report.html"

    cat > "${INDEX_FILE}" <<SIDXEOF
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>ARO Ops Dashboard — ${ENV_LABEL}</title>
<meta http-equiv="refresh" content="0;url=${REPORT_REL}">
<style>
  body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;display:flex;flex-direction:column;align-items:center;padding:40px 20px}
  .box{background:#fff;border-radius:12px;box-shadow:0 2px 10px rgba(0,0,0,.1);padding:32px 40px;max-width:560px;width:100%}
  h1{color:#1f4e79;margin-top:0}
  .btn{display:inline-block;padding:10px 22px;background:#1f4e79;color:#fff;border-radius:6px;text-decoration:none;font-weight:600;margin-top:10px}
</style>
</head>
<body>
<div class="box">
  <h1>ARO Ops Dashboard &nbsp;
    <span style="background:#1f4e79;color:#fff;padding:2px 12px;border-radius:8px;font-size:18px">${ENV_LABEL}</span>
  </h1>
  <p>Redirecting to the latest <strong>${ENV_LABEL}</strong> report&hellip;</p>
  <a href="${REPORT_REL}" class="btn">Open ${ENV_LABEL} Report &#8599;</a>
  <p style="margin-top:24px;font-size:12px;color:#aaa">
    Only <strong>${ENV_LABEL}</strong> ran this cycle. Run with both
    --dev-* and --sit-* flags to generate the comparison report.
    <br>Generated: $(date)
  </p>
</div>
</body>
</html>
SIDXEOF

    echo "  Landing page: ${INDEX_FILE}"
}


#############################################
# Generate Combined Comparison Report
#############################################

if [[ -n "${LATEST_DEV}" && -n "${LATEST_SIT}" ]]
then

    banner "Generating combined comparison report"
    COMBINED_DIR="${SCRIPT_DIR}/output/comparison_$(date +"%Y%m%d_%H%M%S")"
    mkdir -p "${COMBINED_DIR}"
    COMBINED_REPORT="${COMBINED_DIR}/comparison.html"


    # --- read key values from each env ---------------------------------

    read_jq() { jq -r "${1}" "${2}" 2>/dev/null || echo "N/A"; }

    DEV_JSON="${LATEST_DEV}/json"
    SIT_JSON="${LATEST_SIT}/json"

    # capacity_summary.json keys
    DEV_TOTAL_CPU=$(read_jq '.cluster_capacity.cpu_cores'              "${DEV_JSON}/capacity_summary.json")
    DEV_CPU_PCT=$(read_jq   '.utilization.cpu_requested_percent'       "${DEV_JSON}/capacity_summary.json")
    DEV_MEM_PCT=$(read_jq   '.utilization.memory_requested_percent'    "${DEV_JSON}/capacity_summary.json")
    # collection_summary.json keys
    DEV_NODES=$(read_jq     '.nodes'                                   "${DEV_JSON}/collection_summary.json")
    DEV_NS=$(read_jq        '.namespaces'                              "${DEV_JSON}/collection_summary.json")
    # capacity_planning.json keys
    DEV_WORKERS=$(read_jq   '.worker_pool.worker_nodes'                "${DEV_JSON}/capacity_planning.json")
    DEV_PRESSURE=$(read_jq  '.current_utilization.pressure_level'     "${DEV_JSON}/capacity_planning.json")
    # cluster_utilization.json keys
    DEV_UTIL_CPU=$(read_jq  '.cpu.used_cores'                         "${DEV_JSON}/cluster_utilization.json")
    DEV_UTIL_MEM=$(read_jq  '.memory.used_gib'                        "${DEV_JSON}/cluster_utilization.json")
    DEV_PODS=$(read_jq      '.pods.running'                           "${DEV_JSON}/cluster_utilization.json")

    DEV_HEALTH=$(awk "BEGIN{
        cpu=${DEV_CPU_PCT}+0; mem=${DEV_MEM_PCT}+0;
        m=(cpu>mem)?cpu:mem; s=100-m;
        if(s<0)s=0;
        printf \"%d\",int(s)
    }")

    SIT_TOTAL_CPU=$(read_jq '.cluster_capacity.cpu_cores'             "${SIT_JSON}/capacity_summary.json")
    SIT_CPU_PCT=$(read_jq   '.utilization.cpu_requested_percent'      "${SIT_JSON}/capacity_summary.json")
    SIT_MEM_PCT=$(read_jq   '.utilization.memory_requested_percent'   "${SIT_JSON}/capacity_summary.json")
    SIT_NODES=$(read_jq     '.nodes'                                   "${SIT_JSON}/collection_summary.json")
    SIT_NS=$(read_jq        '.namespaces'                              "${SIT_JSON}/collection_summary.json")
    SIT_WORKERS=$(read_jq   '.worker_pool.worker_nodes'               "${SIT_JSON}/capacity_planning.json")
    SIT_PRESSURE=$(read_jq  '.current_utilization.pressure_level'     "${SIT_JSON}/capacity_planning.json")
    SIT_UTIL_CPU=$(read_jq  '.cpu.used_cores'                         "${SIT_JSON}/cluster_utilization.json")
    SIT_UTIL_MEM=$(read_jq  '.memory.used_gib'                        "${SIT_JSON}/cluster_utilization.json")
    SIT_PODS=$(read_jq      '.pods.running'                           "${SIT_JSON}/cluster_utilization.json")

    SIT_HEALTH=$(awk "BEGIN{
        cpu=${SIT_CPU_PCT}+0; mem=${SIT_MEM_PCT}+0;
        m=(cpu>mem)?cpu:mem; s=100-m;
        if(s<0)s=0;
        printf \"%d\",int(s)
    }")


    # --- color helpers -------------------------------------------------

    health_color()
    {
        local S="$1"
        awk "BEGIN{
            s=${S}+0;
            if(s>=75)      print \"#1a7f37\"
            else if(s>=50) print \"#856404\"
            else           print \"#c0392b\"
        }"
    }

    pressure_color()
    {
        case "$1" in
            GREEN)  echo "#1a7f37" ;;
            YELLOW) echo "#856404" ;;
            ORANGE) echo "#d35400" ;;
            RED)    echo "#c0392b" ;;
            *)      echo "#555555" ;;
        esac
    }

    pct_color()
    {
        local P="$1"
        awk "BEGIN{
            p=${P}+0;
            if(p>85)       print \"#c0392b\"
            else if(p>60)  print \"#d35400\"
            else           print \"#1a7f37\"
        }"
    }

    bar_class()
    {
        local P="$1"
        awk "BEGIN{
            p=${P}+0;
            if(p>85)       print \"bar-critical\"
            else if(p>60)  print \"bar-at_risk\"
            else           print \"bar-safe\"
        }"
    }

    DEV_HEALTH_COLOR=$(health_color "${DEV_HEALTH}")
    SIT_HEALTH_COLOR=$(health_color "${SIT_HEALTH}")
    DEV_CPU_COLOR=$(pct_color "${DEV_CPU_PCT}")
    SIT_CPU_COLOR=$(pct_color "${SIT_CPU_PCT}")
    DEV_MEM_COLOR=$(pct_color "${DEV_MEM_PCT}")
    SIT_MEM_COLOR=$(pct_color "${SIT_MEM_PCT}")
    DEV_PRESSURE_COLOR=$(pressure_color "${DEV_PRESSURE}")
    SIT_PRESSURE_COLOR=$(pressure_color "${SIT_PRESSURE}")
    DEV_CPU_BAR=$(bar_class "${DEV_CPU_PCT}")
    SIT_CPU_BAR=$(bar_class "${SIT_CPU_PCT}")
    DEV_MEM_BAR=$(bar_class "${DEV_MEM_PCT}")
    SIT_MEM_BAR=$(bar_class "${SIT_MEM_PCT}")


    # --- relative paths to individual reports (same browser) -----------
    DEV_REL="../$(basename "${LATEST_DEV}")/report.html"
    SIT_REL="../$(basename "${LATEST_SIT}")/report.html"

    CSS_FILE="${SCRIPT_DIR}/assets/dashboard.css"
    CSS_CONTENT=""
    [[ -f "${CSS_FILE}" ]] && CSS_CONTENT=$(cat "${CSS_FILE}")


    # --- write HTML ----------------------------------------------------

    cat > "${COMBINED_REPORT}" <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Capacity Comparison — ${DEV_ENV} vs ${SIT_ENV}</title>
<style>
${CSS_CONTENT}

/* Comparison-specific overrides */
.env-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 20px;
    margin-bottom: 20px;
}
.env-header {
    padding: 12px 18px;
    border-radius: 8px 8px 0 0;
    font-size: 22px;
    font-weight: 700;
    color: #fff;
    letter-spacing: 1px;
}
.env-dev  { background: #1f4e79; }
.env-sit  { background: #6c3483; }
.env-panel {
    background: #fff;
    border-radius: 0 0 10px 10px;
    border: 1px solid #ddd;
    overflow: hidden;
}
.metric-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 16px;
    border-bottom: 1px solid #f0f0f0;
    font-size: 14px;
}
.metric-row:last-child { border-bottom: none; }
.metric-label { color: #555; font-weight: 500; min-width: 160px; }
.metric-value { font-size: 20px; font-weight: 700; }
.bar-row { padding: 8px 16px 12px; border-bottom: 1px solid #f0f0f0; }
.bar-label { font-size: 12px; color: #777; margin-bottom: 4px; }
.bar-wrap  { background: #e9ecef; border-radius: 6px; height: 14px; width: 100%; }
.bar-fill  { border-radius: 6px; height: 14px; }
.bar-safe  { background: #1a7f37; }
.bar-at_risk { background: #d35400; }
.bar-critical { background: #c0392b; }
.compare-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 14px;
}
.compare-table th {
    background: #1f4e79;
    color: #fff;
    padding: 10px 14px;
    text-align: left;
}
.compare-table td {
    padding: 9px 14px;
    border-bottom: 1px solid #eee;
}
.compare-table tr:nth-child(even) td { background: #f8f9fa; }
.tag {
    display: inline-block;
    padding: 2px 10px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 600;
}
.open-link {
    display: inline-block;
    padding: 6px 16px;
    border-radius: 6px;
    color: #fff;
    text-decoration: none;
    font-weight: 600;
    font-size: 13px;
    margin-top: 10px;
}
</style>
</head>
<body>

<div class="header">
  <h1>ARO Capacity Comparison
    <span style="margin-left:14px;padding:4px 14px;background:rgba(255,255,255,0.2);border-radius:8px;font-size:18px">${DEV_ENV} vs ${SIT_ENV}</span>
  </h1>
  <p>Generated: $(date) &nbsp;&bull;&nbsp; Two-environment side-by-side view</p>
</div>


<!-- ======================================================
     Side-by-side environment panels
     ====================================================== -->

<div class="env-grid">

  <!-- DEV panel -->
  <div>
    <div class="env-header env-dev">${DEV_ENV}</div>
    <div class="env-panel">

      <div class="metric-row">
        <span class="metric-label">Health Score</span>
        <span class="metric-value" style="color:${DEV_HEALTH_COLOR}">${DEV_HEALTH}/100</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Nodes (Workers)</span>
        <span class="metric-value">${DEV_NODES} &nbsp;<small style="font-size:13px;color:#888">(${DEV_WORKERS} workers)</small></span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Total CPU (allocatable)</span>
        <span class="metric-value">${DEV_TOTAL_CPU} cores</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Namespaces</span>
        <span class="metric-value">${DEV_NS}</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Capacity Pressure</span>
        <span class="metric-value" style="color:${DEV_PRESSURE_COLOR}">${DEV_PRESSURE}</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Actual CPU Used</span>
        <span class="metric-value">${DEV_UTIL_CPU} cores</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Actual Memory Used</span>
        <span class="metric-value">${DEV_UTIL_MEM} GiB</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Running Pods</span>
        <span class="metric-value">${DEV_PODS}</span>
      </div>

      <div class="bar-row">
        <div class="bar-label">CPU Requested &nbsp;${DEV_CPU_PCT}%</div>
        <div class="bar-wrap"><div class="bar-fill ${DEV_CPU_BAR}" style="width:$(awk "BEGIN{v=${DEV_CPU_PCT}+0;print(v>100)?100:int(v)}")%"></div></div>
      </div>

      <div class="bar-row">
        <div class="bar-label">Memory Requested &nbsp;${DEV_MEM_PCT}%</div>
        <div class="bar-wrap"><div class="bar-fill ${DEV_MEM_BAR}" style="width:$(awk "BEGIN{v=${DEV_MEM_PCT}+0;print(v>100)?100:int(v)}")%"></div></div>
      </div>

      <div style="padding:14px 16px">
        <a href="${DEV_REL}" class="open-link" style="background:#1f4e79">Open Full ${DEV_ENV} Report &#8599;</a>
      </div>

    </div>
  </div>


  <!-- SIT panel -->
  <div>
    <div class="env-header env-sit">${SIT_ENV}</div>
    <div class="env-panel">

      <div class="metric-row">
        <span class="metric-label">Health Score</span>
        <span class="metric-value" style="color:${SIT_HEALTH_COLOR}">${SIT_HEALTH}/100</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Nodes (Workers)</span>
        <span class="metric-value">${SIT_NODES} &nbsp;<small style="font-size:13px;color:#888">(${SIT_WORKERS} workers)</small></span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Total CPU (allocatable)</span>
        <span class="metric-value">${SIT_TOTAL_CPU} cores</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Namespaces</span>
        <span class="metric-value">${SIT_NS}</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Capacity Pressure</span>
        <span class="metric-value" style="color:${SIT_PRESSURE_COLOR}">${SIT_PRESSURE}</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Actual CPU Used</span>
        <span class="metric-value">${SIT_UTIL_CPU} cores</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Actual Memory Used</span>
        <span class="metric-value">${SIT_UTIL_MEM} GiB</span>
      </div>

      <div class="metric-row">
        <span class="metric-label">Running Pods</span>
        <span class="metric-value">${SIT_PODS}</span>
      </div>

      <div class="bar-row">
        <div class="bar-label">CPU Requested &nbsp;${SIT_CPU_PCT}%</div>
        <div class="bar-wrap"><div class="bar-fill ${SIT_CPU_BAR}" style="width:$(awk "BEGIN{v=${SIT_CPU_PCT}+0;print(v>100)?100:int(v)}")%"></div></div>
      </div>

      <div class="bar-row">
        <div class="bar-label">Memory Requested &nbsp;${SIT_MEM_PCT}%</div>
        <div class="bar-wrap"><div class="bar-fill ${SIT_MEM_BAR}" style="width:$(awk "BEGIN{v=${SIT_MEM_PCT}+0;print(v>100)?100:int(v)}")%"></div></div>
      </div>

      <div style="padding:14px 16px">
        <a href="${SIT_REL}" class="open-link" style="background:#6c3483">Open Full ${SIT_ENV} Report &#8599;</a>
      </div>

    </div>
  </div>

</div>


<!-- ======================================================
     Comparison table
     ====================================================== -->

<div class="card">
<h2>Metric Comparison</h2>
<table class="compare-table">
<thead>
<tr>
  <th>Metric</th>
  <th>${DEV_ENV}</th>
  <th>${SIT_ENV}</th>
  <th>Difference</th>
</tr>
</thead>
<tbody>
<tr>
  <td>Health Score</td>
  <td style="color:${DEV_HEALTH_COLOR};font-weight:700">${DEV_HEALTH}/100</td>
  <td style="color:${SIT_HEALTH_COLOR};font-weight:700">${SIT_HEALTH}/100</td>
  <td>$(awk "BEGIN{d=${SIT_HEALTH}-${DEV_HEALTH}+0;printf \"%+d\",d}")</td>
</tr>
<tr>
  <td>Total Nodes</td>
  <td>${DEV_NODES}</td>
  <td>${SIT_NODES}</td>
  <td>$(awk "BEGIN{d=${SIT_NODES}-${DEV_NODES}+0;printf \"%+d\",d}")</td>
</tr>
<tr>
  <td>Worker Nodes</td>
  <td>${DEV_WORKERS}</td>
  <td>${SIT_WORKERS}</td>
  <td>$(awk "BEGIN{d=${SIT_WORKERS}-${DEV_WORKERS}+0;printf \"%+d\",d}")</td>
</tr>
<tr>
  <td>CPU Allocatable (cores)</td>
  <td>${DEV_TOTAL_CPU}</td>
  <td>${SIT_TOTAL_CPU}</td>
  <td>$(awk "BEGIN{d=${SIT_TOTAL_CPU}-${DEV_TOTAL_CPU}+0;printf \"%+.2f\",d}")</td>
</tr>
<tr>
  <td>CPU Requested %</td>
  <td style="color:${DEV_CPU_COLOR};font-weight:700">${DEV_CPU_PCT}%</td>
  <td style="color:${SIT_CPU_COLOR};font-weight:700">${SIT_CPU_PCT}%</td>
  <td>$(awk "BEGIN{d=${SIT_CPU_PCT}-${DEV_CPU_PCT}+0;printf \"%+.1f%%\",d}")</td>
</tr>
<tr>
  <td>Memory Requested %</td>
  <td style="color:${DEV_MEM_COLOR};font-weight:700">${DEV_MEM_PCT}%</td>
  <td style="color:${SIT_MEM_COLOR};font-weight:700">${SIT_MEM_PCT}%</td>
  <td>$(awk "BEGIN{d=${SIT_MEM_PCT}-${DEV_MEM_PCT}+0;printf \"%+.1f%%\",d}")</td>
</tr>
<tr>
  <td>Namespaces</td>
  <td>${DEV_NS}</td>
  <td>${SIT_NS}</td>
  <td>$(awk "BEGIN{d=${SIT_NS}-${DEV_NS}+0;printf \"%+d\",d}")</td>
</tr>
<tr>
  <td>Capacity Pressure</td>
  <td style="color:${DEV_PRESSURE_COLOR};font-weight:700">${DEV_PRESSURE}</td>
  <td style="color:${SIT_PRESSURE_COLOR};font-weight:700">${SIT_PRESSURE}</td>
  <td>—</td>
</tr>
<tr>
  <td>Actual CPU Used (cores)</td>
  <td>${DEV_UTIL_CPU}</td>
  <td>${SIT_UTIL_CPU}</td>
  <td>$(awk "BEGIN{d=${SIT_UTIL_CPU}-${DEV_UTIL_CPU}+0;printf \"%+.1f\",d}")</td>
</tr>
<tr>
  <td>Actual Memory Used (GiB)</td>
  <td>${DEV_UTIL_MEM}</td>
  <td>${SIT_UTIL_MEM}</td>
  <td>$(awk "BEGIN{d=${SIT_UTIL_MEM}-${DEV_UTIL_MEM}+0;printf \"%+.1f\",d}")</td>
</tr>
<tr>
  <td>Running Pods</td>
  <td>${DEV_PODS}</td>
  <td>${SIT_PODS}</td>
  <td>$(awk "BEGIN{d=${SIT_PODS}-${DEV_PODS}+0;printf \"%+d\",d}")</td>
</tr>
</tbody>
</table>
</div>


<div style="text-align:center;color:#aaa;padding:20px;font-size:12px">
  Generated by ARO Ops Dashboardner &mdash; $(date) &mdash;
  <a href="${DEV_REL}">Full ${DEV_ENV} Report</a> &nbsp;|&nbsp;
  <a href="${SIT_REL}">Full ${SIT_ENV} Report</a>
</div>

</body>
</html>
HTMLEOF


    echo ""
    echo "Combined comparison report:"
    echo "  ${COMBINED_REPORT}"
    echo ""


    #############################################
    # Generate index.html landing page
    # (served at the root URL by nginx)
    #############################################

    INDEX_FILE="${SCRIPT_DIR}/output/index.html"
    COMPARISON_REL="$(basename "${COMBINED_DIR}")/comparison.html"

    # Collect all past comparison reports for the history list
    HISTORY_ROWS=""
    while IFS= read -r -d '' DIR
    do
        REL_PATH="$(basename "${DIR}")/comparison.html"
        LABEL="$(basename "${DIR}" | sed 's/comparison_//' | sed 's/_/ /g')"
        HISTORY_ROWS="${HISTORY_ROWS}<tr><td><a href=\"${REL_PATH}\">${LABEL}</a></td><td><a href=\"${REL_PATH}\" class=\"btn\">Open &#8599;</a></td></tr>"$'\n'
    done < <(find "${SCRIPT_DIR}/output" -maxdepth 1 -name "comparison_*" -type d -print0 | sort -rz)

    cat > "${INDEX_FILE}" <<IDXEOF
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>ARO Ops Dashboard — Dashboard</title>
<meta http-equiv="refresh" content="0;url=${COMPARISON_REL}">
<style>
  body { font-family:"Segoe UI",Arial,sans-serif; background:#f4f6f9; display:flex; flex-direction:column; align-items:center; padding:40px 20px; }
  .box { background:#fff; border-radius:12px; box-shadow:0 2px 10px rgba(0,0,0,.1); padding:32px 40px; max-width:640px; width:100%; }
  h1 { color:#1f4e79; margin-top:0; }
  p  { color:#555; }
  .btn { display:inline-block; padding:10px 22px; background:#1f4e79; color:#fff; border-radius:6px; text-decoration:none; font-weight:600; margin-top:10px; }
  table { width:100%; border-collapse:collapse; margin-top:20px; font-size:14px; }
  th { background:#1f4e79; color:#fff; padding:8px 12px; text-align:left; }
  td { padding:8px 12px; border-bottom:1px solid #eee; }
  tr:nth-child(even) td { background:#f8f9fa; }
</style>
</head>
<body>
<div class="box">
  <h1>ARO Ops Dashboard</h1>
  <p>Redirecting to the latest comparison report&hellip;</p>
  <p>If not redirected automatically:<br>
    <a href="${COMPARISON_REL}" class="btn">Open Latest Comparison Report &#8599;</a>
  </p>

  <h2 style="margin-top:28px;color:#1f4e79;font-size:16px">Report History</h2>
  <table>
  <thead><tr><th>Run timestamp</th><th>Report</th></tr></thead>
  <tbody>
${HISTORY_ROWS}
  </tbody>
  </table>

  <p style="margin-top:20px;font-size:12px;color:#aaa">
    Dashboard auto-refreshes on schedule &bull; Generated: $(date)
  </p>
</div>
</body>
</html>
IDXEOF

    echo "Landing page: ${INDEX_FILE}"
    echo ""

elif [[ -n "${LATEST_DEV}" ]]
then
    banner "Only ${DEV_ENV} ran — generating single-env landing page"
    generate_single_index "${DEV_ENV}" "${LATEST_DEV}"
    echo ""
    echo "  Report: ${LATEST_DEV}/report.html"
    echo ""

elif [[ -n "${LATEST_SIT}" ]]
then
    banner "Only ${SIT_ENV} ran — generating single-env landing page"
    generate_single_index "${SIT_ENV}" "${LATEST_SIT}"
    echo ""
    echo "  Report: ${LATEST_SIT}/report.html"
    echo ""

fi

exit 0

