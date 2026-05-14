#!/bin/bash
#############################################################################
# Script: test-ssh-connectivity.sh
# Description: Diagnose SSH connectivity issues to target servers
# Usage: ./test-ssh-connectivity.sh -f servers.txt -u username [-k keyfile]
#############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
SSH_USER="root"
SSH_KEY=""
SERVERS_FILE=""
TIMEOUT=5

usage() {
    cat << EOF
Usage: $0 -f <servers_file> -u <username> [OPTIONS]

Test SSH connectivity to servers and diagnose issues.

Required:
    -f FILE         File containing list of servers
    -u USER         SSH username

Optional:
    -k KEYFILE      SSH private key file
    -p PASSWORD     SSH password (will use sshpass)
    -t TIMEOUT      Connection timeout in seconds (default: 5)
    -h              Show this help

EOF
    exit 1
}

# Parse arguments
while getopts "f:u:k:p:t:h" opt; do
    case $opt in
        f) SERVERS_FILE="$OPTARG" ;;
        u) SSH_USER="$OPTARG" ;;
        k) SSH_KEY="$OPTARG" ;;
        p) SSH_PASSWORD="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        h) usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    esac
done

if [ -z "${SERVERS_FILE}" ] || [ -z "${SSH_USER}" ]; then
    echo -e "${RED}Error: Servers file and username are required${NC}"
    usage
fi

if [ ! -f "${SERVERS_FILE}" ]; then
    echo -e "${RED}Error: Servers file not found: ${SERVERS_FILE}${NC}"
    exit 1
fi

# Build SSH command
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=${TIMEOUT} -o BatchMode=yes"
if [ -n "${SSH_PASSWORD:-}" ]; then
    if ! command -v sshpass &> /dev/null; then
        echo -e "${RED}Error: sshpass not found${NC}"
        exit 1
    fi
    SSH_CMD="sshpass -p '${SSH_PASSWORD}' ssh"
else
    SSH_CMD="ssh"
fi

if [ -n "${SSH_KEY}" ]; then
    if [ ! -f "${SSH_KEY}" ]; then
        echo -e "${RED}Error: SSH key not found: ${SSH_KEY}${NC}"
        exit 1
    fi
    SSH_OPTS="${SSH_OPTS} -i ${SSH_KEY}"
fi

echo "=========================================="
echo "SSH Connectivity Diagnostic Test"
echo "=========================================="
echo "Servers File: ${SERVERS_FILE}"
echo "SSH User:     ${SSH_USER}"
echo "SSH Key:      ${SSH_KEY:-'default/agent'}"
echo "Timeout:      ${TIMEOUT}s"
echo "=========================================="
echo ""

# Test connectivity
total=0
success=0
failed=0

while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    
    server=$(echo "$line" | xargs)
    ((total++))
    
    echo -n "Testing ${server}... "
    
    # Test 1: Ping
    if ! ping -c 1 -W 2 "${server}" &>/dev/null; then
        echo -e "${RED}FAILED${NC} - Host unreachable (ping failed)"
        ((failed++))
        continue
    fi
    echo -n "ping:OK "
    
    # Test 2: Port 22 open
    if ! timeout 3 bash -c "echo >/dev/tcp/${server}/22" 2>/dev/null; then
        echo -e "${RED}FAILED${NC} - Port 22 closed or filtered"
        ((failed++))
        continue
    fi
    echo -n "port:OK "
    
    # Test 3: SSH authentication
    if timeout ${TIMEOUT} ${SSH_CMD} ${SSH_OPTS} ${SSH_USER}@${server} "echo 'SSH OK'" &>/dev/null; then
        echo -e "${GREEN}SUCCESS${NC} - SSH authentication OK"
        ((success++))
    else
        echo -e "${RED}FAILED${NC} - SSH authentication failed"
        ((failed++))
        
        # Additional diagnostics
        echo "  → Trying verbose SSH connection..."
        timeout ${TIMEOUT} ${SSH_CMD} ${SSH_OPTS} -v ${SSH_USER}@${server} "echo test" 2>&1 | grep -i "authentication\|permission\|refused\|publickey" | head -3 | sed 's/^/     /'
    fi
    
done < "${SERVERS_FILE}"

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Total Servers:    ${total}"
echo -e "${GREEN}Successful:       ${success}${NC}"
echo -e "${RED}Failed:           ${failed}${NC}"
echo "=========================================="
echo ""

if [ ${failed} -gt 0 ]; then
    echo "Common SSH Connection Issues:"
    echo ""
    echo "1. Authentication Problems:"
    echo "   - Wrong username (current: ${SSH_USER})"
    echo "   - SSH key not authorized on target servers"
    echo "   - SSH key has wrong permissions (should be 600)"
    echo "   - Password authentication disabled on servers"
    echo ""
    echo "2. Network Issues:"
    echo "   - Firewall blocking port 22"
    echo "   - Network routing problems"
    echo "   - VPN required but not connected"
    echo ""
    echo "3. Server Configuration:"
    echo "   - SSH service not running"
    echo "   - Root login disabled (try different user)"
    echo "   - Public key authentication disabled"
    echo ""
    echo "Troubleshooting Steps:"
    echo ""
    echo "  # Test manual SSH connection:"
    echo "  ssh -v ${SSH_USER}@<server_ip>"
    echo ""
    echo "  # Check SSH key permissions:"
    echo "  chmod 600 ${SSH_KEY:-'~/.ssh/id_rsa'}"
    echo ""
    echo "  # Copy SSH key to server:"
    echo "  ssh-copy-id ${SSH_USER}@<server_ip>"
    echo ""
    echo "  # Test with password (if available):"
    echo "  ssh ${SSH_USER}@<server_ip>"
    echo ""
fi

exit 0
