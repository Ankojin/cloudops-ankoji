#!/bin/bash
#############################################################################
# Script: enable-chrony-ntp.sh
# Description: Configure and enable Chrony NTP service on Linux servers
# Author: CloudOps Team
# Usage: ./enable-chrony-ntp.sh
# Requirements: Root/sudo privileges
#############################################################################

set -euo pipefail

# Configuration
NTP_SERVER="10.189.61.9"
CHRONY_CONF="/etc/chrony.conf"
CHRONY_CONF_BACKUP="${CHRONY_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/chrony-setup-$(date +%Y%m%d_%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#############################################################################
# Function: log_message
# Description: Log messages to both console and log file
#############################################################################
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
    
    case $level in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} ${message}"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} ${message}"
            ;;
        INFO)
            echo "[INFO] ${message}"
            ;;
    esac
}

#############################################################################
# Function: check_root
# Description: Verify script is run with root privileges
#############################################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message ERROR "This script must be run as root or with sudo"
        exit 1
    fi
}

#############################################################################
# Function: detect_os
# Description: Detect Linux distribution
#############################################################################
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        log_message INFO "Detected OS: $OS $VERSION"
    else
        log_message ERROR "Cannot detect OS version"
        exit 1
    fi
}

#############################################################################
# Function: install_chrony
# Description: Install Chrony package based on distribution
#############################################################################
install_chrony() {
    log_message INFO "Checking if Chrony is installed..."
    
    if command -v chronyc &> /dev/null; then
        log_message INFO "Chrony is already installed"
        chronyc -v
        return 0
    fi
    
    log_message INFO "Installing Chrony..."
    
    case $OS in
        rhel|centos|rocky|almalinux|ol)
            yum install -y chrony || dnf install -y chrony
            ;;
        ubuntu|debian)
            apt-get update
            apt-get install -y chrony
            ;;
        sles|opensuse*)
            zypper install -y chrony
            ;;
        *)
            log_message ERROR "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    if command -v chronyc &> /dev/null; then
        log_message SUCCESS "Chrony installed successfully"
    else
        log_message ERROR "Failed to install Chrony"
        exit 1
    fi
}

#############################################################################
# Function: backup_config
# Description: Backup existing chrony configuration
#############################################################################
backup_config() {
    if [ -f "${CHRONY_CONF}" ]; then
        log_message INFO "Backing up existing configuration to ${CHRONY_CONF_BACKUP}"
        cp "${CHRONY_CONF}" "${CHRONY_CONF_BACKUP}"
        log_message SUCCESS "Configuration backed up successfully"
    else
        log_message WARNING "No existing configuration file found"
    fi
}

#############################################################################
# Function: configure_chrony
# Description: Configure Chrony with specified NTP server
#############################################################################
configure_chrony() {
    log_message INFO "Configuring Chrony with NTP server: ${NTP_SERVER}"
    
    # Always fix Azure/Hyper-V PHC issues first (before checking if configured)
    if [ -f "${CHRONY_CONF}" ]; then
        # Comment out PHC refclock lines (Azure/Hyper-V compatibility)
        if grep -q "^refclock PHC" "${CHRONY_CONF}" 2>/dev/null; then
            log_message INFO "Commenting out PHC refclock for Azure/Hyper-V compatibility..."
            sed -i '/^refclock PHC/s/^/# /' "${CHRONY_CONF}"
        fi
        if grep -q "ptp_hyperv" "${CHRONY_CONF}" 2>/dev/null; then
            log_message INFO "Commenting out ptp_hyperv references..."
            sed -i '/ptp_hyperv/s/^/# /' "${CHRONY_CONF}"
        fi
    fi
    
    # Check if our server already exists and is active
    if grep -q "^server ${NTP_SERVER} iburst" "${CHRONY_CONF}" 2>/dev/null; then
        log_message INFO "NTP server ${NTP_SERVER} already configured"
        return 0
    fi
    
    # Create backup if not already done
    if [ -f "${CHRONY_CONF}" ] && [ ! -f "${CHRONY_CONF_BACKUP}" ]; then
        cp "${CHRONY_CONF}" "${CHRONY_CONF_BACKUP}"
    fi
    
    # Comment out existing server and pool lines
    if [ -f "${CHRONY_CONF}" ]; then
        sed -i '/^server /s/^/# /' "${CHRONY_CONF}"
        sed -i '/^pool /s/^/# /' "${CHRONY_CONF}"
    fi
    
    # Add the new server at the beginning of the file
    if [ -f "${CHRONY_CONF}" ]; then
        # Create temp file with new server at top
        {
            echo "# Custom NTP Server Configuration - Added by automation"
            echo "server ${NTP_SERVER} iburst"
            echo ""
            cat "${CHRONY_CONF}"
        } > "${CHRONY_CONF}.new"
        
        mv "${CHRONY_CONF}.new" "${CHRONY_CONF}"
    else
        # Create minimal config if file doesn't exist
        cat > "${CHRONY_CONF}" << EOF
# Custom NTP Server Configuration
server ${NTP_SERVER} iburst

# Allow the system clock to be stepped in the first three updates
makestep 1.0 3

# Enable kernel synchronization of the real-time clock (RTC).
rtcsync

# Specify directory for log files.
logdir /var/log/chrony

# Select which information is logged.
#log measurements statistics tracking
EOF
    fi
    
    # Ensure proper permissions
    chmod 644 "${CHRONY_CONF}"
    
    log_message SUCCESS "NTP server configured successfully"
    log_message INFO "Configuration preview:"
    head -20 "${CHRONY_CONF}" 2>&1 | tee -a "${LOG_FILE}"
}

#############################################################################
# Function: enable_chrony_service
# Description: Enable and start Chrony service
#############################################################################
enable_chrony_service() {
    log_message INFO "Enabling and starting Chrony service..."
    
    # Determine service name (chronyd or chrony)
    local service_name=""
    
    # Check which service exists
    if systemctl list-unit-files chronyd.service &>/dev/null || systemctl status chronyd &>/dev/null 2>&1; then
        service_name="chronyd"
    elif systemctl list-unit-files chrony.service &>/dev/null || systemctl status chrony &>/dev/null 2>&1; then
        service_name="chrony"
    else
        # Default based on OS family
        case $OS in
            rhel|centos|rocky|almalinux|ol|fedora)
                service_name="chronyd"
                ;;
            ubuntu|debian|sles|opensuse*)
                service_name="chrony"
                ;;
            *)
                service_name="chronyd"
                ;;
        esac
    fi
    
    log_message INFO "Using service name: ${service_name}"
    
    # Test configuration before applying
    log_message INFO "Testing chrony configuration..."
    if command -v chronyd &>/dev/null; then
        if ! chronyd -t &>/dev/null; then
            log_message WARNING "Configuration test failed, but continuing..."
        else
            log_message INFO "Configuration test passed"
        fi
    fi
    
    # Enable service
    if systemctl enable ${service_name} 2>&1 | tee -a "${LOG_FILE}"; then
        log_message INFO "Service enabled successfully"
    else
        log_message WARNING "Failed to enable service, but continuing..."
    fi
    
    # Start or restart service to apply configuration
    if systemctl is-active --quiet ${service_name}; then
        log_message INFO "Restarting ${service_name} service..."
        if ! systemctl restart ${service_name} 2>&1 | tee -a "${LOG_FILE}"; then
            log_message ERROR "Failed to restart ${service_name}"
            log_message ERROR "Service status:"
            systemctl status ${service_name} --no-pager -l 2>&1 | tee -a "${LOG_FILE}"
            log_message ERROR "Recent journal entries:"
            journalctl -u ${service_name} -n 20 --no-pager 2>&1 | tee -a "${LOG_FILE}"
            exit 1
        fi
    else
        log_message INFO "Starting ${service_name} service..."
        if ! systemctl start ${service_name} 2>&1 | tee -a "${LOG_FILE}"; then
            log_message ERROR "Failed to start ${service_name}"
            log_message ERROR "Service status:"
            systemctl status ${service_name} --no-pager -l 2>&1 | tee -a "${LOG_FILE}"
            log_message ERROR "Recent journal entries:"
            journalctl -u ${service_name} -n 20 --no-pager 2>&1 | tee -a "${LOG_FILE}"
            log_message ERROR "Configuration file check:"
            cat "${CHRONY_CONF}" 2>&1 | tee -a "${LOG_FILE}"
            exit 1
        fi
    fi
    
    # Wait a moment for service to start
    sleep 2
    
    # Check service status
    if systemctl is-active --quiet ${service_name}; then
        log_message SUCCESS "Chrony service is running"
    else
        log_message ERROR "Chrony service failed to start"
        log_message ERROR "Service status:"
        systemctl status ${service_name} --no-pager 2>&1 | tee -a "${LOG_FILE}"
        log_message ERROR "Checking if service file exists:"
        systemctl list-unit-files ${service_name}.service 2>&1 | tee -a "${LOG_FILE}"
        exit 1
    fi
}

#############################################################################
# Function: verify_ntp_sync
# Description: Verify NTP synchronization status
#############################################################################
verify_ntp_sync() {
    log_message INFO "Verifying NTP synchronization..."
    
    echo ""
    echo "=========================================="
    echo "Chrony Tracking Status:"
    echo "=========================================="
    chronyc tracking
    
    echo ""
    echo "=========================================="
    echo "Chrony Sources:"
    echo "=========================================="
    chronyc sources -v
    
    echo ""
    echo "=========================================="
    echo "Chrony Source Stats:"
    echo "=========================================="
    chronyc sourcestats
    
    # Check if synchronization is happening
    if chronyc tracking | grep -q "Leap status.*Normal"; then
        log_message SUCCESS "NTP synchronization is working"
    else
        log_message WARNING "NTP may not be synchronized yet. Please wait a few minutes and check again."
    fi
}

#############################################################################
# Function: configure_firewall
# Description: Configure firewall to allow NTP traffic
#############################################################################
configure_firewall() {
    log_message INFO "Checking firewall configuration..."
    
    # Check if firewalld is running
    if systemctl is-active --quiet firewalld; then
        log_message INFO "Configuring firewalld for NTP..."
        firewall-cmd --permanent --add-service=ntp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_message SUCCESS "Firewall configured for NTP"
    elif command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log_message INFO "Configuring ufw for NTP..."
        ufw allow ntp 2>/dev/null || true
        log_message SUCCESS "Firewall configured for NTP"
    else
        log_message INFO "No active firewall detected or manual configuration required"
    fi
}

#############################################################################
# Main Script Execution
#############################################################################
main() {
    echo "=========================================="
    echo "Chrony NTP Configuration Script"
    echo "=========================================="
    echo ""
    
    log_message INFO "Starting Chrony NTP configuration..."
    log_message INFO "Log file: ${LOG_FILE}"
    
    # Perform checks and installation
    check_root
    detect_os
    install_chrony
    backup_config
    configure_chrony
    configure_firewall
    enable_chrony_service
    verify_ntp_sync
    
    echo ""
    echo "=========================================="
    log_message SUCCESS "Chrony NTP configuration completed successfully!"
    echo "=========================================="
    echo ""
    echo "Configuration file: ${CHRONY_CONF}"
    echo "Backup file: ${CHRONY_CONF_BACKUP}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "To check status later, run:"
    echo "  chronyc tracking"
    echo "  chronyc sources"
    echo ""
}

# Run main function
main "$@"
