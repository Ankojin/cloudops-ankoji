#!/bin/bash
################################################################################
# RHEL Pre-Reboot Boot Configuration Verification Script
# Purpose: Check /boot health and kernel configuration before reboot
# Usage: Run on each RHEL server or remotely via SSH
################################################################################

set -e
LOG_FILE="/tmp/boot-verification-$(hostname)-$(date +%Y%m%d-%H%M%S).log"
ISSUES_FOUND=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

success() {
    echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

################################################################################
# Check 1: System Information
################################################################################
check_system_info() {
    log "========================================="
    log "System Information"
    log "========================================="
    
    info "Hostname: $(hostname)"
    info "RHEL Version: $(cat /etc/redhat-release)"
    info "Kernel: $(uname -r)"
    info "Uptime: $(uptime -p)"
    
    # Check if running kernel matches installed
    RUNNING_KERNEL=$(uname -r)
    if [ -f "/boot/vmlinuz-${RUNNING_KERNEL}" ]; then
        success "Running kernel binary exists in /boot"
    else
        warn "Running kernel binary NOT found in /boot"
    fi
}

################################################################################
# Check 2: /boot Partition Space
################################################################################
check_boot_space() {
    log ""
    log "========================================="
    log "Check: /boot Partition Disk Space"
    log "========================================="
    
    # Get /boot mount point (could be separate partition or part of /)
    BOOT_MOUNT=$(df /boot | tail -1)
    BOOT_USAGE=$(echo "$BOOT_MOUNT" | awk '{print $5}' | sed 's/%//')
    BOOT_AVAIL=$(echo "$BOOT_MOUNT" | awk '{print $4}')
    BOOT_SIZE=$(echo "$BOOT_MOUNT" | awk '{print $2}')
    
    info "Partition: $(echo "$BOOT_MOUNT" | awk '{print $1}')"
    info "Size: $(echo "$BOOT_MOUNT" | awk '{print $2}') ($(numfmt --to=iec $((BOOT_SIZE * 1024))))"
    info "Used: ${BOOT_USAGE}%"
    info "Available: $(echo "$BOOT_MOUNT" | awk '{print $4}') ($(numfmt --to=iec $((BOOT_AVAIL * 1024))))"
    
    # Thresholds
    if [ "$BOOT_USAGE" -ge 90 ]; then
        error "/boot is ${BOOT_USAGE}% full - CRITICAL! Clean up required before reboot"
    elif [ "$BOOT_USAGE" -ge 80 ]; then
        warn "/boot is ${BOOT_USAGE}% full - WARNING! Consider cleanup"
    elif [ "$BOOT_USAGE" -ge 70 ]; then
        warn "/boot is ${BOOT_USAGE}% full - Cleanup recommended"
    else
        success "/boot has sufficient space (${BOOT_USAGE}% used)"
    fi
    
    # Check minimum available space (should have at least 100MB)
    BOOT_AVAIL_MB=$((BOOT_AVAIL / 1024))
    if [ "$BOOT_AVAIL_MB" -lt 100 ]; then
        error "Less than 100MB available on /boot - cleanup required!"
    fi
}

################################################################################
# Check 3: List Installed Kernels
################################################################################
check_installed_kernels() {
    log ""
    log "========================================="
    log "Check: Installed Kernels"
    log "========================================="
    
    KERNEL_COUNT=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)
    info "Total kernels installed: $KERNEL_COUNT"
    
    log ""
    log "Kernel List:"
    ls -lh /boot/vmlinuz-* | awk '{print $9" - "$5}' | tee -a "$LOG_FILE"
    
    if [ "$KERNEL_COUNT" -gt 3 ]; then
        warn "More than 3 kernels installed - consider removing old ones"
    fi
    
    # List by date
    log ""
    info "Kernels by date (newest first):"
    ls -lt /boot/vmlinuz-* | awk '{print $9}' | head -5 | tee -a "$LOG_FILE"
}

################################################################################
# Check 4: Verify initramfs for All Kernels
################################################################################
check_initramfs() {
    log ""
    log "========================================="
    log "Check: initramfs Files"
    log "========================================="
    
    MISSING_INITRAMFS=0
    
    for kernel in /boot/vmlinuz-*; do
        KERNEL_VERSION=$(basename "$kernel" | sed 's/vmlinuz-//')
        INITRAMFS="/boot/initramfs-${KERNEL_VERSION}.img"
        
        if [ -f "$INITRAMFS" ]; then
            INITRAMFS_SIZE=$(ls -lh "$INITRAMFS" | awk '{print $5}')
            success "initramfs exists for ${KERNEL_VERSION} (${INITRAMFS_SIZE})"
            
            # Check if suspiciously small (should be > 10MB)
            INITRAMFS_BYTES=$(stat -c%s "$INITRAMFS")
            if [ "$INITRAMFS_BYTES" -lt 10485760 ]; then
                warn "initramfs for ${KERNEL_VERSION} is suspiciously small (${INITRAMFS_SIZE})"
            fi
        else
            error "MISSING initramfs for ${KERNEL_VERSION}"
            MISSING_INITRAMFS=$((MISSING_INITRAMFS + 1))
        fi
    done
    
    if [ "$MISSING_INITRAMFS" -gt 0 ]; then
        error "Found $MISSING_INITRAMFS kernel(s) without initramfs - CRITICAL!"
    fi
}

################################################################################
# Check 5: Verify Hyper-V Drivers in Current Kernel initramfs
################################################################################
check_hyperv_drivers() {
    log ""
    log "========================================="
    log "Check: Hyper-V Drivers in initramfs"
    log "========================================="
    
    RUNNING_KERNEL=$(uname -r)
    INITRAMFS="/boot/initramfs-${RUNNING_KERNEL}.img"
    
    if [ ! -f "$INITRAMFS" ]; then
        error "Cannot check drivers - initramfs not found for running kernel"
        return
    fi
    
    info "Checking initramfs for kernel: $RUNNING_KERNEL"
    
    # Check for critical drivers
    CRITICAL_DRIVERS=("hv_storvsc" "hv_vmbus")
    OPTIONAL_DRIVERS=("hv_netvsc" "hv_utils" "hv_balloon")
    
    for driver in "${CRITICAL_DRIVERS[@]}"; do
        if lsinitrd "$INITRAMFS" 2>/dev/null | grep -q "${driver}.ko"; then
            success "Critical driver found: $driver"
        else
            error "CRITICAL driver MISSING: $driver - VM may not boot!"
        fi
    done
    
    for driver in "${OPTIONAL_DRIVERS[@]}"; do
        if lsinitrd "$INITRAMFS" 2>/dev/null | grep -q "${driver}.ko"; then
            success "Optional driver found: $driver"
        else
            warn "Optional driver missing: $driver"
        fi
    done
}

################################################################################
# Check 6: Verify GRUB Configuration
################################################################################
check_grub_config() {
    log ""
    log "========================================="
    log "Check: GRUB Configuration"
    log "========================================="
    
    # Find GRUB config
    GRUB_CFG=""
    if [ -f "/boot/grub2/grub.cfg" ]; then
        GRUB_CFG="/boot/grub2/grub.cfg"
    elif [ -f "/boot/grub/grub.cfg" ]; then
        GRUB_CFG="/boot/grub/grub.cfg"
    fi
    
    if [ -z "$GRUB_CFG" ]; then
        error "GRUB configuration file not found"
        return
    fi
    
    success "GRUB config found: $GRUB_CFG"
    
    # Check default kernel
    if command -v grubby &> /dev/null; then
        DEFAULT_KERNEL=$(grubby --default-kernel 2>/dev/null || echo "unknown")
        info "Default kernel: $DEFAULT_KERNEL"
        
        # Verify default kernel has initramfs
        if [ "$DEFAULT_KERNEL" != "unknown" ]; then
            DEFAULT_VERSION=$(basename "$DEFAULT_KERNEL" | sed 's/vmlinuz-//')
            if [ -f "/boot/initramfs-${DEFAULT_VERSION}.img" ]; then
                success "Default kernel has initramfs"
            else
                error "Default kernel MISSING initramfs - CRITICAL!"
            fi
        fi
    else
        warn "grubby not available - cannot check default kernel"
    fi
    
    # Check GRUB config modification date
    GRUB_MTIME=$(stat -c %Y "$GRUB_CFG")
    GRUB_AGE_DAYS=$(( ($(date +%s) - GRUB_MTIME) / 86400 ))
    info "GRUB config last modified: $(date -d @$GRUB_MTIME '+%Y-%m-%d %H:%M:%S') ($GRUB_AGE_DAYS days ago)"
    
    if [ "$GRUB_AGE_DAYS" -gt 90 ]; then
        warn "GRUB config is old (${GRUB_AGE_DAYS} days) - may need regeneration"
    fi
}

################################################################################
# Check 7: Check Azure dracut Configuration
################################################################################
check_dracut_config() {
    log ""
    log "========================================="
    log "Check: Azure dracut Configuration"
    log "========================================="
    
    DRACUT_AZURE="/etc/dracut.conf.d/azure.conf"
    
    if [ -f "$DRACUT_AZURE" ]; then
        success "Azure dracut config exists"
        info "Contents:"
        cat "$DRACUT_AZURE" | tee -a "$LOG_FILE"
        
        # Check if it includes hv_storvsc
        if grep -q "hv_storvsc" "$DRACUT_AZURE"; then
            success "Azure dracut config includes Hyper-V drivers"
        else
            warn "Azure dracut config exists but missing Hyper-V drivers"
        fi
    else
        warn "Azure dracut config not found - initramfs may not include Hyper-V drivers"
        info "Recommendation: Create $DRACUT_AZURE with Hyper-V drivers"
    fi
}

################################################################################
# Check 8: Identify Old Kernels for Removal
################################################################################
check_old_kernels() {
    log ""
    log "========================================="
    log "Check: Old Kernels (Cleanup Candidates)"
    log "========================================="
    
    RUNNING_KERNEL=$(uname -r)
    DEFAULT_KERNEL=$(grubby --default-kernel 2>/dev/null | sed 's|/boot/vmlinuz-||' || echo "")
    
    KERNEL_LIST=($(ls -1 /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V))
    KERNEL_COUNT=${#KERNEL_LIST[@]}
    
    if [ "$KERNEL_COUNT" -le 2 ]; then
        success "Only $KERNEL_COUNT kernel(s) installed - no cleanup needed"
        return
    fi
    
    info "Found $KERNEL_COUNT kernels - analyzing..."
    
    log ""
    info "Kernels to KEEP:"
    for kernel_ver in "${KERNEL_LIST[@]}"; do
        KEEP_REASON=""
        
        if [ "$kernel_ver" = "$RUNNING_KERNEL" ]; then
            KEEP_REASON="(currently running)"
        elif [ "$kernel_ver" = "$DEFAULT_KERNEL" ]; then
            KEEP_REASON="(default boot kernel)"
        fi
        
        if [ -n "$KEEP_REASON" ]; then
            info "  - $kernel_ver $KEEP_REASON"
        fi
    done
    
    # Identify oldest kernels for removal
    log ""
    warn "Kernels that can be REMOVED (oldest first):"
    
    REMOVABLE=0
    for kernel_ver in "${KERNEL_LIST[@]}"; do
        if [ "$kernel_ver" != "$RUNNING_KERNEL" ] && [ "$kernel_ver" != "$DEFAULT_KERNEL" ]; then
            # Check if it's not the newest
            if [ "$kernel_ver" != "${KERNEL_LIST[-1]}" ]; then
                REMOVABLE=$((REMOVABLE + 1))
                
                # Calculate space that would be freed
                KERNEL_SIZE=$(du -sh "/boot/vmlinuz-${kernel_ver}" 2>/dev/null | awk '{print $1}' || echo "?")
                INITRAMFS_SIZE=$(du -sh "/boot/initramfs-${kernel_ver}.img" 2>/dev/null | awk '{print $1}' || echo "?")
                
                warn "  - $kernel_ver (kernel: $KERNEL_SIZE, initramfs: $INITRAMFS_SIZE)"
                info "    Removal command: yum remove kernel-${kernel_ver}"
            fi
        fi
    done
    
    if [ "$REMOVABLE" -gt 0 ]; then
        log ""
        warn "You can remove $REMOVABLE old kernel(s) to free space"
    else
        success "No old kernels to remove (keeping current and default)"
    fi
}

################################################################################
# Check 9: System Updates Status
################################################################################
check_updates_status() {
    log ""
    log "========================================="
    log "Check: System Updates Status"
    log "========================================="
    
    # Check last yum/dnf update
    if [ -f "/var/log/yum.log" ]; then
        LAST_UPDATE=$(grep -E "Updated|Installed" /var/log/yum.log | tail -1 | awk '{print $1, $2, $3}')
        if [ -n "$LAST_UPDATE" ]; then
            info "Last package update: $LAST_UPDATE"
        fi
    fi
    
    # Check for pending updates
    if command -v yum &> /dev/null; then
        PENDING_UPDATES=$(yum check-update -q 2>/dev/null | grep -E "^[a-zA-Z]" | wc -l || echo "0")
        if [ "$PENDING_UPDATES" -gt 0 ]; then
            warn "$PENDING_UPDATES package update(s) available"
        else
            success "No pending updates"
        fi
    fi
    
    # Check if reboot is required
    if [ -f "/var/run/reboot-required" ]; then
        warn "Reboot required flag is set"
    fi
}

################################################################################
# Generate Summary Report
################################################################################
generate_summary() {
    log ""
    log "========================================="
    log "VERIFICATION SUMMARY"
    log "========================================="
    
    if [ "$ISSUES_FOUND" -eq 0 ]; then
        success "✓ NO ISSUES FOUND - Safe to reboot"
        log "System is ready for reboot after patching"
    elif [ "$ISSUES_FOUND" -le 2 ]; then
        warn "⚠ $ISSUES_FOUND MINOR ISSUE(S) FOUND"
        log "Review warnings above - reboot may be safe"
    else
        error "✗ $ISSUES_FOUND ISSUE(S) FOUND - DO NOT REBOOT"
        log "Fix critical issues before rebooting!"
    fi
    
    log ""
    log "Report saved to: $LOG_FILE"
    log "========================================="
    
    # Return exit code based on issues
    if [ "$ISSUES_FOUND" -gt 5 ]; then
        return 2  # Critical issues
    elif [ "$ISSUES_FOUND" -gt 0 ]; then
        return 1  # Warnings
    else
        return 0  # All good
    fi
}

################################################################################
# Main Execution
################################################################################
main() {
    log "========================================="
    log "RHEL Pre-Reboot Verification Script"
    log "Started: $(date)"
    log "========================================="
    
    # Check if running as root (needed for lsinitrd)
    if [ "$EUID" -ne 0 ]; then
        warn "Not running as root - some checks may be limited"
    fi
    
    # Run all checks
    check_system_info
    check_boot_space
    check_installed_kernels
    check_initramfs
    check_hyperv_drivers
    check_grub_config
    check_dracut_config
    check_old_kernels
    check_updates_status
    
    # Generate summary
    generate_summary
}

# Run main function
main
exit_code=$?

log ""
log "Verification completed: $(date)"

exit $exit_code
