#!/usr/bin/env bash
#
# ARO Ops Dashboard
#
# Part 1/6
# Main Execution Controller
#
# Compatible:
#   OpenShift 4.x
#   Azure Red Hat OpenShift (ARO)
#
# Usage:
#   ./run.sh                                          # uses current oc login context
#   ./run.sh --env DEV                                # labels output as DEV, uses current context
#   ./run.sh --env SIT --token sha256~xxx --api https://api.sit.example.com:6443
#
# Arguments:
#   --env  ENV_NAME   Label for this environment (e.g. DEV, SIT, PROD). Default: cluster
#   --token TOKEN     Bearer token to log in with (optional)
#   --api   URL       API server URL matching the token (required when --token is used)
#

set -Eeuo pipefail


#############################################
# Script Location
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "SCRIPT_DIR=${SCRIPT_DIR}"


#############################################
# Argument Parsing
#############################################

CLUSTER_ENV="cluster"
LOGIN_TOKEN=""
API_SERVER=""

while [[ $# -gt 0 ]]
do
    case "$1" in
        --env)
            CLUSTER_ENV="${2:?--env requires a value}"
            shift 2
            ;;
        --token)
            LOGIN_TOKEN="${2:?--token requires a value}"
            shift 2
            ;;
        --api)
            API_SERVER="${2:?--api requires a value}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--env ENV_NAME] [--token TOKEN --api API_URL]"
            exit 1
            ;;
    esac
done

export CLUSTER_ENV


#############################################
# Timestamp
#############################################

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

##############################################
# Output Structure
#############################################


CAPACITY_OUTPUT="${SCRIPT_DIR}/output/${CLUSTER_ENV}_${TIMESTAMP}"

CAPACITY_RAW="${CAPACITY_OUTPUT}/raw"

CAPACITY_CSV="${CAPACITY_OUTPUT}/csv"

CAPACITY_JSON="${CAPACITY_OUTPUT}/json"

CAPACITY_LOG="${CAPACITY_OUTPUT}/capacity.log"


export CAPACITY_OUTPUT
export CAPACITY_RAW
export CAPACITY_CSV
export CAPACITY_JSON
export CAPACITY_LOG


echo "Output directory:"
echo "${CAPACITY_OUTPUT}"


mkdir -p \
"${CAPACITY_OUTPUT}" \
"${CAPACITY_RAW}" \
"${CAPACITY_CSV}" \
"${CAPACITY_JSON}"
touch "${CAPACITY_LOG}"
#############################################
# Logging
#############################################

log()
{
    local LEVEL="$1"
    shift



    echo "$(date '+%F %T') [RUN] ${LEVEL}: $*" \
    | tee -a "${CAPACITY_LOG}"
}
#############################################
# Banner
#############################################

cat <<EOF | tee -a "${CAPACITY_LOG}"


======================================================

 ARO Ops Dashboard

 Environment: ${CLUSTER_ENV}

 Started:
 $(date)


 Output:

 ${CAPACITY_OUTPUT}


======================================================

EOF



#############################################
# Dependency Check
#############################################

log INFO "Checking dependencies"



DEPENDENCIES=(

oc

jq

awk

)



for CMD in "${DEPENDENCIES[@]}"
do

    if ! command -v "${CMD}" >/dev/null 2>&1
    then

        log ERROR "Missing dependency: ${CMD}"

        exit 1

    fi

done



log INFO "Dependency check completed"



#############################################
# Cluster Login (when token is supplied)
#############################################

if [[ -n "${LOGIN_TOKEN}" ]]
then

    if [[ -z "${API_SERVER}" ]]
    then
        log ERROR "--api is required when --token is provided"
        exit 1
    fi

    log INFO "Logging in to ${API_SERVER} as env=${CLUSTER_ENV}"
    log INFO "Token configured (${#LOGIN_TOKEN} chars)"

    OC_LOGIN_OUT=$(oc login \
        --token="${LOGIN_TOKEN}" \
        --server="${API_SERVER}" \
        --insecure-skip-tls-verify="${OCP_INSECURE_SKIP_TLS_VERIFY:-true}" \
        2>&1) \
    || {
        log ERROR "oc login failed — server=${API_SERVER} env=${CLUSTER_ENV}"
        log ERROR "oc output: ${OC_LOGIN_OUT}"
        exit 1
    }

    log INFO "Login successful — $(oc whoami 2>/dev/null || echo 'unknown user')"

fi


#############################################
# Cluster Validation
#############################################

log INFO "Checking OpenShift connection"



if ! oc whoami >/dev/null 2>&1
then

    log ERROR "

Not logged into OpenShift.

Run:

  oc login <api-server>

or pass --token and --api to this script.

"

    exit 1

fi



CLUSTER_USER=$(oc whoami)

CLUSTER_API=$(oc whoami --show-server)



log INFO "User: ${CLUSTER_USER}"

log INFO "API: ${CLUSTER_API}"

log INFO "Environment label: ${CLUSTER_ENV}"



#############################################
# Execute Collection
#############################################

log INFO "Starting data collection"



bash "${SCRIPT_DIR}/collect_capacity.sh"



if [[ $? -ne 0 ]]
then

    log ERROR "Collection failed"

    exit 1

fi



#############################################
# Execute Analysis
#############################################

log INFO "Starting capacity analysis"



bash "${SCRIPT_DIR}/analyze_capacity.sh"



if [[ $? -ne 0 ]]
then

    log ERROR "Analysis failed"

    exit 1

fi



#############################################
# Dedicated capacity analysis (taints / pools / nodes-to-add)
#############################################

log INFO "Starting dedicated capacity analysis"

if [[ -f "${SCRIPT_DIR}/analyze_dedicated_capacity.sh" ]]
then
    if bash "${SCRIPT_DIR}/analyze_dedicated_capacity.sh"
    then
        log INFO "Dedicated capacity analysis completed"
    else
        log INFO "WARN: dedicated capacity analysis failed — continuing with main report"
    fi
else
    log INFO "WARN: analyze_dedicated_capacity.sh not found — skipping"
fi



#############################################
# Generate HTML Report
#############################################

log INFO "Generating HTML dashboard"

# Report generation is non-fatal — JSON/CSV output is already written and will be
# inserted into the DB.  A generate_report.sh failure (e.g. missing asset, Alpine
# date quirk) should not abort the whole collection run.
if bash "${SCRIPT_DIR}/generate_report.sh"; then
    log INFO "HTML report generated"
else
    log INFO "WARN: report generation failed — JSON/CSV output still available"
fi



#############################################
# Final Summary
#############################################

REPORT_FILE="${CAPACITY_OUTPUT}/report.html"



echo "

======================================================

 ARO Ops Dashboard — Collection Completed


Environment:

${CLUSTER_ENV}


Cluster:

${CLUSTER_API}


User:

${CLUSTER_USER}



Report:

${REPORT_FILE}



CSV:

${CAPACITY_CSV}



JSON:

${CAPACITY_JSON}



Log:

${CAPACITY_LOG}



======================================================

" | tee -a "${CAPACITY_LOG}"



exit 0