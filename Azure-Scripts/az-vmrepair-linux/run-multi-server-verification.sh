#!/bin/bash
################################################################################
# Multi-Server Boot Verification Script
# Purpose: Run boot health checks on multiple RHEL servers
# Usage: ./run-multi-server-verification.sh <server-list-file>
################################################################################

# Configuration
SSH_USER="${SSH_USER:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
TIMEOUT=60
PARALLEL_JOBS=5
OUTPUT_DIR="./boot-verification-reports-$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="$OUTPUT_DIR/SUMMARY.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m'

################################################################################
# Functions
################################################################################

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 <server-list-file> [options]

Arguments:
  server-list-file    File containing list of servers (one per line)
                      Format: hostname or IP address

Options:
  -u, --user USER     SSH username (default: $SSH_USER)
  -k, --key PATH      SSH private key path (default: $SSH_KEY)
  -t, --timeout SEC   SSH timeout in seconds (default: $TIMEOUT)
  -j, --jobs NUM      Number of parallel jobs (default: $PARALLEL_JOBS)
  -h, --help          Show this help message

Server List File Format:
  # Lines starting with # are comments
  server1.example.com
  10.0.1.100
  server3.example.com  # inline comments allowed

Example:
  $0 rhel-servers.txt -u admin -k ~/.ssh/my-key.pem

Environment Variables:
  SSH_USER            Default SSH username
  SSH_KEY             Default SSH private key path

EOF
    exit 1
}

################################################################################
# Verify a single server
################################################################################
verify_server() {
    local server=$1
    local output_file="$OUTPUT_DIR/${server}.log"
    local status_file="$OUTPUT_DIR/${server}.status"
    
    log "Checking $server..."
    
    # Test SSH connectivity first
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$SSH_KEY" "${SSH_USER}@${server}" "echo 'SSH OK'" &>/dev/null; then
        error "$server: SSH connection failed"
        echo "FAILED" > "$status_file"
        echo "SSH_ERROR" >> "$status_file"
        return 1
    fi
    
    # Copy verification script to server
    if ! scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "$SSH_KEY" \
        "$(dirname $0)/verify-boot-health.sh" "${SSH_USER}@${server}:/tmp/" &>/dev/null; then
        error "$server: Failed to copy verification script"
        echo "FAILED" > "$status_file"
        echo "SCP_ERROR" >> "$status_file"
        return 1
    fi
    
    # Run verification script
    ssh -o ConnectTimeout=$TIMEOUT -o StrictHostKeyChecking=no -i "$SSH_KEY" \
        "${SSH_USER}@${server}" "sudo bash /tmp/verify-boot-health.sh" > "$output_file" 2>&1
    
    local exit_code=$?
    
    # Parse results
    local issues=$(grep -c "\[ERROR\]" "$output_file" 2>/dev/null || echo 0)
    local warnings=$(grep -c "\[WARNING\]" "$output_file" 2>/dev/null || echo 0)
    
    # Save status
    if [ $exit_code -eq 0 ]; then
        echo "SUCCESS" > "$status_file"
        echo "ISSUES=0" >> "$status_file"
        echo "WARNINGS=$warnings" >> "$status_file"
        info "$server: ✓ PASSED (warnings: $warnings)"
    elif [ $exit_code -eq 1 ]; then
        echo "WARNING" > "$status_file"
        echo "ISSUES=$issues" >> "$status_file"
        echo "WARNINGS=$warnings" >> "$status_file"
        warn "$server: ⚠ WARNINGS (errors: $issues, warnings: $warnings)"
    else
        echo "CRITICAL" > "$status_file"
        echo "ISSUES=$issues" >> "$status_file"
        echo "WARNINGS=$warnings" >> "$status_file"
        error "$server: ✗ CRITICAL (errors: $issues, warnings: $warnings)"
    fi
    
    return $exit_code
}

################################################################################
# Generate Summary Report
################################################################################
generate_summary() {
    log "Generating summary report..."
    
    {
        echo "========================================="
        echo "Multi-Server Boot Verification Summary"
        echo "========================================="
        echo "Generated: $(date)"
        echo "Total Servers: $TOTAL_SERVERS"
        echo ""
        
        # Count statuses
        SUCCESS_COUNT=$(find "$OUTPUT_DIR" -name "*.status" -exec grep -l "^SUCCESS" {} \; | wc -l)
        WARNING_COUNT=$(find "$OUTPUT_DIR" -name "*.status" -exec grep -l "^WARNING" {} \; | wc -l)
        CRITICAL_COUNT=$(find "$OUTPUT_DIR" -name "*.status" -exec grep -l "^CRITICAL" {} \; | wc -l)
        FAILED_COUNT=$(find "$OUTPUT_DIR" -name "*.status" -exec grep -l "^FAILED" {} \; | wc -l)
        
        echo "Results:"
        echo "  ✓ Success:  $SUCCESS_COUNT"
        echo "  ⚠ Warnings: $WARNING_COUNT"
        echo "  ✗ Critical: $CRITICAL_COUNT"
        echo "  ⨯ Failed:   $FAILED_COUNT"
        echo ""
        
        # List servers by status
        if [ $SUCCESS_COUNT -gt 0 ]; then
            echo "========================================="
            echo "✓ SAFE TO REBOOT ($SUCCESS_COUNT servers):"
            echo "========================================="
            for status_file in "$OUTPUT_DIR"/*.status; do
                if grep -q "^SUCCESS" "$status_file"; then
                    server=$(basename "$status_file" .status)
                    warnings=$(grep "^WARNINGS=" "$status_file" | cut -d= -f2)
                    echo "  ✓ $server (warnings: $warnings)"
                fi
            done
            echo ""
        fi
        
        if [ $WARNING_COUNT -gt 0 ]; then
            echo "========================================="
            echo "⚠ REVIEW BEFORE REBOOT ($WARNING_COUNT servers):"
            echo "========================================="
            for status_file in "$OUTPUT_DIR"/*.status; do
                if grep -q "^WARNING" "$status_file"; then
                    server=$(basename "$status_file" .status)
                    issues=$(grep "^ISSUES=" "$status_file" | cut -d= -f2)
                    warnings=$(grep "^WARNINGS=" "$status_file" | cut -d= -f2)
                    echo "  ⚠ $server (errors: $issues, warnings: $warnings)"
                fi
            done
            echo ""
        fi
        
        if [ $CRITICAL_COUNT -gt 0 ]; then
            echo "========================================="
            echo "✗ DO NOT REBOOT ($CRITICAL_COUNT servers):"
            echo "========================================="
            for status_file in "$OUTPUT_DIR"/*.status; do
                if grep -q "^CRITICAL" "$status_file"; then
                    server=$(basename "$status_file" .status)
                    issues=$(grep "^ISSUES=" "$status_file" | cut -d= -f2)
                    echo "  ✗ $server (CRITICAL ISSUES: $issues)"
                    
                    # Show critical errors
                    log_file="$OUTPUT_DIR/${server}.log"
                    if [ -f "$log_file" ]; then
                        echo "    Critical errors:"
                        grep "\[ERROR\]" "$log_file" | head -5 | sed 's/^/      /'
                    fi
                fi
            done
            echo ""
        fi
        
        if [ $FAILED_COUNT -gt 0 ]; then
            echo "========================================="
            echo "⨯ CONNECTION FAILED ($FAILED_COUNT servers):"
            echo "========================================="
            for status_file in "$OUTPUT_DIR"/*.status; do
                if grep -q "^FAILED" "$status_file"; then
                    server=$(basename "$status_file" .status)
                    error_type=$(grep -v "^FAILED" "$status_file" | head -1)
                    echo "  ⨯ $server ($error_type)"
                fi
            done
            echo ""
        fi
        
        echo "========================================="
        echo "Recommendations:"
        echo "========================================="
        
        if [ $CRITICAL_COUNT -gt 0 ]; then
            echo "⚠ CRITICAL: $CRITICAL_COUNT server(s) have critical issues"
            echo "  → Fix issues before rebooting these servers"
            echo "  → Common fixes: Clean up /boot, rebuild missing initramfs"
            echo ""
        fi
        
        if [ $WARNING_COUNT -gt 0 ]; then
            echo "⚠ WARNING: $WARNING_COUNT server(s) have warnings"
            echo "  → Review individual logs in $OUTPUT_DIR"
            echo "  → Consider fixing non-critical issues"
            echo ""
        fi
        
        if [ $SUCCESS_COUNT -gt 0 ]; then
            echo "✓ SUCCESS: $SUCCESS_COUNT server(s) are safe to reboot"
            echo "  → These servers passed all checks"
            echo ""
        fi
        
        echo "========================================="
        echo "Detailed Reports:"
        echo "========================================="
        echo "Individual server logs: $OUTPUT_DIR/<server>.log"
        echo "Summary report: $SUMMARY_FILE"
        echo ""
        
        echo "========================================="
        echo "Next Steps:"
        echo "========================================="
        echo "1. Review detailed logs for servers with issues"
        echo "2. For CRITICAL servers, run fix-rhel-boot-azure.sh"
        echo "3. For WARNING servers, consider cleanup before reboot"
        echo "4. Reboot SUCCESS servers when ready"
        echo ""
        
    } | tee "$SUMMARY_FILE"
    
    # Display summary on console
    log ""
    log "========================================="
    if [ $CRITICAL_COUNT -gt 0 ]; then
        error "⚠ $CRITICAL_COUNT server(s) have CRITICAL issues - DO NOT REBOOT"
    elif [ $WARNING_COUNT -gt 0 ]; then
        warn "⚠ $WARNING_COUNT server(s) have warnings - REVIEW BEFORE REBOOT"
    fi
    
    if [ $SUCCESS_COUNT -gt 0 ]; then
        log "✓ $SUCCESS_COUNT server(s) are SAFE TO REBOOT"
    fi
    log "========================================="
    log ""
    log "Full report: $SUMMARY_FILE"
}

################################################################################
# Main Execution
################################################################################

# Parse arguments
SERVER_LIST=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -j|--jobs)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$SERVER_LIST" ]; then
                SERVER_LIST="$1"
            else
                error "Unknown option: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$SERVER_LIST" ]; then
    error "Server list file not specified"
    usage
fi

if [ ! -f "$SERVER_LIST" ]; then
    error "Server list file not found: $SERVER_LIST"
    exit 1
fi

if [ ! -f "$(dirname $0)/verify-boot-health.sh" ]; then
    error "verify-boot-health.sh not found in $(dirname $0)"
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    error "SSH key not found: $SSH_KEY"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

log "========================================="
log "Multi-Server Boot Verification"
log "========================================="
log "Server list: $SERVER_LIST"
log "SSH user: $SSH_USER"
log "SSH key: $SSH_KEY"
log "Output directory: $OUTPUT_DIR"
log "Parallel jobs: $PARALLEL_JOBS"
log "========================================="
log ""

# Read server list (skip comments and empty lines)
mapfile -t SERVERS < <(grep -v '^#' "$SERVER_LIST" | grep -v '^[[:space:]]*$' | sed 's/#.*//' | tr -d '[:space:]')
TOTAL_SERVERS=${#SERVERS[@]}

if [ $TOTAL_SERVERS -eq 0 ]; then
    error "No servers found in $SERVER_LIST"
    exit 1
fi

log "Found $TOTAL_SERVERS server(s) to check"
log ""

# Run verification on all servers (with parallel execution)
export -f verify_server log error warn info
export OUTPUT_DIR SSH_USER SSH_KEY TIMEOUT

if command -v parallel &> /dev/null; then
    # Use GNU parallel if available
    log "Using GNU parallel for faster execution..."
    printf '%s\n' "${SERVERS[@]}" | parallel -j "$PARALLEL_JOBS" verify_server {}
else
    # Fallback to sequential execution
    log "Running checks sequentially (install GNU parallel for faster execution)..."
    for server in "${SERVERS[@]}"; do
        verify_server "$server"
    done
fi

log ""
log "All checks completed"
log ""

# Generate summary report
generate_summary

# Exit with appropriate code
if [ $CRITICAL_COUNT -gt 0 ]; then
    exit 2
elif [ $WARNING_COUNT -gt 0 ]; then
    exit 1
else
    exit 0
fi
