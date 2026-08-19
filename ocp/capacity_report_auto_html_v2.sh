#!/usr/bin/env bash
set -euo pipefail

# OpenShift / Kubernetes capacity report
#
# Goals:
#   1. Discover worker nodes automatically.
#   2. Discover node taints automatically (no hard-coded SAS/RPA namespaces).
#   3. Identify dedicated/pool nodes from custom scheduling taints.
#   4. Inspect pod tolerations and actual pod -> node placement.
#   5. Calculate CPU/memory requests from ACTUAL RUNNING PODS, not only Deployment replicas.
#   6. Calculate dedicated-node capacity separately from shared-node capacity.
#   7. Detect dedicated namespaces/workloads running on shared nodes.
#   8. Produce separate CSV sheets/files for nodes, taints, pod placement,
#      requests, dedicated capacity, shared capacity and summary.
#
# Usage:
#   ./capacity_report_auto.sh
#   ./capacity_report_auto.sh --output-dir ./capacity_report_YYYYMMDD_HHMMSS
#   ./capacity_report_auto.sh --debug
#
# Notes:
#   - A node is treated as a DEDICATED node when it has a custom scheduling taint
#     (normally NoSchedule/NoExecute/PreferNoSchedule), excluding standard
#     transient/system taints listed in SYSTEM_TAINT_REGEX.
#   - A pod is treated as dedicated when it targets a tainted node through
#     nodeSelector/nodeAffinity OR tolerates a dedicated node taint OR its actual
#     running placement is on a dedicated node.
#   - Actual node placement is the source of truth for CURRENT capacity usage.
#
# Requirements: oc, jq, awk, sed, grep, sort, column (optional), date

DRY_RUN=false
DEBUG=false
OUTPUT_DIR="capacity_report_$(date +%Y%m%d_%H%M%S)"

# Capacity planning target: schedule only up to this % of allocatable.
# Remaining headroom covers burst, DaemonSets growth, and operational safety.
# Kubernetes scheduler uses Requests (not Limits). Allocatable already excludes
# kube/system reserved; this factor is pure planning headroom.
TARGET_UTILIZATION_PCT=80

# Future workload growth scenarios (percent increase in Requests).
# Comma-separated list, e.g. 10,25,50 means +10%, +25%, +50% request growth.
# Applied independently to Dedicated and Shared pools.
GROWTH_SCENARIOS_PCT="10,25,50"
# Optional: different growth for CPU vs Memory (leave equal for uniform growth)
# If set, overrides uniform GROWTH_SCENARIOS for that resource.
# GROWTH_CPU_PCT and GROWTH_MEM_PCT are not used when GROWTH_SCENARIOS_PCT is set;
# each scenario applies the same % to both CPU and memory requests.

# Standard Kubernetes/OpenShift taints that should not automatically make a worker
# a business/dedicated pool. Add site-specific transient/system taints here if needed.
# Standard Kubernetes/OpenShift transient/system taints. Using [.] avoids jq's invalid \. escape handling.
SYSTEM_TAINT_REGEX='^(node[.]kubernetes[.]io/(not-ready|unreachable|memory-pressure|disk-pressure|pid-pressure|network-unavailable)|node[.]alpha[.]kubernetes[.]io/not-ready|node-role[.]kubernetes[.]io/(master|control-plane|infra))$'

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --debug) DEBUG=true ;;
    --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--dry-run] [--debug] [--output-dir DIR]

  --dry-run          Calculate only; do not write report files.
  --debug            Print discovery and classification diagnostics.
  --output-dir DIR  Output directory (default: capacity_report_TIMESTAMP).
USAGE
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() {
  local level="$1"; shift
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  case "$level" in
    INFO)    echo "[$ts] [INFO]    $*" ;;
    WARN)    echo "[$ts] [WARNING] $*" ;;
    ERROR)   echo "[$ts] [ERROR]   $*" >&2 ;;
    SUCCESS) echo "[$ts] [SUCCESS] $*" ;;
    DEBUG)   [[ "$DEBUG" == true ]] && echo "[$ts] [DEBUG]   $*" ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log ERROR "Required command not found: $1"; exit 1; }
}

for c in oc jq awk sed grep sort date mktemp; do need_cmd "$c"; done

if ! oc whoami >/dev/null 2>&1; then
  log ERROR "oc is not logged in / cluster is not reachable. Run 'oc login' first."
  exit 1
fi

if [[ "$DRY_RUN" == false ]]; then
  mkdir -p "$OUTPUT_DIR"
else
  OUTPUT_DIR="/tmp/capacity_report_dryrun_$$"
  mkdir -p "$OUTPUT_DIR"
fi

# Output files (CSV = Excel-friendly sheets; open separately or combine in Excel).
NODES_FILE="$OUTPUT_DIR/01_node_inventory.csv"
TAINTS_FILE="$OUTPUT_DIR/02_node_taints.csv"
TOLERATIONS_FILE="$OUTPUT_DIR/03_pod_tolerations.csv"
PLACEMENT_FILE="$OUTPUT_DIR/04_pod_placement.csv"
REQUESTS_FILE="$OUTPUT_DIR/05_pod_requests.csv"
DEDICATED_REQ_FILE="$OUTPUT_DIR/06_dedicated_capacity.csv"
SHARED_REQ_FILE="$OUTPUT_DIR/07_shared_capacity.csv"
NS_AUDIT_FILE="$OUTPUT_DIR/08_namespace_dedicated_audit.csv"
SUMMARY_FILE="$OUTPUT_DIR/09_capacity_summary.csv"
NODE_CAP_FILE="$OUTPUT_DIR/10_node_capacity_detail.csv"
METRICS_FILE="$OUTPUT_DIR/14_node_metrics.csv"
POD_METRICS_FILE="$OUTPUT_DIR/15_pod_metrics_top.csv"

RAW_NODES=$(mktemp)
RAW_PODS=$(mktemp)
RAW_PODS_TAB=$(mktemp)
RAW_TAINTS=$(mktemp)
RAW_TOLERATIONS=$(mktemp)
trap 'rm -f "$RAW_NODES" "$RAW_PODS" "$RAW_PODS_TAB" "$RAW_TAINTS" "$RAW_TOLERATIONS"' EXIT

log INFO "Collecting worker nodes..."
oc get nodes -o json > "$RAW_NODES"
log INFO "Collecting all pods..."
oc get pods --all-namespaces -o json > "$RAW_PODS"

# jq parsing helpers.
# Robust Kubernetes quantity parsers (CPU cores, memory bytes).
JQ_HELPERS='
  def cpu:
    try (
      if . == null or . == "" then 0
      elif (type == "number") then .
      else
        (tostring | gsub("^\\s+|\\s+$";"")) as $s |
        if ($s | test("m$")) then (($s | sub("m$";"")) | tonumber / 1000)
        elif ($s | test("^[0-9]*\\.?[0-9]+$")) then ($s | tonumber)
        else 0 end
      end
    ) catch 0;

  def mem_bytes:
    try (
      if . == null or . == "" then 0
      elif (type == "number") then .
      else
        (tostring | gsub("^\\s+|\\s+$";"")) as $s |
        if ($s | test("Ki$")) then (($s | sub("Ki$";"")) | tonumber * 1024)
        elif ($s | test("Mi$")) then (($s | sub("Mi$";"")) | tonumber * 1048576)
        elif ($s | test("Gi$")) then (($s | sub("Gi$";"")) | tonumber * 1073741824)
        elif ($s | test("Ti$")) then (($s | sub("Ti$";"")) | tonumber * 1099511627776)
        elif ($s | test("Pi$")) then (($s | sub("Pi$";"")) | tonumber * 1125899906842624)
        elif ($s | test("Ei$")) then (($s | sub("Ei$";"")) | tonumber * 1152921504606846976)
        elif ($s | test("K$")) then (($s | sub("K$";"")) | tonumber * 1000)
        elif ($s | test("M$")) then (($s | sub("M$";"")) | tonumber * 1000000)
        elif ($s | test("G$")) then (($s | sub("G$";"")) | tonumber * 1000000000)
        elif ($s | test("T$")) then (($s | sub("T$";"")) | tonumber * 1000000000000)
        elif ($s | test("P$")) then (($s | sub("P$";"")) | tonumber * 1000000000000000)
        elif ($s | test("E$")) then (($s | sub("E$";"")) | tonumber * 1000000000000000000)
        elif ($s | test("^[0-9]*\\.?[0-9]+$")) then ($s | tonumber)
        else 0 end
      end
    ) catch 0;

  def effective_requests:
    # Kubernetes effective pod request is max(sum(app container requests),
    # max(init-container request)) for each resource.
    (.spec.containers // []) as $c |
    (.spec.initContainers // []) as $i |
    {
      cpu_app:   ([$c[].resources.requests.cpu // "0" | cpu] | add // 0),
      mem_app:   ([$c[].resources.requests.memory // "0" | mem_bytes] | add // 0),
      cpu_init:  ([$i[].resources.requests.cpu // "0" | cpu] | max // 0),
      mem_init:  ([$i[].resources.requests.memory // "0" | mem_bytes] | max // 0)
    } |
    . + {
      cpu: ([.cpu_app, .cpu_init] | max),
      mem: ([.mem_app, .mem_init] | max)
    };

  def is_system_taint:
    ((.key // "") | test("^(node[.]kubernetes[.]io/(not-ready|unreachable|memory-pressure|disk-pressure|pid-pressure|network-unavailable)|node[.]alpha[.]kubernetes[.]io/not-ready|node-role[.]kubernetes[.]io/(master|control-plane|infra))$"));

  def custom_taints:
    [(.spec.taints // [])[] | select(is_system_taint | not)];

  def dedicated_taints:
    [(.spec.taints // [])[] |
      select((.effect // "NoSchedule") == "NoSchedule" or
             (.effect // "NoSchedule") == "NoExecute" or
             (.effect // "NoSchedule") == "PreferNoSchedule") |
      select(is_system_taint | not)
    ];
'

# -----------------------------------------------------------------------------
# 1. Node inventory + automatic dedicated/shared classification
# -----------------------------------------------------------------------------
log INFO "Discovering node taints and classifying nodes..."
jq -r "$JQ_HELPERS"'
  .items[] |
  . as $n |
  (($n.spec.taints // []) | map(select(is_system_taint | not))) as $custom |
  (($n.spec.taints // []) | map(select((.effect // "NoSchedule") == "NoSchedule" or (.effect // "NoSchedule") == "NoExecute" or (.effect // "NoSchedule") == "PreferNoSchedule") | select(is_system_taint | not))) as $ded |
  (($n.status.conditions // []) | map(select(.type == "Ready")) | .[0].status // "Unknown") as $ready |
  [$n.status.allocatable.cpu // "0" | cpu] as $cpu |
  [$n.status.allocatable.memory // "0" | mem_bytes] as $mem |
  {
    node: $n.metadata.name,
    ready: $ready,
    role: (
            if (($n.metadata.labels // {})["node-role.kubernetes.io/worker"] != null)
               or (($n.metadata.labels // {})["node-role.kubernetes.io/compute"] != null)
               or (($n.metadata.labels // {})["machine.openshift.io/cluster-api-machine-role"] == "worker")
               or (($n.metadata.labels // {})["machine.openshift.io/cluster-api-machine-type"] == "worker")
               or ((($n.metadata.labels // {})["node.openshift.io/os_id"] != null)
                   and (($n.metadata.labels // {})["node-role.kubernetes.io/master"] == null)
                   and (($n.metadata.labels // {})["node-role.kubernetes.io/control-plane"] == null)
                   and (($n.metadata.labels // {})["node-role.kubernetes.io/infra"] == null))
            then "worker"
            elif ((($n.metadata.labels // {})["node-role.kubernetes.io/master"] == null)
              and (($n.metadata.labels // {})["node-role.kubernetes.io/control-plane"] == null)
              and (($n.metadata.labels // {})["node-role.kubernetes.io/infra"] == null))
            then "worker-fallback"
            else "control-plane/infra" end),
    dedicated: ($ded | length > 0),
    dedicated_taint_count: ($ded | length),
    taints: ([$custom[] | ((.key // "") + "=" + (.value // "") + ":" + (.effect // "NoSchedule"))] | join(";")),
    cpu: $cpu[0],
    mem: $mem[0],
    labels: (($n.metadata.labels // {}) | to_entries | map(.key + "=" + .value) | join(";"))
  } |
  select(.role == "worker" or .role == "worker-fallback") |
  [ .node,.role,.ready,(if .dedicated then "DEDICATED" else "SHARED" end),.dedicated_taint_count,.taints,(.cpu|tostring),((.mem/1073741824*100|floor/100)|tostring),.labels ] | @csv
' "$RAW_NODES" > "$OUTPUT_DIR/.nodes_raw.csv"
{
  echo 'Node,role,ready,Classification,dedicated_taint_count,taints,cpu,mem,labels'
  cat "$OUTPUT_DIR/.nodes_raw.csv"
} > "$NODES_FILE"
rm -f "$OUTPUT_DIR/.nodes_raw.csv"

# Count worker nodes. If worker role labels are absent, use all Ready schedulable non-control-plane nodes.
WORKER_COUNT=$(awk -F',' 'NR>1 {r=$2;ready=$3;gsub(/"/,"",r);gsub(/"/,"",ready); if ((r=="worker" || r=="worker-fallback") && ready=="True") c++} END{print c+0}' "$NODES_FILE")
DEDICATED_NODE_COUNT=$(awk -F',' 'NR>1 {gsub(/"/,"",$4); if ($4=="DEDICATED") c++} END{print c+0}' "$NODES_FILE")
SHARED_NODE_COUNT=$((WORKER_COUNT - DEDICATED_NODE_COUNT))

log INFO "Worker/compute nodes discovered: $WORKER_COUNT"
log INFO "Automatically tainted/dedicated nodes: $DEDICATED_NODE_COUNT"
log INFO "Shared/general-purpose nodes: $SHARED_NODE_COUNT"

if [[ "$DEBUG" == true ]]; then
  echo "----- NODE CLASSIFICATION -----"
  cat "$NODES_FILE"
  echo "-------------------------------"
fi

# Dedicated node names as a jq array, restricted to nodes classified above.
DEDICATED_NODE_JSON=$(jq -R -s 'split("\n") | map(select(length>0))' < <(awk -F',' 'NR>1 {n=$1; gsub(/^"|"$/,"",n); d=$4; gsub(/^"|"$/,"",d); if(d=="DEDICATED") print n}' "$NODES_FILE"))

# -----------------------------------------------------------------------------
# 2. All node taints
# -----------------------------------------------------------------------------
log INFO "Capturing all node taints..."
jq -r '
  .items[] as $n |
  ($n.spec.taints // [])[]? |
  [$n.metadata.name,.key,.value,.effect] | @csv
' "$RAW_NODES" > "$RAW_TAINTS"
{
  echo 'Node,Taint_Key,Taint_Value,Taint_Effect,Classification'
  awk -F',' 'BEGIN{OFS=","} {gsub(/"/,"",$1); gsub(/"/,"",$2); gsub(/"/,"",$3); gsub(/"/,"",$4); cls="SYSTEM/TRANSIENT"; if ($2 !~ /^(node\.kubernetes\.io\/(not-ready|unreachable|memory-pressure|disk-pressure|pid-pressure|network-unavailable)|node\.alpha\.kubernetes\.io\/not-ready|node-role\.kubernetes\.io\/(master|control-plane|infra))$/ && $4 ~ /^(NoSchedule|NoExecute|PreferNoSchedule)$/) cls="DEDICATED/POOL-CANDIDATE"; print $1,$2,$3,$4,cls}' "$RAW_TAINTS"
} > "$TAINTS_FILE"

# -----------------------------------------------------------------------------
# 3. Pod tolerations + actual placement + effective CPU/memory requests
# -----------------------------------------------------------------------------
log INFO "Calculating effective pod requests and actual placement..."

# Build node class lookup for the pod report.
awk -F',' 'NR>1 {for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i); print $1"\t"$4}' "$NODES_FILE" > "$OUTPUT_DIR/.node_class_lookup"

# Pod placement records. We deliberately use actual running pod requests.
# Build node class lookup first so the placement sheet is authoritative.
node_class_jq=$(awk -F',' 'NR>1 {n=$1;gsub(/^"|"$/,"",n);c=$4;gsub(/^"|"$/,"",c);printf "%s\t%s\n",n,c}' "$NODES_FILE" | jq -Rn 'reduce (inputs | split("\t")) as $x ({}; .[$x[0]]=$x[1])')

jq -r --argjson nodeclasses "$node_class_jq" "$JQ_HELPERS"'
  .items[] |
  (effective_requests) as $r |
  (.spec.nodeName // "") as $node |
  ($nodeclasses[$node] // "NO NODE") as $class |
  ([ .spec.tolerations[]? | ((.key // "<operatorExists>") + "=" + (.value // "") + ":" + (.effect // "")) ] | join(";")) as $tols |
  [
    .metadata.namespace,
    .metadata.name,
    (.status.phase // "Unknown"),
    $node,
    $class,
    ($r.cpu | tostring),
    (($r.mem / 1073741824 * 100 | floor / 100) | tostring),
    $tols,
    ((.spec.nodeSelector // {}) | to_entries | map(.key+"="+.value) | join(";")),
    ((.metadata.ownerReferences // []) | map(select(.controller==true)) | if length>0 then (.[0].kind+"/"+.[0].name) else "standalone" end)
  ] | @csv
' "$RAW_PODS" > "$OUTPUT_DIR/.placement_authoritative.csv"

{
  echo 'Namespace,Pod_Name,Phase,Node,Node_Class,Effective_CPU_Request_Cores,Effective_Memory_Request_GiB,Pod_Tolerations,NodeSelector,Controller'
  cat "$OUTPUT_DIR/.placement_authoritative.csv"
} > "$PLACEMENT_FILE"

# Pod toleration sheet, one row per pod/taint toleration.
jq -r '
  .items[] as $p |
  ($p.spec.tolerations // [])[]? |
  [$p.metadata.namespace,$p.metadata.name,($p.spec.nodeName // ""),(.key // "<operatorExists>"),(.operator // "Equal"),(.value // ""),(.effect // ""),(.tolerationSeconds // "")] | @csv
' "$RAW_PODS" > "$RAW_TOLERATIONS"
{
  echo 'Namespace,Pod_Name,Node,Toleration_Key,Operator,Toleration_Value,Toleration_Effect,Toleration_Seconds'
  cat "$RAW_TOLERATIONS"
} > "$TOLERATIONS_FILE"

# Separate pod request sheet: actual running/pending pod effective requests.
jq -r "$JQ_HELPERS"'
  .items[] |
  (effective_requests) as $r |
  [
    .metadata.namespace,
    .metadata.name,
    (.status.phase // "Unknown"),
    (.spec.nodeName // ""),
    ($r.cpu | tostring),
    (($r.mem / 1073741824 * 100 | floor / 100) | tostring),
    ((.spec.containers // []) | length | tostring),
    ((.spec.initContainers // []) | length | tostring),
    ((.metadata.ownerReferences // []) | map(select(.controller==true)) | if length>0 then (.[0].kind+"/"+.[0].name) else "standalone" end)
  ] | @csv
' "$RAW_PODS" > "$OUTPUT_DIR/.request_rows.csv"
{
  echo 'Namespace,Pod_Name,Phase,Node,Effective_CPU_Request_Cores,Effective_Memory_Request_GiB,Container_Count,InitContainer_Count,Controller'
  cat "$OUTPUT_DIR/.request_rows.csv"
} > "$REQUESTS_FILE"

# -----------------------------------------------------------------------------
# 4. Node-level request aggregation (actual hosted running pods)
# -----------------------------------------------------------------------------
log INFO "Aggregating CPU/memory requests by node..."

jq -r "$JQ_HELPERS"'
  .items[] |
  select((.status.phase // "") == "Running") |
  (.spec.nodeName // "") as $node |
  select($node != "") |
  (effective_requests) as $r |
  [$node,$r.cpu,($r.mem/1073741824),.metadata.namespace,.metadata.name] | @tsv
' "$RAW_PODS" > "$OUTPUT_DIR/.running_requests.tsv"

# Build capacity from actual allocatable values and actual running pod requests.
node_cap_jq=$(jq -r "$JQ_HELPERS"'
  .items[] |
  ((.status.allocatable.cpu // "0") | cpu) as $cpu |
  ((.status.allocatable.memory // "0") | mem_bytes) as $mem |
  ((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready |
  [ .metadata.name, $ready, $cpu, ($mem/1073741824) ] | @tsv
' "$RAW_NODES")

# Node classification + request sums.
{
  echo 'Node,Node_Class,Ready,Allocatable_CPU_Cores,Allocatable_Memory_GiB,Running_Pods,CPU_Requests_Cores,Memory_Requests_GiB,CPU_Free_Cores,Memory_Free_GiB,CPU_Request_Pct,Memory_Request_Pct'
  while IFS=$'\t' read -r node ready cpu mem; do
    [[ -z "$node" ]] && continue
    class=$(awk -F '\t' -v n="$node" '$1==n{print $2}' "$OUTPUT_DIR/.node_class_lookup")
    [[ -z "$class" ]] && class="UNKNOWN"
    sums=$(awk -F'\t' -v n="$node" 'BEGIN{p=0;c=0;m=0} $1==n{p++;c+=$2;m+=$3} END{printf "%d\t%.6f\t%.6f",p,c,m}' "$OUTPUT_DIR/.running_requests.tsv")
    IFS=$'\t' read -r pods cpu_req mem_req <<< "$sums"
    cpu_free=$(awk -v a="$cpu" -v r="$cpu_req" 'BEGIN{printf "%.4f",a-r}')
    mem_free=$(awk -v a="$mem" -v r="$mem_req" 'BEGIN{printf "%.4f",a-r}')
    cpu_pct=$(awk -v r="$cpu_req" -v a="$cpu" 'BEGIN{if(a>0)printf "%.2f",100*r/a; else print "0.00"}')
    mem_pct=$(awk -v r="$mem_req" -v a="$mem" 'BEGIN{if(a>0)printf "%.2f",100*r/a; else print "0.00"}')
    printf '%s,%s,%s,%.4f,%.4f,%d,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f\n' "$node" "$class" "$ready" "$cpu" "$mem" "$pods" "$cpu_req" "$mem_req" "$cpu_free" "$mem_free" "$cpu_pct" "$mem_pct"
  done <<< "$node_cap_jq"
} > "$NODE_CAP_FILE"

# -----------------------------------------------------------------------------
# 4b. Metrics utilization (oc adm top) — optional, never fails the report
# -----------------------------------------------------------------------------
# Red Hat capacity practice: watch BOTH Request/Allocatable AND Usage/Allocatable.
# Usage comes from metrics-server via: oc adm top nodes / pods
log INFO "Collecting node/pod utilization metrics (oc adm top)..."
METRICS_AVAILABLE=false
{
  echo 'Node,CPU_Usage_Cores,CPU_Usage_Pct,Memory_Usage_Bytes,Memory_Usage_Pct'
  if [[ "$DRY_RUN" != "true" ]]; then
    # oc adm top nodes: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
    oc adm top nodes --no-headers 2>/dev/null | while read -r name cpu_cores cpu_pct mem_val mem_pct rest; do
      [[ -z "$name" ]] && continue
      # Strip % sign
      cpu_pct=${cpu_pct%%%}
      mem_pct=${mem_pct%%%}
      # Normalize memory to bytes if possible (e.g. 1234Mi, 1Gi)
      mem_bytes=$(awk -v v="$mem_val" 'BEGIN{
        if (v ~ /Ki$/) { sub(/Ki$/,"",v); printf "%.0f", v*1024; exit }
        if (v ~ /Mi$/) { sub(/Mi$/,"",v); printf "%.0f", v*1048576; exit }
        if (v ~ /Gi$/) { sub(/Gi$/,"",v); printf "%.0f", v*1073741824; exit }
        if (v ~ /Ti$/) { sub(/Ti$/,"",v); printf "%.0f", v*1099511627776; exit }
        printf "%.0f", v+0
      }')
      # keep millicores suffix for awk conversion (do not strip 'm' here)
      # oc adm top shows CPU as 250m or 1 — normalize to cores
      cpu_cores_n=$(awk -v v="$cpu_cores" 'BEGIN{
        gsub(/ /,"",v)
        if (v ~ /m$/) { sub(/m$/,"",v); printf "%.4f", (v+0)/1000; exit }
        printf "%.4f", v+0
      }')
      printf '%s,%.4f,%s,%s,%s\n' "$name" "$cpu_cores_n" "$cpu_pct" "$mem_bytes" "$mem_pct"
    done
  fi
} > "$METRICS_FILE" 2>/dev/null || echo 'Node,CPU_Usage_Cores,CPU_Usage_Pct,Memory_Usage_Bytes,Memory_Usage_Pct' > "$METRICS_FILE"

if [[ $(wc -l < "$METRICS_FILE") -gt 1 ]]; then
  METRICS_AVAILABLE=true
  log INFO "Node metrics collected from metrics-server"
else
  log WARN "Node metrics unavailable (metrics-server missing or oc adm top failed) — HTML will show requests only"
fi

{
  echo 'Namespace,Pod,CPU_Usage,Memory_Usage'
  if [[ "$DRY_RUN" != "true" && "$METRICS_AVAILABLE" == "true" ]]; then
    oc adm top pods -A --no-headers 2>/dev/null | while read -r ns pod cpu mem rest; do
      [[ -z "$ns" ]] && continue
      printf '%s,%s,%s,%s\n' "$ns" "$pod" "$cpu" "$mem"
    done | head -n 5000
  fi
} > "$POD_METRICS_FILE" 2>/dev/null || echo 'Namespace,Pod,CPU_Usage,Memory_Usage' > "$POD_METRICS_FILE"

# -----------------------------------------------------------------------------
# 5. Dedicated vs shared capacity — SEPARATE calculations
# -----------------------------------------------------------------------------
aggregate_capacity() {
  local class="$1" out="$2"
  awk -F',' -v cls="$class" '
    BEGIN{cpu=mem=creq=mreq=pods=nodes=0}
    NR>1 && $2==cls {nodes++; cpu+=$4; mem+=$5; pods+=$6; creq+=$7; mreq+=$8}
    END{
      cpu_pct=(cpu>0?100*creq/cpu:0); mem_pct=(mem>0?100*mreq/mem:0)
      free_cpu=cpu-creq; free_mem=mem-mreq
      printf "Capacity_Type,Node_Count,Running_Pods,Allocatable_CPU_Cores,Allocatable_Memory_GiB,CPU_Requests_Cores,Memory_Requests_GiB,Free_CPU_Cores,Free_Memory_GiB,CPU_Request_Pct,Memory_Request_Pct\n"
      printf "%s,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f\n",cls,nodes,pods,cpu,mem,creq,mreq,free_cpu,free_mem,cpu_pct,mem_pct
    }' "$NODE_CAP_FILE" > "$out"
}

aggregate_capacity DEDICATED "$DEDICATED_REQ_FILE"
aggregate_capacity SHARED "$SHARED_REQ_FILE"

# -----------------------------------------------------------------------------
# 6. Namespace/pod audit: dedicated workloads on dedicated vs shared nodes
# -----------------------------------------------------------------------------
log INFO "Auditing namespace/pod placement against dedicated nodes..."

# A namespace is considered "dedicated" when at least one running pod is on a dedicated
# node OR its pods contain nodeSelector/nodeAffinity/toleration targeting a dedicated taint.
# The audit deliberately uses actual placement as the strongest signal.

dedicated_taint_json=$(jq -r '
  [ .items[] | (.spec.taints // [])[]? |
    select((.effect // "NoSchedule") == "NoSchedule" or (.effect // "NoSchedule") == "NoExecute" or (.effect // "NoSchedule") == "PreferNoSchedule") |
    select(((.key // "") | test("^(node[.]kubernetes[.]io/(not-ready|unreachable|memory-pressure|disk-pressure|pid-pressure|network-unavailable)|node[.]alpha[.]kubernetes[.]io/not-ready|node-role[.]kubernetes[.]io/(master|control-plane|infra))$")) | not) |
    {key:(.key//""),value:(.value//""),effect:(.effect//"NoSchedule")}
  ] | unique_by([.key,.value,.effect])
' "$RAW_NODES")

jq -r --argjson nodeclasses "$node_class_jq" --argjson dedtaints "$dedicated_taint_json" "$JQ_HELPERS"'
  .items[] |
  select((.status.phase // "") == "Running") |
  (.spec.nodeName // "") as $node |
  ($nodeclasses[$node] // "NO NODE") as $class |
  (effective_requests) as $r |
  [ .spec.tolerations[]? ] as $tols |
  ([$dedtaints[] as $dt |
      $tols[]? |
      select(
        ((.effect // "") == "" or (.effect // "") == $dt.effect) and
        ((.operator // "Equal") == "Exists" or ((.key // "") == $dt.key and ((.operator // "Equal") == "Exists" or (.value // "") == $dt.value)))
      ) |
      $dt.key + "=" + $dt.value + ":" + $dt.effect
    ] | unique | join(";")) as $matched |
  # True dedicated targeting: nodeSelector or affinity references a dedicated taint KEY
  # (not merely "any" selector — that was flooding exceptions with CP4I etc.)
  (
    [ $dedtaints[].key ] | unique
  ) as $dkeys |
  (
    [
      ((.spec.nodeSelector // {}) | keys[]) ,
      ((.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms // [])[]? |
        (.matchExpressions // [])[]? | .key),
      ((.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution // [])[]? |
        (.preference.matchExpressions // [])[]? | .key)
    ] | unique
  ) as $selkeys |
  (
    any($selkeys[]; . as $k | any($dkeys[]; . == $k))
  ) as $targeted |
  (
    [$selkeys[] as $k | select(any($dkeys[]; . == $k)) | $k] | unique | join(";")
  ) as $target_keys |
  [
    .metadata.namespace,
    .metadata.name,
    $node,
    $class,
    (if $class == "DEDICATED" then "YES" else "NO" end),
    $matched,
    (if $targeted then "YES" else "NO" end),
    $target_keys,
    ($r.cpu | tostring),
    (($r.mem/1073741824*100|floor/100)|tostring),
    ((.metadata.ownerReferences // []) | map(select(.controller==true)) | if length>0 then (.[0].kind+"/"+.[0].name) else "standalone" end)
  ] | @csv
' "$RAW_PODS" > "$OUTPUT_DIR/.audit_rows.csv"

{
  echo 'Namespace,Pod_Name,Node,Node_Class,Actually_On_Dedicated_Node,Matching_Dedicated_Taint_Toleration,Has_NodeSelector_Or_Affinity,Dedicated_Target_Keys,CPU_Request_Cores,Memory_Request_GiB,Controller'
  cat "$OUTPUT_DIR/.audit_rows.csv"
} > "$NS_AUDIT_FILE"

# -----------------------------------------------------------------------------
# 7. Summary with explicit capacity math
# -----------------------------------------------------------------------------
readarray -t DED_SUM < <(tail -n +2 "$DEDICATED_REQ_FILE" | awk -F',' '{print $2,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
readarray -t SHR_SUM < <(tail -n +2 "$SHARED_REQ_FILE" | awk -F',' '{print $2,$4,$5,$6,$7,$8,$9,$10,$11,$12}')

# Extract fields safely from one-row capacity CSV.
IFS=',' read -r _ dc_nodes dc_pods dc_cpu dc_mem dc_req_cpu dc_req_mem dc_free_cpu dc_free_mem dc_cpu_pct dc_mem_pct < <(tail -n +2 "$DEDICATED_REQ_FILE")
IFS=',' read -r _ sc_nodes sc_pods sc_cpu sc_mem sc_req_cpu sc_req_mem sc_free_cpu sc_free_mem sc_cpu_pct sc_mem_pct < <(tail -n +2 "$SHARED_REQ_FILE")

# Dedicated namespace placement violations.
# Exception = Running on SHARED + matches dedicated taint toleration + has nodeSelector/affinity
# (mere toleration without targeting is too common and creates noise)
DEDICATED_ON_SHARED=$(awk -F',' 'NR>1 {
  for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
  if ($5=="NO" && $6!="" && $7=="YES") c++
} END{print c+0}' "$NS_AUDIT_FILE")
DEDICATED_ON_DEDICATED=$(awk -F',' 'NR>1 {
  for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
  if ($5=="YES") c++
} END{print c+0}' "$NS_AUDIT_FILE")

# Namespaces with any pod on shared nodes AND any pod on dedicated nodes.
MIXED_NS=$(awk -F',' 'NR>1 {
  for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
  ns=$1; d=$5; seen[ns]++; if(d=="YES") yes[ns]++; if(d=="NO") no[ns]++
} END{for(ns in seen) if(yes[ns]>0 && no[ns]>0)c++; print c+0}' "$NS_AUDIT_FILE")

# Create a small text classification for the report.
{
  echo 'Metric,Value,Unit/Description'
  echo "Total Worker/Compute Nodes,$WORKER_COUNT,nodes"
  echo "Dedicated/Tainted Pool Nodes,$DEDICATED_NODE_COUNT,nodes"
  echo "Shared/General-Purpose Nodes,$SHARED_NODE_COUNT,nodes"
  echo "Dedicated Node Definition,Custom scheduling taint on node,Automatically discovered"
  echo "Dedicated Capacity CPU,$dc_cpu,cores"
  echo "Dedicated Capacity Memory,$dc_mem,GiB"
  echo "Dedicated CPU Requests,$dc_req_cpu,cores"
  echo "Dedicated Memory Requests,$dc_req_mem,GiB"
  echo "Dedicated CPU Request Utilization,$dc_cpu_pct,%"
  echo "Dedicated Memory Request Utilization,$dc_mem_pct,%"
  echo "Dedicated Free CPU,$dc_free_cpu,cores"
  echo "Dedicated Free Memory,$dc_free_mem,GiB"
  echo "Shared Capacity CPU,$sc_cpu,cores"
  echo "Shared Capacity Memory,$sc_mem,GiB"
  echo "Shared CPU Requests,$sc_req_cpu,cores"
  echo "Shared Memory Requests,$sc_req_mem,GiB"
  echo "Shared CPU Request Utilization,$sc_cpu_pct,%"
  echo "Shared Memory Request Utilization,$sc_mem_pct,%"
  echo "Shared Free CPU,$sc_free_cpu,cores"
  echo "Shared Free Memory,$sc_free_mem,GiB"
  echo "Running Dedicated-Pool Pods,$DEDICATED_ON_DEDICATED,pods"
  echo "Running Pods From Dedicated/Targeted Workloads On Shared Nodes,$DEDICATED_ON_SHARED,pods (placement issue candidates)"
  echo "Namespaces Using Both Dedicated And Shared Nodes,$MIXED_NS,namespaces (review candidates)"
  echo "Capacity Method,Actual Running Pod Effective Requests vs Node Allocatable,No replica multiplication"
  echo "Effective Pod Request,Max(sum app requests), max(init-container request),Kubernetes scheduling semantics"
  echo "Planning Basis,Requests (scheduler guarantee) — not Limits,Golden rule"
  echo "Target Utilization,$TARGET_UTILIZATION_PCT,% of allocatable (planning headroom)"
} > "$SUMMARY_FILE"

# -----------------------------------------------------------------------------
# 7b. DaemonSet footprint + Node recommendation (forecast how many nodes to add)
# -----------------------------------------------------------------------------
# DaemonSets run on every matching node. Net capacity per NEW node =
#   avg_allocatable - avg_daemonset_requests
# Then apply TARGET_UTILIZATION_PCT headroom on that net figure.
#
# TWO recommendation modes:
#   A) Actual Running pods (current consumption)
#   B) Desired replicas (Deployment/StatefulSet/ReplicaSet desired * template requests)
log INFO "Measuring DaemonSet request footprint on worker nodes..."

DS_CPU_PER_NODE="0"
DS_MEM_PER_NODE="0"
DS_POD_COUNT="0"
if [[ -f "$PLACEMENT_FILE" ]]; then
  _ds_out=$(awk -F',' '
    NR>1 {
      for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
      phase=$3; node=$4; cls=$5; cpu=$6+0; mem=$7+0; ctrl=$10
      if (phase!="Running") next
      if (cls!="DEDICATED" && cls!="SHARED") next
      if (ctrl !~ /^DaemonSet\//) next
      nodes[node]=1
      c[node]+=cpu; m[node]+=mem; pods++
    }
    END {
      n=0; tc=0; tm=0
      for (x in nodes) { n++; tc+=c[x]; tm+=m[x] }
      if (n>0) printf "%.4f %.4f %d", tc/n, tm/n, pods+0
      else printf "0 0 0"
    }
  ' "$PLACEMENT_FILE" 2>/dev/null || true)
  if [[ -n "${_ds_out:-}" ]]; then
    read -r DS_CPU_PER_NODE DS_MEM_PER_NODE DS_POD_COUNT <<< "$_ds_out" || true
  fi
fi
DS_CPU_PER_NODE=${DS_CPU_PER_NODE:-0}
DS_MEM_PER_NODE=${DS_MEM_PER_NODE:-0}
DS_POD_COUNT=${DS_POD_COUNT:-0}

log INFO "DaemonSet avg footprint per worker node: ${DS_CPU_PER_NODE} cores, ${DS_MEM_PER_NODE} GiB (${DS_POD_COUNT} DS pods total)"

# Helper: safe nodes-to-add calculation (prints: cpu_add mem_add)
# Args via env-like awk vars: nodes avg_cpu avg_mem creq mreq net_cpu net_mem tgt
calc_nodes_to_add() {
  awk -v nodes="${1:-0}" -v avg_cpu="${2:-0}" -v avg_mem="${3:-0}" \
      -v creq="${4:-0}" -v mreq="${5:-0}" \
      -v net_cpu="${6:-0}" -v net_mem="${7:-0}" \
      -v t="${8:-0.8}" 'BEGIN{
    cpu_head = (nodes+0)*(avg_cpu+0)*t - (creq+0)
    mem_head = (nodes+0)*(avg_mem+0)*t - (mreq+0)
    gain_c = (net_cpu+0)*t
    gain_m = (net_mem+0)*t
    if (cpu_head >= 0 || gain_c <= 0) cpu_add=0
    else cpu_add = int((-cpu_head)/gain_c + 0.9999)
    if (mem_head >= 0 || gain_m <= 0) mem_add=0
    else mem_add = int((-mem_head)/gain_m + 0.9999)
    printf "%d %d %.4f %.4f", cpu_add, mem_add, cpu_head, mem_head
  }'
}

# Pool averages from NODE_CAP_FILE -> prints: nodes avg_cpu avg_mem creq mreq
pool_stats() {
  local cls="$1"
  awk -F',' -v cls="$cls" '
    NR>1 {
      for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
      if ($2==cls) { n++; cpu+=$4+0; mem+=$5+0; creq+=$7+0; mreq+=$8+0 }
    }
    END {
      if(n>0) printf "%d %.4f %.4f %.4f %.4f", n, cpu/n, mem/n, creq, mreq
      else printf "0 0 0 0 0"
    }' "$NODE_CAP_FILE" 2>/dev/null || echo "0 0 0 0 0"
}

log INFO "Calculating node recommendations (target utilization ${TARGET_UTILIZATION_PCT}%, DaemonSet-aware)..."

RECOMMEND_FILE="$OUTPUT_DIR/11_node_recommendations.csv"
: > "$RECOMMEND_FILE"
echo 'Pool,Basis,Current_Nodes,Avg_CPU_Cores_Per_Node,Avg_Memory_GiB_Per_Node,DaemonSet_CPU_Per_Node,DaemonSet_Mem_Per_Node,Net_CPU_Per_New_Node,Net_Mem_Per_New_Node,CPU_Requests,Mem_Requests,Target_Util_Pct,CPU_Headroom_Cores,Mem_Headroom_GiB,CPU_Nodes_To_Add,Mem_Nodes_To_Add,Recommended_Nodes_To_Add,Binding_Constraint,Status' >> "$RECOMMEND_FILE"

tgt=$(awk -v t="${TARGET_UTILIZATION_PCT:-80}" 'BEGIN{printf "%.4f", t/100}')

for pool in DEDICATED SHARED; do
  read -r nodes avg_cpu avg_mem creq mreq <<< "$(pool_stats "$pool")" || true
  nodes=${nodes:-0}; avg_cpu=${avg_cpu:-0}; avg_mem=${avg_mem:-0}; creq=${creq:-0}; mreq=${mreq:-0}
  net_cpu=$(awk -v a="$avg_cpu" -v d="$DS_CPU_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
  net_mem=$(awk -v a="$avg_mem" -v d="$DS_MEM_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
  read -r cpu_add mem_add cpu_head mem_head <<< "$(calc_nodes_to_add "$nodes" "$avg_cpu" "$avg_mem" "$creq" "$mreq" "$net_cpu" "$net_mem" "$tgt")" || true
  cpu_add=${cpu_add:-0}; mem_add=${mem_add:-0}; cpu_head=${cpu_head:-0}; mem_head=${mem_head:-0}
  if [[ "$cpu_add" -ge "$mem_add" ]]; then rec=$cpu_add; bind=CPU; else rec=$mem_add; bind=Memory; fi
  if [[ "$rec" -eq 0 ]]; then
    status="OK - within target headroom"
  else
    status="ADD ${rec} node(s) - requests exceed ${TARGET_UTILIZATION_PCT}% target"
  fi
  printf '%s,Actual_Running,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s,%.4f,%.4f,%s,%s,%s,%s,%s\n' \
    "$pool" "$nodes" "$avg_cpu" "$avg_mem" "$DS_CPU_PER_NODE" "$DS_MEM_PER_NODE" \
    "$net_cpu" "$net_mem" "$creq" "$mreq" "${TARGET_UTILIZATION_PCT}" \
    "$cpu_head" "$mem_head" "$cpu_add" "$mem_add" "$rec" "$bind" "$status" >> "$RECOMMEND_FILE"
done

log INFO "Actual-running recommendations written"

# -----------------------------------------------------------------------------
# 7b2. Desired-replica recommendations (Deployments / StatefulSets / pods)
# -----------------------------------------------------------------------------
# Uses controller desired replicas * per-pod effective request estimated from
# actual running pods of that controller (avg). Falls back to Running total
# when controller has 0 samples.
log INFO "Calculating desired-replica based recommendations (Deploy/STS/pods)..."

DESIRED_FILE="$OUTPUT_DIR/13_desired_replica_recommendations.csv"
DESIRED_DETAIL="$OUTPUT_DIR/13_desired_replica_detail.csv"

# From placement: controller -> sum cpu, sum mem, count running pods, set of nodes classes
# Estimate per-replica request = total_running_req / running_pods for that controller
# Desired replicas: for Deploy/STS we need API; approximate with max(running,1) is wrong.
# Better: query Deployments and StatefulSets for .spec.replicas
RAW_WORKLOADS="$OUTPUT_DIR/.workloads.json"
if [[ "$DRY_RUN" == "true" ]]; then
  echo '{"items":[]}' > "$RAW_WORKLOADS"
else
  # Merge Deployments + StatefulSets into one List (best-effort; never fail the report)
  _dep=$(oc get deploy --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
  _sts=$(oc get sts --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
  jq -s '{apiVersion:"v1",kind:"List",items:(map(.items // []) | add)}' \
    <(echo "$_dep") <(echo "$_sts") > "$RAW_WORKLOADS" 2>/dev/null \
    || echo '{"items":[]}' > "$RAW_WORKLOADS"
fi

# Build controller key = Kind/Name in namespace -> desired replicas, and template requests if present
# Also aggregate from placement: Namespace, Controller -> running count, cpu, mem
jq -r --argjson helpers 0 '
  # placeholder; real logic in next jq using helpers string
  empty
' /dev/null 2>/dev/null || true

# Per-controller running stats from placement CSV
awk -F',' '
  NR>1 {
    for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
    phase=$3; cls=$5; cpu=$6+0; mem=$7+0; ns=$1; ctrl=$10
    if (phase!="Running") next
    if (cls!="DEDICATED" && cls!="SHARED") next
    if (ctrl=="" || ctrl=="standalone") next
    key=ns "|" ctrl
    c[key]+=cpu; m[key]+=mem; n[key]++
    # track pool: if any pod on DEDICATED mark dedicated affinity
    if (cls=="DEDICATED") d[key]=1
    if (cls=="SHARED") s[key]=1
  }
  END {
    for (k in n)
      printf "%s\t%d\t%.6f\t%.6f\t%d\t%d\n", k, n[k], c[k], m[k], d[k]+0, s[k]+0
  }
' "$PLACEMENT_FILE" > "$OUTPUT_DIR/.ctrl_running.tsv" 2>/dev/null || : > "$OUTPUT_DIR/.ctrl_running.tsv"

# Desired replicas from Deploy/STS
jq -r '
  .items[]? |
  (.kind // "Unknown") as $k |
  (.metadata.namespace // "") as $ns |
  (.metadata.name // "") as $name |
  ((.spec.replicas // 1) | tonumber) as $rep |
  # template requests
  ([ (.spec.template.spec.containers[]? | .resources.requests.cpu // "0") ] ) as $cpus |
  ([ (.spec.template.spec.containers[]? | .resources.requests.memory // "0") ] ) as $mems |
  ([ (.spec.template.spec.initContainers[]? | .resources.requests.cpu // "0") ] ) as $icpus |
  ([ (.spec.template.spec.initContainers[]? | .resources.requests.memory // "0") ] ) as $imems |
  [$k, $ns, $name, $rep, ($cpus|join(";")), ($mems|join(";")), ($icpus|join(";")), ($imems|join(";"))] | @tsv
' "$RAW_WORKLOADS" 2>/dev/null > "$OUTPUT_DIR/.workload_desired.tsv" || : > "$OUTPUT_DIR/.workload_desired.tsv"

# Parse quantity helpers in awk is hard; use a small python helper for desired totals
python3 - "$OUTPUT_DIR" <<'PYDES' || true
import csv, re, sys
from pathlib import Path
out = Path(sys.argv[1])

def cpu(s):
    if s is None or s == "": return 0.0
    s = str(s).strip()
    try:
        if s.endswith("m"): return float(s[:-1]) / 1000.0
        return float(s)
    except: return 0.0

def mem_gib(s):
    if s is None or s == "": return 0.0
    s = str(s).strip()
    try:
        units = {"Ki":1/(1024**2), "Mi":1/1024, "Gi":1.0, "Ti":1024.0,
                 "K":1/(1000**2)*1.024/1.024, "M":1/1000*1.024, "G":1.0, "T":1000.0}
        # simpler:
        for suf, mult in [("Ki",1/1048576),("Mi",1/1024),("Gi",1),("Ti",1024),
                          ("K",0.000001),("M",0.001),("G",1),("T",1000)]:
            if s.endswith(suf):
                return float(s[:-len(suf)]) * mult
        return float(s) / (1024**3)  # assume bytes
    except: return 0.0

def eff_cpu(cpus, icpus):
    app = sum(cpu(x) for x in cpus if x)
    init = max([cpu(x) for x in icpus if x] or [0])
    return max(app, init)

def eff_mem(mems, imems):
    app = sum(mem_gib(x) for x in mems if x)
    init = max([mem_gib(x) for x in imems if x] or [0])
    return max(app, init)

# running stats
running = {}  # ns|Kind/name -> (pods, cpu, mem, on_ded, on_shr)
for line in (out/".ctrl_running.tsv").read_text(errors="replace").splitlines():
    if not line.strip(): continue
    parts = line.split("\t")
    if len(parts) < 6: continue
    running[parts[0]] = (int(parts[1]), float(parts[2]), float(parts[3]), int(parts[4]), int(parts[5]))

# desired workloads
detail_rows = []
ded_cpu = ded_mem = shr_cpu = shr_mem = 0.0
total_cpu = total_mem = 0.0

wl_path = out/".workload_desired.tsv"
if wl_path.exists():
    for line in wl_path.read_text(errors="replace").splitlines():
        if not line.strip(): continue
        parts = line.split("\t")
        if len(parts) < 8: continue
        kind, ns, name, rep_s, cpus, mems, icpus, imems = parts[:8]
        try: rep = int(float(rep_s))
        except: rep = 1
        ctrl = f"{kind}/{name}"
        key = f"{ns}|{ctrl}"
        # Prefer template requests; fall back to observed avg per running pod
        pc = eff_cpu(cpus.split(";") if cpus else [], icpus.split(";") if icpus else [])
        pm = eff_mem(mems.split(";") if mems else [], imems.split(";") if imems else [])
        if pc == 0 and pm == 0 and key in running:
            pods, csum, msum, _, _ = running[key]
            if pods > 0:
                pc = csum / pods
                pm = msum / pods
        d_cpu = pc * rep
        d_mem = pm * rep
        on_ded = running.get(key, (0,0,0,0,0))[3]
        on_shr = running.get(key, (0,0,0,0,0))[4]
        # Assign to pool: dedicated if any running on dedicated, else shared
        if on_ded and not on_shr:
            pool = "DEDICATED"
            ded_cpu += d_cpu; ded_mem += d_mem
        elif on_ded and on_shr:
            pool = "MIXED"
            # split by running ratio if possible
            pods, csum, msum, _, _ = running[key]
            # put all in shared for safety (worst case shared pressure) + count dedicated portion
            shr_cpu += d_cpu; shr_mem += d_mem
        else:
            pool = "SHARED"
            shr_cpu += d_cpu; shr_mem += d_mem
        total_cpu += d_cpu; total_mem += d_mem
        detail_rows.append({
            "Namespace": ns, "Controller": ctrl, "Desired_Replicas": rep,
            "CPU_Per_Replica": f"{pc:.4f}", "Mem_GiB_Per_Replica": f"{pm:.4f}",
            "Desired_CPU_Cores": f"{d_cpu:.4f}", "Desired_Mem_GiB": f"{d_mem:.4f}",
            "Pool_Hint": pool
        })

# Also add standalone / non-deploy running demand already captured in actual mode;
# desired mode focuses on Deploy/STS. DaemonSets handled separately via net_per_node.

with (out/"13_desired_replica_detail.csv").open("w", newline="", encoding="utf-8") as f:
    cols = ["Namespace","Controller","Desired_Replicas","CPU_Per_Replica","Mem_GiB_Per_Replica","Desired_CPU_Cores","Desired_Mem_GiB","Pool_Hint"]
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    for r in sorted(detail_rows, key=lambda x: -float(x["Desired_CPU_Cores"])):
        w.writerow(r)

# Write pool desired totals for shell to consume
with (out/".desired_pool_totals.tsv").open("w") as f:
    f.write(f"DEDICATED\t{ded_cpu:.6f}\t{ded_mem:.6f}\n")
    f.write(f"SHARED\t{shr_cpu:.6f}\t{shr_mem:.6f}\n")
    f.write(f"TOTAL\t{total_cpu:.6f}\t{total_mem:.6f}\n")
print(f"Desired replica workloads: {len(detail_rows)} controllers, CPU={total_cpu:.2f} Mem={total_mem:.2f}GiB")
PYDES

# Append desired-replica recommendations per pool into RECOMMEND_FILE
echo 'Pool,Basis,Current_Nodes,Avg_CPU_Cores_Per_Node,Avg_Memory_GiB_Per_Node,DaemonSet_CPU_Per_Node,DaemonSet_Mem_Per_Node,Net_CPU_Per_New_Node,Net_Mem_Per_New_Node,CPU_Requests,Mem_Requests,Target_Util_Pct,CPU_Headroom_Cores,Mem_Headroom_GiB,CPU_Nodes_To_Add,Mem_Nodes_To_Add,Recommended_Nodes_To_Add,Binding_Constraint,Status' > "$DESIRED_FILE"

for pool in DEDICATED SHARED; do
  read -r nodes avg_cpu avg_mem _creq _mreq <<< "$(pool_stats "$pool")" || true
  nodes=${nodes:-0}; avg_cpu=${avg_cpu:-0}; avg_mem=${avg_mem:-0}
  # desired requests for this pool
  creq=$(awk -F'\t' -v p="$pool" '$1==p{printf "%.4f",$2}' "$OUTPUT_DIR/.desired_pool_totals.tsv" 2>/dev/null || echo 0)
  mreq=$(awk -F'\t' -v p="$pool" '$1==p{printf "%.4f",$3}' "$OUTPUT_DIR/.desired_pool_totals.tsv" 2>/dev/null || echo 0)
  creq=${creq:-0}; mreq=${mreq:-0}
  # Add DaemonSet cost for existing nodes into desired demand (DS already run)
  ds_cpu_total=$(awk -v n="$nodes" -v d="$DS_CPU_PER_NODE" 'BEGIN{printf "%.4f", n*d}')
  ds_mem_total=$(awk -v n="$nodes" -v d="$DS_MEM_PER_NODE" 'BEGIN{printf "%.4f", n*d}')
  creq=$(awk -v a="$creq" -v b="$ds_cpu_total" 'BEGIN{printf "%.4f", a+b}')
  mreq=$(awk -v a="$mreq" -v b="$ds_mem_total" 'BEGIN{printf "%.4f", a+b}')
  net_cpu=$(awk -v a="$avg_cpu" -v d="$DS_CPU_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
  net_mem=$(awk -v a="$avg_mem" -v d="$DS_MEM_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
  read -r cpu_add mem_add cpu_head mem_head <<< "$(calc_nodes_to_add "$nodes" "$avg_cpu" "$avg_mem" "$creq" "$mreq" "$net_cpu" "$net_mem" "$tgt")" || true
  cpu_add=${cpu_add:-0}; mem_add=${mem_add:-0}; cpu_head=${cpu_head:-0}; mem_head=${mem_head:-0}
  if [[ "$cpu_add" -ge "$mem_add" ]]; then rec=$cpu_add; bind=CPU; else rec=$mem_add; bind=Memory; fi
  if [[ "$rec" -eq 0 ]]; then
    status="OK - desired replicas within target"
  else
    status="ADD ${rec} node(s) for desired replica demand"
  fi
  line=$(printf '%s,Desired_Replicas,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s,%.4f,%.4f,%s,%s,%s,%s,%s' \
    "$pool" "$nodes" "$avg_cpu" "$avg_mem" "$DS_CPU_PER_NODE" "$DS_MEM_PER_NODE" \
    "$net_cpu" "$net_mem" "$creq" "$mreq" "${TARGET_UTILIZATION_PCT}" \
    "$cpu_head" "$mem_head" "$cpu_add" "$mem_add" "$rec" "$bind" "$status")
  echo "$line" >> "$RECOMMEND_FILE"
  echo "$line" >> "$DESIRED_FILE"
done

log INFO "Desired-replica recommendations written"

# Append recommendation metrics to summary (best-effort)
{
  echo "DaemonSet Avg CPU Per Worker Node,$DS_CPU_PER_NODE,cores"
  echo "DaemonSet Avg Memory Per Worker Node,$DS_MEM_PER_NODE,GiB"
  echo "DaemonSet Running Pods Count,$DS_POD_COUNT,pods"
  while IFS=',' read -r pool basis nodes avg_cpu avg_mem ds_cpu ds_mem net_cpu net_mem creq mreq tutil cpu_h mem_h cpu_a mem_a rec bind status; do
    [[ "$pool" == "Pool" ]] && continue
    echo "${pool} [${basis}] Recommended Nodes To Add,$rec,nodes (binding: $bind) $status"
  done < "$RECOMMEND_FILE" || true
} >> "$SUMMARY_FILE" || true

# -----------------------------------------------------------------------------
# 7c. Future workload growth simulation (based on Actual Running)
# -----------------------------------------------------------------------------
log INFO "Simulating future workload growth scenarios: ${GROWTH_SCENARIOS_PCT}% ..."

GROWTH_FILE="$OUTPUT_DIR/12_growth_simulation.csv"
: > "$GROWTH_FILE"
echo 'Pool,Growth_Pct,Projected_CPU_Requests,Projected_Mem_Requests,Current_Nodes,Avg_CPU_Per_Node,Avg_Mem_Per_Node,Target_Util_Pct,CPU_Nodes_To_Add,Mem_Nodes_To_Add,Recommended_Nodes_To_Add,Binding_Constraint,Status' >> "$GROWTH_FILE"

IFS=',' read -ra GROWTHS <<< "${GROWTH_SCENARIOS_PCT:-10,25,50}"
for pool in DEDICATED SHARED; do
  read -r nodes avg_cpu avg_mem creq mreq <<< "$(pool_stats "$pool")" || true
  nodes=${nodes:-0}; avg_cpu=${avg_cpu:-0}; avg_mem=${avg_mem:-0}; creq=${creq:-0}; mreq=${mreq:-0}
  net_cpu=$(awk -v a="$avg_cpu" -v d="$DS_CPU_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
  net_mem=$(awk -v a="$avg_mem" -v d="$DS_MEM_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
  for g in "${GROWTHS[@]}"; do
    g=$(echo "$g" | tr -d ' ')
    [[ -z "$g" ]] && continue
    proj_cpu=$(awk -v r="$creq" -v g="$g" 'BEGIN{printf "%.4f", r*(1+g/100)}')
    proj_mem=$(awk -v r="$mreq" -v g="$g" 'BEGIN{printf "%.4f", r*(1+g/100)}')
    read -r cpu_add mem_add cpu_head mem_head <<< "$(calc_nodes_to_add "$nodes" "$avg_cpu" "$avg_mem" "$proj_cpu" "$proj_mem" "$net_cpu" "$net_mem" "$tgt")" || true
    cpu_add=${cpu_add:-0}; mem_add=${mem_add:-0}
    if [[ "$cpu_add" -ge "$mem_add" ]]; then rec=$cpu_add; bind=CPU; else rec=$mem_add; bind=Memory; fi
    if [[ "$rec" -eq 0 ]]; then status="OK at +${g}% growth"; else status="ADD ${rec} node(s) at +${g}% growth"; fi
    printf '%s,%s,%.4f,%.4f,%s,%.4f,%.4f,%s,%s,%s,%s,%s,%s\n' \
      "$pool" "$g" "$proj_cpu" "$proj_mem" "$nodes" "$avg_cpu" "$avg_mem" \
      "${TARGET_UTILIZATION_PCT}" "$cpu_add" "$mem_add" "$rec" "$bind" "$status" >> "$GROWTH_FILE"
  done
done

{
  echo "Growth Scenarios Simulated,${GROWTH_SCENARIOS_PCT},percent request increase"
  while IFS=',' read -r pool g proj_cpu proj_mem nodes avg_cpu avg_mem tutil cpu_a mem_a rec bind status; do
    [[ "$pool" == "Pool" ]] && continue
    echo "${pool} +${g}% Growth Nodes To Add,$rec,nodes ($bind)"
  done < "$GROWTH_FILE" || true
} >> "$SUMMARY_FILE" || true

log INFO "Recommendations and growth simulation complete"

# -----------------------------------------------------------------------------
# 8. HTML dashboard
# -----------------------------------------------------------------------------
# Enrich summary with pool-level usage if metrics exist
if [[ -f "$METRICS_FILE" && -f "$NODE_CAP_FILE" ]]; then
  python3 - "$METRICS_FILE" "$NODE_CAP_FILE" "$SUMMARY_FILE" <<'PYM' || true
import csv, sys
from pathlib import Path
metrics_path, cap_path, summary_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
usage = {}
with metrics_path.open() as f:
    for r in csv.DictReader(f):
        usage[r.get("Node","")] = r
cap_rows = list(csv.DictReader(cap_path.open()))
for pool in ("DEDICATED", "SHARED"):
    nodes = [r for r in cap_rows if r.get("Node_Class")==pool]
    if not nodes: continue
    alloc_cpu = sum(float(r.get("Allocatable_CPU_Cores") or 0) for r in nodes)
    alloc_mem = sum(float(r.get("Allocatable_Memory_GiB") or 0) for r in nodes)
    use_cpu = use_mem = 0.0
    for r in nodes:
        m = usage.get(r.get("Node",""), {})
        use_cpu += float(m.get("CPU_Usage_Cores") or 0)
        # mem bytes -> GiB
        try: use_mem += float(m.get("Memory_Usage_Bytes") or 0) / 1073741824
        except: pass
    cpu_pct = (100*use_cpu/alloc_cpu) if alloc_cpu else 0
    mem_pct = (100*use_mem/alloc_mem) if alloc_mem else 0
    with summary_path.open("a") as out:
        out.write(f"{pool} CPU Usage Cores,{use_cpu:.4f},cores (metrics)\n")
        out.write(f"{pool} Memory Usage GiB,{use_mem:.4f},GiB (metrics)\n")
        out.write(f"{pool} CPU Usage Pct,{cpu_pct:.2f},% of allocatable (metrics)\n")
        out.write(f"{pool} Memory Usage Pct,{mem_pct:.2f},% of allocatable (metrics)\n")
PYM
fi

log INFO "Building HTML capacity dashboard..."
HTML_FILE="$OUTPUT_DIR/capacity_report.html"

set +e
python3 - "$OUTPUT_DIR" "$HTML_FILE" <<'PYHTML'
import csv, html, json, sys
from pathlib import Path
from datetime import datetime

out = Path(sys.argv[1]); html_file = Path(sys.argv[2])

def read_csv(n):
    p = out / n
    if not p.exists():
        return []
    with p.open(newline="", encoding="utf-8", errors="replace") as f:
        return list(csv.DictReader(f))

def esc(x):
    return html.escape(str(x if x is not None else ""), quote=True)

def num(x):
    try:
        return float(str(x).replace("%", "").strip())
    except Exception:
        return 0.0

def pct(x):
    return max(0, min(100, num(x)))

_table_id = 0
def table(rows, cols, limit=None, filterable=True):
    """Render all rows (limit ignored for display — kept for API compat). Optional search filter."""
    global _table_id
    if not rows:
        return '<div class="empty">No data</div>'
    _table_id += 1
    tid = f"t{_table_id}"
    shown = rows  # always full data; scroll + filter instead of truncating
    h = []
    if filterable and len(shown) > 8:
        h.append(
            f'<div class="filter-bar">'
            f'<input type="search" class="table-filter" data-table="{tid}" '
            f'placeholder="Filter {len(shown)} rows…" oninput="filterTable(this)">'
            f'<span class="muted filter-count" data-count="{tid}">{len(shown)} rows</span>'
            f'</div>'
        )
    h.append(f'<div class="table-wrap"><table id="{tid}"><thead><tr>')
    h += [f"<th>{esc(c)}</th>" for c in cols]
    h.append("</tr></thead><tbody>")
    for r in shown:
        cells = [str(r.get(c, "") or "") for c in cols]
        search_blob = esc(" ".join(cells).lower())
        h.append(f'<tr data-search="{search_blob}">')
        h += [f"<td>{esc(c)}</td>" for c in cells]
        h.append("</tr>")
    h.append("</tbody></table></div>")
    return "".join(h)

def bar(pct_val, label=""):
    p = pct(pct_val)
    cls = "ok" if p < 70 else ("warn" if p < 80 else "bad")
    return f'<div class="bar-label">{esc(label)} <b>{esc(str(round(p,1)))}%</b></div><div class="bar"><div class="fill {cls}" style="width:{p}%"></div></div>'

sm = {r.get("Metric", ""): r.get("Value", "") for r in read_csv("09_capacity_summary.csv")}
nodes = read_csv("01_node_inventory.csv")
nodecap = [r for r in read_csv("10_node_capacity_detail.csv") if r.get("Node_Class") in ("DEDICATED", "SHARED")]
recs = read_csv("11_node_recommendations.csv")
growth = read_csv("12_growth_simulation.csv")
desired_detail = read_csv("13_desired_replica_detail.csv")
audit = read_csv("08_namespace_dedicated_audit.csv")
metrics_rows = read_csv("14_node_metrics.csv")
metrics = {r.get("Node", ""): r for r in metrics_rows}
has_metrics = len(metrics_rows) > 0

def cap(name):
    rows = read_csv(name)
    return rows[0] if rows else {}

ded = cap("06_dedicated_capacity.csv")
shr = cap("07_shared_capacity.csv")

# Exceptions: targeted dedicated workloads on shared nodes
exceptions = [
    r for r in audit
    if r.get("Actually_On_Dedicated_Node") == "NO"
    and r.get("Has_NodeSelector_Or_Affinity") == "YES"
    and r.get("Dedicated_Target_Keys")
]
# Namespace / controller rollup of misplaced dedicated-targeted workloads
misplaced = {}
for r in exceptions:
    ns = r.get("Namespace") or ""
    ctrl = r.get("Controller") or "standalone"
    key = (ns, ctrl)
    x = misplaced.setdefault(key, {"Namespace": ns, "Controller": ctrl, "Pods": 0, "CPU": 0.0, "Mem_GiB": 0.0, "Target_Keys": r.get("Dedicated_Target_Keys") or ""})
    x["Pods"] += 1
    x["CPU"] += num(r.get("CPU_Request_Cores"))
    x["Mem_GiB"] += num(r.get("Memory_Request_GiB"))
misplaced_rows = sorted(
    [{"Namespace": v["Namespace"], "Controller": v["Controller"], "Pods": v["Pods"],
      "CPU_Requests": f"{v['CPU']:.2f}", "Mem_GiB": f"{v['Mem_GiB']:.2f}", "Target_Keys": v["Target_Keys"]}
     for v in misplaced.values()],
    key=lambda r: -num(r["CPU_Requests"])
)

def pick(basis):
    m = {}
    for r in recs:
        if r.get("Basis") == basis or (not r.get("Basis") and basis == "Actual_Running"):
            m[r.get("Pool", "")] = r
    return m

actual = pick("Actual_Running")
desired = pick("Desired_Replicas")

def rec_val(m, pool, key, default="0"):
    return str((m.get(pool) or {}).get(key) or default)

worker = sm.get("Total Worker/Compute Nodes", "0")
dnodes = sm.get("Dedicated/Tainted Pool Nodes", "0")
snodes = sm.get("Shared/General-Purpose Nodes", "0")

# Primary planning number = Desired Replicas (RH capacity planning)
d_add = rec_val(desired, "DEDICATED", "Recommended_Nodes_To_Add")
s_add = rec_val(desired, "SHARED", "Recommended_Nodes_To_Add")
d_bind = rec_val(desired, "DEDICATED", "Binding_Constraint", "—")
s_bind = rec_val(desired, "SHARED", "Binding_Constraint", "—")
d_status = rec_val(desired, "DEDICATED", "Status", "")
s_status = rec_val(desired, "SHARED", "Status", "")

# Secondary = actual running
d_add_a = rec_val(actual, "DEDICATED", "Recommended_Nodes_To_Add")
s_add_a = rec_val(actual, "SHARED", "Recommended_Nodes_To_Add")

ds_cpu = sm.get("DaemonSet Avg CPU Per Worker Node", "0")
ds_mem = sm.get("DaemonSet Avg Memory Per Worker Node", "0")
tgt = rec_val(desired, "DEDICATED", "Target_Util_Pct") or rec_val(actual, "DEDICATED", "Target_Util_Pct") or "80"

dpct = ded.get("CPU_Request_Pct", "0")
dmpct = ded.get("Memory_Request_Pct", "0")
spct = shr.get("CPU_Request_Pct", "0")
smpct = shr.get("Memory_Request_Pct", "0")

# Merge metrics into worker node rows for dual view
for r in nodecap:
    m = metrics.get(r.get("Node", ""), {})
    r["CPU_Usage_Pct"] = m.get("CPU_Usage_Pct", "")
    r["Memory_Usage_Pct"] = m.get("Memory_Usage_Pct", "")
    r["CPU_Usage_Cores"] = m.get("CPU_Usage_Cores", "")
    try:
        r["Memory_Usage_GiB"] = f"{float(m.get('Memory_Usage_Bytes') or 0)/1073741824:.2f}" if m.get("Memory_Usage_Bytes") else ""
    except Exception:
        r["Memory_Usage_GiB"] = ""

# Pool-level usage from summary (written by pre-HTML enrichment)
d_use_cpu = sm.get("DEDICATED CPU Usage Pct", "")
d_use_mem = sm.get("DEDICATED Memory Usage Pct", "")
s_use_cpu = sm.get("SHARED CPU Usage Pct", "")
s_use_mem = sm.get("SHARED Memory Usage Pct", "")

# Top namespaces by running requests
ns = {}
for r in read_csv("05_pod_requests.csv"):
    if r.get("Phase") != "Running":
        continue
    n = r.get("Namespace", "")
    x = ns.setdefault(n, [0, 0.0, 0.0])
    x[0] += 1
    x[1] += num(r.get("Effective_CPU_Request_Cores"))
    x[2] += num(r.get("Effective_Memory_Request_GiB"))
nsrows = [
    {"Namespace": n, "Pods": v[0], "CPU": f"{v[1]:.2f}", "Memory GiB": f"{v[2]:.1f}"}
    for n, v in ns.items()
]
nsrows.sort(key=lambda r: num(r["CPU"]), reverse=True)

css = """
:root{--bg:#f6f8fb;--card:#fff;--text:#1a2332;--muted:#667085;--line:#e4e7ec;
--blue:#2563eb;--green:#16a34a;--amber:#d97706;--red:#dc2626;--shadow:0 2px 12px rgba(0,0,0,.06)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);
font-family:Inter,Segoe UI,system-ui,sans-serif;line-height:1.45}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
.hero{background:linear-gradient(135deg,#0f1c33,#1e4a8c);color:#fff;border-radius:16px;padding:24px 28px;margin-bottom:20px}
.hero h1{margin:0 0 6px;font-size:24px}.hero p{margin:0;opacity:.85;font-size:14px}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;box-shadow:var(--shadow)}
.card h3{margin:0 0 8px;font-size:13px;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.03em}
.metric{font-size:28px;font-weight:700}.sub{font-size:12px;color:var(--muted);margin-top:4px}
.ok{color:var(--green)}.warn{color:var(--amber)}.bad{color:var(--red)}
.section{margin:22px 0}.section h2{font-size:18px;margin:0 0 12px}
.twocol{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.bar{height:10px;background:#eef1f6;border-radius:6px;overflow:hidden;margin:6px 0 12px}
.fill{height:100%;border-radius:6px;background:var(--blue)}.fill.warn{background:var(--amber)}.fill.bad{background:var(--red)}.fill.ok{background:var(--green)}
.bar-label{font-size:13px;display:flex;justify-content:space-between}
.info{background:#eff6ff;border-left:4px solid var(--blue);padding:12px 14px;border-radius:8px;font-size:13px;margin-bottom:14px}
.alert{background:#fff1f2;border-left:4px solid var(--red);padding:12px 14px;border-radius:8px;font-size:13px;margin-bottom:12px}
.table-wrap{overflow:auto;max-height:420px;border:1px solid var(--line);border-radius:10px;background:#fff}
table{border-collapse:collapse;width:100%;font-size:12px}
th{position:sticky;top:0;background:#f8fafc;text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
td{padding:7px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
tr:hover td{background:#f8fbff}
.empty{padding:16px;color:var(--muted);background:#fff;border:1px solid var(--line);border-radius:10px}
.muted{color:var(--muted);font-size:12px}
.footer{margin:28px 0 8px;font-size:12px;color:var(--muted)}
.filter-bar{display:flex;align-items:center;gap:10px;margin-bottom:8px}
.table-filter{flex:1;max-width:420px;padding:8px 12px;border:1px solid var(--line);border-radius:8px;
font-size:13px;background:#fff;color:var(--text)}
.table-filter:focus{outline:2px solid var(--blue);border-color:var(--blue)}
.table-wrap{max-height:520px}
tr.filtered-out{display:none}
@media(max-width:800px){.grid,.twocol{grid-template-columns:1fr 1fr}}
@media(max-width:520px){.grid,.twocol{grid-template-columns:1fr}}
"""

def add_cls(v):
    return "bad" if num(v) > 0 else "ok"

doc = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenShift Capacity Report</title>
<style>{css}</style>
</head><body><div class="wrap">

<div class="hero">
  <h1>OpenShift Capacity Report</h1>
  <p>Generated {esc(datetime.now().astimezone().isoformat(timespec="seconds"))} ·
  Aligned with Red Hat capacity management: schedule on <b>Requests</b> vs <b>Allocatable</b>, plan scale-out near <b>{esc(tgt)}%</b> Request/Allocatable.</p>
</div>

<div class="grid">
  <div class="card"><h3>Worker nodes</h3><div class="metric">{esc(worker)}</div>
    <div class="sub">Dedicated {esc(dnodes)} · Shared {esc(snodes)}</div></div>
  <div class="card"><h3>Add nodes (desired scale)</h3>
    <div class="metric {add_cls(num(d_add)+num(s_add))}">{esc(str(int(num(d_add)+num(s_add))))}</div>
    <div class="sub">Dedicated +{esc(d_add)} · Shared +{esc(s_add)}</div></div>
  <div class="card"><h3>Add nodes (running now)</h3>
    <div class="metric {add_cls(num(d_add_a)+num(s_add_a))}">{esc(str(int(num(d_add_a)+num(s_add_a))))}</div>
    <div class="sub">Dedicated +{esc(d_add_a)} · Shared +{esc(s_add_a)}</div></div>
  <div class="card"><h3>Placement issues</h3>
    <div class="metric {'bad' if exceptions else 'ok'}">{len(exceptions)}</div>
    <div class="sub">Dedicated-targeted pods on shared nodes</div></div>
</div>

<div class="section">
  <h2>Cluster utilization — Requests vs Usage</h2>
  <div class="info"><b>Requests / Allocatable</b> = scheduler capacity (will pods fit?).
  <b>Usage / Allocatable</b> = real consumption from metrics-server (<code>oc adm top</code>).
  Plan scale-out near ~{esc(tgt)}% requests; use usage to spot over/under-requesting.
  {"Metrics collected from oc adm top." if has_metrics else "<b>Metrics unavailable</b> — check metrics-server / <code>oc adm top nodes</code>."}</div>
  <div class="twocol">
    <div class="card">
      <h3>Dedicated pool</h3>
      {bar(dpct, "CPU requests")}
      {(bar(d_use_cpu, "CPU usage (metrics)") if has_metrics else '<div class="muted">CPU usage: n/a</div>')}
      {bar(dmpct, "Memory requests")}
      {(bar(d_use_mem, "Memory usage (metrics)") if has_metrics else '<div class="muted">Memory usage: n/a</div>')}
      <div class="sub">{esc(ded.get('CPU_Requests_Cores','0'))} / {esc(ded.get('Allocatable_CPU_Cores','0'))} cores requested ·
      {esc(ded.get('Memory_Requests_GiB','0'))} / {esc(ded.get('Allocatable_Memory_GiB','0'))} GiB requested</div>
    </div>
    <div class="card">
      <h3>Shared pool</h3>
      {bar(spct, "CPU requests")}
      {(bar(s_use_cpu, "CPU usage (metrics)") if has_metrics else '<div class="muted">CPU usage: n/a</div>')}
      {bar(smpct, "Memory requests")}
      {(bar(s_use_mem, "Memory usage (metrics)") if has_metrics else '<div class="muted">Memory usage: n/a</div>')}
      <div class="sub">{esc(shr.get('CPU_Requests_Cores','0'))} / {esc(shr.get('Allocatable_CPU_Cores','0'))} cores requested ·
      {esc(shr.get('Memory_Requests_GiB','0'))} / {esc(shr.get('Allocatable_Memory_GiB','0'))} GiB requested</div>
    </div>
  </div>
</div>

<div class="section">
  <h2>Node recommendation</h2>
  <div class="info"><b>Primary:</b> Desired Deployment/StatefulSet replicas × pod template Requests (planning).<br>
  <b>Secondary:</b> Actual Running pod Requests (current pressure).<br>
  Net capacity per new node = allocatable − DaemonSet Requests (avg {esc(ds_cpu)} CPU, {esc(ds_mem)} GiB per worker), then × {esc(tgt)}% target.</div>
  <div class="twocol">
    <div class="card">
      <h3>Dedicated — desired scale</h3>
      <div class="metric {add_cls(d_add)}">+{esc(d_add)}</div>
      <div class="sub">Binding: {esc(d_bind)} · {esc(d_status)}</div>
    </div>
    <div class="card">
      <h3>Shared — desired scale</h3>
      <div class="metric {add_cls(s_add)}">+{esc(s_add)}</div>
      <div class="sub">Binding: {esc(s_bind)} · {esc(s_status)}</div>
    </div>
  </div>
  {table(recs, ["Pool","Basis","Current_Nodes","CPU_Requests","Mem_Requests","Net_CPU_Per_New_Node","Net_Mem_Per_New_Node","Recommended_Nodes_To_Add","Binding_Constraint","Status"])}
</div>

<div class="section">
  <h2>Growth scenarios (from current Running)</h2>
  {table(growth, ["Pool","Growth_Pct","Projected_CPU_Requests","Projected_Mem_Requests","Recommended_Nodes_To_Add","Binding_Constraint","Status"])}
</div>

<div class="section">
  <h2>Desired replica demand (top controllers)</h2>
  {table(desired_detail, ["Namespace","Controller","Desired_Replicas","CPU_Per_Replica","Mem_GiB_Per_Replica","Desired_CPU_Cores","Desired_Mem_GiB","Pool_Hint"])}
</div>

<div class="section">
  <h2>Worker node pressure</h2>
  {table(nodecap, ["Node","Node_Class","CPU_Request_Pct","CPU_Usage_Pct","Memory_Request_Pct","Memory_Usage_Pct","CPU_Requests_Cores","CPU_Usage_Cores","Memory_Requests_GiB","Memory_Usage_GiB"])}
</div>

<div class="section">
  <h2>Top namespaces (Running requests)</h2>
  {table(nsrows, ["Namespace","Pods","CPU","Memory GiB"])}
</div>

<div class="section">
  <h2>Misplaced dedicated workloads</h2>
  <div class="info">Pods whose <b>nodeSelector/affinity targets a dedicated taint key</b> (e.g. <code>dedicated=uipath</code>, <code>app=sas</code>) but are <b>Running on SHARED</b> nodes.
  Toleration alone is not enough — that is common on operators and is not treated as an exception.</div>
  {('<div class="alert"><b>' + str(len(exceptions)) + '</b> pod(s) / <b>' + str(len(misplaced_rows)) + '</b> controllers appear misplaced.</div>'
    + '<h3 style="font-size:14px;margin:12px 0 8px">By controller</h3>'
    + table(misplaced_rows, ["Namespace","Controller","Pods","CPU_Requests","Mem_GiB","Target_Keys"])
    + '<h3 style="font-size:14px;margin:12px 0 8px">Pod sample</h3>'
    + table(exceptions, ["Namespace","Pod_Name","Node","Dedicated_Target_Keys","Controller"])
   ) if exceptions else '<div class="card ok"><b>None detected — dedicated-targeted workloads are on dedicated nodes.</b></div>'}
</div>

<div class="section">
  <h2>Node inventory</h2>
  {table(nodes, ["Node","role","ready","Classification","dedicated_taint_count","cpu","mem"])}
</div>

<div class="footer">
  <b>Red Hat OpenShift capacity practices used here</b><br>
  1. Capacity = sum of pod <b>Requests</b> vs node <b>Allocatable</b> (scheduler does not oversubscribe Requests).<br>
  2. Overcommit means Limits &gt; Requests on pods — it does <i>not</i> mean scheduling more Requests than Allocatable.<br>
  3. Prefer always setting CPU/memory Requests; avoid CPU Limits when possible; size Requests from observed average usage.<br>
  4. Plan scale-out when Request/Allocatable approaches ~80% (OpenShift monitoring guidance / autoscaler pressure).<br>
  5. DaemonSets consume capacity on every new node — subtracted from net capacity per node.<br>
  6. Desired replicas (Deployment/STS) are the primary planning signal; Running pods are the current-pressure signal.<br>
  7. Usage metrics from <code>oc adm top</code> (metrics-server) show real consumption vs Requests for rightsizing.<br>
  CSVs in the output directory have full detail for Excel (including 14_node_metrics.csv).
</div>

</div>
<script>
function filterTable(input){{
  const tid = input.getAttribute('data-table');
  const q = (input.value || '').toLowerCase().trim();
  const table = document.getElementById(tid);
  if(!table) return;
  let visible = 0;
  table.querySelectorAll('tbody tr').forEach(tr => {{
    const hay = tr.getAttribute('data-search') || '';
    const show = !q || hay.indexOf(q) !== -1;
    tr.classList.toggle('filtered-out', !show);
    if(show) visible++;
  }});
  const counter = document.querySelector('.filter-count[data-count="'+tid+'"]');
  if(counter){{
    const total = table.querySelectorAll('tbody tr').length;
    counter.textContent = q ? (visible + ' / ' + total + ' rows') : (total + ' rows');
  }}
}}
</script>
</body></html>
"""

html_file.write_text(doc, encoding="utf-8")
print(html_file)
PYHTML
HTML_RC=$?
if [[ $HTML_RC -eq 0 && -f "$HTML_FILE" ]]; then
  log SUCCESS "HTML dashboard written: $HTML_FILE"
else
  log WARN "HTML dashboard generation failed (exit $HTML_RC). CSV reports are still available in $OUTPUT_DIR"
fi
set -e

# -----------------------------------------------------------------------------
# 8. Console summary and cleanup
# -----------------------------------------------------------------------------
rm -f "$OUTPUT_DIR/.node_class_lookup" "$OUTPUT_DIR/.placement_authoritative.csv" "$OUTPUT_DIR/.running_requests.tsv" "$OUTPUT_DIR/.audit_rows.csv"

if [[ "$DRY_RUN" == true ]]; then
  log WARN "DRY-RUN: files were generated under $OUTPUT_DIR for inspection but are temporary."
fi

cat <<SUMMARY

========================================
 CAPACITY REPORT COMPLETE
========================================
Worker/compute nodes                 : $WORKER_COUNT
Dedicated/tainted pool nodes         : $DEDICATED_NODE_COUNT
Shared/general-purpose nodes         : $SHARED_NODE_COUNT

--- DEDICATED CAPACITY ---
Allocatable CPU                      : $dc_cpu cores
CPU requests                         : $dc_req_cpu cores ($dc_cpu_pct%)
Allocatable Memory                   : $dc_mem GiB
Memory requests                      : $dc_req_mem GiB ($dc_mem_pct%)

--- SHARED CAPACITY ---
Allocatable CPU                      : $sc_cpu cores
CPU requests                         : $sc_req_cpu cores ($sc_cpu_pct%)
Allocatable Memory                   : $sc_mem GiB
Memory requests                      : $sc_req_mem GiB ($sc_mem_pct%)

--- PLACEMENT AUDIT ---
Dedicated-pool pods on dedicated nodes : $DEDICATED_ON_DEDICATED
Dedicated/targeted pods on shared nodes: $DEDICATED_ON_SHARED
Namespaces using both node types       : $MIXED_NS

--- NODE RECOMMENDATIONS (target ${TARGET_UTILIZATION_PCT}% utilization) ---
(see 11_node_recommendations.csv and HTML Capacity Glance)

--- GROWTH SIMULATION (+${GROWTH_SCENARIOS_PCT}%) ---
(see 12_growth_simulation.csv)

--- FILES ---
$OUTPUT_DIR/01_node_inventory.csv
$OUTPUT_DIR/02_node_taints.csv
$OUTPUT_DIR/03_pod_tolerations.csv
$OUTPUT_DIR/04_pod_placement.csv
$OUTPUT_DIR/05_pod_requests.csv
$OUTPUT_DIR/06_dedicated_capacity.csv
$OUTPUT_DIR/07_shared_capacity.csv
$OUTPUT_DIR/08_namespace_dedicated_audit.csv
$OUTPUT_DIR/09_capacity_summary.csv
$OUTPUT_DIR/10_node_capacity_detail.csv
$OUTPUT_DIR/11_node_recommendations.csv
$OUTPUT_DIR/12_growth_simulation.csv
$OUTPUT_DIR/13_desired_replica_recommendations.csv
$OUTPUT_DIR/13_desired_replica_detail.csv
$OUTPUT_DIR/14_node_metrics.csv
$OUTPUT_DIR/15_pod_metrics_top.csv
$HTML_FILE
========================================
SUMMARY


log SUCCESS "Capacity report generated in: $OUTPUT_DIR"