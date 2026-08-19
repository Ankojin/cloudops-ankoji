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

on_err() {
  local exit_code=$? line=$1
  log ERROR "Script aborted (exit $exit_code) at line $line while running: $BASH_COMMAND"
  log ERROR "No HTML report was generated. Re-run with --debug to see node/pod discovery diagnostics leading up to this point."
}
trap 'on_err $LINENO' ERR

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
  # Explicit pool targeting: nodeSelector or nodeAffinity present
  (
    ((.spec.nodeSelector // {}) | length > 0) or
    ((.spec.affinity.nodeAffinity // null) != null)
  ) as $targeted |
  [
    .metadata.namespace,
    .metadata.name,
    $node,
    $class,
    (if $class == "DEDICATED" then "YES" else "NO" end),
    $matched,
    (if $targeted then "YES" else "NO" end),
    ($r.cpu | tostring),
    (($r.mem/1073741824*100|floor/100)|tostring),
    ((.metadata.ownerReferences // []) | map(select(.controller==true)) | if length>0 then (.[0].kind+"/"+.[0].name) else "standalone" end)
  ] | @csv
' "$RAW_PODS" > "$OUTPUT_DIR/.audit_rows.csv"

{
  echo 'Namespace,Pod_Name,Node,Node_Class,Actually_On_Dedicated_Node,Matching_Dedicated_Taint_Toleration,Has_NodeSelector_Or_Affinity,CPU_Request_Cores,Memory_Request_GiB,Controller'
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
# DaemonSets run on every (matching) node. When you ADD a node, you also ADD
# DaemonSet request cost. Net capacity gained per new node =
#   avg_allocatable - avg_daemonset_requests
# Then apply TARGET_UTILIZATION_PCT headroom on that net figure.
#
# Logic (Requests-based, not Limits):
#   1. Average node allocatable from nodes in each pool.
#   2. Average DaemonSet effective requests per worker node (from Running DS pods).
#   3. Net usable per new node = max(0, avg_alloc - avg_ds).
#   4. Target usable (current) = allocatable * target_factor.
#   5. Deficit = requests - target_usable (if positive).
#   6. Nodes to add = ceil(deficit / (net_usable_per_node * target_factor)).
log INFO "Measuring DaemonSet request footprint on worker nodes..."

# Per-worker-node average DaemonSet requests (Controller starts with DaemonSet/)
# Uses placement file columns: Node, Node_Class, Effective_CPU, Effective_Mem, Controller
# Only Running pods on DEDICATED/SHARED nodes.
read -r DS_CPU_PER_NODE DS_MEM_PER_NODE DS_POD_COUNT < <(awk -F',' '
  NR>1 {
    for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
    # 04_pod_placement: Namespace,Pod_Name,Phase,Node,Node_Class,CPU,Mem,Tolerations,NodeSelector,Controller
    phase=$3; node=$4; cls=$5; cpu=$6; mem=$7; ctrl=$10
    if (phase!="Running") next
    if (cls!="DEDICATED" && cls!="SHARED") next
    if (ctrl !~ /^DaemonSet\//) next
    nodes[node]=1
    c[node]+=cpu; m[node]+=mem; pods++
  }
  END {
    n=0; tc=0; tm=0
    for (x in nodes) { n++; tc+=c[x]; tm+=m[x] }
    if (n>0) printf "%.4f %.4f %d", tc/n, tm/n, pods
    else printf "0 0 0"
  }
' "$PLACEMENT_FILE")

log INFO "DaemonSet avg footprint per worker node: ${DS_CPU_PER_NODE} cores, ${DS_MEM_PER_NODE} GiB (${DS_POD_COUNT} DS pods total)"

log INFO "Calculating node recommendations (target utilization ${TARGET_UTILIZATION_PCT}%, DaemonSet-aware)..."

# RFC4180-safe CSV field quoting for the manually-built rows below (NODE_CAP_FILE
# via jq/@tsv+printf is safe; RECOMMEND_FILE/GROWTH_FILE embed a free-text $status
# field that is NOT guaranteed comma-free, so it must be quoted like the jq @csv
# files already are, or a future status message containing a comma will silently
# shift every column to the right in the downstream HTML tables).
csv_q() {
  local f="$1"
  if [[ "$f" == *[,\"$'\n']* ]]; then
    f=${f//\"/\"\"}
    printf '"%s"' "$f"
  else
    printf '%s' "$f"
  fi
}

RECOMMEND_FILE="$OUTPUT_DIR/11_node_recommendations.csv"
{
  echo 'Pool,Current_Nodes,Avg_CPU_Cores_Per_Node,Avg_Memory_GiB_Per_Node,DaemonSet_CPU_Per_Node,DaemonSet_Mem_Per_Node,Net_CPU_Per_New_Node,Net_Mem_Per_New_Node,CPU_Requests,Mem_Requests,Target_Util_Pct,CPU_Headroom_Cores,Mem_Headroom_GiB,CPU_Nodes_To_Add,Mem_Nodes_To_Add,Recommended_Nodes_To_Add,Binding_Constraint,Status'
  for pool in DEDICATED SHARED; do
    read -r nodes avg_cpu avg_mem creq mreq < <(awk -F',' -v cls="$pool" '
      NR>1 && $2==cls {
        for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
        n++; cpu+=$4; mem+=$5; creq+=$7; mreq+=$8
      }
      END {
        if(n>0) printf "%d %.4f %.4f %.4f %.4f", n, cpu/n, mem/n, creq, mreq
        else printf "0 0 0 0 0"
      }' "$NODE_CAP_FILE")
    tgt=$(awk -v t="$TARGET_UTILIZATION_PCT" 'BEGIN{printf "%.4f", t/100}')
    # Net capacity a NEW node contributes after DaemonSets land on it
    net_cpu=$(awk -v a="$avg_cpu" -v d="$DS_CPU_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
    net_mem=$(awk -v a="$avg_mem" -v d="$DS_MEM_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
    # Current headroom at target (cluster-wide for this pool)
    cpu_head=$(awk -v nodes="$nodes" -v avg="$avg_cpu" -v req="$creq" -v t="$tgt" 'BEGIN{printf "%.4f", (nodes*avg*t) - req}')
    mem_head=$(awk -v nodes="$nodes" -v avg="$avg_mem" -v req="$mreq" -v t="$tgt" 'BEGIN{printf "%.4f", (nodes*avg*t) - req}')
    # Nodes to add: deficit covered by net usable * target per new node
    cpu_add=$(awk -v head="$cpu_head" -v net="$net_cpu" -v t="$tgt" 'BEGIN{
      gain=net*t
      if (head >= 0 || gain <= 0) print 0
      else print int( ((-head) / gain) + 0.9999 )
    }')
    mem_add=$(awk -v head="$mem_head" -v net="$net_mem" -v t="$tgt" 'BEGIN{
      gain=net*t
      if (head >= 0 || gain <= 0) print 0
      else print int( ((-head) / gain) + 0.9999 )
    }')
    if [[ "$cpu_add" -ge "$mem_add" ]]; then
      rec="$cpu_add"; bind="CPU"
    else
      rec="$mem_add"; bind="Memory"
    fi
    if [[ "$rec" -eq 0 ]]; then
      status="OK — within target headroom (DaemonSet-aware)"
    else
      status="ADD NODES — requests exceed ${TARGET_UTILIZATION_PCT}% (net of DaemonSets)"
    fi
    printf '%s,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s,%.4f,%.4f,%s,%s,%s,%s,%s\n' \
      "$pool" "$nodes" "$avg_cpu" "$avg_mem" "$DS_CPU_PER_NODE" "$DS_MEM_PER_NODE" \
      "$net_cpu" "$net_mem" "$creq" "$mreq" "$TARGET_UTILIZATION_PCT" \
      "$cpu_head" "$mem_head" "$cpu_add" "$mem_add" "$rec" "$bind" "$(csv_q "$status")"
  done
} > "$RECOMMEND_FILE"

# Append recommendation metrics to summary
{
  echo "DaemonSet Avg CPU Per Worker Node,$DS_CPU_PER_NODE,cores (auto-scheduled on new nodes too)"
  echo "DaemonSet Avg Memory Per Worker Node,$DS_MEM_PER_NODE,GiB"
  echo "DaemonSet Running Pods Count,$DS_POD_COUNT,pods"
  while IFS=',' read -r pool nodes avg_cpu avg_mem ds_cpu ds_mem net_cpu net_mem creq mreq tgt cpu_h mem_h cpu_a mem_a rec bind status; do
    [[ "$pool" == "Pool" ]] && continue
    echo "${pool} Avg Node CPU,$avg_cpu,cores"
    echo "${pool} Avg Node Memory,$avg_mem,GiB"
    echo "${pool} Net CPU Per New Node (after DaemonSets),$net_cpu,cores"
    echo "${pool} Net Memory Per New Node (after DaemonSets),$net_mem,GiB"
    echo "${pool} CPU Headroom at ${TARGET_UTILIZATION_PCT}%,$cpu_h,cores (negative = deficit)"
    echo "${pool} Memory Headroom at ${TARGET_UTILIZATION_PCT}%,$mem_h,GiB (negative = deficit)"
    echo "${pool} Recommended Nodes To Add,$rec,nodes (binding: $bind)"
    echo "${pool} Recommendation Status,$status,"
  done < "$RECOMMEND_FILE"
} >> "$SUMMARY_FILE"

# -----------------------------------------------------------------------------
# 7c. Future workload growth simulation
# -----------------------------------------------------------------------------
# Projects current Running-pod Requests under growth scenarios and recomputes
# nodes-to-add at TARGET_UTILIZATION_PCT. Uses Requests only (not Limits).
log INFO "Simulating future workload growth scenarios: ${GROWTH_SCENARIOS_PCT}% ..."

GROWTH_FILE="$OUTPUT_DIR/12_growth_simulation.csv"
{
  echo 'Pool,Growth_Pct,Projected_CPU_Requests,Projected_Mem_Requests,Current_Nodes,Avg_CPU_Per_Node,Avg_Mem_Per_Node,Target_Util_Pct,CPU_Nodes_To_Add,Mem_Nodes_To_Add,Recommended_Nodes_To_Add,Binding_Constraint,Status'
  IFS=',' read -ra GROWTHS <<< "$GROWTH_SCENARIOS_PCT"
  for pool in DEDICATED SHARED; do
    read -r nodes avg_cpu avg_mem creq mreq < <(awk -F',' -v cls="$pool" '
      NR>1 && $2==cls {
        for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)
        n++; cpu+=$4; mem+=$5; creq+=$7; mreq+=$8
      }
      END {
        if(n>0) printf "%d %.4f %.4f %.4f %.4f", n, cpu/n, mem/n, creq, mreq
        else printf "0 0 0 0 0"
      }' "$NODE_CAP_FILE")
    tgt=$(awk -v t="$TARGET_UTILIZATION_PCT" 'BEGIN{printf "%.4f", t/100}')
    net_cpu=$(awk -v a="$avg_cpu" -v d="$DS_CPU_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
    net_mem=$(awk -v a="$avg_mem" -v d="$DS_MEM_PER_NODE" 'BEGIN{v=a-d; if(v<0)v=0; printf "%.4f", v}')
    for g in "${GROWTHS[@]}"; do
      g=$(echo "$g" | tr -d ' ')
      [[ -z "$g" ]] && continue
      # Projected app+all requests grow; DaemonSets on existing nodes already in baseline.
      # New nodes still pay full DS cost via net_cpu/net_mem.
      proj_cpu=$(awk -v r="$creq" -v g="$g" 'BEGIN{printf "%.4f", r * (1 + g/100)}')
      proj_mem=$(awk -v r="$mreq" -v g="$g" 'BEGIN{printf "%.4f", r * (1 + g/100)}')
      cpu_head=$(awk -v nodes="$nodes" -v avg="$avg_cpu" -v req="$proj_cpu" -v t="$tgt" 'BEGIN{printf "%.4f", (nodes*avg*t) - req}')
      mem_head=$(awk -v nodes="$nodes" -v avg="$avg_mem" -v req="$proj_mem" -v t="$tgt" 'BEGIN{printf "%.4f", (nodes*avg*t) - req}')
      cpu_add=$(awk -v head="$cpu_head" -v net="$net_cpu" -v t="$tgt" 'BEGIN{
        gain=net*t
        if (head >= 0 || gain <= 0) print 0
        else print int( ((-head) / gain) + 0.9999 )
      }')
      mem_add=$(awk -v head="$mem_head" -v net="$net_mem" -v t="$tgt" 'BEGIN{
        gain=net*t
        if (head >= 0 || gain <= 0) print 0
        else print int( ((-head) / gain) + 0.9999 )
      }')
      if [[ "$cpu_add" -ge "$mem_add" ]]; then
        rec="$cpu_add"; bind="CPU"
      else
        rec="$mem_add"; bind="Memory"
      fi
      if [[ "$rec" -eq 0 ]]; then
        status="OK at +${g}% growth (DaemonSet-aware)"
      else
        status="ADD ${rec} node(s) at +${g}% growth (net of DaemonSets)"
      fi
      printf '%s,%s,%.4f,%.4f,%s,%.4f,%.4f,%s,%s,%s,%s,%s,%s\n' \
        "$pool" "$g" "$proj_cpu" "$proj_mem" "$nodes" "$avg_cpu" "$avg_mem" \
        "$TARGET_UTILIZATION_PCT" "$cpu_add" "$mem_add" "$rec" "$bind" "$(csv_q "$status")"
    done
  done
} > "$GROWTH_FILE"

# Append key growth findings to summary
{
  echo "Growth Scenarios Simulated,${GROWTH_SCENARIOS_PCT},percent request increase"
  while IFS=',' read -r pool g proj_cpu proj_mem nodes avg_cpu avg_mem tgt cpu_a mem_a rec bind status; do
    [[ "$pool" == "Pool" ]] && continue
    echo "${pool} +${g}% Growth Nodes To Add,$rec,nodes ($bind) — $status"
  done < "$GROWTH_FILE"
} >> "$SUMMARY_FILE"

# -----------------------------------------------------------------------------
# 8. HTML dashboard
# -----------------------------------------------------------------------------
log INFO "Building HTML capacity dashboard..."
HTML_FILE="$OUTPUT_DIR/capacity_report.html"

need_cmd python3
if ! python3 - "$OUTPUT_DIR" "$HTML_FILE" <<'PYHTML'
import csv, html, json, sys
from pathlib import Path
from datetime import datetime

out=Path(sys.argv[1]); html_file=Path(sys.argv[2])
def read_csv(n):
    p=out/n
    if not p.exists(): return []
    with p.open(newline='',encoding='utf-8',errors='replace') as f: return list(csv.DictReader(f))
def esc(x): return html.escape(str(x if x is not None else ''),quote=True)
def num(x):
    try: return float(str(x).replace('%','').strip())
    except: return 0.0
def table(rows,cols,limit=None):
    if not rows: return '<div class="empty">No data available.</div>'
    shown=rows[:limit] if limit else rows
    h=['<div class="table-wrap"><table class="data-table"><thead><tr>']
    h += [f'<th>{esc(c)}</th>' for c in cols]; h.append('</tr></thead><tbody>')
    for r in shown:
        h.append('<tr>'); h += [f'<td>{esc(r.get(c,""))}</td>' for c in cols]; h.append('</tr>')
    h.append('</tbody></table></div>')
    if limit and len(rows)>limit: h.append(f'<div class="muted">Showing {limit} of {len(rows)} rows.</div>')
    return ''.join(h)
summary=read_csv('09_capacity_summary.csv'); sm={r.get('Metric',''):r.get('Value','') for r in summary}
nodes=read_csv('01_node_inventory.csv'); nodecap=read_csv('10_node_capacity_detail.csv'); placement=read_csv('04_pod_placement.csv'); requests=read_csv('05_pod_requests.csv'); audit=read_csv('08_namespace_dedicated_audit.csv'); taints=read_csv('02_node_taints.csv'); tols=read_csv('03_pod_tolerations.csv'); recs=read_csv('11_node_recommendations.csv'); growth=read_csv('12_growth_simulation.csv')
def cap(n):
    x=read_csv(n); return x[0] if x else {}
ded=cap('06_dedicated_capacity.csv'); shr=cap('07_shared_capacity.csv')
# Tight exceptions: SHARED + matched dedicated toleration + nodeSelector/affinity
exceptions=[r for r in audit if r.get('Actually_On_Dedicated_Node')=='NO' and r.get('Matching_Dedicated_Taint_Toleration') and r.get('Has_NodeSelector_Or_Affinity')=='YES']
placements={}
for r in audit: placements.setdefault(r.get('Namespace',''),set()).add(r.get('Actually_On_Dedicated_Node','NO'))
mixed=[{'Namespace':n,'Placement':'DEDICATED + SHARED'} for n,v in placements.items() if 'YES' in v and 'NO' in v]
ns={}
for r in requests:
    if r.get('Phase')!='Running': continue
    n=r.get('Namespace',''); x=ns.setdefault(n,[0,0,0]); x[0]+=1; x[1]+=num(r.get('Effective_CPU_Request_Cores')); x[2]+=num(r.get('Effective_Memory_Request_GiB'))
nsrows=[{'Namespace':n,'Pods':v[0],'CPU Requests Cores':f'{v[1]:.3f}','Memory Requests GiB':f'{v[2]:.2f}'} for n,v in ns.items()]; nsrows.sort(key=lambda r:num(r['CPU Requests Cores']),reverse=True)
# Charts: workers only
worker_cap=[r for r in nodecap if r.get('Node_Class') in ('DEDICATED','SHARED')]
node_json=json.dumps([{'node':r.get('Node',''),'class':r.get('Node_Class',''),'cpu':num(r.get('CPU_Request_Pct')),'mem':num(r.get('Memory_Request_Pct'))} for r in worker_cap]).replace('</script','<\\/script').replace('<!--','<\\!--')
def pct(x): return max(0,min(100,num(x)))
worker=sm.get('Total Worker/Compute Nodes','0'); dnodes=sm.get('Dedicated/Tainted Pool Nodes','0'); snodes=sm.get('Shared/General-Purpose Nodes','0')
dcpu=ded.get('Allocatable_CPU_Cores','0'); dreq=ded.get('CPU_Requests_Cores','0'); dpct=ded.get('CPU_Request_Pct','0'); dmem=ded.get('Allocatable_Memory_GiB','0'); dmreq=ded.get('Memory_Requests_GiB','0'); dmpct=ded.get('Memory_Request_Pct','0')
scpu=shr.get('Allocatable_CPU_Cores','0'); sreq=shr.get('CPU_Requests_Cores','0'); spct=shr.get('CPU_Request_Pct','0'); smem=shr.get('Allocatable_Memory_GiB','0'); smreq=shr.get('Memory_Requests_GiB','0'); smpct=shr.get('Memory_Request_Pct','0')
rec_map={r.get('Pool',''):r for r in recs}
drec=rec_map.get('DEDICATED',{}); srec=rec_map.get('SHARED',{})
d_add=drec.get('Recommended_Nodes_To_Add','0'); s_add=srec.get('Recommended_Nodes_To_Add','0')
d_status=drec.get('Status',''); s_status=srec.get('Status','')
d_bind=drec.get('Binding_Constraint',''); s_bind=srec.get('Binding_Constraint','')
tgt_util=drec.get('Target_Util_Pct') or srec.get('Target_Util_Pct') or '80'
css='''
:root{--bg:#f4f7fb;--card:#fff;--text:#172033;--muted:#667085;--line:#e4e7ec;--accent:#2563eb;--good:#16a34a;--warn:#d97706;--bad:#dc2626;--shadow:0 4px 18px rgba(16,24,40,.07)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Inter,Segoe UI,Arial,sans-serif;line-height:1.45}.container{max-width:1500px;margin:auto;padding:28px}.hero{background:linear-gradient(135deg,#18243d,#2f5aa8);color:white;border-radius:18px;padding:28px;box-shadow:var(--shadow)}h1{margin:0 0 7px;font-size:28px}.sub{opacity:.85}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:18px 0}.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;box-shadow:var(--shadow)}.metric{font-size:28px;font-weight:750;margin-top:5px}.label{font-size:13px;color:var(--muted)}.section{margin-top:22px}.section h2{font-size:20px;margin:0 0 12px}.twocol{display:grid;grid-template-columns:1fr 1fr;gap:18px}.pill{display:inline-block;padding:4px 9px;border-radius:999px;font-size:12px;font-weight:700;background:#eef2ff}.good{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}.bar{height:12px;background:#edf0f5;border-radius:8px;overflow:hidden;margin-top:8px}.fill{height:100%;background:var(--accent)}.table-wrap{overflow:auto;max-height:540px;border:1px solid var(--line);border-radius:10px}.data-table{border-collapse:collapse;width:100%;font-size:12px;background:#fff}.data-table th{position:sticky;top:0;background:#f8fafc;text-align:left;z-index:1}.data-table th,.data-table td{padding:8px 9px;border-bottom:1px solid var(--line);white-space:nowrap}.data-table tr:hover{background:#f8fbff}.empty{padding:20px;background:#fff;border:1px solid var(--line);border-radius:10px;color:var(--muted)}.muted{color:var(--muted);font-size:12px;margin-top:7px}.alert{border-left:5px solid var(--bad);background:#fff1f2;padding:14px;border-radius:10px;margin-bottom:12px}.info{border-left:5px solid var(--accent);background:#eff6ff;padding:14px;border-radius:10px}.chart{height:330px;background:#fff;border:1px solid var(--line);border-radius:12px;padding:10px;overflow:auto}.chart-row{display:grid;grid-template-columns:280px 1fr 65px;gap:10px;align-items:center;margin:8px 0;font-size:12px}.chartbar{height:18px;background:#edf0f5;border-radius:5px;overflow:hidden}.chartbar span{display:block;height:100%;background:var(--accent)}.chartbar span.warn{background:var(--warn)}.chartbar span.bad{background:var(--bad)}.footer{color:var(--muted);font-size:12px;margin:28px 0 10px}@media(max-width:1000px){.grid,.twocol{grid-template-columns:1fr 1fr}}@media(max-width:650px){.grid,.twocol{grid-template-columns:1fr}.container{padding:14px}.chart-row{grid-template-columns:150px 1fr 55px}}
'''
exception_html=(f'<div class="alert"><b>Review required:</b> {len(exceptions)} pod(s) have nodeSelector/affinity + dedicated taint toleration but are running on shared nodes.</div>'+table(exceptions,['Namespace','Pod_Name','Node','Node_Class','Matching_Dedicated_Taint_Toleration','Has_NodeSelector_Or_Affinity','CPU_Request_Cores','Memory_Request_GiB','Controller'],100)) if exceptions else '<div class="card good"><b>No dedicated-placement exception detected.</b></div>'
mixed_html=table(mixed,['Namespace','Placement']) if mixed else '<div class="card good"><b>No mixed namespace placement detected.</b></div>'
rec_html=table(recs,['Pool','Current_Nodes','Avg_CPU_Cores_Per_Node','Avg_Memory_GiB_Per_Node','DaemonSet_CPU_Per_Node','DaemonSet_Mem_Per_Node','Net_CPU_Per_New_Node','Net_Mem_Per_New_Node','CPU_Requests','Mem_Requests','Target_Util_Pct','Recommended_Nodes_To_Add','Binding_Constraint','Status'])
growth_html=table(growth,['Pool','Growth_Pct','Projected_CPU_Requests','Projected_Mem_Requests','Current_Nodes','Recommended_Nodes_To_Add','Binding_Constraint','Status'])
doc='''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenShift Capacity Report</title><style>'''+css+'''</style></head><body><div class="container">
<div class="hero"><h1>OpenShift Capacity & Node Placement Report</h1><div class="sub">Generated: '''+esc(datetime.now().astimezone().isoformat(timespec='seconds'))+'''</div><div class="sub">Actual running pod effective requests vs node allocatable capacity. Dedicated and shared pools are calculated separately.</div></div>
<div class="grid"><div class="card"><div class="label">Total Worker / Compute Nodes</div><div class="metric">'''+esc(worker)+'''</div></div><div class="card"><div class="label">Dedicated / Tainted Nodes</div><div class="metric">'''+esc(dnodes)+'''</div><div class="label">Automatically discovered</div></div><div class="card"><div class="label">Shared / General Nodes</div><div class="metric">'''+esc(snodes)+'''</div><div class="label">Shared capacity pool</div></div><div class="card"><div class="label">Placement Exceptions</div><div class="metric '''+('bad' if exceptions else 'good')+'''">'''+str(len(exceptions))+'''</div><div class="label">Dedicated-targeted pods on shared nodes</div></div></div>
<div class="section"><h2>Capacity at a glance</h2><div class="twocol"><div class="card"><h3>Dedicated capacity</h3><div class="label">CPU requests / allocatable</div><b>'''+esc(dreq)+''' / '''+esc(dcpu)+''' cores ('''+esc(dpct)+'''%)</b><div class="bar"><div class="fill" style="width:'''+str(pct(dpct))+'''%"></div></div><div class="label" style="margin-top:12px">Memory requests / allocatable</div><b>'''+esc(dmreq)+''' / '''+esc(dmem)+''' GiB ('''+esc(dmpct)+'''%)</b><div class="bar"><div class="fill" style="width:'''+str(pct(dmpct))+'''%"></div></div></div><div class="card"><h3>Shared capacity</h3><div class="label">CPU requests / allocatable</div><b>'''+esc(sreq)+''' / '''+esc(scpu)+''' cores ('''+esc(spct)+'''%)</b><div class="bar"><div class="fill" style="width:'''+str(pct(spct))+'''%"></div></div><div class="label" style="margin-top:12px">Memory requests / allocatable</div><b>'''+esc(smreq)+''' / '''+esc(smem)+''' GiB ('''+esc(smpct)+'''%)</b><div class="bar"><div class="fill" style="width:'''+str(pct(smpct))+'''%"></div></div></div></div></div>
<div class="section"><h2>📈 Node forecast (Capacity Glance)</h2>
<div class="info"><b>Planning rule:</b> Calculations use <b>Requests</b> (scheduler guarantee), not Limits. Node allocatable already excludes kube/system reserved capacity. Target utilization = '''+esc(tgt_util)+'''% — remaining headroom is for burst, DaemonSets, and operational safety.<br>
Formula: net_per_new_node = avg_allocatable − avg_DaemonSet_requests; nodes_to_add = ceil(deficit / (net × target_factor)). Binding = max(CPU, Memory). DaemonSets are included because they consume capacity on every new node.</div>
<div class="twocol" style="margin-top:14px">
<div class="card"><h3>Dedicated pool</h3>
<div class="label">Recommended nodes to add</div><div class="metric '''+('bad' if num(d_add)>0 else 'good')+'''">'''+esc(d_add)+'''</div>
<div class="label">Binding constraint: '''+esc(d_bind or '—')+'''</div>
<div class="label" style="margin-top:8px">'''+esc(d_status)+'''</div>
</div>
<div class="card"><h3>Shared pool</h3>
<div class="label">Recommended nodes to add</div><div class="metric '''+('bad' if num(s_add)>0 else 'good')+'''">'''+esc(s_add)+'''</div>
<div class="label">Binding constraint: '''+esc(s_bind or '—')+'''</div>
<div class="label" style="margin-top:8px">'''+esc(s_status)+'''</div>
</div></div>
'''+rec_html+'''
</div>
<div class="section"><h2>🚀 Future workload growth simulation</h2>
<div class="info"><b>How it works:</b> Current Running-pod <b>Requests</b> are scaled by each growth % (CPU and memory equally). Nodes-to-add is recomputed at the same target utilization. This answers: <i>“If demand grows by X%, how many nodes do we need?”</i><br>
Configure scenarios via <code>GROWTH_SCENARIOS_PCT</code> (default 10,25,50).</div>
'''+growth_html+'''
</div>
<div class="section"><h2>Node request utilization</h2><div class="twocol"><div class="card"><h3>CPU request %</h3><div class="chart" id="cpuChart"></div></div><div class="card"><h3>Memory request %</h3><div class="chart" id="memChart"></div></div></div></div>
<div class="section"><h2>🚨 Dedicated placement exceptions</h2>'''+exception_html+'''</div><div class="section"><h2>🔀 Namespaces using both dedicated and shared nodes</h2>'''+mixed_html+'''</div>
<div class="section"><h2>Top namespaces by actual running requests</h2>'''+table(nsrows,['Namespace','Pods','CPU Requests Cores','Memory Requests GiB'],20)+'''</div><div class="section"><h2>Node inventory</h2>'''+table(nodes,['Node','role','ready','Classification','dedicated_taint_count','taints','cpu','mem','labels'],100)+'''</div><div class="section"><h2>Detailed node capacity</h2>'''+table(nodecap,['Node','Node_Class','Ready','Allocatable_CPU_Cores','Allocatable_Memory_GiB','Running_Pods','CPU_Requests_Cores','Memory_Requests_GiB','CPU_Free_Cores','Memory_Free_GiB','CPU_Request_Pct','Memory_Request_Pct'],200)+'''</div>
<div class="section"><h2>Pod placement and effective requests</h2>'''+table(placement,['Namespace','Pod_Name','Phase','Node','Node_Class','Effective_CPU_Request_Cores','Effective_Memory_Request_GiB','Pod_Tolerations','NodeSelector','Controller'],300)+'''</div><div class="section"><h2>All node taints</h2>'''+table(taints,['Node','Taint_Key','Taint_Value','Taint_Effect','Classification'],300)+'''</div><div class="section"><h2>All pod tolerations</h2>'''+table(tols,['Namespace','Pod_Name','Node','Toleration_Key','Operator','Toleration_Value','Toleration_Effect','Toleration_Seconds'],300)+'''</div>
<div class="section"><div class="info"><b>Capacity methodology</b><br>
• <b>Requests only</b> (scheduler guarantee) — Limits are ignored for capacity planning.<br>
• Effective pod request = max(sum app-container requests, max init-container request).<br>
• Node allocatable already excludes kubelet/system reserved capacity.<br>
• Dedicated nodes = custom scheduling taints (NoSchedule/NoExecute/PreferNoSchedule), excluding system taints.<br>
• Target utilization (default 80%) leaves headroom for burst and operational safety.<br>
• Nodes-to-add = ceil(request_deficit / (net_usable_per_node × target_factor)) where net = allocatable − DaemonSet requests (DaemonSets auto-schedule on new nodes).<br>
• Binding resource = max(CPU, Memory).<br>
• Placement exceptions require both a dedicated-taint toleration <i>and</i> nodeSelector/affinity while running on a shared node.
</div></div><div class="footer">Generated by capacity_report_auto_html.sh. The dashboard is self-contained and requires no internet/CDN access.</div></div>
<script>const nodes='''+node_json+''';function draw(id,key){const el=document.getElementById(id);el.innerHTML=nodes.map(x=>{let v=x[key]||0;let c=v>=90?'bad':(v>=75?'warn':'');return '<div class="chart-row"><div title="'+x.node+'">'+x.node+' <span class="pill">'+x.class+'</span></div><div class="chartbar"><span class="'+c+'" style="width:'+Math.min(100,v)+'%"></span></div><div>'+v.toFixed(1)+'%</div></div>'}).join('')}draw('cpuChart','cpu');draw('memChart','mem');</script></body></html>'''
html_file.write_text(doc,encoding='utf-8'); print(html_file)
PYHTML
then
  log ERROR "HTML dashboard generation failed (python3 exited non-zero). CSV sheets in $OUTPUT_DIR are still valid; only $HTML_FILE was not produced."
  exit 1
fi
log SUCCESS "HTML dashboard written: $HTML_FILE"

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
$HTML_FILE
========================================
SUMMARY

log SUCCESS "Capacity report generated in: $OUTPUT_DIR"