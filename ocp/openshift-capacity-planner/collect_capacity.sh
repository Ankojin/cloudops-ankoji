#!/usr/bin/env bash
#
# ARO Ops Dashboard
#
# Part 2A/6
# Data Collection Engine
#
# Supports:
#   OpenShift 4.x
#   Azure Red Hat OpenShift
#

set -Eeuo pipefail


#############################################
# Environment
#############################################

: "${CAPACITY_OUTPUT:?CAPACITY_OUTPUT missing}"
: "${CAPACITY_RAW:?CAPACITY_RAW missing}"
: "${CAPACITY_CSV:?CAPACITY_CSV missing}"
: "${CAPACITY_JSON:?CAPACITY_JSON missing}"
: "${CAPACITY_LOG:?CAPACITY_LOG missing}"



#############################################
# Logging
#############################################

log()
{
    local LEVEL="$1"
    shift

    echo "$(date '+%F %T') [COLLECT] ${LEVEL}: $*" \
    | tee -a "${CAPACITY_LOG}"
}



#############################################
# Directories
#############################################

mkdir -p \
"${CAPACITY_RAW}" \
"${CAPACITY_CSV}" \
"${CAPACITY_JSON}"



#############################################
# Command Wrapper
#############################################

run_oc()
{
    local DESCRIPTION="$1"
    shift

    log INFO "Running: $*"

    if "$@" > /tmp/oc_output.json
    then

        cat /tmp/oc_output.json

    else

        log ERROR "Failed: ${DESCRIPTION}"

        return 1

    fi
}



#############################################
# Banner
#############################################

log INFO "Starting OpenShift inventory collection"



#############################################
# Cluster Information
#############################################

log INFO "Collecting cluster information"



oc get clusterversion \
-o json \
> "${CAPACITY_RAW}/cluster_version.json"



log INFO "Saved cluster_version.json"



oc get infrastructure cluster \
-o json \
> "${CAPACITY_RAW}/infrastructure.json"



log INFO "Saved infrastructure.json"



#############################################
# Nodes
#############################################

log INFO "Collecting nodes"



oc get nodes \
-o json \
> "${CAPACITY_RAW}/nodes.json"



NODE_COUNT=$(jq '.items | length' \
"${CAPACITY_RAW}/nodes.json")



log INFO "Nodes collected: ${NODE_COUNT}"



#############################################
# Node Inventory CSV
#############################################

log INFO "Creating node inventory"



jq -r '

[
"node",
"role",
"cpu_capacity",
"memory_capacity"
],

(

.items[] |

[
.metadata.name,

(
.metadata.labels
| to_entries[]
| select(.key|contains("node-role.kubernetes.io/"))
| .key | split("/") | last
),

.status.capacity.cpu,

.status.capacity.memory

]

)

| @csv

' \
"${CAPACITY_RAW}/nodes.json" \
> "${CAPACITY_CSV}/nodes_inventory.csv"





#############################################
# MachineSets
#############################################

log INFO "Collecting MachineSets"



oc get machinesets \
-n openshift-machine-api \
-o json \
> "${CAPACITY_RAW}/machinesets.json" 2>/dev/null || true



if jq empty \
"${CAPACITY_RAW}/machinesets.json" \
2>/dev/null
then

    MACHINESET_COUNT=$(jq '.items | length' \
    "${CAPACITY_RAW}/machinesets.json")


    log INFO "MachineSets collected: ${MACHINESET_COUNT}"

else

    log WARN "MachineSets not available"

    echo '{"items":[]}' \
    > "${CAPACITY_RAW}/machinesets.json"

fi



#############################################
# Metrics Server Detection
#############################################

log INFO "Checking Metrics Server"



if oc get --raw \
"/apis/metrics.k8s.io/v1beta1/nodes" \
> "${CAPACITY_JSON}/metrics_server.json" \
2>/dev/null

then

    log INFO "Metrics Server available"

    echo "true" \
    > "${CAPACITY_JSON}/metrics_available.txt"


else

    log INFO "Kubernetes Metrics Server unavailable - using Prometheus/resource requests fallback"

    echo "false" \
    > "${CAPACITY_JSON}/metrics_available.txt"

fi



#############################################
# Prometheus Detection
# In ARO the preferred route is thanos-querier (multi-tenant aware).
# Fall back to prometheus-k8s (standard OpenShift) if not found.
#############################################

log INFO "Checking OpenShift Prometheus / Thanos-Querier"

_prom_found=false

for _prom_route in thanos-querier prometheus-k8s; do
    if oc get route \
        -n openshift-monitoring \
        "${_prom_route}" \
        -o json \
        > "${CAPACITY_JSON}/prometheus_route.json" \
        2>/dev/null; then
        log INFO "Prometheus route found: ${_prom_route}"
        _prom_found=true
        break
    fi
done

if [[ "${_prom_found}" == "true" ]]; then
    echo "true" > "${CAPACITY_JSON}/prometheus_available.txt"
else
    log WARN "Prometheus route not available (tried thanos-querier and prometheus-k8s)"
    echo "false" > "${CAPACITY_JSON}/prometheus_available.txt"
fi



#############################################
# Cluster Utilization via Prometheus
#
# Queries actual CPU/Memory/Filesystem/Network
# usage from the OpenShift built-in Prometheus.
# Falls back to zeros if Prometheus unavailable.
#############################################

log INFO "Collecting cluster utilization metrics"



prom_query()
{
    local QUERY="$1"
    local HOST="$2"
    local TOKEN="$3"

    curl -sk \
        -H "Authorization: Bearer ${TOKEN}" \
        "https://${HOST}/api/v1/query?query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${QUERY}" 2>/dev/null || echo "${QUERY}" | sed 's/ /%20/g;s/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/=/%3D/g;s/!/%21/g;s/,/%2C/g;s|/|%2F|g')" \
        2>/dev/null \
    | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null \
    || echo "0"
}



if [[ "$(cat "${CAPACITY_JSON}/prometheus_available.txt")" == "true" ]]
then

    PROM_HOST=$(jq -r '.spec.host // empty' \
    "${CAPACITY_JSON}/prometheus_route.json" 2>/dev/null)

    PROM_TOKEN=$(oc whoami --show-token 2>/dev/null || echo "")


    if [[ -n "${PROM_HOST}" && -n "${PROM_TOKEN}" ]]
    then

        log INFO "Querying Prometheus: ${PROM_HOST}"


        CPU_USED=$(prom_query \
            'sum(rate(container_cpu_usage_seconds_total{container!="",id=~"/kubepods.*"}[5m]))' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        MEM_USED_BYTES=$(prom_query \
            'sum(container_memory_working_set_bytes{container!="",id=~"/kubepods.*"})' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        POD_COUNT_RUNNING=$(prom_query \
            'sum(kube_pod_status_phase{phase="Running"})' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        FS_TOTAL_BYTES=$(prom_query \
            'sum(node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        FS_AVAIL_BYTES=$(prom_query \
            'sum(node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        NET_RX_BPS=$(prom_query \
            'sum(rate(container_network_receive_bytes_total{namespace!=""}[5m]))' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        NET_TX_BPS=$(prom_query \
            'sum(rate(container_network_transmit_bytes_total{namespace!=""}[5m]))' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        # Actual pod ephemeral storage used (container overlay fs, emptyDir, logs)
        # This is the real disk consumed by pods — distinct from full-node Filesystem above
        EPHEM_POD_BYTES=$(prom_query \
            'sum(container_fs_usage_bytes{container!="",id=~"/kubepods.*"})' \
            "${PROM_HOST}" "${PROM_TOKEN}")


        # Convert bytes → GiB/TiB for display
        MEM_USED_GIB=$(awk  "BEGIN{printf \"%.1f\",${MEM_USED_BYTES}/1073741824}")
        FS_TOTAL_TIB=$(awk  "BEGIN{printf \"%.2f\",${FS_TOTAL_BYTES}/1099511627776}")
        FS_AVAIL_TIB=$(awk  "BEGIN{printf \"%.2f\",${FS_AVAIL_BYTES}/1099511627776}")
        FS_USED_TIB=$(awk   "BEGIN{v=${FS_TOTAL_TIB}-${FS_AVAIL_TIB};printf \"%.2f\",(v<0?0:v)}")
        NET_RX_MBPS=$(awk   "BEGIN{printf \"%.2f\",${NET_RX_BPS}/1048576}")
        NET_TX_MBPS=$(awk   "BEGIN{printf \"%.2f\",${NET_TX_BPS}/1048576}")
        CPU_USED_ROUNDED=$(awk "BEGIN{printf \"%.1f\",${CPU_USED}+0}")
        EPHEM_POD_GIB=$(awk "BEGIN{printf \"%.1f\",${EPHEM_POD_BYTES}/1073741824}")


        cat > "${CAPACITY_JSON}/cluster_utilization.json" <<EOF
{
    "collected_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "source": "prometheus",
    "cpu": {
        "used_cores": ${CPU_USED_ROUNDED},
        "unit": "cores"
    },
    "memory": {
        "used_gib": ${MEM_USED_GIB},
        "unit": "GiB"
    },
    "filesystem": {
        "used_tib":  ${FS_USED_TIB},
        "total_tib": ${FS_TOTAL_TIB},
        "avail_tib": ${FS_AVAIL_TIB},
        "note": "Physical node root filesystem (OS + images + pods)",
        "unit": "TiB"
    },
    "ephemeral_pod_storage": {
        "used_gib": ${EPHEM_POD_GIB},
        "note": "Actual disk used by pod overlay filesystems (container_fs_usage_bytes)",
        "unit": "GiB"
    },
    "network": {
        "rx_mbps": ${NET_RX_MBPS},
        "tx_mbps": ${NET_TX_MBPS},
        "unit": "MBps"
    },
    "pods": {
        "running": ${POD_COUNT_RUNNING}
    }
}
EOF


        log INFO "Cluster utilization collected from Prometheus"


    else

        log WARN "Prometheus token or host unavailable — skipping utilization queries"
        _fallback_pods=$(oc get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') || _fallback_pods=0
        log INFO "Pod count from oc fallback: ${_fallback_pods}"
        echo "{\"source\":\"unavailable\",\"cpu\":{\"used_cores\":0},\"memory\":{\"used_gib\":0},\"filesystem\":{\"used_tib\":0,\"total_tib\":0,\"avail_tib\":0},\"ephemeral_pod_storage\":{\"used_gib\":0},\"network\":{\"rx_mbps\":0,\"tx_mbps\":0},\"pods\":{\"running\":${_fallback_pods}}}" \
        > "${CAPACITY_JSON}/cluster_utilization.json"

    fi


else

    log INFO "Prometheus unavailable — cluster utilization will show request-based data only"
    _fallback_pods=$(oc get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') || _fallback_pods=0
    log INFO "Pod count from oc fallback: ${_fallback_pods}"
    echo "{\"source\":\"unavailable\",\"cpu\":{\"used_cores\":0},\"memory\":{\"used_gib\":0},\"filesystem\":{\"used_tib\":0,\"total_tib\":0,\"avail_tib\":0},\"ephemeral_pod_storage\":{\"used_gib\":0},\"network\":{\"rx_mbps\":0,\"tx_mbps\":0},\"pods\":{\"running\":${_fallback_pods}}}" \
    > "${CAPACITY_JSON}/cluster_utilization.json"

fi



#############################################
# Collect Pods
#############################################

log INFO "Collecting pods"

# --chunk-size keeps the oc process footprint small by paging the API server
# response instead of buffering the full item list in memory at once.
# The output is still a valid JSON list because oc merges chunks into a single object.
# || true makes a possible OOM kill non-fatal — later stages handle a missing/partial file.
oc get pods \
--all-namespaces \
-o json \
--chunk-size=250 \
--request-timeout=120s \
> "${CAPACITY_RAW}/pods.json" 2>&1 || {
    log INFO "WARN: oc get pods returned non-zero — writing empty list and continuing"
    echo '{"items":[]}' > "${CAPACITY_RAW}/pods.json"
}

POD_COUNT=$(jq '.items | length' \
"${CAPACITY_RAW}/pods.json" 2>/dev/null || echo 0)

log INFO "Pods collected: ${POD_COUNT}"



#############################################
# Pod Resource Inventory
#############################################

log INFO "Creating pod resource inventory"



cat > "${CAPACITY_CSV}/pod_resources.csv" <<EOF
namespace,pod,container,cpu_request,memory_request,cpu_limit,memory_limit
EOF



jq -r '

.items[]

|

.metadata.namespace as $ns |

.metadata.name as $pod |

.spec.containers[] |

[

$ns,

$pod,

.metadata.name,

(.resources.requests.cpu // "0"),

(.resources.requests.memory // "0"),

(.resources.limits.cpu // "0"),

(.resources.limits.memory // "0")

]

|

@csv

' \
"${CAPACITY_RAW}/pods.json" \
>> "${CAPACITY_CSV}/pod_resources.csv"



#############################################
# Pod-to-Node Mapping (for dedicated pools)
#############################################

log INFO "Creating pod-to-node mapping"

jq -r '
.items[]
| select(.status.phase == "Running" and .spec.nodeName != null)
| [.metadata.namespace, .spec.nodeName]
| @csv
' \
"${CAPACITY_RAW}/pods.json" \
> "${CAPACITY_RAW}/pod_node_map.csv"



#############################################
# Namespaces
#############################################

log INFO "Creating namespace inventory"



oc get namespaces \
-o json \
> "${CAPACITY_RAW}/namespaces.json"



NAMESPACE_COUNT=$(jq '.items | length' \
"${CAPACITY_RAW}/namespaces.json")



jq -r '

["name"],

(

.items[] | [.metadata.name]

)

| @csv

' \
"${CAPACITY_RAW}/namespaces.json" \
> "${CAPACITY_CSV}/namespace_inventory.csv"





#############################################
# PVC Inventory
#############################################

log INFO "Processing PVC inventory"



oc get pvc \
--all-namespaces \
-o json \
> "${CAPACITY_RAW}/pvcs.json"



PVC_COUNT=$(jq '.items | length' \
"${CAPACITY_RAW}/pvcs.json")



cat > "${CAPACITY_CSV}/pvc_inventory.csv" <<EOF
namespace,pvc,status,capacity,storageclass
EOF



jq -r '

.items[]

|

[

.metadata.namespace,

.metadata.name,

.status.phase,

(.status.capacity.storage // "0"),

(.spec.storageClassName // "default")

]

|

@csv

' \
"${CAPACITY_RAW}/pvcs.json" \
>> "${CAPACITY_CSV}/pvc_inventory.csv"





#############################################
# Storage Classes
#############################################

log INFO "Collect Storage Classes"



oc get storageclass \
-o json \
> "${CAPACITY_RAW}/storageclasses.json"



jq -r '

[

"name",

"provisioner",

"default"

],

(

.items[]

|

[

.metadata.name,

.provisioner,

(

.metadata.annotations[
"storageclass.kubernetes.io/is-default-class"
]

// "false"

)

]

)

| @csv

' \
"${CAPACITY_RAW}/storageclasses.json" \
> "${CAPACITY_CSV}/storageclasses.csv"





#############################################
# Pod Metrics Collection
#############################################

log INFO "Collecting pod metrics"



if [[ "$(cat "${CAPACITY_JSON}/metrics_available.txt")" == "true" ]]
then


oc get podmetrics \
--all-namespaces \
-o json \
--chunk-size=500 \
> "${CAPACITY_RAW}/pod_metrics.json" \
2>/dev/null || true


else


echo '{"items":[]}' \
> "${CAPACITY_RAW}/pod_metrics.json"


fi





#############################################
# Node Metrics Collection
#############################################

log INFO "Collecting node metrics"



if [[ "$(cat "${CAPACITY_JSON}/metrics_available.txt")" == "true" ]]
then


oc get --raw \
"/apis/metrics.k8s.io/v1beta1/nodes" \
> "${CAPACITY_RAW}/node_metrics.json" \
2>/dev/null || true


else


echo '{}' \
> "${CAPACITY_RAW}/node_metrics.json"


fi





#############################################
# Collection Summary
#############################################

log INFO "Creating collection summary"



cat > "${CAPACITY_JSON}/collection_summary.json" <<EOF
{
    "collection_time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "nodes": ${NODE_COUNT},
    "pods": ${POD_COUNT},
    "pvcs": ${PVC_COUNT},
    "namespaces": ${NAMESPACE_COUNT},
    "metrics_server": "$(cat ${CAPACITY_JSON}/metrics_available.txt)",
    "prometheus": "$(cat ${CAPACITY_JSON}/prometheus_available.txt)"
}
EOF




#############################################
# Final Summary
#############################################

log INFO "Collection completed successfully"



echo "

=============================================

 Collection Completed

=============================================

Nodes:

${NODE_COUNT}


Pods:

${POD_COUNT}


PVCs:

${PVC_COUNT}


Namespaces:

${NAMESPACE_COUNT}



Output:

${CAPACITY_OUTPUT}


=============================================

"