#!/bin/bash
#############################################################################
# Script: deploy-chrony-simple.sh
# Description: Deploy Chrony NTP using sshpass (based on run_on_rhel.sh pattern)
# Usage: ./deploy-chrony-simple.sh
#############################################################################

read -s -p "Enter SSH password: " PASSWORD
echo

USERNAME="azureadmin"
SCRIPT_NAME="enable-chrony-ntp.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
SERVER_FILE="${SCRIPT_DIR}/servers.txt"
REMOTE_SCRIPT_PATH="/home/${USERNAME}/${SCRIPT_NAME}"  # Use home directory instead of /tmp
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEPLOYMENT_LOG="${LOG_DIR}/deployment-${TIMESTAMP}.log"
RESULTS_LOG="${LOG_DIR}/results-${TIMESTAMP}.csv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Create log directory
mkdir -p "${LOG_DIR}"

# Check if chrony script exists
if [ ! -f "${SCRIPT_PATH}" ]; then
    echo -e "${RED}ERROR: Chrony script not found: ${SCRIPT_PATH}${NC}"
    exit 1
fi

# Check if server file exists
if [ ! -f "${SERVER_FILE}" ]; then
    echo -e "${RED}ERROR: Server file not found: ${SERVER_FILE}${NC}"
    exit 1
fi

echo "=========================================="
echo "Chrony NTP Multi-Server Deployment"
echo "=========================================="
echo "Server File: ${SERVER_FILE}"
echo "Username:    ${USERNAME}"
echo "Script:      ${SCRIPT_NAME}"
echo "Log File:    ${DEPLOYMENT_LOG}"
echo "=========================================="
echo ""

# Initialize results file
echo "Server,Status,Message" > "${RESULTS_LOG}"

total=0
success=0
failed=0

while IFS=$'\n' read -r HOST || [[ -n "$HOST" ]]; do
    # Trim whitespace and carriage returns
    HOST=$(echo "$HOST" | tr -d '\r' | xargs)
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue  # Skip comments
    
    ((total++))
    
    echo "====== $HOST ======" | tee -a "${DEPLOYMENT_LOG}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing: $HOST" >> "${DEPLOYMENT_LOG}"
    
    # Test connectivity
    if ! ping -c 1 -W 2 "${HOST}" &>/dev/null; then
        echo -e "${RED}FAILED${NC} - Host unreachable" | tee -a "${DEPLOYMENT_LOG}"
        echo "${HOST},FAILED,Host unreachable" >> "${RESULTS_LOG}"
        ((failed++))
        echo
        continue
    fi
    
    # Copy script to server
    echo -n "Copying script... "
    scp_output=$(sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SCRIPT_PATH}" "$USERNAME@$HOST:${REMOTE_SCRIPT_PATH}" < /dev/null 2>&1)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}OK${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Script copied successfully" >> "${DEPLOYMENT_LOG}"
    else
        echo -e "${RED}FAILED${NC}" | tee -a "${DEPLOYMENT_LOG}"
        echo "  Error: $scp_output" | tee -a "${DEPLOYMENT_LOG}"
        echo "${HOST},FAILED,SCP failed: $scp_output" >> "${RESULTS_LOG}"
        ((failed++))
        echo
        continue
    fi
    
    # Execute script on server
    echo -n "Executing Chrony configuration... "
    if sshpass -p "$PASSWORD" ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USERNAME@$HOST" \
        "printf '%s\n' '$PASSWORD' | sudo -S bash ${REMOTE_SCRIPT_PATH} && rm -f ${REMOTE_SCRIPT_PATH}" < /dev/null >> "${LOG_DIR}/${HOST}_${TIMESTAMP}.log" 2>&1; then
        echo -e "${GREEN}SUCCESS${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuration completed successfully" >> "${DEPLOYMENT_LOG}"
        echo "${HOST},SUCCESS,Chrony configured successfully" >> "${RESULTS_LOG}"
        ((success++))
        
        # Get chrony status
        echo -n "Checking Chrony status... "
        sshpass -p "$PASSWORD" ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USERNAME@$HOST" "chronyc tracking" < /dev/null >> "${LOG_DIR}/${HOST}_${TIMESTAMP}.log" 2>&1 || true
        echo "Done"
    else
        echo -e "${RED}FAILED${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuration failed" >> "${DEPLOYMENT_LOG}"
        echo "${HOST},FAILED,Configuration script execution failed" >> "${RESULTS_LOG}"
        ((failed++))
    fi
    
    echo "Completed: $HOST"
    echo
    
done < "${SERVER_FILE}"

echo "=========================================="
echo "Deployment Summary"
echo "=========================================="
echo "Total Servers:   ${total}"
echo -e "${GREEN}Successful:      ${success}${NC}"
echo -e "${RED}Failed:          ${failed}${NC}"
echo "=========================================="
echo ""
echo "Results: ${RESULTS_LOG}"
echo "Logs:    ${LOG_DIR}/"
echo ""

# Display results
if [ -f "${RESULTS_LOG}" ]; then
    echo "Detailed Results:"
    column -t -s ',' "${RESULTS_LOG}"
fi

echo ""
echo "All servers processed."
