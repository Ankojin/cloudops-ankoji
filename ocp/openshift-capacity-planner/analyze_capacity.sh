#!/usr/bin/env bash
#
# ARO Ops Dashboard
#
# Part 3/6
# Capacity Analysis Engine
#

set -Eeuo pipefail


#############################################
# Environment validation
#############################################

: "${CAPACITY_OUTPUT:?Missing CAPACITY_OUTPUT}"
: "${CAPACITY_RAW:?Missing CAPACITY_RAW}"
: "${CAPACITY_CSV:?Missing CAPACITY_CSV}"
: "${CAPACITY_JSON:?Missing CAPACITY_JSON}"
: "${CAPACITY_LOG:?Missing CAPACITY_LOG}"



#############################################
# Logging
#############################################

log()
{
    echo "$(date '+%F %T') [ANALYZE] $*" \
    | tee -a "${CAPACITY_LOG}"
}



#############################################
# Helpers
#############################################

cpu_to_cores()
{
    local value="$1"


    if [[ "${value}" == *m ]]
    then

        echo "${value%m}" \
        | awk '{printf "%.3f",$1/1000}'

    else

        echo "${value}" \
        | awk '{printf "%.3f",$1+0}'

    fi
}



memory_to_gb()
{
    local value="$1"


    awk -v mem="$value" '

    function convert(v)
    {

        if(v ~ /Ki$/)
            return substr(v,1,length(v)-2)/1024/1024;


        if(v ~ /Mi$/)
            return substr(v,1,length(v)-2)/1024;


        if(v ~ /Gi$/)
            return substr(v,1,length(v)-2);


        if(v ~ /Ti$/)
            return substr(v,1,length(v)-2)*1024;


        return 0;
    }


    BEGIN{
        printf "%.2f",convert(mem)
    }

    '

}



#############################################
# Node Capacity Analysis
#############################################

log INFO "Calculating node capacity"



echo \
"node,role,cpu_allocatable,memory_allocatable_gb" \
> "${CAPACITY_CSV}/node_capacity.csv"



jq -r '

.items[] |

[
.metadata.name,

(
if (.metadata.labels["node-role.kubernetes.io/master"] or
    .metadata.labels["node-role.kubernetes.io/control-plane"])
then "master"

elif .metadata.labels["node-role.kubernetes.io/infra"]
then "infra"

elif .metadata.labels["node-role.kubernetes.io/worker"]
then "worker"

else "other"

end
),

.status.allocatable.cpu // "0",

.status.allocatable.memory // "0"

]

| @csv

' \
"${CAPACITY_RAW}/nodes.json" \
| while IFS=',' read -r node role cpu memory
do


node=$(echo "${node}" | tr -d '"')
role=$(echo "${role}" | tr -d '"')
cpu=$(echo "${cpu}"   | tr -d '"')
memory=$(echo "${memory}" | tr -d '"')


CPU=$(cpu_to_cores "${cpu}")

MEM=$(memory_to_gb "${memory}")


echo "${node},${role},${CPU},${MEM}" \
>> "${CAPACITY_CSV}/node_capacity.csv"


done



#############################################
# Node Pool Detection (dedicated worker pools)
# MOVED EARLY: must run before the worker-pool pressure gauge below so
# dedicated-pool node capacity can be excluded from the "standard worker
# pool" denominator, and dedicated-pool pods can be excluded from its
# request numerator. See "Standard vs Dedicated Worker Capacity" section.
#
# Looks for WORKER nodes that carry custom taints (e.g. app=sas:NoSchedule)
# identifying dedicated pools. System/lifecycle taints (node.kubernetes.io/*)
# are excluded. A worker node with zero qualifying taints is "standard-worker".
#############################################

log INFO "Detecting node pools (worker taints)"

jq -c '
.items[] |
select(
  (.metadata.labels["node-role.kubernetes.io/master"]        == null) and
  (.metadata.labels["node-role.kubernetes.io/control-plane"] == null) and
  (.metadata.labels["node-role.kubernetes.io/infra"]         == null)
) |
(
  [.spec.taints[]? |
    select(
      (.key | startswith("node.kubernetes.io/")      | not) and
      (.key | startswith("node-role.kubernetes.io/") | not)
    )
  ]
) as $custom_taints |
{
  name:            .metadata.name,
  custom_taints:   $custom_taints,
  cpu_allocatable: (.status.allocatable.cpu    // "0"),
  mem_allocatable: (.status.allocatable.memory // "0")
}
' "${CAPACITY_RAW}/nodes.json" \
| jq -rs '
[
  .[] |
  . as $node |
  if ($node.custom_taints | length) > 0 then
    $node.custom_taints[] |
    {
      pool_key:    (.key + (if .value and .value != "" then "=" + .value else "" end)),
      taint_str:   (.key + (if .value and .value != "" then "=" + .value else "" end) + ":" + .effect),
      taint_key:   .key,
      taint_value: (.value // ""),
      effect:      .effect,
      node_name:   $node.name,
      cpu:         $node.cpu_allocatable,
      mem:         $node.mem_allocatable
    }
  else
    {
      pool_key:    "standard-worker",
      taint_str:   "none",
      taint_key:   "",
      taint_value: "",
      effect:      "none",
      node_name:   $node.name,
      cpu:         $node.cpu_allocatable,
      mem:         $node.mem_allocatable
    }
  end
] |
group_by(.pool_key) |
map(
  . as $pool |
  {
    pool_name:   $pool[0].pool_key,
    taint:       $pool[0].taint_str,
    taint_key:   $pool[0].taint_key,
    taint_value: $pool[0].taint_value,
    effect:      $pool[0].effect,
    dedicated:   ($pool[0].pool_key != "standard-worker"),
    node_count:  ($pool | length),
    nodes:       ($pool | map(.node_name) | unique),
    cpu_cores: (
      $pool | map(
        .cpu |
        if endswith("m") then (.[:-1] | tonumber) / 1000
        else (tonumber? // 0)
        end
      ) | add // 0 | (. * 100 | round) / 100
    ),
    memory_gib: (
      $pool | map(
        .mem |
        if endswith("Ki") then (.[:-2] | tonumber) / 1048576
        elif endswith("Mi") then (.[:-2] | tonumber) / 1024
        elif endswith("Gi") then (.[:-2] | tonumber)
        elif endswith("Ti") then (.[:-2] | tonumber) * 1024
        else (tonumber? // 0) / 1073741824
        end
      ) | add // 0 | (. * 10 | round) / 10
    )
  }
) |
sort_by(if .dedicated then 0 else 1 end)
' > "${CAPACITY_JSON}/node_pools_raw.json"

# Plain node -> pool_name lookup, comma-separated, no quoting — used below
# to join individual pod requests against the pool their node belongs to.
jq -r '
.[] as $p | $p.nodes[] | [., $p.pool_name] | @csv
' "${CAPACITY_JSON}/node_pools_raw.json" \
| tr -d '"' \
> "${CAPACITY_RAW}/node_pool_lookup.csv"

# Total capacity carved out by dedicated pools — subtracted from the
# all-worker total below to get the *standard* worker pool's own capacity.
DEDICATED_POOL_CPU=$(jq '[.[] | select(.dedicated) | .cpu_cores] | add // 0' "${CAPACITY_JSON}/node_pools_raw.json")
DEDICATED_POOL_MEM=$(jq '[.[] | select(.dedicated) | .memory_gib] | add // 0' "${CAPACITY_JSON}/node_pools_raw.json")
DEDICATED_POOL_COUNT=$(jq '[.[] | select(.dedicated)] | length' "${CAPACITY_JSON}/node_pools_raw.json")

log INFO "Dedicated pools found: ${DEDICATED_POOL_COUNT} (${DEDICATED_POOL_CPU} cores / ${DEDICATED_POOL_MEM} GiB carved out of the worker fleet)"



#############################################
# Cluster totals
#############################################

TOTAL_CPU=$(

awk -F',' '

NR>1 {
sum+=$3
}

END{
printf "%.3f",sum
}

' \
"${CAPACITY_CSV}/node_capacity.csv"

)



TOTAL_MEMORY=$(

awk -F',' '

NR>1 {
sum+=$4
}

END{
printf "%.2f",sum
}

' \
"${CAPACITY_CSV}/node_capacity.csv"

)



#############################################
# Ephemeral Storage (from node allocatable)
#############################################

# Convert Ki/Mi/Gi/Ti → GiB for each node, then sum
ki_to_gib() {
    awk '{
        v=$1
        if      (v ~ /Ti$/) { sub(/Ti$/,"",v); printf "%.1f", v*1024 }
        else if (v ~ /Gi$/) { sub(/Gi$/,"",v); printf "%.1f", v }
        else if (v ~ /Mi$/) { sub(/Mi$/,"",v); printf "%.1f", v/1024 }
        else if (v ~ /Ki$/) { sub(/Ki$/,"",v); printf "%.1f", v/1048576 }
        else                 { printf "%.1f", v/1073741824 }
    }'
}

EPHEMERAL_CAPACITY_GIB=$(jq -r \
    '.items[].status.capacity["ephemeral-storage"] // "0"' \
    "${CAPACITY_RAW}/nodes.json" \
| awk '
{ v=$1
  if      (v ~ /Ti$/) { sub(/Ti$/,"",v); s+=v*1024 }
  else if (v ~ /Gi$/) { sub(/Gi$/,"",v); s+=v }
  else if (v ~ /Mi$/) { sub(/Mi$/,"",v); s+=v/1024 }
  else if (v ~ /Ki$/) { sub(/Ki$/,"",v); s+=v/1048576 }
  else                 { s+=v/1073741824 }
}
END { printf "%.1f", s+0 }')

EPHEMERAL_ALLOC_GIB=$(jq -r \
    '.items[].status.allocatable["ephemeral-storage"] // "0"' \
    "${CAPACITY_RAW}/nodes.json" \
| awk '
{ v=$1
  if      (v ~ /Ti$/) { sub(/Ti$/,"",v); s+=v*1024 }
  else if (v ~ /Gi$/) { sub(/Gi$/,"",v); s+=v }
  else if (v ~ /Mi$/) { sub(/Mi$/,"",v); s+=v/1024 }
  else if (v ~ /Ki$/) { sub(/Ki$/,"",v); s+=v/1048576 }
  else                 { s+=v/1073741824 }
}
END { printf "%.1f", s+0 }')

EPHEMERAL_USED_GIB=$(jq -r '
.items[] |
( (.status.capacity["ephemeral-storage"] // "0") as $cap |
  (.status.allocatable["ephemeral-storage"] // "0") as $alloc |
  { cap: $cap, alloc: $alloc }
)' "${CAPACITY_RAW}/nodes.json" 2>/dev/null | \
awk '
/cap:/ { v=$2; gsub(/[",]/,"",v)
  if      (v ~ /Ki$/) { sub(/Ki$/,"",v); cap+=v/1048576 }
  else if (v ~ /Gi$/) { sub(/Gi$/,"",v); cap+=v }
  else if (v ~ /Mi$/) { sub(/Mi$/,"",v); cap+=v/1024 }
  else                 { cap+=v/1073741824 }
}
/alloc:/ { v=$2; gsub(/[",]/,"",v)
  if      (v ~ /Ki$/) { sub(/Ki$/,"",v); alloc+=v/1048576 }
  else if (v ~ /Gi$/) { sub(/Gi$/,"",v); alloc+=v }
  else if (v ~ /Mi$/) { sub(/Mi$/,"",v); alloc+=v/1024 }
  else                 { alloc+=v/1073741824 }
}
END { d=cap-alloc; printf "%.1f", (d<0)?0:d }
' 2>/dev/null || echo "0")

# The awk/jq parse above is fragile; cross-check by subtracting the two
# already-verified totals and use whichever is larger (non-zero).
EPHEMERAL_USED_GIB_FALLBACK=$(awk "BEGIN{
    d=${EPHEMERAL_CAPACITY_GIB}-${EPHEMERAL_ALLOC_GIB};
    printf \"%.1f\",(d<0)?0:d
}")
# If the awk/jq result is 0 but the fallback is non-zero, prefer the fallback
EPHEMERAL_USED_GIB=$(awk -v a="${EPHEMERAL_USED_GIB}" -v b="${EPHEMERAL_USED_GIB_FALLBACK}" \
    'BEGIN{printf "%.1f",(a+0==0 && b+0>0)?b+0:a+0}')

EPHEMERAL_USED_PCT=$(awk "BEGIN{
    c=${EPHEMERAL_CAPACITY_GIB}+0;
    printf \"%.1f\",(c>0)?(${EPHEMERAL_USED_GIB}/c)*100:0
}")


#############################################
# Pod Request Calculation
#############################################

log INFO "Calculating pod requests"



TOTAL_CPU_REQUEST=0
TOTAL_MEMORY_REQUEST=0



echo \
"namespace,pods,cpu_request,memory_request_gb" \
> "${CAPACITY_CSV}/namespace_usage.csv"



jq -r '

.items[]

# Skip evicted pods (phase=Failed, reason=Evicted) and completed pods.
# ALL namespaces (infra + tenant) are included here so that
# capacity_summary.json reflects true cluster-wide utilization.
# The chargeback section classifies infra vs tenant separately.
| select(
    (.status.phase != "Failed" or .status.reason != "Evicted") and
    (.status.phase != "Succeeded")
)

|

.metadata.namespace as $ns

|

[
$ns,

.metadata.name,

(
[
.spec.containers[].resources.requests.cpu? // "0"
]
| map(
if test("m$")
then (.[:-1] | tonumber) / 1000
else (tonumber? // 0)
end
)
| add // 0
),

(
[
.spec.containers[].resources.requests.memory? // "0"
]
| map(
if test("Ki$") then (.[:-2] | tonumber) / 1024 / 1024
elif test("Mi$") then (.[:-2] | tonumber) / 1024
elif test("Gi$") then (.[:-2] | tonumber)
elif test("Ti$") then (.[:-2] | tonumber) * 1024
else 0
end
)
| add // 0
)

]

| @csv


' \
"${CAPACITY_RAW}/pods.json" \
> "${CAPACITY_RAW}/pod_requests_raw.csv"



awk -F',' '

{

namespace=$1


cpu=$3
memory=$4


if(cpu=="")
cpu="0"


if(memory=="")
memory="0"



cpu_total[namespace]+=cpu


mem_total[namespace]+=memory


pods[namespace]++

}



END{


for(ns in pods)

print ns","pods[ns]","cpu_total[ns]","mem_total[ns]


}

' \
"${CAPACITY_RAW}/pod_requests_raw.csv" \
>> "${CAPACITY_CSV}/namespace_usage.csv"



#############################################
# Pool Request Attribution
#
# BUG FIX: the cluster-wide CPU_REQUEST/MEM_REQUEST totals (computed later,
# from namespace_usage.csv) include every pod in every namespace regardless
# of which node it actually landed on. Comparing that global total against
# worker-only (or standard-worker-only) capacity overstates pressure whenever
# infra nodes or dedicated/tainted worker pools are carrying real load —
# those pods' requests get counted against capacity they were never
# competing for.
#
# This join attributes each pod's request to the specific pool (standard
# worker vs. a named dedicated pool) its node belongs to, using the
# pod-name-enriched pod_node_map.csv and the node_pool_lookup.csv built
# earlier from node_pools_raw.json. Pods on master/infra nodes are dropped
# entirely — they were never eligible to consume worker capacity.
#############################################

log INFO "Attributing pod requests to worker pools"

POOL_REQUESTS_CSV="${CAPACITY_JSON}/pool_requests.csv"

if [[ -f "${CAPACITY_RAW}/pod_node_map.csv" && -f "${CAPACITY_RAW}/node_pool_lookup.csv" ]]; then
  awk -F',' '
  # File 1: node_pool_lookup.csv -> node,pool_name (unquoted)
  FNR==NR { node_pool[$1] = $2; next }

  # File 2: pod_node_map.csv -> "namespace","pod","node" (quoted)
  FILENAME ~ /pod_node_map/ {
    gsub(/"/, "", $0)
    n = split($0, f, ",")
    if (n >= 3) pod_node[f[1] SUBSEP f[2]] = f[3]
    next
  }

  # File 3: pod_requests_raw.csv -> "namespace","pod",cpu,mem (quoted ns/pod)
  {
    gsub(/"/, "", $1); gsub(/"/, "", $2)
    ns = $1; pod = $2; cpu = $3 + 0; mem = $4 + 0
    key = ns SUBSEP pod
    if (!(key in pod_node)) next          # pod not Running / not mapped — skip
    node = pod_node[key]
    if (!(node in node_pool)) next        # master/infra node — not worker capacity, skip
    pool = node_pool[node]
    pool_cpu[pool] += cpu
    pool_mem[pool] += mem
  }
  END {
    for (p in pool_cpu) printf "%s,%.3f,%.3f\n", p, pool_cpu[p], pool_mem[p]+0
  }
  ' "${CAPACITY_RAW}/node_pool_lookup.csv" "${CAPACITY_RAW}/pod_node_map.csv" "${CAPACITY_RAW}/pod_requests_raw.csv" \
  > "${POOL_REQUESTS_CSV}" 2>/dev/null || echo "" > "${POOL_REQUESTS_CSV}"
else
  log INFO "WARN: pod_node_map.csv or node_pool_lookup.csv missing — pool-level request attribution unavailable, standard-worker figures will read as 0"
  echo "" > "${POOL_REQUESTS_CSV}"
fi

# Standard worker pool's own requested CPU/memory (excludes dedicated pools
# and excludes anything scheduled on master/infra nodes).
STANDARD_WORKER_CPU_REQUEST=$(awk -F',' '$1=="standard-worker"{print $2}' "${POOL_REQUESTS_CSV}")
STANDARD_WORKER_MEM_REQUEST=$(awk -F',' '$1=="standard-worker"{print $3}' "${POOL_REQUESTS_CSV}")
STANDARD_WORKER_CPU_REQUEST="${STANDARD_WORKER_CPU_REQUEST:-0}"
STANDARD_WORKER_MEM_REQUEST="${STANDARD_WORKER_MEM_REQUEST:-0}"

log INFO "Standard worker pool requested: ${STANDARD_WORKER_CPU_REQUEST} cores / ${STANDARD_WORKER_MEM_REQUEST} GiB (dedicated pools and infra/master excluded)"



#############################################
# Top CPU Consumers
#############################################

log INFO "Generating CPU consumers"



echo "namespace,pods,cpu_request" \
> "${CAPACITY_CSV}/top_cpu_consumers.csv"

tail -n +2 \
"${CAPACITY_CSV}/namespace_usage.csv" \
| sort -t',' -k3 -nr \
| head -10 \
>> "${CAPACITY_CSV}/top_cpu_consumers.csv"



#############################################
# Top Memory Consumers
#############################################

log INFO "Generating memory consumers"



echo "namespace,pods,memory_request_gb" \
> "${CAPACITY_CSV}/top_memory_consumers.csv"

awk -F',' '
NR>1 { print $1","$2","$4 }
' \
"${CAPACITY_CSV}/namespace_usage.csv" \
| sort -t',' -k3 -nr \
| head -10 \
>> "${CAPACITY_CSV}/top_memory_consumers.csv"



#############################################
# PVC Consumers
#############################################

log INFO "Processing PVC usage"



echo "namespace,pvc,storage" \
> "${CAPACITY_CSV}/top_pvc_consumers.csv"


# Sort by size inside jq (avoids | head broken-pipe with set -o pipefail)
jq -r '
.items
| sort_by(
    .spec.resources.requests.storage // "0"
    | if   test("Ti$") then (.[:-2]|tonumber)*1099511627776
      elif test("Gi$") then (.[:-2]|tonumber)*1073741824
      elif test("Mi$") then (.[:-2]|tonumber)*1048576
      elif test("Ki$") then (.[:-2]|tonumber)*1024
      else (tonumber? // 0)
      end
  )
| reverse
| .[:10][]
| [.metadata.namespace, .metadata.name,
   (.spec.resources.requests.storage // "0")]
| @csv
' \
"${CAPACITY_RAW}/pvcs.json" \
>> "${CAPACITY_CSV}/top_pvc_consumers.csv"
#############################################
# Actual Metrics Analysis
#############################################

log INFO "Analyzing actual utilization"



CPU_USED=0
MEM_USED=0



if [[ -s "${CAPACITY_RAW}/node_metrics.json" ]]
then

    log INFO "Using Metrics Server node data"


    while read -r line
    do

        cpu=$(echo "$line" | awk '{print $2}')

        mem=$(echo "$line" | awk '{print $3}')


        cpu=$(cpu_to_cores "$cpu")

        mem=$(memory_to_gb "$mem")


        CPU_USED=$(awk \
        "BEGIN {print ${CPU_USED}+${cpu}}")


        MEM_USED=$(awk \
        "BEGIN {print ${MEM_USED}+${mem}}")



    done < "${CAPACITY_RAW}/node_metrics.json"


else

    log INFO "Metrics unavailable - using requested capacity"


fi



#############################################
# Request Totals
#############################################

CPU_REQUEST=$(

awk -F',' '

NR>1 {

sum+=$3

}

END{

printf "%.3f",sum

}

' \
"${CAPACITY_CSV}/namespace_usage.csv"

)



MEM_REQUEST=$(

awk -F',' '

NR>1 {

sum+=$4

}

END{

printf "%.2f",sum

}

' \
"${CAPACITY_CSV}/namespace_usage.csv"

)



#############################################
# Percentage Calculations
#############################################

CPU_REQUEST_PERCENT=$(

awk \
-v req="${CPU_REQUEST}" \
-v total="${TOTAL_CPU}" '

BEGIN{

if(total>0)

printf "%.2f",(req/total)*100;

else

printf "0"

}

'

)



MEM_REQUEST_PERCENT=$(

awk \
-v req="${MEM_REQUEST}" \
-v total="${TOTAL_MEMORY}" '

BEGIN{

if(total>0)

printf "%.2f",(req/total)*100;

else

printf "0"

}

'

)



CPU_USED_PERCENT=$(

awk \
-v used="${CPU_USED}" \
-v total="${TOTAL_CPU}" '

BEGIN{

if(total>0)

printf "%.2f",(used/total)*100;

else

printf "0"

}

'

)



MEM_USED_PERCENT=$(

awk \
-v used="${MEM_USED}" \
-v total="${TOTAL_MEMORY}" '

BEGIN{

if(total>0)

printf "%.2f",(used/total)*100;

else

printf "0"

}

'

)



#############################################
# Chargeback by Namespace
#
# Logic:
#   - Namespaces prefixed with openshift-*, kube-*,
#     open-cluster-management*, istio-system, etc.
#     are classified as "infra" — platform overhead.
#   - All other namespaces are "tenant" — chargeable.
#
# Chargeback unit = CPU cores reserved (requests).
# Each replica is already an individual pod entry in
# pods.json, so the sum already reflects replica count.
#############################################

log INFO "Generating chargeback report"

#############################################
# Per-Namespace Actual CPU & Memory Usage
# Source: pod_metrics.json (oc get podmetrics)
# Formula: actual_used / cpu_requested × 100 = utilization %
# If Metrics Server unavailable → 0 for actual, 0 for util_pct
#############################################

NS_ACTUAL_USAGE="${CAPACITY_JSON}/ns_actual_usage.tmp"

if [[ -s "${CAPACITY_RAW}/pod_metrics.json" ]] && \
   jq -e '.items | length > 0' "${CAPACITY_RAW}/pod_metrics.json" &>/dev/null
then
    log INFO "Aggregating per-namespace actual usage from pod_metrics.json"
    jq -r '
    .items[] |
    .metadata.namespace as $ns |
    [
        $ns,
        ([.containers[].usage.cpu // "0"] | map(
            if test("m$") then (.[:-1] | tonumber) / 1000
            else (tonumber? // 0) end
        ) | add // 0),
        ([.containers[].usage.memory // "0"] | map(
            if test("Ki$") then (.[:-2] | tonumber) / 1048576
            elif test("Mi$") then (.[:-2] | tonumber) / 1024
            elif test("Gi$") then (.[:-2] | tonumber)
            else 0 end
        ) | add // 0)
    ] | @csv
    ' "${CAPACITY_RAW}/pod_metrics.json" \
    | awk -F'"*,+"*' '
    {
        gsub(/"/, "", $1)
        sum_cpu[$1] += $2+0
        sum_mem[$1] += $3+0
    }
    END { for (ns in sum_cpu) printf "%s,%.3f,%.4f\n", ns, sum_cpu[ns], sum_mem[ns] }
    ' > "${NS_ACTUAL_USAGE}"
else
    log INFO "pod_metrics.json unavailable — actual usage columns will be 0"
    : > "${NS_ACTUAL_USAGE}"
fi

echo "namespace,type,running_pods,cpu_cores_reserved,memory_gb_reserved,cpu_pct_of_cluster,memory_pct_of_cluster,cpu_actual_cores,mem_actual_gb,cpu_util_pct,mem_util_pct" \
> "${CAPACITY_CSV}/chargeback_by_namespace.csv"



awk -F',' \
-v total_cpu="${TOTAL_CPU}" \
-v total_mem="${TOTAL_MEMORY}" '

FNR==NR {
    # First file: ns_actual_usage.tmp  (no header)
    # columns: namespace, cpu_actual_cores, mem_actual_gb
    gsub(/"/, "", $1)
    if ($1 != "") {
        cpu_act[$1] = $2+0
        mem_act[$1] = $3+0
    }
    next
}

FNR==1 { next }   # skip namespace_usage.csv header

{
    gsub(/"/, "", $1)

    ns   = $1
    pods = $2
    cpu  = $3+0
    mem  = $4+0

    type = "tenant"
    if ( ns ~ /^openshift-/           ||
         ns ~ /^kube-/                ||
         ns ~ /^kube$/                ||
         ns ~ /^open-cluster-/        ||
         ns ~ /^istio-/               ||
         ns ~ /^cert-manager/         ||
         ns ~ /^metallb-/             ||
         ns ~ /^default$/             ||
         ns ~ /^multicluster-/        ||
         ns ~ /^hive$/                ||
         ns ~ /^local-cluster$/       ||
         ns ~ /^redhat-/              ||
         ns ~ /^stackrox/             ||
         ns ~ /^rhacs-/               ||
         ns ~ /^ansible-automation/   ||
         ns ~ /^aap-/                 ||
         ns ~ /^submariner-/          ||
         ns ~ /^managed-/             ||
         ns ~ /^hypershift$/          ||
         ns ~ /^assisted-installer$/  ||
         ns ~ /^image-registry$/      ||
         ns ~ /^logging$/             ||
         ns ~ /^openshift$/  )
    {
        type = "infra"
    }

    cpu_pct  = (total_cpu > 0) ? (cpu / total_cpu) * 100 : 0
    mem_pct  = (total_mem > 0) ? (mem / total_mem) * 100 : 0

    c_act    = cpu_act[ns]+0
    m_act    = mem_act[ns]+0

    # Utilization % = actual used / requested × 100
    # "You requested 10 cores and pods are using 5 → 50% utilization"
    cpu_util = (cpu > 0) ? (c_act / cpu) * 100 : 0
    mem_util = (mem > 0) ? (m_act / mem) * 100 : 0

    printf "%s,%s,%s,%.3f,%.2f,%.2f,%.2f,%.3f,%.3f,%.1f,%.1f\n",
        ns, type, pods, cpu, mem, cpu_pct, mem_pct, c_act, m_act, cpu_util, mem_util
}

' \
"${NS_ACTUAL_USAGE}" "${CAPACITY_CSV}/namespace_usage.csv" \
>> "${CAPACITY_CSV}/chargeback_by_namespace.csv"



TENANT_CPU=$(awk -F',' 'NR>1 && $2=="tenant" { sum+=$4 } END { printf "%.3f", sum+0 }' \
"${CAPACITY_CSV}/chargeback_by_namespace.csv")

TENANT_MEM=$(awk -F',' 'NR>1 && $2=="tenant" { sum+=$5 } END { printf "%.2f", sum+0 }' \
"${CAPACITY_CSV}/chargeback_by_namespace.csv")

INFRA_CPU=$(awk -F',' 'NR>1 && $2=="infra" { sum+=$4 } END { printf "%.3f", sum+0 }' \
"${CAPACITY_CSV}/chargeback_by_namespace.csv")

INFRA_MEM=$(awk -F',' 'NR>1 && $2=="infra" { sum+=$5 } END { printf "%.2f", sum+0 }' \
"${CAPACITY_CSV}/chargeback_by_namespace.csv")

TENANT_COUNT=$(awk -F',' 'NR>1 && $2=="tenant" { c++ } END { print c+0 }' \
"${CAPACITY_CSV}/chargeback_by_namespace.csv")



TENANT_JSON=$(awk -F',' '
NR>1 && $2=="tenant" {
    printf "{\"namespace\":\"%s\",\"running_pods\":%s,\"cpu_cores_reserved\":%.3f,\"memory_gb_reserved\":%.2f,\"cpu_pct_of_cluster\":%.2f,\"memory_pct_of_cluster\":%.2f,\"cpu_actual_cores\":%.3f,\"mem_actual_gb\":%.3f,\"cpu_util_pct\":%.1f,\"mem_util_pct\":%.1f},",
        $1, $3, $4, $5, $6, $7, $8+0, $9+0, $10+0, $11+0
}
' "${CAPACITY_CSV}/chargeback_by_namespace.csv")

TENANT_JSON="[${TENANT_JSON%,}]"



# Use separate if/else instead of ternary to avoid BusyBox awk non-short-circuit on 0/0
INFRA_CPU_PCT=$(awk  "BEGIN{c=${TOTAL_CPU}+0;  printf \"%.2f\",(c>0)?(${INFRA_CPU}+0)/c*100:0}")
INFRA_MEM_PCT=$(awk  "BEGIN{m=${TOTAL_MEMORY}+0; printf \"%.2f\",(m>0)?(${INFRA_MEM}+0)/m*100:0}")
TENANT_CPU_PCT=$(awk "BEGIN{c=${TOTAL_CPU}+0;  printf \"%.2f\",(c>0)?(${TENANT_CPU}+0)/c*100:0}")
TENANT_MEM_PCT=$(awk "BEGIN{m=${TOTAL_MEMORY}+0; printf \"%.2f\",(m>0)?(${TENANT_MEM}+0)/m*100:0}")



cat > "${CAPACITY_JSON}/chargeback.json" <<EOF
{
    "generated": "$(date -Iseconds)",
    "chargeback_note": "Unit = cpu_cores_reserved (sum of cpu requests across all running replicas). Each tenant is billed proportionally to cpu_pct_of_cluster.",
    "cluster_capacity": {
        "cpu_cores": ${TOTAL_CPU},
        "memory_gb": ${TOTAL_MEMORY}
    },
    "infrastructure_overhead": {
        "cpu_cores_reserved": ${INFRA_CPU},
        "memory_gb_reserved": ${INFRA_MEM},
        "cpu_pct_of_cluster": ${INFRA_CPU_PCT},
        "memory_pct_of_cluster": ${INFRA_MEM_PCT}
    },
    "tenant_workloads": {
        "namespace_count": ${TENANT_COUNT},
        "cpu_cores_reserved": ${TENANT_CPU},
        "memory_gb_reserved": ${TENANT_MEM},
        "cpu_pct_of_cluster": ${TENANT_CPU_PCT},
        "memory_pct_of_cluster": ${TENANT_MEM_PCT}
    },
    "tenants": ${TENANT_JSON}
}
EOF



log INFO "Chargeback JSON  : ${CAPACITY_JSON}/chargeback.json"
log INFO "Chargeback CSV   : ${CAPACITY_CSV}/chargeback_by_namespace.csv"



#############################################
# Capacity Planning — Worker-only pool
#
# Masters are tainted; user workloads run on
# workers only.  All pressure thresholds are
# computed against worker allocatable capacity.
#
# Safe scheduling threshold = 80%
#   - 20% headroom absorbs: node failures,
#     burst traffic, rolling deployments
#
# Pressure thresholds:
#   GREEN  : < 60%  — comfortable
#   YELLOW : 60-80% — monitor, plan expansion
#   ORANGE : 80-90% — at risk, add capacity soon
#   RED    : > 90%  — critical, immediate action
#############################################

log INFO "Calculating capacity planning metrics"



WORKER_CPU=$(awk -F',' '
NR>1 { gsub(/"/,"",$2); if($2=="worker") sum+=$3 }
END { printf "%.3f", sum+0 }
' "${CAPACITY_CSV}/node_capacity.csv")

WORKER_MEM=$(awk -F',' '
NR>1 { gsub(/"/,"",$2); if($2=="worker") sum+=$4 }
END { printf "%.2f", sum+0 }
' "${CAPACITY_CSV}/node_capacity.csv")

# BUG FIX: WORKER_CPU/WORKER_MEM above are ALL worker-labeled nodes, which
# includes any dedicated/tainted pools (node_pools_raw.json, built earlier,
# still classifies them role="worker"). The pressure gauge below must be
# scoped to the STANDARD worker pool only — general-purpose, untainted
# nodes — otherwise dedicated-pool capacity and demand get blended into the
# same number as standard-worker capacity/demand, which is meaningless for
# either one. DEDICATED_POOL_CPU/MEM were computed in the Node Pool
# Detection section above.
STANDARD_WORKER_CPU=$(awk "BEGIN{ v=${WORKER_CPU}-${DEDICATED_POOL_CPU}; printf \"%.3f\",(v<0?0:v) }")
STANDARD_WORKER_MEM=$(awk "BEGIN{ v=${WORKER_MEM}-${DEDICATED_POOL_MEM}; printf \"%.2f\",(v<0?0:v) }")

WORKER_COUNT=$(awk -F',' 'NR>1 { gsub(/"/,"",$2); if($2=="worker") c++ } END { print c+0 }' \
"${CAPACITY_CSV}/node_capacity.csv")

NODE_CPU=$(awk -F',' 'NR>1 { gsub(/"/,"",$2); if($2=="worker") { print $3; exit } }' \
"${CAPACITY_CSV}/node_capacity.csv")

# Master node pool stats
MASTER_CPU=$(awk -F',' '
NR>1 { gsub(/"/,"",$2); if($2=="master") sum+=$3 }
END { printf "%.3f", sum+0 }
' "${CAPACITY_CSV}/node_capacity.csv")

MASTER_MEM=$(awk -F',' '
NR>1 { gsub(/"/,"",$2); if($2=="master") sum+=$4 }
END { printf "%.2f", sum+0 }
' "${CAPACITY_CSV}/node_capacity.csv")

MASTER_COUNT=$(awk -F',' 'NR>1 { gsub(/"/,"",$2); if($2=="master") c++ } END { print c+0 }' \
"${CAPACITY_CSV}/node_capacity.csv")

# Infra node pool stats (may be 0 on compact clusters)
INFRA_NODE_CPU=$(awk -F',' '
NR>1 { gsub(/"/,"",$2); if($2=="infra") sum+=$3 }
END { printf "%.3f", sum+0 }
' "${CAPACITY_CSV}/node_capacity.csv")

INFRA_NODE_MEM=$(awk -F',' '
NR>1 { gsub(/"/,"",$2); if($2=="infra") sum+=$4 }
END { printf "%.2f", sum+0 }
' "${CAPACITY_CSV}/node_capacity.csv")

INFRA_NODE_COUNT=$(awk -F',' 'NR>1 { gsub(/"/,"",$2); if($2=="infra") c++ } END { print c+0 }' \
"${CAPACITY_CSV}/node_capacity.csv")

# Safe threshold = 80% of STANDARD worker pool capacity (dedicated pools excluded)
WORKER_CPU_SAFE=$(awk "BEGIN{printf \"%.3f\",${STANDARD_WORKER_CPU}*0.80}")
WORKER_MEM_SAFE=$(awk "BEGIN{printf \"%.2f\",${STANDARD_WORKER_MEM}*0.80}")

# How many cores/GB remain before hitting safe threshold.
# BUG FIX: previously used the cluster-wide CPU_REQUEST/MEM_REQUEST, which
# included pods on infra nodes and on dedicated/tainted pools — resources
# those pods were never competing with standard workers for. Now uses
# STANDARD_WORKER_CPU_REQUEST/MEM_REQUEST, attributed per-pod via actual
# node placement (see "Pool Request Attribution" section).
WORKER_CPU_AVAILABLE=$(awk "BEGIN{
    v=${WORKER_CPU_SAFE}-${STANDARD_WORKER_CPU_REQUEST}
    printf \"%.3f\",(v<0?0:v)
}")
WORKER_MEM_AVAILABLE=$(awk "BEGIN{
    v=${WORKER_MEM_SAFE}-${STANDARD_WORKER_MEM_REQUEST}
    printf \"%.2f\",(v<0?0:v)
}")

# Utilization % against the STANDARD worker pool only
WORKER_CPU_PCT=$(awk "BEGIN{
    printf \"%.2f\",(${STANDARD_WORKER_CPU}>0)?(${STANDARD_WORKER_CPU_REQUEST}/${STANDARD_WORKER_CPU})*100:0
}")
WORKER_MEM_PCT=$(awk "BEGIN{
    printf \"%.2f\",(${STANDARD_WORKER_MEM}>0)?(${STANDARD_WORKER_MEM_REQUEST}/${STANDARD_WORKER_MEM})*100:0
}")

# Pressure level
PRESSURE_LEVEL="GREEN"
if   (( $(awk "BEGIN{print (${WORKER_CPU_PCT}>90)}") )); then PRESSURE_LEVEL="RED"
elif (( $(awk "BEGIN{print (${WORKER_CPU_PCT}>80)}") )); then PRESSURE_LEVEL="ORANGE"
elif (( $(awk "BEGIN{print (${WORKER_CPU_PCT}>60)}") )); then PRESSURE_LEVEL="YELLOW"
fi

# How many new worker nodes needed to safely onboard the available headroom
# (i.e., if available cores < 1 node worth, recommend adding a node)
NODES_NEEDED=$(awk -v avail="${WORKER_CPU_AVAILABLE}" -v per_node="${NODE_CPU}" '
BEGIN{
    if(per_node>0 && avail<per_node)
        printf "%d", int((per_node-avail)/per_node)+1
    else
        print 0
}')

# Growth forecast — grows STANDARD WORKER pool demand, checks against
# STANDARD WORKER pool capacity (dedicated pools excluded — same fix as the
# pressure gauge above; growing the blended global request against blended
# worker capacity inherited the same overstatement bug).
create_growth()
{
    local percent=$1
    awk \
    -v cpu="${STANDARD_WORKER_CPU_REQUEST}" \
    -v mem="${STANDARD_WORKER_MEM_REQUEST}" \
    -v factor="${percent}" \
    -v worker_cpu="${STANDARD_WORKER_CPU}" \
    -v worker_mem="${STANDARD_WORKER_MEM}" '
    BEGIN{
        cpu_future = cpu*(1+factor/100)
        mem_future = mem*(1+factor/100)
        cpu_pct    = (worker_cpu>0) ? (cpu_future/worker_cpu)*100 : 0
        mem_pct    = (worker_mem>0) ? (mem_future/worker_mem)*100 : 0
        safe       = (cpu_pct<=80) ? "safe" : (cpu_pct<=90) ? "at_risk" : "critical"
        printf "{\"cpu_request\":%.2f,\"memory_request_gb\":%.2f,\"cpu_pct_of_workers\":%.2f,\"memory_pct_of_workers\":%.2f,\"status\":\"%s\"}",
            cpu_future, mem_future, cpu_pct, mem_pct, safe
    }
    '
}



cat > "${CAPACITY_JSON}/growth_forecast.json" <<EOF
{
    "current":   $(create_growth 0),
    "growth_25": $(create_growth 25),
    "growth_50": $(create_growth 50),
    "growth_75": $(create_growth 75),
    "growth_100":$(create_growth 100)
}
EOF



#############################################
# Capacity Planning Summary
#############################################

log INFO "Generating capacity planning summary"



cat > "${CAPACITY_JSON}/capacity_planning.json" <<EOF
{
    "generated": "$(date -Iseconds)",
    "note": "Pressure/utilization figures below are scoped to the STANDARD worker pool only (dedicated/tainted pools excluded). See dedicated_pools block and node_pools.json for per-project-pool figures. Masters are excluded entirely — they run control-plane components and cannot schedule tenant workloads.",

    "master_pool": {
        "master_nodes": ${MASTER_COUNT},
        "cpu_cores_total": ${MASTER_CPU},
        "memory_gb_total": ${MASTER_MEM},
        "schedulable": false,
        "note": "Control-plane nodes — tainted, not schedulable for tenant workloads"
    },

    "infra_pool": {
        "infra_nodes": ${INFRA_NODE_COUNT},
        "cpu_cores_total": ${INFRA_NODE_CPU},
        "memory_gb_total": ${INFRA_NODE_MEM},
        "schedulable": false,
        "note": "Infrastructure nodes for router/registry/monitoring workloads"
    },

    "worker_pool": {
        "worker_nodes": ${WORKER_COUNT},
        "cpu_cores_per_node": ${NODE_CPU},
        "cpu_cores_total": ${WORKER_CPU},
        "memory_gb_total": ${WORKER_MEM},
        "schedulable": true,
        "note": "ALL worker-labeled nodes, including any dedicated/tainted pools. Informational only — pressure/utilization below use standard_worker_pool, not this total."
    },

    "standard_worker_pool": {
        "cpu_cores_total": ${STANDARD_WORKER_CPU},
        "memory_gb_total": ${STANDARD_WORKER_MEM},
        "note": "worker_pool minus dedicated/tainted pool capacity. This is what current_utilization, safe_threshold_80pct, headroom_for_new_projects, and pressure_level below are actually computed against."
    },

    "dedicated_pools": {
        "pool_count": ${DEDICATED_POOL_COUNT},
        "cpu_cores_total": ${DEDICATED_POOL_CPU},
        "memory_gb_total": ${DEDICATED_POOL_MEM},
        "note": "Aggregate across all dedicated/tainted pools. Per-pool capacity, requested CPU/memory, utilization %, and per-project pod attribution are in node_pools.json."
    },

    "current_utilization": {
        "cpu_cores_requested": ${STANDARD_WORKER_CPU_REQUEST},
        "memory_gb_requested": ${STANDARD_WORKER_MEM_REQUEST},
        "cpu_pct_of_workers": ${WORKER_CPU_PCT},
        "memory_pct_of_workers": ${WORKER_MEM_PCT},
        "pressure_level": "${PRESSURE_LEVEL}"
    },

    "safe_threshold_80pct": {
        "cpu_cores": ${WORKER_CPU_SAFE},
        "memory_gb": ${WORKER_MEM_SAFE}
    },

    "headroom_for_new_projects": {
        "cpu_cores_available": ${WORKER_CPU_AVAILABLE},
        "memory_gb_available": ${WORKER_MEM_AVAILABLE},
        "equivalent_worker_nodes": $(awk "BEGIN{printf \"%.1f\",(${NODE_CPU}+0>0)?(${WORKER_CPU_AVAILABLE}+0)/(${NODE_CPU}+0):0}"),
        "action": "$(
            if   (( $(awk "BEGIN{print (${WORKER_CPU_PCT}>90)}") )); then echo "CRITICAL: Stop onboarding. Add worker nodes immediately."
            elif (( $(awk "BEGIN{print (${WORKER_CPU_PCT}>80)}") )); then echo "AT RISK: Limit new project onboarding. Add ${NODES_NEEDED} worker node(s)."
            elif (( $(awk "BEGIN{print (${WORKER_CPU_PCT}>60)}") )); then echo "MONITOR: ${WORKER_CPU_AVAILABLE} cores available. Plan expansion before reaching 80%."
            else echo "HEALTHY: ${WORKER_CPU_AVAILABLE} cores available for new projects."
            fi
        )"
    },

    "expansion_planning": {
        "cores_to_add_for_1_new_node": ${NODE_CPU},
        "nodes_to_reach_80pct_safe_again": ${NODES_NEEDED},
        "growth_forecast": "See growth_forecast.json"
    },

    "pressure_thresholds": {
        "GREEN":  "< 60%  — comfortable, onboard freely",
        "YELLOW": "60-80% — monitor weekly, prepare expansion",
        "ORANGE": "80-90% — restrict new projects, add capacity soon",
        "RED":    "> 90%  — critical, immediate node expansion required"
    }
}
EOF



log INFO "Capacity planning: ${CAPACITY_JSON}/capacity_planning.json"



#############################################
# Recommendation Logic
#############################################

log INFO "Generating recommendations"



CPU_RECOMMENDATION="No CPU expansion required"

MEM_RECOMMENDATION="No memory expansion required"



if (( $(awk "BEGIN {print (${CPU_REQUEST_PERCENT}>85)}") ))
then

CPU_RECOMMENDATION="CPU capacity above 85%. Add worker capacity."

fi



if (( $(awk "BEGIN {print (${MEM_REQUEST_PERCENT}>85)}") ))
then

MEM_RECOMMENDATION="Memory capacity above 85%. Add worker memory."

fi



#############################################
# Capacity Summary
#############################################


cat > "${CAPACITY_JSON}/capacity_summary.json" <<EOF
{

"generated":"$(date -Iseconds)",


"cluster_capacity":
{

"cpu_cores":${TOTAL_CPU},

"memory_gb":${TOTAL_MEMORY}

},


"requests":
{

"cpu_cores":${CPU_REQUEST},

"memory_gb":${MEM_REQUEST}

},


"utilization":
{

"cpu_requested_percent":${CPU_REQUEST_PERCENT},

"memory_requested_percent":${MEM_REQUEST_PERCENT},

"cpu_used_percent":${CPU_USED_PERCENT},

"memory_used_percent":${MEM_USED_PERCENT}

},


"ephemeral_storage":
{

"capacity_gib":${EPHEMERAL_CAPACITY_GIB},

"allocatable_gib":${EPHEMERAL_ALLOC_GIB},

"used_gib":${EPHEMERAL_USED_GIB},

"used_pct":${EPHEMERAL_USED_PCT}

}

}
EOF



#############################################
# Recommendations JSON
#############################################

cat > "${CAPACITY_JSON}/recommendations.json" <<EOF
{

"cpu":
"${CPU_RECOMMENDATION}",


"memory":
"${MEM_RECOMMENDATION}",


"growth":

{

"25_percent":
"Monitor",

"50_percent":
"Review worker scaling",

"75_percent":
"Plan expansion",

"100_percent":
"Immediate capacity planning required"

}


}
EOF



#############################################
# Final Output
#############################################

log INFO "Capacity analysis completed"



echo "

============================================
 Capacity Analysis Completed
============================================

CPU Capacity:
${TOTAL_CPU} cores


Memory Capacity:
${TOTAL_MEMORY} GB


CPU Requested:
${CPU_REQUEST} cores (${CPU_REQUEST_PERCENT}%)


Memory Requested:
${MEM_REQUEST} GB (${MEM_REQUEST_PERCENT}%)


Reports:

${CAPACITY_JSON}/capacity_summary.json

${CAPACITY_JSON}/growth_forecast.json

${CAPACITY_JSON}/recommendations.json


============================================

"


#############################################
# DEDICATED NODE POOL ANALYSIS — namespace/request attribution
# Node/taint detection itself (node_pools_raw.json) now runs earlier,
# right after node_capacity.csv, so it's available to the worker-pool
# pressure gauge above. This section maps tenant namespaces and actual
# CPU/memory requests onto those pools.
#############################################

log INFO "Attributing namespaces and requests to node pools"


# Infra/platform namespaces (openshift-*, kube-*, etc.) are excluded —
# DaemonSet pods from those namespaces run on every node and add noise
# to the "Projects on Pool" list without being meaningful tenant workloads.
POD_NODE_MAP="${CAPACITY_RAW}/pod_node_map.csv"
if [[ -f "${POD_NODE_MAP}" ]]; then
  # Build node→pool lookup from the raw pools file
  NODE_POOL_LOOKUP=$(jq -r '
    .[] |
    . as $p |
    $p.nodes[] | . + "\t" + $p.pool_name
  ' "${CAPACITY_JSON}/node_pools_raw.json" 2>/dev/null || true)

  # Aggregate: pool,namespace → pod_count  (tenant namespaces only)
  awk -v lookup="${NODE_POOL_LOOKUP}" '
  BEGIN {
    n = split(lookup, pairs, "\n")
    for (i = 1; i <= n; i++) {
      split(pairs[i], kv, "\t")
      if (kv[1] != "") node_pool[kv[1]] = kv[2]
    }
  }
  {
    # Input CSV: "namespace","pod","node_name" (pod field added so requests
    # can be attributed per-pod elsewhere; not needed for this pod-count pass)
    gsub(/"/, "", $0)
    split($0, f, ",")
    ns   = f[1]
    node = f[3]

    # ── Skip infra / platform namespaces ──────────────────────────────
    # Same patterns as chargeback classification in the main analysis.
    if (ns ~ /^openshift-/          || ns ~ /^openshift$/        ||
        ns ~ /^kube-/               || ns == "kube"              ||
        ns ~ /^open-cluster-/       || ns ~ /^multicluster-/     ||
        ns ~ /^istio-/              || ns ~ /^cert-manager/       ||
        ns ~ /^metallb-/            || ns == "default"            ||
        ns ~ /^redhat-/             || ns ~ /^stackrox/           ||
        ns ~ /^rhacs-/              || ns ~ /^ansible-automation/ ||
        ns ~ /^aap-/                || ns ~ /^submariner-/        ||
        ns ~ /^managed-/            || ns == "hypershift"          ||
        ns == "assisted-installer"  || ns == "image-registry"     ||
        ns == "logging"             || ns == "hive"                ||
        ns == "local-cluster")
      next
    # ─────────────────────────────────────────────────────────────────

    pool = (node in node_pool) ? node_pool[node] : "standard-worker"
    counts[pool SUBSEP ns]++
  }
  END {
    for (key in counts) {
      split(key, kv, SUBSEP)
      print kv[1] "," kv[2] "," counts[key]
    }
  }
  ' "${POD_NODE_MAP}" > "${CAPACITY_JSON}/pool_ns_pods.tmp" 2>/dev/null || true
else
  touch "${CAPACITY_JSON}/pool_ns_pods.tmp"
fi

# Step 3: Merge namespace pod counts AND actual requested CPU/memory
# (from pool_requests.csv, computed earlier in "Pool Request Attribution")
# into the final node_pools.json — so every pool, dedicated or standard,
# shows real utilization and headroom, not just which projects are on it.
[[ -f "${POOL_REQUESTS_CSV}" ]] || POOL_REQUESTS_CSV="/dev/null"

jq -Rs '
[
  (split("\n")[] | select(length > 0) | split(",") | select(length == 3) |
   { pool: .[0], cpu: (.[1] | tonumber? // 0), mem: (.[2] | tonumber? // 0) })
] | (reduce .[] as $r ({}; . + { ($r.pool): { cpu: $r.cpu, mem: $r.mem } }))
' "${POOL_REQUESTS_CSV}" > "${CAPACITY_JSON}/pool_requests.json" 2>/dev/null \
|| echo '{}' > "${CAPACITY_JSON}/pool_requests.json"

jq \
  --rawfile usage "${CAPACITY_JSON}/pool_ns_pods.tmp" \
  --slurpfile requests "${CAPACITY_JSON}/pool_requests.json" '
def parse_usage:
  [
    ($usage | split("\n"))[] |
    select(length > 0) |
    split(",") |
    select(length == 3) |
    { pool: .[0], ns: .[1], pods: (.[2] | tonumber? // 0) }
  ]
;
($requests[0] // {}) as $req |
. as $pools |
parse_usage as $rows |
$pools | map(
  . as $p |
  ($req[$p.pool_name].cpu // 0) as $cpu_req |
  ($req[$p.pool_name].mem // 0) as $mem_req |
  ($cpu_req | . * 100 | round / 100) as $cpu_req_r |
  ($mem_req | . * 100 | round / 100) as $mem_req_r |
  (if $p.cpu_cores > 0 then (($cpu_req / $p.cpu_cores) * 100) else 0 end) as $cpu_pct |
  (if $p.memory_gib > 0 then (($mem_req / $p.memory_gib) * 100) else 0 end) as $mem_pct |
  ([$cpu_pct, $mem_pct] | max) as $max_pct |
  $p + {
    cpu_cores_requested: $cpu_req_r,
    memory_gib_requested: $mem_req_r,
    cpu_utilization_pct: ($cpu_pct * 100 | round / 100),
    memory_utilization_pct: ($mem_pct * 100 | round / 100),
    pressure_level: (
      if   $max_pct > 90 then "RED"
      elif $max_pct > 80 then "ORANGE"
      elif $max_pct > 60 then "YELLOW"
      else "GREEN"
      end
    ),
    namespaces: [
      $rows[] |
      select(.pool == $p.pool_name) |
      { namespace: .ns, pod_count: .pods }
    ] | sort_by(-.pod_count)
  }
)
' "${CAPACITY_JSON}/node_pools_raw.json" \
> "${CAPACITY_JSON}/node_pools.json" 2>/dev/null \
|| cp "${CAPACITY_JSON}/node_pools_raw.json" "${CAPACITY_JSON}/node_pools.json"

rm -f "${CAPACITY_JSON}/node_pools_raw.json" "${CAPACITY_JSON}/pool_ns_pods.tmp" "${CAPACITY_JSON}/pool_requests.json" "${NS_ACTUAL_USAGE}"

DEDICATED_COUNT=$(jq '[.[] | select(.dedicated == true)] | length' "${CAPACITY_JSON}/node_pools.json" 2>/dev/null || echo 0)
log INFO "Dedicated node pool analysis complete → node_pools.json"
log INFO "  ${DEDICATED_COUNT} dedicated worker pool(s) found (e.g. app=sas:NoSchedule)"