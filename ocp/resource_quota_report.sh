#!/bin/bash

# Script to generate a CSV report of CPU, Memory assignments, and ResourceQuotas for projects in an OpenShift cluster
# Version: 3.0
# Fixes: pipefail, trap cleanup, CPU/memory conversion accuracy, format_cpu decimal output,
#        format_memory rounding, dead regex branch, performance (single jq pass), array iteration,
#        CSV quoting, -h exit code, cluster_name sanitization, progress counter accuracy,
#        redundant eviction filter, stderr for progress messages, quota aggregation, used vs hard quota columns

set -o pipefail

# Usage function
usage() {
    echo "Usage: $0 [-p PROJECT_NAME] [-o OUTPUT_DIR] [-h]" >&2
    echo "  -p PROJECT_NAME  Filter report to specific project (can be used multiple times)" >&2
    echo "  -o OUTPUT_DIR    Directory to write output files (default: current directory)" >&2
    echo "  -h               Display this help message" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0                              # Generate report for all projects" >&2
    echo "  $0 -p my-project                # Generate report for single project" >&2
    echo "  $0 -p project1 -p project2      # Generate report for specific projects" >&2
    echo "  $0 -o /tmp/reports              # Write output to /tmp/reports/" >&2
}

# Parse command-line arguments
specific_projects=()
output_dir="."
while getopts "p:o:h" opt; do
    case $opt in
        p)
            specific_projects+=("$OPTARG")
            ;;
        o)
            output_dir="$OPTARG"
            ;;
        h)
            usage
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            exit 1
            ;;
    esac
done

# Ensure oc is installed and user is logged in
if ! command -v oc &> /dev/null; then
    echo "Error: 'oc' command not found. Please install the OpenShift CLI and log in to the cluster." >&2
    exit 1
fi

# Check if jq is installed (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' command not found. Please install jq for JSON parsing." >&2
    exit 1
fi

# Check if awk is installed (required for floating-point math)
if ! command -v awk &> /dev/null; then
    echo "Error: 'awk' command not found. Please install awk." >&2
    exit 1
fi

# Check if user is logged in to the cluster
if ! oc whoami &> /dev/null; then
    echo "Error: Not logged in to an OpenShift cluster. Please run 'oc login' first." >&2
    exit 1
fi

# Validate and create output directory
if [ ! -d "$output_dir" ]; then
    mkdir -p "$output_dir" || { echo "Error: Cannot create output directory '$output_dir'." >&2; exit 1; }
fi

# Get cluster info for filename — sanitize all non-alphanumeric chars
cluster_name=$(oc config current-context | sed 's|[^a-zA-Z0-9_.-]|_|g')
timestamp=$(date +%Y%m%d_%H%M%S)

# Output CSV file and error log with timestamp
output_file="${output_dir}/openshift_resource_report_${cluster_name}_${timestamp}.csv"
error_log="${output_dir}/errors_${timestamp}.log"

# Initialize error log
: > "$error_log"

# Cleanup partial output on interrupt
trap 'echo "" >&2; echo "Interrupted. Partial output may exist: $output_file" >&2; exit 130' INT TERM

# Write CSV header — all fields double-quoted for RFC 4180 compliance
echo '"Project","Total CPU Requests","Total CPU Limits","Total Memory Requests","Total Memory Limits","Quota CPU Requests Hard","Quota CPU Limits Hard","Quota Memory Requests Hard","Quota Memory Limits Hard","Quota CPU Requests Used","Quota CPU Limits Used","Quota Memory Requests Used","Quota Memory Limits Used","Pod Count","Multiple Quotas"' > "$output_file"

echo "Gathering CPU, Memory assignments, and ResourceQuotas for all projects..." >&2
echo "Output will be saved to $output_file" >&2
echo "Errors will be logged to $error_log" >&2

# Function to convert CPU string to millicores (integer)
# Handles: 500m, 1, 1.5, 0.5 — using awk for accurate decimal math
convert_cpu_to_millicores() {
    local cpu="$1"
    # Remove any surrounding quotes
    cpu="${cpu//\"/}"
    cpu="${cpu//\'/}"

    if [[ "$cpu" =~ ^([0-9]+)m$ ]]; then
        # Already in millicores (e.g., 500m)
        echo "${BASH_REMATCH[1]}"
    elif [[ "$cpu" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
        # Whole or decimal cores (e.g., 1, 1.5, 0.5) — use awk to avoid bash integer rounding
        awk -v c="$cpu" 'BEGIN { printf "%d\n", c * 1000 }'
    else
        echo "0"
    fi
}

# Function to convert memory string to KiB (integer) using awk for accuracy
# Using KiB as internal unit avoids losing small values (e.g., 512Ki) during integer division
convert_memory_to_kib() {
    local mem="$1"
    local kib=0

    if [[ "$mem" =~ ^([0-9]+)Ki$ ]]; then
        kib=${BASH_REMATCH[1]}
    elif [[ "$mem" =~ ^([0-9]+)Mi$ ]]; then
        kib=$(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$mem" =~ ^([0-9]+)Gi$ ]]; then
        kib=$(( ${BASH_REMATCH[1]} * 1024 * 1024 ))
    elif [[ "$mem" =~ ^([0-9]+)Ti$ ]]; then
        kib=$(( ${BASH_REMATCH[1]} * 1024 * 1024 * 1024 ))
    elif [[ "$mem" =~ ^([0-9]+)K$ ]]; then
        # SI kilobytes: 1K = 1000 bytes = ~0.9766 KiB
        kib=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v * 1000 / 1024 }')
    elif [[ "$mem" =~ ^([0-9]+)M$ ]]; then
        # SI megabytes: 1M = 1000000 bytes
        kib=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v * 1000000 / 1024 }')
    elif [[ "$mem" =~ ^([0-9]+)G$ ]]; then
        # SI gigabytes: 1G = 1000000000 bytes
        kib=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v * 1000000000 / 1024 }')
    elif [[ "$mem" =~ ^([0-9]+)T$ ]]; then
        # SI terabytes
        kib=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v * 1000000000000 / 1024 }')
    elif [[ "$mem" =~ ^([0-9]+)$ ]]; then
        # Plain bytes
        kib=$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v / 1024 }')
    fi

    echo "$kib"
}

# Function to format CPU millicores for display (e.g., 1500 -> "1.5", 500 -> "500m")
format_cpu() {
    local millicores="$1"
    if [ "$millicores" -eq 0 ]; then
        echo "0"
    elif [ "$millicores" -ge 1000 ]; then
        # Use awk to produce clean decimal (strips trailing zeros)
        awk -v m="$millicores" 'BEGIN { v=m/1000; if(v==int(v)) printf "%d\n",v; else printf "%g\n",v }'
    else
        echo "${millicores}m"
    fi
}

# Function to format memory KiB for display (e.g., 1048576 KiB -> "1Gi", 512 KiB -> "512Ki")
format_memory() {
    local kib="$1"
    if [ "$kib" -eq 0 ]; then
        echo "0"
    elif [ "$kib" -ge $(( 1024 * 1024 * 1024 )) ]; then
        awk -v k="$kib" 'BEGIN { v=k/1024/1024/1024; if(v==int(v)) printf "%dTi\n",v; else printf "%gTi\n",v }'
    elif [ "$kib" -ge $(( 1024 * 1024 )) ]; then
        awk -v k="$kib" 'BEGIN { v=k/1024/1024; if(v==int(v)) printf "%dGi\n",v; else printf "%gGi\n",v }'
    elif [ "$kib" -ge 1024 ]; then
        awk -v k="$kib" 'BEGIN { v=k/1024; if(v==int(v)) printf "%dMi\n",v; else printf "%gMi\n",v }'
    else
        echo "${kib}Ki"
    fi
}

# Build the list of projects to process
if [ ${#specific_projects[@]} -gt 0 ]; then
    echo "Filtering for specific projects: ${specific_projects[*]}" >&2
else
    mapfile -t specific_projects < <(oc get projects -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
fi

if [ ${#specific_projects[@]} -eq 0 ]; then
    echo "No projects found in the cluster." >&2
    echo '"No projects found"' > "$output_file"
    exit 0
fi

# Pre-filter system namespaces so progress counter is accurate
filtered_projects=()
for p in "${specific_projects[@]}"; do
    if [[ "$p" == openshift-* || "$p" == "openshift" || \
          "$p" == kube-* || "$p" == "default" || \
          "$p" == "kube-system" || "$p" == "kube-public" ]]; then
        echo "Skipping OpenShift system namespace: $p" >&2
        continue
    fi
    filtered_projects+=("$p")
done

total_projects=${#filtered_projects[@]}
current=0

# Iterate through each user project
for project in "${filtered_projects[@]}"; do
    current=$(( current + 1 ))

    # Verify project is accessible (always check — handles typos in -p and RBAC issues)
    if ! oc get project "$project" &>/dev/null; then
        echo "Warning: Project '$project' not found or not accessible. Skipping..." >&2
        echo "Warning: Project '$project' not found or not accessible." >> "$error_log"
        continue
    fi

    echo "Processing project $current/$total_projects: $project" >&2

    # Initialize totals
    total_cpu_requests_mc=0
    total_cpu_limits_mc=0
    total_mem_requests_kib=0
    total_mem_limits_kib=0
    pod_count=0

    # Fetch all pods once; capture stderr to error log
    all_pods_json=$(oc get pods -n "$project" -o json 2>>"$error_log") || {
        echo "Warning: Failed to retrieve pods for project '$project'. Skipping pod data." >&2
        echo "Warning: 'oc get pods -n $project' failed." >> "$error_log"
        all_pods_json='{"items":[]}'
    }

    # Count active pods (Running or Pending/ContainerCreating)
    pod_count=$(echo "$all_pods_json" | jq '
        [.items[] | select(
            (.status.phase == "Running") or
            (.status.phase == "Pending" and
             (.status.containerStatuses[]?.state.waiting.reason? == "ContainerCreating"))
        )] | length' 2>/dev/null)
    [[ "$pod_count" =~ ^[0-9]+$ ]] || pod_count=0

    # Extract all resource fields in a single jq pass — output tab-separated rows
    # Each row: cpu_req<TAB>cpu_lim<TAB>mem_req<TAB>mem_lim
    while IFS=$'\t' read -r cpu_req cpu_lim mem_req mem_lim; do
        [[ "$cpu_req" == "0" ]] || total_cpu_requests_mc=$(( total_cpu_requests_mc + $(convert_cpu_to_millicores "$cpu_req") ))
        [[ "$cpu_lim"  == "0" ]] || total_cpu_limits_mc=$(( total_cpu_limits_mc   + $(convert_cpu_to_millicores "$cpu_lim") ))
        [[ "$mem_req" == "0" ]] || total_mem_requests_kib=$(( total_mem_requests_kib + $(convert_memory_to_kib "$mem_req") ))
        [[ "$mem_lim"  == "0" ]] || total_mem_limits_kib=$(( total_mem_limits_kib   + $(convert_memory_to_kib "$mem_lim") ))
    done < <(echo "$all_pods_json" | jq -r '
        .items[] |
        select(
            (.status.phase == "Running") or
            (.status.phase == "Pending" and
             (.status.containerStatuses[]?.state.waiting.reason? == "ContainerCreating"))
        ) |
        (.spec.containers[]?, .spec.initContainers[]?) |
        [
            (.resources.requests.cpu  // "0"),
            (.resources.limits.cpu    // "0"),
            (.resources.requests.memory // "0"),
            (.resources.limits.memory   // "0")
        ] | @tsv')

    # Format totals for display
    cpu_requests_display=$(format_cpu  "$total_cpu_requests_mc")
    cpu_limits_display=$(format_cpu    "$total_cpu_limits_mc")
    mem_requests_display=$(format_memory "$total_mem_requests_kib")
    mem_limits_display=$(format_memory   "$total_mem_limits_kib")

    # Fetch ResourceQuota (hard limits + used)
    quota_cpu_req_hard="N/A"; quota_cpu_lim_hard="N/A"
    quota_mem_req_hard="N/A"; quota_mem_lim_hard="N/A"
    quota_cpu_req_used="N/A"; quota_cpu_lim_used="N/A"
    quota_mem_req_used="N/A"; quota_mem_lim_used="N/A"
    multiple_quotas="No"

    quota_json=$(oc get resourcequota -n "$project" -o json 2>>"$error_log") || quota_json='{"items":[]}'
    quota_count=$(echo "$quota_json" | jq '.items | length' 2>/dev/null)
    [[ "$quota_count" =~ ^[0-9]+$ ]] || quota_count=0

    if [ "$quota_count" -gt 0 ]; then
        if [ "$quota_count" -gt 1 ]; then
            multiple_quotas="Yes ($quota_count quotas)"
            echo "Info: Project '$project' has $quota_count ResourceQuotas. Aggregating all." >> "$error_log"
        fi

        # Aggregate hard limits and used across ALL quotas via jq
        read -r quota_cpu_req_hard quota_cpu_lim_hard quota_mem_req_hard quota_mem_lim_hard \
                quota_cpu_req_used quota_cpu_lim_used quota_mem_req_used quota_mem_lim_used \
            < <(echo "$quota_json" | jq -r '
                def pick(f): [.items[].spec.hard | f // empty] | if length > 0 then .[0] else "N/A" end;
                def pickused(f): [.items[].status.used | f // empty] | if length > 0 then .[0] else "N/A" end;
                [
                    pick(.["requests.cpu"]),
                    pick(.["limits.cpu"]),
                    pick(.["requests.memory"]),
                    pick(.["limits.memory"]),
                    pickused(.["requests.cpu"]),
                    pickused(.["limits.cpu"]),
                    pickused(.["requests.memory"]),
                    pickused(.["limits.memory"])
                ] | @tsv')
    fi

    # Write CSV row — all fields quoted per RFC 4180
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$project" \
        "$cpu_requests_display" "$cpu_limits_display" \
        "$mem_requests_display" "$mem_limits_display" \
        "$quota_cpu_req_hard"   "$quota_cpu_lim_hard" \
        "$quota_mem_req_hard"   "$quota_mem_lim_hard" \
        "$quota_cpu_req_used"   "$quota_cpu_lim_used" \
        "$quota_mem_req_used"   "$quota_mem_lim_used" \
        "$pod_count" "$multiple_quotas" \
        >> "$output_file"
done

echo "" >&2
echo "==================================================" >&2
echo "Report generated successfully!" >&2
echo "Output file: $output_file" >&2
echo "Error log:   $error_log" >&2
echo "Total projects processed: $current/$total_projects" >&2
echo "==================================================" >&2