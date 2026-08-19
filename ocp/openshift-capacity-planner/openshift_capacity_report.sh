#!/usr/bin/env bash
#
# ARO Ops Dashboard
# Main Execution Controller
#
# Compatible:
#   OpenShift 4.x
#   ARO
#
# Requirements:
#   oc
#   jq
#   awk
#

set -Eeuo pipefail


############################################
# Configuration
############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

BASE_OUTPUT="${SCRIPT_DIR}/output"

RUN_DIR="${BASE_OUTPUT}/${TIMESTAMP}"

RAW_DIR="${RUN_DIR}/raw"
CSV_DIR="${RUN_DIR}/csv"
JSON_DIR="${RUN_DIR}/json"
LOG_DIR="${RUN_DIR}/logs"

LOG_FILE="${LOG_DIR}/capacity_report.log"


############################################
# Logging
############################################

mkdir -p \
"${RAW_DIR}" \
"${CSV_DIR}" \
"${JSON_DIR}" \
"${LOG_DIR}"



log()
{
    local LEVEL="$1"
    shift

    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LEVEL] $*" \
        | tee -a "${LOG_FILE}"
}



error_exit()
{
    log "ERROR" "$1"
    exit 1
}



############################################
# Trap Errors
############################################

trap '
log "ERROR" "Script failed at line ${LINENO}"
exit 1
' ERR



############################################
# Banner
############################################


echo "

====================================================
 ARO Ops Dashboard
====================================================

Version : 1.0
Started : $(date)

Output:
${RUN_DIR}

====================================================

"



log INFO "Starting OpenShift Capacity Report"



############################################
# Dependency Check
############################################


check_command()
{

    if ! command -v "$1" >/dev/null 2>&1
    then
        error_exit "$1 command not found"
    fi

}



log INFO "Checking prerequisites"



check_command oc
check_command jq
check_command awk



log INFO "Prerequisites OK"



############################################
# OpenShift Login Check
############################################


log INFO "Checking OpenShift connection"



if ! oc whoami >/dev/null 2>&1
then

    error_exit "
Not logged into OpenShift.

Run:

oc login <cluster-api>

"

fi



CURRENT_USER=$(oc whoami)

CLUSTER=$(oc whoami --show-server)



log INFO "User     : ${CURRENT_USER}"
log INFO "Cluster  : ${CLUSTER}"



############################################
# Cluster Info
############################################


log INFO "Collecting cluster metadata"



oc version -o json \
> "${JSON_DIR}/cluster_version.json" \
2>>"${LOG_FILE}" || true



oc get clusterversion \
-o json \
> "${JSON_DIR}/cluster_version_status.json" \
2>>"${LOG_FILE}" || true



############################################
# Environment Variables
############################################


export CAPACITY_OUTPUT="${RUN_DIR}"
export CAPACITY_RAW="${RAW_DIR}"
export CAPACITY_CSV="${CSV_DIR}"
export CAPACITY_JSON="${JSON_DIR}"
export CAPACITY_LOG="${LOG_FILE}"



############################################
# Execute Collector
############################################


log INFO "Starting data collection"



if [[ ! -f "${SCRIPT_DIR}/collect_capacity.sh" ]]
then
    error_exit "collect_capacity.sh missing"
fi



bash "${SCRIPT_DIR}/collect_capacity.sh"



log INFO "Collection completed"



############################################
# Execute Analyzer
############################################


log INFO "Starting capacity analysis"



if [[ ! -f "${SCRIPT_DIR}/analyze_capacity.sh" ]]
then
    error_exit "analyze_capacity.sh missing"
fi



bash "${SCRIPT_DIR}/analyze_capacity.sh"



log INFO "Analysis completed"



############################################
# Generate Report
############################################


log INFO "Generating HTML dashboard"



if [[ ! -f "${SCRIPT_DIR}/generate_report.sh" ]]
then
    error_exit "generate_report.sh missing"
fi



bash "${SCRIPT_DIR}/generate_report.sh"



log INFO "HTML report generated"



############################################
# Summary
############################################


REPORT_FILE="${RUN_DIR}/report.html"



echo "

====================================================
 OpenShift Capacity Report Completed
====================================================

Output Directory:

${RUN_DIR}


HTML Report:

${REPORT_FILE}


Files Generated:

RAW DATA:
${RAW_DIR}

CSV:
${CSV_DIR}

JSON:
${JSON_DIR}

LOG:
${LOG_FILE}


====================================================

"



log INFO "Completed successfully"