#!/bin/bash
#############################################################################
# Script: deploy-chrony-ssh.sh
# Description: Deploy and configure Chrony NTP on multiple Linux servers via SSH
# Author: CloudOps Team
# Usage: ./deploy-chrony-ssh.sh -f servers.txt [-u username] [-k keyfile]
# Requirements: SSH access to target servers, sudo privileges
#############################################################################

set -euo pipefail

# Configuration
SCRIPT_NAME="enable-chrony-ntp.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
TEMP_SCRIPT="/tmp/${SCRIPT_NAME}"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEPLOYMENT_LOG="${LOG_DIR}/deployment-${TIMESTAMP}.log"
RESULTS_LOG="${LOG_DIR}/results-${TIMESTAMP}.csv"

# Default values
SSH_USER="root"
SSH_KEY=""
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SERVERS_FILE=""
PARALLEL_JOBS=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#############################################################################
# Function: usage
# Description: Display usage information
#############################################################################
usage() {
    cat << EOF
Usage: $0 -f <servers_file> [OPTIONS]

Deploy Chrony NTP configuration to multiple Linux servers via SSH.

Required:
    -f FILE         File containing list of servers (one per line, IP or hostname)

Optional:
    -u USER         SSH username (default: root)
    -k KEYFILE      SSH private key file (default: uses ssh-agent or default key)
    -p PASSWORD     SSH password (will use sshpass)
    -j JOBS         Number of parallel deployments (default: 5)
    -h              Show this help message

Examples:
    # Using root with SSH key
    $0 -f servers.txt

    # Using specific user and key file
    $0 -f servers.txt -u admin -k ~/.ssh/id_rsa

    # Using password authentication
    $0 -f servers.txt -u admin -p 'YourPassword'

    # Run with 10 parallel jobs
    $0 -f servers.txt -j 10

Server file format (one server per line):
    192.168.1.10
    192.168.1.11
    server1.example.com
    # Comments are ignored

EOF
    exit 1
}

#############################################################################
# Function: log_message
# Description: Log messages to console and file
#############################################################################
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Ensure log directory exists
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    
    echo "[${timestamp}] [${level}] ${message}" >> "${DEPLOYMENT_LOG}"
    
    case $level in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} ${message}"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} ${message}"
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} ${message}"
            ;;
    esac
}

#############################################################################
# Function: check_prerequisites
# Description: Check if required tools are available
#############################################################################
check_prerequisites() {
    log_message INFO "Checking prerequisites..."
    
    # Check if SSH is available
    if ! command -v ssh &> /dev/null; then
        log_message ERROR "SSH command not found. Please install OpenSSH client."
        exit 1
    fi
    
    # Check if the chrony script exists
    if [ ! -f "${SCRIPT_PATH}" ]; then
        log_message ERROR "Chrony script not found: ${SCRIPT_PATH}"
        exit 1
    fi
    
    # Check if servers file exists
    if [ ! -f "${SERVERS_FILE}" ]; then
        log_message ERROR "Servers file not found: ${SERVERS_FILE}"
        exit 1
    fi
    
    # Ensure log directory exists (redundant but safe)
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    
    # Check if using password and sshpass is available
    if [ -n "${SSH_PASSWORD:-}" ]; then
        if ! command -v sshpass &> /dev/null; then
            log_message ERROR "sshpass not found. Install it or use SSH key authentication."
            exit 1
        fi
        SSH_CMD="sshpass -p '${SSH_PASSWORD}' ssh"
        SCP_CMD="sshpass -p '${SSH_PASSWORD}' scp"
    else
        SSH_CMD="ssh"
        SCP_CMD="scp"
    fi
    
    # Add SSH key if specified
    if [ -n "${SSH_KEY}" ]; then
        if [ ! -f "${SSH_KEY}" ]; then
            log_message ERROR "SSH key file not found: ${SSH_KEY}"
            exit 1
        fi
        SSH_OPTS="${SSH_OPTS} -i ${SSH_KEY}"
    fi
    
    log_message SUCCESS "Prerequisites check completed"
}

#############################################################################
# Function: deploy_to_server
# Description: Deploy and execute Chrony configuration on a single server
#############################################################################
deploy_to_server() {
    local server=$1
    local result_file="/tmp/deploy_result_${server//[.:]/_}_${TIMESTAMP}.log"
    
    # Validate server parameter
    if [ -z "$server" ]; then
        log_message ERROR "[UNKNOWN] Server parameter is empty"
        echo "UNKNOWN,FAILED,Empty server parameter" >> "${RESULTS_LOG}"
        return 1
    fi
    
    log_message INFO "[$server] Starting deployment..."
    
    # Test SSH connectivity
    if ! timeout 30 ${SSH_CMD} ${SSH_OPTS} ${SSH_USER}@${server} "echo 'SSH OK'" 2>/dev/null; then
        log_message ERROR "[$server] SSH connection failed"
        echo "${server},FAILED,SSH connection failed" >> "${RESULTS_LOG}"
        return 1
    fi
    
    log_message INFO "[$server] SSH connection successful"
    
    # Copy script to server
    if ! ${SCP_CMD} ${SSH_OPTS} "${SCRIPT_PATH}" ${SSH_USER}@${server}:${TEMP_SCRIPT} &>/dev/null; then
        log_message ERROR "[$server] Failed to copy script"
        echo "${server},FAILED,Failed to copy script" >> "${RESULTS_LOG}"
        return 1
    fi
    
    log_message INFO "[$server] Script copied successfully"
    
    # Execute script on server
    log_message INFO "[$server] Executing Chrony configuration..."
    
    if ${SSH_CMD} ${SSH_OPTS} ${SSH_USER}@${server} "chmod +x ${TEMP_SCRIPT} && ${TEMP_SCRIPT}" > "${result_file}" 2>&1; then
        log_message SUCCESS "[$server] Chrony configured successfully"
        echo "${server},SUCCESS,Chrony configured successfully" >> "${RESULTS_LOG}"
        
        # Get service status
        ${SSH_CMD} ${SSH_OPTS} ${SSH_USER}@${server} "chronyc tracking" >> "${result_file}" 2>&1 || true
        
        # Save detailed log
        cat "${result_file}" >> "${LOG_DIR}/${server}_${TIMESTAMP}.log"
        rm -f "${result_file}"
        return 0
    else
        log_message ERROR "[$server] Configuration failed"
        echo "${server},FAILED,Configuration script failed" >> "${RESULTS_LOG}"
        
        # Save error log
        cat "${result_file}" >> "${LOG_DIR}/${server}_${TIMESTAMP}.log"
        rm -f "${result_file}"
        return 1
    fi
}

#############################################################################
# Function: deploy_all_servers
# Description: Deploy to all servers with parallel execution
#############################################################################
deploy_all_servers() {
    local servers=()
    local active_jobs=0
    local total_servers=0
    local successful=0
    local failed=0
    
    # Read servers from file (skip comments and empty lines)
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Trim whitespace
        server=$(echo "$line" | xargs)
        servers+=("$server")
    done < "${SERVERS_FILE}"
    
    total_servers=${#servers[@]}
    
    if [ $total_servers -eq 0 ]; then
        log_message ERROR "No valid servers found in ${SERVERS_FILE}"
        exit 1
    fi
    
    log_message INFO "Found ${total_servers} server(s) to configure"
    
    # Initialize results CSV
    echo "Server,Status,Message" > "${RESULTS_LOG}"
    
    # Deploy to servers with parallel control
    for server in "${servers[@]}"; do
        # Wait if we've reached max parallel jobs
        while [ $(jobs -r | wc -l) -ge ${PARALLEL_JOBS} ]; do
            sleep 1
        done
        
        # Deploy in background with explicit server parameter
        (deploy_to_server "$server") &
    done
    
    # Wait for all background jobs to complete
    log_message INFO "Waiting for all deployments to complete..."
    wait
    
    # Count results
    successful=$(grep -c ",SUCCESS," "${RESULTS_LOG}" || echo "0")
    failed=$(grep -c ",FAILED," "${RESULTS_LOG}" || echo "0")
    
    echo ""
    echo "=========================================="
    echo "Deployment Summary"
    echo "=========================================="
    echo "Total Servers:   ${total_servers}"
    echo "Successful:      ${successful}"
    echo "Failed:          ${failed}"
    echo "=========================================="
    echo ""
    echo "Results saved to: ${RESULTS_LOG}"
    echo "Logs saved to:    ${LOG_DIR}/"
    echo ""
}

#############################################################################
# Function: show_results
# Description: Display deployment results in a formatted table
#############################################################################
show_results() {
    echo ""
    echo "Deployment Results:"
    echo "=========================================="
    
    if [ -f "${RESULTS_LOG}" ]; then
        column -t -s ',' "${RESULTS_LOG}"
    else
        log_message WARNING "No results file found"
    fi
    
    echo "=========================================="
}

#############################################################################
# Main Script Execution
#############################################################################
main() {
    # Parse command line arguments
    while getopts "f:u:k:p:j:h" opt; do
        case $opt in
            f)
                SERVERS_FILE="$OPTARG"
                ;;
            u)
                SSH_USER="$OPTARG"
                ;;
            k)
                SSH_KEY="$OPTARG"
                ;;
            p)
                SSH_PASSWORD="$OPTARG"
                ;;
            j)
                PARALLEL_JOBS="$OPTARG"
                ;;
            h)
                usage
                ;;
            \?)
                log_message ERROR "Invalid option: -$OPTARG"
                usage
                ;;
        esac
    done
    
    # Check if servers file is provided
    if [ -z "${SERVERS_FILE}" ]; then
        log_message ERROR "Servers file is required. Use -f option."
        usage
    fi
    
    # Create log directory first
    mkdir -p "${LOG_DIR}" 2>/dev/null || true
    
    echo "=========================================="
    echo "Chrony NTP Multi-Server Deployment"
    echo "=========================================="
    echo "Servers File:    ${SERVERS_FILE}"
    echo "SSH User:        ${SSH_USER}"
    echo "Parallel Jobs:   ${PARALLEL_JOBS}"
    echo "Deployment Log:  ${DEPLOYMENT_LOG}"
    echo "=========================================="
    echo ""
    
    # Run deployment
    check_prerequisites
    deploy_all_servers
    show_results
    
    log_message SUCCESS "Deployment completed. Check logs for details."
}

# Run main function
main "$@"
