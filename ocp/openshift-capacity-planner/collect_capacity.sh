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

# Full shell tracing would expose the bearer token expanded by Prometheus
# calls, so debug mode emits additional status messages without `set -x`.
if [[ "${COLLECT_DEBUG:-false}" == "true" ]]; then
    echo "INFO: COLLECT_DEBUG enabled (sensitive command tracing remains disabled)"
fi


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
"${CAPACITY_RAW}/nodes.json" 2>/dev/null || echo 0)



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
    local CURL_TLS_ARGS=()

    if [[ "${OCP_INSECURE_SKIP_TLS_VERIFY:-true}" == "true" ]]; then
        CURL_TLS_ARGS+=(--insecure)
    elif [[ -n "${OCP_CA_FILE:-}" ]]; then
        CURL_TLS_ARGS+=(--cacert "${OCP_CA_FILE}")
    fi

    curl -sS --connect-timeout 10 --max-time 30 "${CURL_TLS_ARGS[@]}" \
        -H "Authorization: Bearer ${TOKEN}" \
        --get --data-urlencode "query=${QUERY}" \
        "https://${HOST}/api/v1/query" \
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
            'sum(rate(container_cpu_usage_seconds_total{container!="",id=~"/kubepods.*"}[5m]) * on(node) group_left() max by (node) (kube_node_role{role="worker"}))' \
            "${PROM_HOST}" "${PROM_TOKEN}")

        MEM_USED_BYTES=$(prom_query \
            'sum(container_memory_working_set_bytes{container!="",id=~"/kubepods.*"} * on(node) group_left() max by (node) (kube_node_role{role="worker"}))' \
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

        #############################################
        # Per-Namespace Actual Usage via Prometheus
        #
        # FIX: chargeback/tenant-project cards were showing "Metrics
        # unavailable" for every namespace even when the cluster-wide
        # utilization above succeeded. Root cause: per-namespace actual
        # usage was sourced ONLY from `oc get podmetrics` (the
        # metrics.k8s.io / prometheus-adapter API), which is a DIFFERENT,
        # separately-gated API from the Thanos route used above — a
        # cluster can have a working Prometheus/Thanos route with no
        # prometheus-adapter installed at all, which is exactly what
        # metrics_available.txt=false vs. prometheus_available.txt=true
        # indicates when both are compared. Since we already have a
        # confirmed-working Prometheus connection right here, query it
        # directly, grouped by namespace, as a same-source alternative
        # analyze_capacity.sh can fall back to.
        #############################################

        prom_query_vector()
        {
            local QUERY="$1"
            local QUERY_NAME="${2:-vector-query}"
            local ALLOW_EMPTY="${3:-false}"
            local CURL_TLS_ARGS=()
            local RESPONSE_FILE
            local PARSED_FILE
            local HTTP_CODE
            local ERROR_DETAIL
            local RESULT_COUNT
            local PARSED_COUNT
            local ATTEMPT
            if [[ "${OCP_INSECURE_SKIP_TLS_VERIFY:-true}" == "true" ]]; then
                CURL_TLS_ARGS+=(--insecure)
            elif [[ -n "${OCP_CA_FILE:-}" ]]; then
                CURL_TLS_ARGS+=(--cacert "${OCP_CA_FILE}")
            fi
            RESPONSE_FILE=$(mktemp)
            PARSED_FILE=$(mktemp)

            for ATTEMPT in 1 2; do
                HTTP_CODE=$(curl -sS --connect-timeout 10 --max-time 30 \
                    "${CURL_TLS_ARGS[@]}" \
                    -o "${RESPONSE_FILE}" -w '%{http_code}' \
                    -H "Authorization: Bearer ${PROM_TOKEN}" \
                    --get --data-urlencode "query=${QUERY}" \
                    "https://${PROM_HOST}/api/v1/query" 2>/dev/null || echo '000')

                if [[ "${HTTP_CODE}" == "200" ]] \
                    && jq -e '.status == "success" and (.data.result | type == "array")' \
                        "${RESPONSE_FILE}" >/dev/null 2>&1; then
                    RESULT_COUNT=$(jq '.data.result | length' "${RESPONSE_FILE}" 2>/dev/null || echo 0)
                    if [[ "${RESULT_COUNT}" -gt 0 || "${ALLOW_EMPTY}" == "true" ]]; then
                        jq -c '[.data.result[]? | {
                            namespace: (.metric.namespace // "unknown"),
                            pod: (.metric.pod // null),
                            persistentvolumeclaim: (.metric.persistentvolumeclaim // null),
                            value: ((.value[1] // "0") | tonumber? // 0)
                        }]' "${RESPONSE_FILE}" > "${PARSED_FILE}" 2>/dev/null \
                        || echo '[]' > "${PARSED_FILE}"
                        PARSED_COUNT=$(jq 'length' "${PARSED_FILE}" 2>/dev/null || echo 0)
                        log INFO "Prometheus ${QUERY_NAME}: ${RESULT_COUNT} source series, ${PARSED_COUNT} parsed rows" >&2
                        cat "${PARSED_FILE}"
                        rm -f "${RESPONSE_FILE}" "${PARSED_FILE}"
                        return 0
                    fi

                    log WARN "Prometheus ${QUERY_NAME} attempt ${ATTEMPT}/2 returned a valid empty vector" >&2
                    continue
                fi

                ERROR_DETAIL=$(jq -r '.error // .errorType // "invalid or empty response"' \
                    "${RESPONSE_FILE}" 2>/dev/null || echo 'request failed')
                log WARN "Prometheus ${QUERY_NAME} attempt ${ATTEMPT}/2 failed: HTTP ${HTTP_CODE}, ${ERROR_DETAIL}" >&2
            done

            rm -f "${RESPONSE_FILE}" "${PARSED_FILE}"
            echo '[]'
        }

        _ns_cpu_json=$(prom_query_vector \
            'sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace!="",container!="",id=~"/kubepods.*"}[5m]) * on(node) group_left() max by (node) (kube_node_role{role="worker"}))' \
            'namespace CPU')
        _ns_mem_json=$(prom_query_vector \
            'sum by (namespace) (container_memory_working_set_bytes{namespace!="",container!="",id=~"/kubepods.*"} * on(node) group_left() max by (node) (kube_node_role{role="worker"}))' \
            'namespace memory')

        if [[ "$(jq 'length' <<< "${_ns_cpu_json:-[]}" 2>/dev/null || echo 0)" == "0" ]]; then
            log WARN "Raw namespace CPU query returned no rows; trying the OpenShift recording rule"
            _ns_cpu_json=$(prom_query_vector \
                'sum by (namespace) (node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate{namespace!="",container!=""})' \
                'namespace CPU recording rule')
        fi
        if [[ "$(jq 'length' <<< "${_ns_mem_json:-[]}" 2>/dev/null || echo 0)" == "0" ]]; then
            log WARN "Worker-scoped namespace memory query returned no rows; trying unscoped cAdvisor metrics"
            _ns_mem_json=$(prom_query_vector \
                'sum by (namespace) (container_memory_working_set_bytes{namespace!="",container!=""})' \
                'namespace memory unscoped')
        fi

        _pod_cpu_json=$(prom_query_vector \
            'sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{namespace!="",pod!="",container!="",id=~"/kubepods.*"}[5m]) * on(node) group_left() max by (node) (kube_node_role{role="worker"}))' \
            'pod CPU')
        _pod_mem_json=$(prom_query_vector \
            'sum by (namespace, pod) (container_memory_working_set_bytes{namespace!="",pod!="",container!="",id=~"/kubepods.*"} * on(node) group_left() max by (node) (kube_node_role{role="worker"}))' \
            'pod memory')

        if [[ "$(jq 'length' <<< "${_pod_cpu_json:-[]}" 2>/dev/null || echo 0)" == "0" ]]; then
            log WARN "Worker-scoped pod CPU query returned no rows; trying unscoped cAdvisor metrics"
            _pod_cpu_json=$(prom_query_vector \
                'sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{namespace!="",pod!="",container!=""}[5m]))' \
                'pod CPU unscoped')
        fi
        if [[ "$(jq 'length' <<< "${_pod_mem_json:-[]}" 2>/dev/null || echo 0)" == "0" ]]; then
            log WARN "Worker-scoped pod memory query returned no rows; trying unscoped cAdvisor metrics"
            _pod_mem_json=$(prom_query_vector \
                'sum by (namespace, pod) (container_memory_working_set_bytes{namespace!="",pod!="",container!=""})' \
                'pod memory unscoped')
        fi

        printf '%s\n' "${_pod_cpu_json:-[]}" > "${CAPACITY_JSON}/prometheus_pod_cpu_vector.json"
        printf '%s\n' "${_pod_mem_json:-[]}" > "${CAPACITY_JSON}/prometheus_pod_memory_vector.json"

        jq -n \
            --slurpfile cpu "${CAPACITY_JSON}/prometheus_pod_cpu_vector.json" \
            --slurpfile mem "${CAPACITY_JSON}/prometheus_pod_memory_vector.json" '
            (reduce ($cpu[0][] | select(.pod != null) |
                    {key: (.namespace + "/" + .pod), value: {
                        namespace: .namespace, pod: .pod, cpu_used_cores: .value
                    }}) as $r
                ({}; .[$r.key] = $r.value)) as $cpu_map |
            reduce ($mem[0][] | select(.pod != null) |
                    {key: (.namespace + "/" + .pod), value: {
                        namespace: .namespace, pod: .pod,
                        memory_used_gib: (.value / 1073741824)
                    }}) as $r
                ($cpu_map; .[$r.key] = ((.[$r.key] // {}) + $r.value)) |
            [.[] | select(.namespace != null and .pod != null) | {
                namespace,
                pod,
                cpu_used_cores: (.cpu_used_cores // 0),
                memory_used_gib: (.memory_used_gib // 0)
            }]
        ' > "${CAPACITY_JSON}/pod_actual_usage_prom.json" 2>/dev/null \
        || echo '[]' > "${CAPACITY_JSON}/pod_actual_usage_prom.json"

        log INFO "Per-pod Prometheus usage: $(jq 'length' "${CAPACITY_JSON}/pod_actual_usage_prom.json" 2>/dev/null || echo 0) pods"

        _pvc_used_json=$(prom_query_vector 'max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{persistentvolumeclaim!=""})' 'PVC used bytes' 'true')
        _pvc_capacity_json=$(prom_query_vector 'max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{persistentvolumeclaim!=""})' 'PVC capacity bytes' 'true')

        printf '%s\n' "${_pvc_used_json:-[]}" > "${CAPACITY_JSON}/prometheus_pvc_used_vector.json"
        printf '%s\n' "${_pvc_capacity_json:-[]}" > "${CAPACITY_JSON}/prometheus_pvc_capacity_vector.json"

        jq -n \
            --slurpfile used "${CAPACITY_JSON}/prometheus_pvc_used_vector.json" \
            --slurpfile capacity "${CAPACITY_JSON}/prometheus_pvc_capacity_vector.json" '
            (reduce ($used[0][] | select(.persistentvolumeclaim != null) |
                    {key: (.namespace + "/" + .persistentvolumeclaim), value: {used_bytes: .value}}) as $r
                ({}; .[$r.key] = $r.value)) as $step1 |
            reduce ($capacity[0][] | select(.persistentvolumeclaim != null) |
                    {key: (.namespace + "/" + .persistentvolumeclaim), value: .value}) as $r
                ($step1; .[$r.key] = ((.[$r.key] // {}) + {capacity_bytes: $r.value}))
        ' > "${CAPACITY_JSON}/pvc_volume_usage.json" 2>/dev/null \
        || echo '{}' > "${CAPACITY_JSON}/pvc_volume_usage.json"

        log INFO "Prometheus PVC filesystem usage: $(jq 'length' "${CAPACITY_JSON}/pvc_volume_usage.json" 2>/dev/null || echo 0) PVCs"

        printf '%s\n' "${_ns_cpu_json:-[]}" > "${CAPACITY_JSON}/prometheus_namespace_cpu_vector.json"
        printf '%s\n' "${_ns_mem_json:-[]}" > "${CAPACITY_JSON}/prometheus_namespace_memory_vector.json"

        jq -n \
            --slurpfile cpu "${CAPACITY_JSON}/prometheus_namespace_cpu_vector.json" \
            --slurpfile mem "${CAPACITY_JSON}/prometheus_namespace_memory_vector.json" '
            (reduce ($cpu[0][] | {ns: .namespace, k: "cpu_cores", v: .value}) as $r
                ({}; .[$r.ns] = ((.[$r.ns] // {}) + {($r.k): $r.v}))) as $step1 |
            reduce ($mem[0][] | {ns: .namespace, k: "mem_gb", v: (.value / 1073741824)}) as $r
                ($step1; .[$r.ns] = ((.[$r.ns] // {}) + {($r.k): $r.v}))
        ' > "${CAPACITY_JSON}/ns_actual_usage_prom.json" 2>/dev/null \
        || echo '{}' > "${CAPACITY_JSON}/ns_actual_usage_prom.json"

        _prom_ns_count=$(jq 'length' "${CAPACITY_JSON}/ns_actual_usage_prom.json" 2>/dev/null || echo 0)
        log INFO "Per-namespace Prometheus usage: ${_prom_ns_count} namespaces"

        # If Prometheus returned zero namespaces (e.g. ARO cgroup path differs),
        # fall back to oc adm top pods — works on any OpenShift cluster,
        # doesn't require Prometheus/Thanos. Approach borrowed from
        # capacity_report_auto_html_v2.sh which uses this as primary source.
        if [[ "${_prom_ns_count}" == "0" ]]; then
            log INFO "Prometheus per-namespace query returned 0 rows — falling back to oc adm top pods"
            # oc adm top pods --all-namespaces output:
            #   NAMESPACE  NAME  CPU(cores)  MEMORY(bytes)
            # CPU can be: 250m, 1 (no suffix = cores), 0 (zero)
            # Memory can be: 512Mi, 2Gi, 1024Ki, 100 (bytes, rare)
            oc adm top pods --all-namespaces --no-headers 2>/dev/null \
            | awk '
            {
                ns=$1; cpu=$3; mem=$4
                # CPU: strip unit, convert to cores
                if (cpu ~ /m$/) { sub(/m$/,"",cpu); cpu_cores=cpu/1000 }
                else if (cpu+0 > 0) { cpu_cores=cpu+0 }
                else { cpu_cores=0 }
                # Memory: strip unit, convert to GiB
                if (mem ~ /Gi$/) { sub(/Gi$/,"",mem); mem_gib=mem+0 }
                else if (mem ~ /Mi$/) { sub(/Mi$/,"",mem); mem_gib=mem/1024 }
                else if (mem ~ /Ki$/) { sub(/Ki$/,"",mem); mem_gib=mem/1048576 }
                else if (mem+0 > 0) { mem_gib=mem/1073741824 }
                else { mem_gib=0 }
                sum_cpu[ns] += cpu_cores
                sum_mem[ns] += mem_gib
            }
            END {
                for (ns in sum_cpu)
                    if (ns != "" && ns != "NAMESPACE")
                        printf "{\"ns\":\"%s\",\"cpu\":%.4f,\"mem\":%.4f}\n", ns, sum_cpu[ns], sum_mem[ns]
            }' \
            | jq -Rs '
            [ split("\n")[] | select(length>0) | fromjson ] |
            reduce .[] as $r
                ({}; .[$r.ns] = {cpu_cores: $r.cpu, mem_gb: $r.mem})
            ' > "${CAPACITY_JSON}/ns_actual_usage_prom.json" 2>/dev/null \
            || echo '{}' > "${CAPACITY_JSON}/ns_actual_usage_prom.json"
            log INFO "oc adm top fallback: $(jq 'length' "${CAPACITY_JSON}/ns_actual_usage_prom.json" 2>/dev/null || echo 0) namespaces"
        fi

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
    "source": "prometheus-worker-nodes",
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
        echo '{}' > "${CAPACITY_JSON}/ns_actual_usage_prom.json"
        echo '{}' > "${CAPACITY_JSON}/pvc_volume_usage.json"

    fi


else

    log INFO "Prometheus unavailable — cluster utilization will show request-based data only"
    _fallback_pods=$(oc get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ') || _fallback_pods=0
    log INFO "Pod count from oc fallback: ${_fallback_pods}"
    echo "{\"source\":\"unavailable\",\"cpu\":{\"used_cores\":0},\"memory\":{\"used_gib\":0},\"filesystem\":{\"used_tib\":0,\"total_tib\":0,\"avail_tib\":0},\"ephemeral_pod_storage\":{\"used_gib\":0},\"network\":{\"rx_mbps\":0,\"tx_mbps\":0},\"pods\":{\"running\":${_fallback_pods}}}" \
    > "${CAPACITY_JSON}/cluster_utilization.json"
    echo '{}' > "${CAPACITY_JSON}/ns_actual_usage_prom.json"
    echo '{}' > "${CAPACITY_JSON}/pvc_volume_usage.json"

fi



#############################################
# Collect Pods
#############################################

log INFO "Collecting pods"

# --chunk-size keeps the oc process footprint small by paging the API server
# response instead of buffering the full item list in memory at once.
# The output is still a valid JSON list because oc merges chunks into a single object.
if ! oc get pods \
--all-namespaces \
-o json \
--chunk-size=250 \
--request-timeout=120s \
> "${CAPACITY_RAW}/pods.json" \
2>"${CAPACITY_RAW}/pods_stderr.txt"; then
    log ERROR "Pod collection failed: $(head -3 "${CAPACITY_RAW}/pods_stderr.txt" 2>/dev/null)"
    exit 1
fi
if ! jq -e '.items | arrays' "${CAPACITY_RAW}/pods.json" > /dev/null 2>&1; then
    log ERROR "pods.json is not valid JSON — stderr: $(cat "${CAPACITY_RAW}/pods_stderr.txt" 2>/dev/null | head -3)"
    exit 1
fi

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

# Includes pod name (not just namespace+node) so analyze_capacity.sh can join
# this against per-pod CPU/memory requests and attribute actual resource
# demand to the specific pool a pod landed on — not just a pod count.
jq -r '
.items[]
| select(.status.phase == "Running" and .spec.nodeName != null)
| [.metadata.namespace, .metadata.name, .spec.nodeName]
| @csv
' \
"${CAPACITY_RAW}/pods.json" \
> "${CAPACITY_RAW}/pod_node_map.csv"



#############################################
# Pod Effective Requests
# (Red Hat best practice — Kubernetes scheduling semantics)
#
# Effective pod request = max(sum(app containers), max(init containers))
# for each resource. A heavy init container counts even though it
# does not run alongside app containers.
#
# Source: capacity_report_auto_html_v2.sh (uploaded reference script)
# Ref: https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
#      #resource-sharing-between-init-containers-and-app-containers
#############################################

log INFO "Computing effective pod requests (app containers vs init containers)"

jq -r '
def cpu_cores:
  if . == null or . == "" then 0
  elif test("m$") then (sub("m$";"") | tonumber) / 1000
  else (tonumber? // 0) end;

def mem_gib:
  if . == null or . == "" then 0
  elif test("Ki$") then (sub("Ki$";"") | tonumber) / 1048576
  elif test("Mi$") then (sub("Mi$";"") | tonumber) / 1024
  elif test("Gi$") then (sub("Gi$";"") | tonumber)
  elif test("Ti$") then (sub("Ti$";"") | tonumber) * 1024
  else (tonumber? // 0) / 1073741824 end;

.items[] |
select(.status.phase == "Running" or .status.phase == "Pending") |
(.spec.nodeName // "") as $node |

# App containers: sum of requests
([ (.spec.containers // [])[] |
   .resources.requests.cpu // "0" | cpu_cores ] | add // 0) as $app_cpu |
([ (.spec.containers // [])[] |
   .resources.requests.memory // "0" | mem_gib ] | add // 0) as $app_mem |

# Init containers: max of individual requests (they run sequentially)
([ (.spec.initContainers // [])[] |
   .resources.requests.cpu // "0" | cpu_cores ] | max // 0) as $init_cpu |
([ (.spec.initContainers // [])[] |
   .resources.requests.memory // "0" | mem_gib ] | max // 0) as $init_mem |

# Effective = max(app, init) — what the scheduler actually reserves
([$app_cpu, $init_cpu] | max) as $eff_cpu |
([$app_mem, $init_mem] | max) as $eff_mem |

[
  .metadata.namespace,
  .metadata.name,
  $node,
  $eff_cpu,
  $eff_mem,
  ((.metadata.ownerReferences // []) | map(select(.controller==true)) |
   if length>0 then (.[0].kind + "/" + .[0].name) else "standalone" end)
] | @csv
' \
"${CAPACITY_RAW}/pods.json" \
> "${CAPACITY_RAW}/pod_requests_raw.csv" 2>/dev/null || true

log INFO "Effective pod requests: $(wc -l < "${CAPACITY_RAW}/pod_requests_raw.csv" 2>/dev/null || echo 0) pods"



#############################################
# Namespaces
#############################################

log INFO "Creating namespace inventory"



oc get namespaces \
-o json \
> "${CAPACITY_RAW}/namespaces.json"



NAMESPACE_COUNT=$(jq '.items | length' \
"${CAPACITY_RAW}/namespaces.json" 2>/dev/null || echo 0)



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
--chunk-size=250 \
--request-timeout=120s \
> "${CAPACITY_RAW}/pvcs.json" \
2>"${CAPACITY_RAW}/pvcs_stderr.txt" || {
    log ERROR "oc get pvc failed — stderr: $(cat "${CAPACITY_RAW}/pvcs_stderr.txt" 2>/dev/null | head -5)"
    echo '{"items":[]}' > "${CAPACITY_RAW}/pvcs.json"
}

# Validate the JSON is not corrupted (e.g. by warnings mixed into stdout)
if ! jq -e '.items' "${CAPACITY_RAW}/pvcs.json" > /dev/null 2>&1; then
    log ERROR "pvcs.json is not valid JSON — likely stderr mixed in. Writing empty list."
    echo '{"items":[]}' > "${CAPACITY_RAW}/pvcs.json"
fi



PVC_COUNT=$(jq '.items | length' \
"${CAPACITY_RAW}/pvcs.json" 2>/dev/null || echo 0)



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

# Cluster-scoped PV inventory is required to distinguish PVC state from the
# underlying retained storage asset. Missing permission degrades to an empty
# inventory without affecting the core capacity report.
oc get persistentvolumes -o json --request-timeout=120s \
> "${CAPACITY_RAW}/pvs.json" 2>"${CAPACITY_RAW}/pvs_stderr.txt" || {
    log WARN "PersistentVolume inventory unavailable"
    echo '{"items":[]}' > "${CAPACITY_RAW}/pvs.json"
}

oc get volumeattachments.storage.k8s.io -o json --request-timeout=120s \
> "${CAPACITY_RAW}/volumeattachments.json" 2>/dev/null || echo '{"items":[]}' > "${CAPACITY_RAW}/volumeattachments.json"





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
# Desired Replica Collection
# (Red Hat practice #6: desired replicas = primary planning signal)
#
# Running pods tell you CURRENT pressure.
# Desired replicas (spec.replicas × template requests) tell you what
# the cluster MUST support if all workloads are healthy — the correct
# basis for capacity planning decisions.
#
# Produces: desired_capacity.json  (per-namespace desired CPU/mem)
#           desired_vs_running.csv (gap between desired and running)
#############################################

log INFO "Collecting desired replica capacity (Deployments + StatefulSets)"

# Collect Deployments
oc get deployments --all-namespaces -o json \
    --chunk-size=250 --request-timeout=120s \
> "${CAPACITY_RAW}/deployments.json" 2>/dev/null || echo '{"items":[]}' > "${CAPACITY_RAW}/deployments.json"

# Collect StatefulSets
oc get statefulsets --all-namespaces -o json \
    --chunk-size=250 --request-timeout=120s \
> "${CAPACITY_RAW}/statefulsets.json" 2>/dev/null || echo '{"items":[]}' > "${CAPACITY_RAW}/statefulsets.json"

# ReplicaSets connect Deployment-owned pods back to their controller. Pods do
# not normally reference Deployments directly.
oc get replicasets --all-namespaces -o json \
    --chunk-size=250 --request-timeout=120s \
> "${CAPACITY_RAW}/replicasets.json" 2>/dev/null || echo '{"items":[]}' > "${CAPACITY_RAW}/replicasets.json"

# Scheduled workloads may reserve PVCs even when no pod is currently active.
oc get cronjobs --all-namespaces -o json \
    --chunk-size=250 --request-timeout=120s \
> "${CAPACITY_RAW}/cronjobs.json" 2>/dev/null || echo '{"items":[]}' > "${CAPACITY_RAW}/cronjobs.json"

oc get jobs --all-namespaces -o json \
    --chunk-size=250 --request-timeout=120s \
> "${CAPACITY_RAW}/jobs.json" 2>/dev/null || echo '{"items":[]}' > "${CAPACITY_RAW}/jobs.json"

# Compute desired CPU/mem per namespace:
# desired_cpu = spec.replicas × sum(container cpu requests in template)
# desired_mem = spec.replicas × sum(container mem requests in template)
jq -rs '
def cpu_to_cores(v):
  if v == null or v == "0" then 0
  elif (v | test("m$")) then ((v[:-1] | tonumber) / 1000)
  else (v | tonumber? // 0) end;

def mem_to_gib(v):
  if v == null or v == "0" then 0
  elif (v | test("Ki$")) then ((v[:-2] | tonumber) / 1048576)
  elif (v | test("Mi$")) then ((v[:-2] | tonumber) / 1024)
  elif (v | test("Gi$")) then (v[:-2] | tonumber)
  elif (v | test("Ti$")) then ((v[:-2] | tonumber) * 1024)
  else 0 end;

[ .[].items[] |
  {
    namespace: .metadata.namespace,
    name:      .metadata.name,
    kind:      .kind,
    replicas:  (.spec.replicas // 1),
        toleration_keys: ([.spec.template.spec.tolerations[]?.key // empty] | unique),
        node_selector_keys: ((.spec.template.spec.nodeSelector // {}) | keys),
        affinity_keys: ([
            .spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?.key
            // empty
        ] | unique),
    cpu_per_replica: ([
      .spec.template.spec.containers[]?.resources.requests.cpu? // "0"
    ] | map(cpu_to_cores(.)) | add // 0),
    mem_per_replica: ([
      .spec.template.spec.containers[]?.resources.requests.memory? // "0"
    ] | map(mem_to_gib(.)) | add // 0)
  } |
  . + {
    desired_cpu: (.replicas * .cpu_per_replica),
    desired_mem: (.replicas * .mem_per_replica)
  }
] |
group_by(.namespace) |
map({
  namespace: .[0].namespace,
  desired_cpu_cores:  (map(.desired_cpu) | add // 0 | (. * 1000 | round) / 1000),
  desired_mem_gib:    (map(.desired_mem) | add // 0 | (. * 100 | round) / 100),
  workload_count:     length,
    workloads: map({name, kind, replicas, cpu_per_replica, mem_per_replica, desired_cpu, desired_mem, toleration_keys, node_selector_keys, affinity_keys})
}) |
{
  generated: now | todate,
  note: "Desired = spec.replicas × template requests. Compare against running_requested (from namespace_usage) to find scheduling gaps and rightsizing opportunities.",
  namespaces: .
}
' "${CAPACITY_RAW}/deployments.json" "${CAPACITY_RAW}/statefulsets.json" \
> "${CAPACITY_JSON}/desired_capacity.json" 2>/dev/null \
|| echo '{"namespaces":[]}' > "${CAPACITY_JSON}/desired_capacity.json"

# Produce CSV for Excel (matching the spirit of the capacity_report_auto_html_v2.sh approach)
echo "namespace,desired_cpu_cores,desired_mem_gib,workload_count" \
> "${CAPACITY_CSV}/desired_capacity_by_namespace.csv"
jq -r '.namespaces[] | [.namespace, .desired_cpu_cores, .desired_mem_gib, .workload_count] | @csv' \
"${CAPACITY_JSON}/desired_capacity.json" \
>> "${CAPACITY_CSV}/desired_capacity_by_namespace.csv" 2>/dev/null || true

DESIRED_NS_COUNT=$(jq '.namespaces | length' "${CAPACITY_JSON}/desired_capacity.json" 2>/dev/null || echo 0)
log INFO "Desired capacity: ${DESIRED_NS_COUNT} namespaces with workloads"

#############################################
# Storage Planning and Stale Inventory
#############################################

log INFO "Building storage planning and stale-resource inventory"

jq -n \
    --slurpfile pvcs "${CAPACITY_RAW}/pvcs.json" \
    --slurpfile pvs "${CAPACITY_RAW}/pvs.json" \
    --slurpfile pods "${CAPACITY_RAW}/pods.json" \
    --slurpfile deployments "${CAPACITY_RAW}/deployments.json" \
    --slurpfile statefulsets "${CAPACITY_RAW}/statefulsets.json" \
    --slurpfile cronjobs "${CAPACITY_RAW}/cronjobs.json" \
    --slurpfile jobs "${CAPACITY_RAW}/jobs.json" \
    --slurpfile volumeattachments "${CAPACITY_RAW}/volumeattachments.json" \
    --slurpfile volume_usage "${CAPACITY_JSON}/pvc_volume_usage.json" '
    def age_days($timestamp):
        if ($timestamp // "") == "" then 0
        else (((now - ($timestamp | fromdateiso8601)) / 86400) | floor) end;
    def capacity_gib:
        if . == null or . == "" then 0
        elif test("Ki$") then (sub("Ki$"; "") | tonumber) / 1048576
        elif test("Mi$") then (sub("Mi$"; "") | tonumber) / 1024
        elif test("Gi$") then (sub("Gi$"; "") | tonumber)
        elif test("Ti$") then (sub("Ti$"; "") | tonumber) * 1024
        else (tonumber? // 0) / 1073741824 end;

    [($pods[0].items // [])[] |
        select(.status.phase == "Running" or .status.phase == "Pending") |
        .metadata.namespace as $namespace |
        (.spec.volumes // [])[]? |
        select(.persistentVolumeClaim.claimName != null) |
        {key: ($namespace + "/" + .persistentVolumeClaim.claimName), pod: .metadata.name}
    ] | group_by(.key) | map({key: .[0].key, value: map(.pod) | unique}) | from_entries as $pvc_refs |

     ([($deployments[0].items // [])[] |
          . as $controller |
          ($controller.spec.template.spec.volumes // [])[]? |
          select(.persistentVolumeClaim.claimName != null) |
          {key: ($controller.metadata.namespace + "/" + .persistentVolumeClaim.claimName), controller: ("Deployment/" + $controller.metadata.name)}
      ] +
      [($statefulsets[0].items // [])[] |
          . as $controller |
          ($controller.spec.template.spec.volumes // [])[]? |
          select(.persistentVolumeClaim.claimName != null) |
          {key: ($controller.metadata.namespace + "/" + .persistentVolumeClaim.claimName), controller: ("StatefulSet/" + $controller.metadata.name)}
      ] +
      [($cronjobs[0].items // [])[] |
          . as $controller |
          ($controller.spec.jobTemplate.spec.template.spec.volumes // [])[]? |
          select(.persistentVolumeClaim.claimName != null) |
          {key: ($controller.metadata.namespace + "/" + .persistentVolumeClaim.claimName), controller: ("CronJob/" + $controller.metadata.name)}
         ] +
         [($jobs[0].items // [])[] |
                . as $controller |
                ($controller.spec.template.spec.volumes // [])[]? |
                select(.persistentVolumeClaim.claimName != null) |
                {key: ($controller.metadata.namespace + "/" + .persistentVolumeClaim.claimName), controller: ("Job/" + $controller.metadata.name)}
      ]) |
     group_by(.key) | map({key: .[0].key, value: map(.controller) | unique}) | from_entries as $direct_controller_refs |

        [($volumeattachments[0].items // [])[] |
            select(.status.attached == true and .spec.source.persistentVolumeName != null) |
            .spec.source.persistentVolumeName] | unique as $attached_pvs |

    [($pvcs[0].items // [])[] |
          . as $pvc |
        (.metadata.namespace + "/" + .metadata.name) as $key |
        (.status.capacity.storage // .spec.resources.requests.storage // "0") as $capacity |
        ($volume_usage[0][$key] // {}) as $usage |
                (($direct_controller_refs[$key] // []) +
                    [($pvc.metadata.ownerReferences // [])[]? | (.kind + "/" + .name)] +
             [($statefulsets[0].items // [])[] |
                . as $controller |
                ($controller.spec.volumeClaimTemplates // [])[]? |
                 . as $claim |
                select($pvc.metadata.namespace == $controller.metadata.namespace and
                     ($pvc.metadata.name | startswith($claim.metadata.name + "-" + $controller.metadata.name + "-"))) |
                "StatefulSet/" + $controller.metadata.name
             ] | unique) as $controller_refs |
        {
            namespace: .metadata.namespace,
            name: .metadata.name,
            status: (.status.phase // "Unknown"),
            storageclass: (.spec.storageClassName // "default"),
            volume_name: (.spec.volumeName // ""),
            capacity_gib: ($capacity | capacity_gib),
            used_gib: (($usage.used_bytes // 0) / 1073741824),
            actual_capacity_gib: (($usage.capacity_bytes // 0) / 1073741824),
            used_percent: (if ($usage.capacity_bytes // 0) > 0
                       then (($usage.used_bytes // 0) / $usage.capacity_bytes * 100)
                       else null end),
            age_days: age_days(.metadata.creationTimestamp),
            pod_reference_count: (($pvc_refs[$key] // []) | length),
            referencing_pods: ($pvc_refs[$key] // []),
            controller_reference_count: ($controller_refs | length),
            referencing_controllers: $controller_refs,
            volume_attached: (($attached_pvs | index($pvc.spec.volumeName // "")) != null),
            candidate_reason: (
                if (.status.phase // "Unknown") != "Bound" then "PVC_" + (.status.phase // "UNKNOWN" | ascii_upcase)
                elif ($usage.capacity_bytes // 0) > 0 and (($usage.used_bytes // 0) / $usage.capacity_bytes * 100) >= 85 then "UTILIZATION_85_PERCENT"
                elif (($pvc_refs[$key] // []) | length) > 0 then "ACTIVE_POD_MOUNT"
                elif (($attached_pvs | index($pvc.spec.volumeName // "")) != null) then "VOLUME_ATTACHED"
                elif ($controller_refs | length) > 0 then "CONTROLLER_RESERVED"
                else "REVIEW_NO_ACTIVE_WORKLOAD_REFERENCE" end
            )
        }
    ] as $pvc_inventory |

    [($pvs[0].items // [])[] |
        (.spec.capacity.storage // "0") as $capacity |
        {
            name: .metadata.name,
            status: (.status.phase // "Unknown"),
            storageclass: (.spec.storageClassName // "default"),
            reclaim_policy: (.spec.persistentVolumeReclaimPolicy // "Unknown"),
            capacity_gib: ($capacity | capacity_gib),
            claim_namespace: (.spec.claimRef.namespace // ""),
            claim_name: (.spec.claimRef.name // ""),
            age_days: age_days(.metadata.creationTimestamp),
            candidate_reason: (
                if (.status.phase // "Unknown") == "Released" then "RELEASED_PV"
                elif (.status.phase // "Unknown") == "Failed" then "FAILED_PV"
                elif (.status.phase // "Unknown") == "Available" and age_days(.metadata.creationTimestamp) >= 30 then "AVAILABLE_30_DAYS"
                else "ACTIVE" end
            )
        }
    ] as $pv_inventory |

    [($deployments[0].items // [])[], ($statefulsets[0].items // [])[] |
        select((.spec.replicas // 1) == 0) |
        {
            namespace: .metadata.namespace,
            kind: .kind,
            name: .metadata.name,
            replicas: 0,
            age_days: age_days(.metadata.creationTimestamp),
            candidate_reason: "ZERO_REPLICAS"
        }
    ] as $zero_replicas |

    [($pods[0].items // [])[] |
        select((.status.phase == "Succeeded" or .status.phase == "Failed") and age_days(.metadata.creationTimestamp) >= 7) |
        {
            namespace: .metadata.namespace,
            name: .metadata.name,
            phase: .status.phase,
            age_days: age_days(.metadata.creationTimestamp),
            owner: ((.metadata.ownerReferences // []) | map(select(.controller == true)) | first // {} |
                      if .kind then (.kind + "/" + .name) else "standalone" end),
            candidate_reason: "TERMINAL_POD_7_DAYS"
        }
    ] as $terminal_pods |

    {
        generated: (now | todate),
        thresholds: {available_pv_days: 30, terminal_pod_days: 7},
        note: "Candidates require owner and retention-policy review before deletion.",
        summary: {
            total_pvcs: ($pvc_inventory | length),
            provisioned_gib: ($pvc_inventory | map(.capacity_gib) | add // 0),
            used_gib: ($pvc_inventory | map(.used_gib) | add // 0),
            pvc_usage_metrics_count: ($pvc_inventory | map(select(.used_percent != null)) | length),
            high_utilization_pvcs: ($pvc_inventory | map(select(.candidate_reason == "UTILIZATION_85_PERCENT")) | length),
            actively_mounted_pvcs: ($pvc_inventory | map(select(.candidate_reason == "ACTIVE_POD_MOUNT" or .candidate_reason == "VOLUME_ATTACHED" or .candidate_reason == "UTILIZATION_85_PERCENT")) | length),
            controller_reserved_pvcs: ($pvc_inventory | map(select(.candidate_reason == "CONTROLLER_RESERVED")) | length),
            controller_reserved_gib: ($pvc_inventory | map(select(.candidate_reason == "CONTROLLER_RESERVED") | .capacity_gib) | add // 0),
            unreferenced_review_pvcs: ($pvc_inventory | map(select(.candidate_reason == "REVIEW_NO_ACTIVE_WORKLOAD_REFERENCE")) | length),
            unreferenced_review_gib: ($pvc_inventory | map(select(.candidate_reason == "REVIEW_NO_ACTIVE_WORKLOAD_REFERENCE") | .capacity_gib) | add // 0),
            non_bound_pvcs: ($pvc_inventory | map(select(.status != "Bound")) | length),
            pv_candidates: ($pv_inventory | map(select(.candidate_reason != "ACTIVE")) | length),
            zero_replica_controllers: ($zero_replicas | length),
            old_terminal_pods: ($terminal_pods | length)
        },
        pvc_inventory: $pvc_inventory,
        pv_inventory: $pv_inventory,
        zero_replica_controllers: $zero_replicas,
        old_terminal_pods: $terminal_pods
    }
' > "${CAPACITY_JSON}/storage_planning.json"

log INFO "Storage planning inventory: ${CAPACITY_JSON}/storage_planning.json"

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
# Node Metrics — oc adm top nodes
# (Red Hat practice #7: usage vs Requests for rightsizing)
#
# PRIMARY:  oc adm top nodes — works on any OpenShift cluster with
#           metrics-server. Produces 14_node_metrics.csv matching the
#           format from capacity_report_auto_html_v2.sh.
# FALLBACK: metrics.k8s.io raw API — used when oc adm top fails.
# Purpose:  Rightsizing signal: compare CPU/Mem Usage against Requests
#           to identify over-provisioned (Requests >> Usage) or
#           under-provisioned (Usage >> Requests) namespaces/pods.
#############################################

log INFO "Collecting node metrics (oc adm top nodes)"

NODE_METRICS_CSV="${CAPACITY_CSV}/14_node_metrics.csv"
echo "Node,CPU_Usage_Cores,CPU_Usage_Pct,Memory_Usage_GiB,Memory_Usage_Pct" \
> "${NODE_METRICS_CSV}"

if oc adm top nodes --no-headers > "${CAPACITY_RAW}/adm_top_nodes.txt" 2>/dev/null \
   && [[ $(wc -l < "${CAPACITY_RAW}/adm_top_nodes.txt") -gt 0 ]]; then
    log INFO "oc adm top nodes: OK"
    awk '{
        name=$1; cpu=$2; cpu_pct=$3; mem=$4; mem_pct=$5
        # Strip units: m=millicores, %
        gsub(/%/, "", cpu_pct); gsub(/%/, "", mem_pct)
        # CPU: could be e.g. 250m or 2 (cores)
        cpu_cores = (cpu ~ /m$/) ? (substr(cpu,1,length(cpu)-1)+0)/1000 : cpu+0
        # Memory: Mi or Gi
        if (mem ~ /Gi$/) mem_gib = substr(mem,1,length(mem)-2)+0
        else if (mem ~ /Mi$/) mem_gib = (substr(mem,1,length(mem)-2)+0)/1024
        else mem_gib = mem+0
        printf "%s,%.4f,%s,%.2f,%s\n", name, cpu_cores, cpu_pct, mem_gib, mem_pct
    }' "${CAPACITY_RAW}/adm_top_nodes.txt" >> "${NODE_METRICS_CSV}"
    echo "true" > "${CAPACITY_JSON}/metrics_available.txt"
else
    log INFO "oc adm top nodes unavailable — trying metrics.k8s.io raw API"
    if oc get --raw "/apis/metrics.k8s.io/v1beta1/nodes" \
       > "${CAPACITY_RAW}/node_metrics.json" 2>/dev/null; then
        jq -r '.items[] | [
            .metadata.name,
            (.usage.cpu | if test("m$") then (.[:-1]|tonumber)/1000 else (tonumber? // 0) end),
            0,
            (.usage.memory | if test("Ki$") then (.[:-2]|tonumber)/1048576
             elif test("Mi$") then (.[:-2]|tonumber)/1024
             elif test("Gi$") then (.[:-2]|tonumber) else 0 end),
            0
        ] | @csv' "${CAPACITY_RAW}/node_metrics.json" \
        | tr -d '"' >> "${NODE_METRICS_CSV}" 2>/dev/null || true
        echo "true" > "${CAPACITY_JSON}/metrics_available.txt"
    else
        echo '{}' > "${CAPACITY_RAW}/node_metrics.json"
        echo "false" > "${CAPACITY_JSON}/metrics_available.txt"
        log INFO "WARN: Node metrics unavailable from both oc adm top and metrics.k8s.io"
    fi
fi

log INFO "Node metrics CSV: ${NODE_METRICS_CSV}"


#############################################
# Top Pod Metrics — normalized actual usage
# Adapted from capacity_report_auto_html_v2.sh.
#############################################

log INFO "Collecting normalized top pod metrics"

POD_METRICS_TOP_CSV="${CAPACITY_CSV}/15_pod_metrics_top.csv"
POD_METRICS_TOP_JSON="${CAPACITY_JSON}/pod_metrics_top.json"
echo "namespace,pod,cpu_used_cores,memory_used_gib" > "${POD_METRICS_TOP_CSV}"

if [[ -s "${CAPACITY_JSON}/pod_actual_usage_prom.json" ]] \
   && [[ "$(jq 'length' "${CAPACITY_JSON}/pod_actual_usage_prom.json" 2>/dev/null || echo 0)" -gt 0 ]]; then
    log INFO "Top pod metrics source: Prometheus"
    jq -r '
        sort_by([-.cpu_used_cores, -.memory_used_gib])[:5000][] |
        [.namespace, .pod, .cpu_used_cores, .memory_used_gib] | @csv
    ' "${CAPACITY_JSON}/pod_actual_usage_prom.json" \
    | tr -d '"' >> "${POD_METRICS_TOP_CSV}"
elif oc adm top pods --all-namespaces --no-headers \
     > "${CAPACITY_RAW}/adm_top_pods.txt" 2>/dev/null; then
    log INFO "Top pod metrics source: oc adm top pods fallback"
        awk '
        {
                namespace=$1; pod=$2; cpu=$3; memory=$4
                if (cpu ~ /n$/)      cpu_cores=(substr(cpu,1,length(cpu)-1)+0)/1000000000
                else if (cpu ~ /u$/) cpu_cores=(substr(cpu,1,length(cpu)-1)+0)/1000000
                else if (cpu ~ /m$/) cpu_cores=(substr(cpu,1,length(cpu)-1)+0)/1000
                else                 cpu_cores=cpu+0

                if (memory ~ /Ki$/)      memory_gib=(substr(memory,1,length(memory)-2)+0)/1048576
                else if (memory ~ /Mi$/) memory_gib=(substr(memory,1,length(memory)-2)+0)/1024
                else if (memory ~ /Gi$/) memory_gib=substr(memory,1,length(memory)-2)+0
                else if (memory ~ /Ti$/) memory_gib=(substr(memory,1,length(memory)-2)+0)*1024
                else                     memory_gib=(memory+0)/1073741824

                printf "%s,%s,%.6f,%.6f\n", namespace, pod, cpu_cores, memory_gib
        }
        ' "${CAPACITY_RAW}/adm_top_pods.txt" \
        | sort -t',' -k3,3nr -k4,4nr \
        | head -5000 >> "${POD_METRICS_TOP_CSV}"
fi

tail -n +2 "${POD_METRICS_TOP_CSV}" \
| jq -Rn '[inputs | split(",") | {
        namespace: .[0],
        pod: .[1],
        cpu_used_cores: (.[2] | tonumber? // 0),
        memory_used_gib: (.[3] | tonumber? // 0)
    }]' > "${POD_METRICS_TOP_JSON}" \
|| echo '[]' > "${POD_METRICS_TOP_JSON}"

log INFO "Top pod metrics: $(jq 'length' "${POD_METRICS_TOP_JSON}" 2>/dev/null || echo 0) pods"





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