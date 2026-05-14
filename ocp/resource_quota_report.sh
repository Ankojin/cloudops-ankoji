#!/bin/bash

# Script to generate a CSV report of CPU, Memory assignments, and ResourceQuotas for projects in an OpenShift cluster
# Version: 2.0
# Improvements: Decimal CPU support, all memory formats, init containers, better performance, multiple quota handling

# Usage function
usage() {
    echo "Usage: $0 [-p PROJECT_NAME] [-h]"
    echo "  -p PROJECT_NAME  Filter report to specific project (can be used multiple times)"
    echo "  -h               Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0                              # Generate report for all projects"
    echo "  $0 -p my-project                # Generate report for single project"
    echo "  $0 -p project1 -p project2      # Generate report for specific projects"
    exit 1
}

# Parse command-line arguments
specific_projects=()
while getopts "p:h" opt; do
    case $opt in
        p)
            specific_projects+=("$OPTARG")
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
    esac
done

# Ensure oc is installed and user is logged in
if ! command -v oc &> /dev/null; then
    echo "Error: 'oc' command not found. Please install the OpenShift CLI and log in to the cluster."
    exit 1
fi

# Check if jq is installed (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' command not found. Please install jq for JSON parsing."
    exit 1
fi

# Check if user is logged in to the cluster
if ! oc whoami &> /dev/null; then
    echo "Error: Not logged in to an OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

# Get cluster info for filename
cluster_name=$(oc config current-context | sed 's|/|_|g' | sed 's|:|_|g')
timestamp=$(date +%Y%m%d_%H%M%S)

# Output CSV file and error log with timestamp
output_file="openshift_resource_report_${cluster_name}_${timestamp}.csv"
error_log="errors_${timestamp}.log"

# Initialize error log
: > "$error_log"

# Write CSV header
echo "Project,Total CPU Requests,Total CPU Limits,Total Memory Requests,Total Memory Limits,Quota CPU Requests,Quota CPU Limits,Quota Memory Requests,Quota Memory Limits,Pod Count" > "$output_file"

echo "Gathering CPU, Memory assignments, and ResourceQuotas for all projects..."
echo "Output will be saved to $output_file"
echo "Errors will be logged to $error_log"

# Function to convert CPU to millicores
convert_cpu_to_millicores() {
    local cpu="$1"
    local millicores=0
    
    # Remove quotes if present
    cpu=$(echo "$cpu" | tr -d '"' | tr -d "'")
    
    if [[ "$cpu" =~ ^([0-9]+)m$ ]]; then
        # Already in millicores (e.g., 500m)
        millicores=${BASH_REMATCH[1]}
    elif [[ "$cpu" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        # Decimal cores (e.g., 1.5 = 1500m)
        local whole=${BASH_REMATCH[1]}
        local decimal=${BASH_REMATCH[2]}
        # Pad or truncate decimal to 3 digits
        while [ ${#decimal} -lt 3 ]; do
            decimal="${decimal}0"
        done
        decimal=${decimal:0:3}
        millicores=$(( whole * 1000 + decimal ))
    elif [[ "$cpu" =~ ^0\.([0-9]+)$ ]]; then
        # Decimal less than 1 (e.g., 0.5 = 500m)
        local decimal=${BASH_REMATCH[1]}
        while [ ${#decimal} -lt 3 ]; do
            decimal="${decimal}0"
        done
        decimal=${decimal:0:3}
        millicores=$decimal
    elif [[ "$cpu" =~ ^([0-9]+)$ ]]; then
        # Whole cores (e.g., 1 = 1000m)
        millicores=$(( ${BASH_REMATCH[1]} * 1000 ))
    fi
    
    echo "$millicores"
}

# Function to convert memory to MiB
convert_memory_to_mib() {
    local mem="$1"
    local mib=0
    
    if [[ "$mem" =~ ^([0-9]+)Ki$ ]]; then
        # Kibibytes to MiB
        mib=$(( ${BASH_REMATCH[1]} / 1024 ))
    elif [[ "$mem" =~ ^([0-9]+)Mi$ ]]; then
        # Already in MiB
        mib=${BASH_REMATCH[1]}
    elif [[ "$mem" =~ ^([0-9]+)Gi$ ]]; then
        # GiB to MiB
        mib=$(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$mem" =~ ^([0-9]+)Ti$ ]]; then
        # TiB to MiB
        mib=$(( ${BASH_REMATCH[1]} * 1024 * 1024 ))
    elif [[ "$mem" =~ ^([0-9]+)K$ ]]; then
        # Kilobytes to MiB (1K = 1000 bytes)
        mib=$(( ${BASH_REMATCH[1]} / 1049 ))
    elif [[ "$mem" =~ ^([0-9]+)M$ ]]; then
        # Megabytes to MiB
        mib=$(( ${BASH_REMATCH[1]} * 1000 / 1049 ))
    elif [[ "$mem" =~ ^([0-9]+)G$ ]]; then
        # Gigabytes to MiB
        mib=$(( ${BASH_REMATCH[1]} * 1000000 / 1049 ))
    elif [[ "$mem" =~ ^([0-9]+)$ ]]; then
        # Plain bytes to MiB
        mib=$(( ${BASH_REMATCH[1]} / 1048576 ))
    fi
    
    echo "$mib"
}

# Function to format CPU for display
format_cpu() {
    local millicores="$1"
    
    if [ "$millicores" -eq 0 ]; then
        echo "0"
    elif [ "$millicores" -ge 1000 ]; then
        local cores=$(( millicores / 1000 ))
        local remainder=$(( millicores % 1000 ))
        if [ "$remainder" -eq 0 ]; then
            echo "${cores}"
        else
            # Format with decimal
            echo "${cores}.${remainder}"
        fi
    else
        echo "${millicores}m"
    fi
}

# Function to format memory for display
format_memory() {
    local mib="$1"
    
    if [ "$mib" -eq 0 ]; then
        echo "0"
    elif [ "$mib" -ge 1024 ]; then
        local gib=$(( mib / 1024 ))
        local remainder=$(( mib % 1024 ))
        if [ "$remainder" -eq 0 ]; then
            echo "${gib}Gi"
        else
            echo "${gib}.$(( remainder * 100 / 1024 ))Gi"
        fi
    else
        echo "${mib}Mi"
    fi
}

# Get all projects (namespaces)
if [ ${#specific_projects[@]} -gt 0 ]; then
    echo "Filtering for specific projects: ${specific_projects[*]}"
    projects="${specific_projects[*]}"
else
    projects=$(oc get projects -o jsonpath='{.items[*].metadata.name}')
fi

# Check if projects exist
if [ -z "$projects" ]; then
    echo "No projects found in the cluster."
    echo "No projects found" > "$output_file"
    exit 0
fi

# Count total projects for progress
total_projects=$(echo "$projects" | wc -w)
current=0

# Iterate through each project
for project in $projects; do
    current=$(( current + 1 ))
    
    # Verify project exists if filtering for specific projects
    if [ ${#specific_projects[@]} -gt 0 ]; then
        if ! oc get project "$project" &>/dev/null; then
            echo "Warning: Project '$project' not found. Skipping..."
            continue
        fi
    fi
    
    echo "Processing project $current/$total_projects: $project"
    
    # Initialize totals for pod resources
    total_cpu_requests=0
    total_cpu_limits=0
    total_mem_requests=0
    total_mem_limits=0
    pod_count=0

    # Get all pods in the project at once (more efficient)
    all_pods_json=$(oc get pods -n "$project" -o json 2>>"$error_log")
    
    if [ -n "$all_pods_json" ] && [ "$all_pods_json" != "null" ]; then
        # Count pods (ensure single integer value)
        pod_count=$(echo "$all_pods_json" | jq '.items | length' 2>/dev/null | head -n 1 | tr -d '\n')
        # Validate it's a number
        if ! [[ "$pod_count" =~ ^[0-9]+$ ]]; then
            pod_count=0
        fi
        
        # Process all containers and init containers in one pass
        while IFS= read -r container; do
            cpu_req=$(echo "$container" | jq -r '.resources.requests.cpu // "0"')
            cpu_lim=$(echo "$container" | jq -r '.resources.limits.cpu // "0"')
            mem_req=$(echo "$container" | jq -r '.resources.requests.memory // "0"')
            mem_lim=$(echo "$container" | jq -r '.resources.limits.memory // "0"')

            # Convert and accumulate CPU
            if [ "$cpu_req" != "0" ]; then
                cpu_req_millicores=$(convert_cpu_to_millicores "$cpu_req")
                total_cpu_requests=$(( total_cpu_requests + cpu_req_millicores ))
            fi
            if [ "$cpu_lim" != "0" ]; then
                cpu_lim_millicores=$(convert_cpu_to_millicores "$cpu_lim")
                total_cpu_limits=$(( total_cpu_limits + cpu_lim_millicores ))
            fi

            # Convert and accumulate Memory
            if [ "$mem_req" != "0" ]; then
                mem_req_mib=$(convert_memory_to_mib "$mem_req")
                total_mem_requests=$(( total_mem_requests + mem_req_mib ))
            fi
            if [ "$mem_lim" != "0" ]; then
                mem_lim_mib=$(convert_memory_to_mib "$mem_lim")
                total_mem_limits=$(( total_mem_limits + mem_lim_mib ))
            fi
        done < <(echo "$all_pods_json" | jq -c '.items[].spec.containers[]?, .items[].spec.initContainers[]?')
    fi

    # Format pod resource totals for display
    cpu_requests_display=$(format_cpu "$total_cpu_requests")
    cpu_limits_display=$(format_cpu "$total_cpu_limits")
    mem_requests_display=$(format_memory "$total_mem_requests")
    mem_limits_display=$(format_memory "$total_mem_limits")

    # Get ResourceQuota details (handle multiple quotas by taking the first one)
    quota_cpu_requests="N/A"
    quota_cpu_limits="N/A"
    quota_mem_requests="N/A"
    quota_mem_limits="N/A"

    # Check if ResourceQuota exists
    quota_json=$(oc get resourcequota -n "$project" -o json 2>>"$error_log" || echo '{}')
    quota_count=$(echo "$quota_json" | jq '.items | length' 2>/dev/null | head -n 1 | tr -d '\n')
    # Validate it's a number
    if ! [[ "$quota_count" =~ ^[0-9]+$ ]]; then
        quota_count=0
    fi
    
    if [ "$quota_count" -gt 0 ]; then
        # Get first quota's hard limits
        quota_info=$(echo "$quota_json" | jq -r '.items[0].spec.hard // {}')
        if [ "$quota_info" != "{}" ]; then
            quota_cpu_requests=$(echo "$quota_info" | jq -r '.["requests.cpu"] // "N/A"')
            quota_cpu_limits=$(echo "$quota_info" | jq -r '.["limits.cpu"] // "N/A"')
            quota_mem_requests=$(echo "$quota_info" | jq -r '.["requests.memory"] // "N/A"')
            quota_mem_limits=$(echo "$quota_info" | jq -r '.["limits.memory"] // "N/A"')
        fi
        
        # Log if multiple quotas exist
        if [ "$quota_count" -gt 1 ]; then
            echo "Info: Project $project has $quota_count ResourceQuotas. Using first one." >> "$error_log"
        fi
    fi

    # Write to CSV (escape commas in project name)
    project_escaped=$(echo "$project" | sed 's/,/\\,/g')
    echo "$project_escaped,$cpu_requests_display,$cpu_limits_display,$mem_requests_display,$mem_limits_display,$quota_cpu_requests,$quota_cpu_limits,$quota_mem_requests,$quota_mem_limits,$pod_count" >> "$output_file"
done

echo ""
echo "=================================================="
echo "Report generated successfully!"
echo "Output file: $output_file"
echo "Error log: $error_log"
echo "Total projects processed: $total_projects"
echo "=================================================="