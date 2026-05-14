#!/bin/bash
################################################################################
# Azure RHEL VM Boot Repair Script
# Purpose: Fix kernel panic "VFS: Unable to mount root fs" after patching
# Usage: Run on rescue VM with broken OS disk attached as data disk
################################################################################

set -e  # Exit on error
LOG_FILE="/tmp/rhel-boot-repair-$(date +%Y%m%d-%H%M%S).log"

# Global variables
RHEL_MAJOR=""
RHEL_VERSION=""
VG_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

################################################################################
# Step 1: Detect the broken OS disk
################################################################################
detect_disk() {
    log "Detecting LVM physical volumes (PVs) for broken OS..."
    lsblk -o NAME,SIZE,TYPE 1>&2 | tee -a "$LOG_FILE" 1>&2
    # Only process actual disk devices (type 'disk', not partitions or LVs)
    PV_DISKS=()
    for disk in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print $1}' | grep -v '^sda$'); do
        if pvs "/dev/$disk" &>/dev/null; then
            PV_DISKS+=("/dev/$disk")
            log "Detected LVM PV: /dev/$disk" 1>&2
        fi
    done
    if [ ${#PV_DISKS[@]} -eq 0 ]; then
        error "No LVM PVs detected on attached disks. Please check disk attachment."
    fi
    # Only echo device names, one per line, for clean parsing in main
    for pv in "${PV_DISKS[@]}"; do
        echo "$pv"
    done
}

################################################################################
# Step 2: Detect RHEL version
################################################################################
detect_rhel_version() {
    local mount_point=$1
    
    if [ -f "$mount_point/etc/redhat-release" ]; then
        RHEL_VERSION=$(cat "$mount_point/etc/redhat-release")
        RHEL_MAJOR=$(echo "$RHEL_VERSION" | grep -oP 'release \K[0-9]+' | head -1)
        log "Detected RHEL Version: $RHEL_VERSION (Major: $RHEL_MAJOR)"
    else
        RHEL_MAJOR="unknown"
        warn "Could not detect RHEL version, proceeding with generic settings"
    fi
}

################################################################################
# Step 3: Activate LVM volumes
################################################################################
activate_lvm() {
    log "Activating LVM volumes..."
    
    # Scan for volume groups
    vgscan 2>&1 | tee -a "$LOG_FILE"
    
    # Check if any VGs found
    if ! vgs --noheadings 2>/dev/null | grep -q .; then
        log "No LVM volume groups found"
        echo ""
        return 1
    fi
    
    # Activate all volume groups
    vgchange -ay 2>&1 | tee -a "$LOG_FILE"
    
    # List logical volumes
    lvs 2>&1 | tee -a "$LOG_FILE"
    
    # Get volume group name dynamically
    VG_NAME=$(vgs --noheadings -o vg_name 2>/dev/null | head -1 | xargs)
    if [ -n "$VG_NAME" ]; then
        log "Detected Volume Group: $VG_NAME"
        echo "$VG_NAME"
        return 0
    else
        log "No volume group found after activation"
        echo ""
        return 1
    fi
}

################################################################################
# Step 4: Mount the broken system
################################################################################
mount_system() {
    local disk=$1
    local mount_point="/mnt/rescue"
    
    log "Mounting broken system at $mount_point..."
    
    # Create mount point
    mkdir -p "$mount_point"
    
    # Check for LVM presence
    log "Checking for LVM on $disk..."
    HAS_LVM=$(lsblk -ln -o TYPE "$disk" 2>/dev/null | grep -c "lvm" || echo "0")
    log "HAS_LVM result: '$HAS_LVM'"
    
    # Defensive: treat empty as 0
    if [ -z "$HAS_LVM" ]; then HAS_LVM=0; fi
    # Defensive: ensure HAS_LVM is numeric
    if ! echo "$HAS_LVM" | grep -qE '^[0-9]+$'; then HAS_LVM=0; fi
    
    # Activate LVM if present
    if [ "$HAS_LVM" -gt 0 ] 2>/dev/null; then
        log "LVM detected, activating..."
        VG_NAME=$(activate_lvm)
        
        if [ -z "$VG_NAME" ]; then
            warn "LVM detected but no volume group found, trying standard partitions"
            HAS_LVM=0
        fi
    else
        log "No LVM detected, using standard partitions"
    fi
    
    # Mount LVM volumes if LVM is present
    if [ "$HAS_LVM" -gt 0 ] 2>/dev/null && [ -n "$VG_NAME" ]; then
        # Find root LV dynamically
        ROOT_LV=$(lvs --noheadings -o lv_name,vg_name | grep -E "root|rootlv" | head -1 | awk '{print "/dev/mapper/"$2"-"$1}')
        if [ -z "$ROOT_LV" ] || [ ! -e "$ROOT_LV" ]; then
            error "Could not identify root logical volume for LVM."
        fi
            log "Mounting LVM root volume: $ROOT_LV"
            # Check if already mounted anywhere
            MOUNTED_AT=$(findmnt -rn -S "$ROOT_LV" -o TARGET | head -n1 | tr -d ' \t\r\n')
            if [ -n "$MOUNTED_AT" ]; then
                warn "Root LV $ROOT_LV already mounted at $MOUNTED_AT."
                if [ "$MOUNTED_AT" != "/mnt/rescue" ]; then
                    log "Bind-mounting $MOUNTED_AT to /mnt/rescue."
                    if ! mount --bind "$MOUNTED_AT" /mnt/rescue; then
                        error "Failed to bind-mount $MOUNTED_AT to /mnt/rescue."
                        return 1
                    fi
                else
                    log "Root LV already mounted at /mnt/rescue. Skipping mount."
                fi
            else
                if ! mount $ROOT_LV /mnt/rescue; then
                    error "Failed to mount root LV"
                    return 1
                fi
            fi
        # Mount other LVs if they exist (dynamically)
        for lv_type in usr var tmp home opt; do
            LV_PATH=$(lvs --noheadings -o lv_path,lv_name | grep -iE "${lv_type}lv|${lv_type}$" | awk '{print $1}' | head -1)
            if [ -n "$LV_PATH" ] && [ -e "$LV_PATH" ]; then
                log "Mounting /${lv_type}..."
                mount "$LV_PATH" "$mount_point/${lv_type}" 2>/dev/null || warn "Failed to mount /${lv_type}"
            fi
        done
        # Auto-detect and mount /boot and /boot/efi partitions if not present in root LV
        if [ ! -d "$mount_point/boot" ] || [ -z "$(ls -A $mount_point/boot 2>/dev/null)" ]; then
            log "Attempting to detect and mount separate /boot partition..."
            BOOT_PART=$(lsblk -ln -o NAME,MOUNTPOINT,FSTYPE | grep -E 'xfs|ext4' | grep -v "$disk" | awk '{print "/dev/"$1}' | head -1)
            if [ -n "$BOOT_PART" ]; then
                mkdir -p "$mount_point/boot"
                mount "$BOOT_PART" "$mount_point/boot" && log "Mounted /boot from $BOOT_PART" || warn "Failed to mount /boot from $BOOT_PART"
            else
                warn "No separate /boot partition detected."
            fi
        fi
        if [ ! -d "$mount_point/boot/efi" ] || [ -z "$(ls -A $mount_point/boot/efi 2>/dev/null)" ]; then
            log "Attempting to detect and mount separate /boot/efi partition..."
            EFI_PART=$(lsblk -ln -o NAME,MOUNTPOINT,FSTYPE | grep 'vfat' | awk '{print "/dev/"$1}' | head -1)
            if [ -n "$EFI_PART" ]; then
                mkdir -p "$mount_point/boot/efi"
                mount "$EFI_PART" "$mount_point/boot/efi" && log "Mounted /boot/efi from $EFI_PART" || warn "Failed to mount /boot/efi from $EFI_PART"
            else
                warn "No separate /boot/efi partition detected."
            fi
        fi
    else
        # Standard partitioning (non-LVM)
        log "Detected standard partitioning (no LVM)"
        
        # Get disk name without /dev/ prefix
        DISK_NAME=$(basename "$disk")
        log "Working with disk: $DISK_NAME"
        
        # List partitions with filesystem types for debugging
        log "Partition layout:"
        lsblk -ln -o NAME,SIZE,FSTYPE "$disk" | tee -a "$LOG_FILE"
        
        # Get all partitions on this disk
        PARTITIONS=$(lsblk -ln -o NAME,TYPE "$disk" | grep "part" | awk '{print $1}')
        
        if [ -z "$PARTITIONS" ]; then
            error "No partitions found on $disk"
        fi
        
        log "Found partitions: $PARTITIONS"
        
        # Initialize variables
        ROOT_PART=""
        BOOT_PART=""
        EFI_PART=""
        
        # Count partitions
        PART_COUNT=$(echo "$PARTITIONS" | wc -l)
        log "Partition count: $PART_COUNT"
        
        # For each partition, check filesystem type and size
        for part_name in $PARTITIONS; do
            PART_DEV="/dev/${part_name}"
            PART_SIZE=$(lsblk -ln -o SIZE "$PART_DEV" 2>/dev/null || echo "0")
            PART_FSTYPE=$(lsblk -ln -o FSTYPE "$PART_DEV" 2>/dev/null || echo "unknown")
            
            log "Checking partition: $PART_DEV (Size: $PART_SIZE, FS: $PART_FSTYPE)"
            
            # Identify EFI partition (vfat, usually < 200M)
            if [ "$PART_FSTYPE" = "vfat" ]; then
                EFI_PART="$PART_DEV"
                log "Identified EFI partition: $EFI_PART"
            # Identify boot partition (usually 200M-1G, xfs or ext4)
            elif [ "$PART_FSTYPE" = "xfs" ] || [ "$PART_FSTYPE" = "ext4" ]; then
                # Check size - boot is typically smaller
                SIZE_NUM=$(echo "$PART_SIZE" | grep -oE "[0-9.]+" | head -1)
                SIZE_UNIT=$(echo "$PART_SIZE" | grep -oE "[KMGT]" | head -1)
                
                # If size is in MB or < 2G, likely boot
                if [ "$SIZE_UNIT" = "M" ] || [ "$SIZE_UNIT" = "K" ]; then
                    BOOT_PART="$PART_DEV"
                    log "Identified boot partition: $BOOT_PART ($PART_SIZE)"
                elif [ "$SIZE_UNIT" = "G" ] && [ "${SIZE_NUM%.*}" -lt 2 ]; then
                    BOOT_PART="$PART_DEV"
                    log "Identified boot partition: $BOOT_PART ($PART_SIZE)"
                else
                    # Larger partition is root
                    ROOT_PART="$PART_DEV"
                    log "Identified root partition: $ROOT_PART ($PART_SIZE)"
                fi
            fi
        done
        
        # Fallback: if we didn't identify partitions, use simple logic
        if [ -z "$ROOT_PART" ]; then
            # Find largest partition
            ROOT_PART=$(lsblk -ln -o NAME,SIZE "$disk" | grep "${DISK_NAME}[0-9]" | sort -k2 -h | tail -1 | awk '{print "/dev/"$1}')
            log "Using fallback root partition: $ROOT_PART"
        fi
        
        if [ -z "$BOOT_PART" ] && [ "$PART_COUNT" -ge 2 ]; then
            # Find smallest non-EFI partition
            for part_name in $PARTITIONS; do
                PART_DEV="/dev/${part_name}"
                if [ "$PART_DEV" != "$EFI_PART" ] && [ "$PART_DEV" != "$ROOT_PART" ]; then
                    BOOT_PART="$PART_DEV"
                    log "Using fallback boot partition: $BOOT_PART"
                    break
                fi
            done
        fi
        
        # Validate we have at least root
        if [ -z "$ROOT_PART" ]; then
            error "Could not identify root partition"
        fi
        
        log "=== Final partition assignment ==="
        log "Root: $ROOT_PART"
        log "Boot: $BOOT_PART"
        log "EFI:  $EFI_PART"
        
        # Mount root
        # Guard: do not allow mounting the whole disk (e.g., /dev/sdb)
        if [ "$ROOT_PART" = "$disk" ]; then
            error "Refusing to mount whole disk device $ROOT_PART. Partition detection failed."
        fi
        log "Mounting root partition $ROOT_PART..."
        mount "$ROOT_PART" "$mount_point" || error "Failed to mount root partition $ROOT_PART"
        
        # Mount boot if identified
        if [ -n "$BOOT_PART" ]; then
            log "Mounting boot partition $BOOT_PART..."
            mkdir -p "$mount_point/boot"
            mount "$BOOT_PART" "$mount_point/boot" || warn "Failed to mount /boot"
        fi
        
        # Mount EFI if exists
        if [ -n "$EFI_PART" ]; then
            log "Mounting EFI partition $EFI_PART..."
            mkdir -p "$mount_point/boot/efi"
            mount "$EFI_PART" "$mount_point/boot/efi" || warn "Failed to mount /boot/efi"
        fi
    fi
    
    # Bind mount necessary filesystems
    log "Bind mounting system filesystems..."
    mount --bind /dev "$mount_point/dev"
    mount --bind /dev/pts "$mount_point/dev/pts"
    mount --bind /proc "$mount_point/proc"
    mount --bind /sys "$mount_point/sys"
    
    # Verify mounts
    log "Current mount status:"
    df -h | grep -E "rescue|rootvg|sdb|sdc" | tee -a "$LOG_FILE"
    
    echo "$mount_point"
}

################################################################################
# Step 4: Clean up old kernels if /boot is full
################################################################################
cleanup_boot() {
    local mount_point=$1
    
    log "Checking /boot disk space..."
    local boot_usage=$(df -h "$mount_point/boot" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [ "$boot_usage" -gt 70 ]; then
        warn "/boot is ${boot_usage}% full. Cleaning up old kernels..."
        
        # List all kernels
        log "Current kernels:"
        ls -lh "$mount_point/boot/vmlinuz-"* | tee -a "$LOG_FILE"
        
        # Find oldest kernel (excluding rescue)
        local oldest_kernel=$(ls -lt "$mount_point/boot/vmlinuz-"* | grep -v rescue | tail -1 | awk '{print $NF}' | xargs basename | sed 's/vmlinuz-//')
        
        if [ -n "$oldest_kernel" ]; then
            log "Removing oldest kernel: $oldest_kernel"
            rm -f "$mount_point/boot/vmlinuz-${oldest_kernel}"
            rm -f "$mount_point/boot/initramfs-${oldest_kernel}.img"
            rm -f "$mount_point/boot/initramfs-${oldest_kernel}kdump.img"
            rm -f "$mount_point/boot/System.map-${oldest_kernel}"
            rm -f "$mount_point/boot/config-${oldest_kernel}"
            rm -f "$mount_point/boot/.vmlinuz-${oldest_kernel}.hmac"
            
            log "Freed space on /boot:"
            df -h "$mount_point/boot" | tee -a "$LOG_FILE"
        fi
    else
        log "/boot has sufficient space (${boot_usage}% used)"
    fi
}

################################################################################
# Step 6: Create Azure dracut configuration
################################################################################
create_azure_dracut_config() {
    local mount_point=$1
    
    log "Creating Azure-specific dracut configuration..."
    
    # Create dracut config directory if it doesn't exist
    mkdir -p "$mount_point/etc/dracut.conf.d"
    
    # Different configs for RHEL 7 vs 8/9
    if [ "$RHEL_MAJOR" = "7" ]; then
        log "Applying RHEL 7-specific dracut configuration..."
        cat > "$mount_point/etc/dracut.conf.d/azure.conf" <<'EOF'
# Azure Hyper-V drivers for boot (RHEL 7)
add_drivers+=" hv_storvsc hv_vmbus hv_netvsc hv_utils "

# Disable host-only mode to ensure all drivers are included
hostonly="no"

# Include LVM modules
add_dracutmodules+=" lvm "
EOF
    else
        log "Applying RHEL 8/9-specific dracut configuration..."
        cat > "$mount_point/etc/dracut.conf.d/azure.conf" <<'EOF'
# Azure Hyper-V drivers for boot (RHEL 8/9)
add_drivers+=" hv_storvsc hv_vmbus hv_netvsc hv_utils hv_balloon "

# Disable host-only mode to ensure all drivers are included
hostonly="no"

# Include LVM modules
add_dracutmodules+=" lvm "

# Compress with xz for smaller initramfs
compress="xz"
EOF
    fi

    log "Azure dracut config created at $mount_point/etc/dracut.conf.d/azure.conf"
    cat "$mount_point/etc/dracut.conf.d/azure.conf" | tee -a "$LOG_FILE"
}

################################################################################
# Step 6: Rebuild initramfs for all or specific kernels
################################################################################
rebuild_initramfs() {
    local mount_point=$1
    local specific_kernel=$2
    
    log "Rebuilding initramfs..."
    
    # Chroot into the broken system
    if [ -n "$specific_kernel" ]; then
        # Rebuild for specific kernel
        log "Rebuilding initramfs for kernel: $specific_kernel"
        chroot "$mount_point" dracut --force --kver "$specific_kernel" 2>&1 | tee -a "$LOG_FILE"
        
        # Verify creation
        if [ -f "$mount_point/boot/initramfs-${specific_kernel}.img" ]; then
            log "✓ Successfully created initramfs-${specific_kernel}.img"
            ls -lh "$mount_point/boot/initramfs-${specific_kernel}.img" | tee -a "$LOG_FILE"
            
            # Verify Hyper-V drivers
            log "Verifying Hyper-V drivers in initramfs..."
            chroot "$mount_point" lsinitrd "/boot/initramfs-${specific_kernel}.img" | grep -E "hv_storvsc|hv_vmbus" | tee -a "$LOG_FILE"
        else
            error "Failed to create initramfs for $specific_kernel"
        fi
    else
        # Rebuild for all installed kernels
        log "Rebuilding initramfs for all kernels..."
        chroot "$mount_point" dracut --force --regenerate-all 2>&1 | tee -a "$LOG_FILE"
    fi
}

################################################################################
# Step 7: Fix GRUB configuration
################################################################################
fix_grub() {
    local mount_point=$1
    local disk=$2
    
    log "Checking GRUB configuration..."
    
    # Detect RHEL version for GRUB handling
    detect_rhel_version "$mount_point"
    
    # RHEL 7 uses grub2, RHEL 8/9 also use grub2
    GRUB_CFG=""
    if [ -f "$mount_point/boot/grub2/grub.cfg" ]; then
        GRUB_CFG="/boot/grub2/grub.cfg"
    elif [ -f "$mount_point/boot/grub/grub.cfg" ]; then
        GRUB_CFG="/boot/grub/grub.cfg"
    fi
    
    if [ -n "$GRUB_CFG" ]; then
        log "Found GRUB config at: $GRUB_CFG"
        log "Backing up GRUB config..."
        cp "$mount_point$GRUB_CFG" "$mount_point${GRUB_CFG}.backup-$(date +%Y%m%d)"
        
        # Regenerate GRUB config
        log "Regenerating GRUB configuration..."
        chroot "$mount_point" grub2-mkconfig -o "$GRUB_CFG" 2>&1 | tee -a "$LOG_FILE"
        
        # For UEFI systems - check multiple possible paths
        EFI_GRUB_CFG=""
        for efi_path in /boot/efi/EFI/redhat /boot/efi/EFI/centos /boot/efi/EFI/almalinux /boot/efi/EFI/rocky; do
            if [ -d "$mount_point$efi_path" ]; then
                EFI_GRUB_CFG="${efi_path}/grub.cfg"
                log "Updating UEFI GRUB config at: $EFI_GRUB_CFG"
                chroot "$mount_point" grub2-mkconfig -o "$EFI_GRUB_CFG" 2>&1 | tee -a "$LOG_FILE" || warn "Failed to update UEFI GRUB"
                break
            fi
        done
    else
        warn "GRUB config not found at expected location"
    fi
    
    # Verify default kernel
    log "Default kernel entry:"
    chroot "$mount_point" grubby --default-kernel 2>&1 | tee -a "$LOG_FILE" || warn "grubby command failed"
}

################################################################################
# Step 8: Unmount everything
################################################################################
unmount_system() {
    local mount_point=$1
    
    log "Unmounting filesystems..."
    
    # Unmount in reverse order
    umount "$mount_point/sys" 2>/dev/null || true
    umount "$mount_point/proc" 2>/dev/null || true
    umount "$mount_point/dev/pts" 2>/dev/null || true
    umount "$mount_point/dev" 2>/dev/null || true
    umount "$mount_point/boot/efi" 2>/dev/null || true
    umount "$mount_point/boot" 2>/dev/null || true
    umount "$mount_point/home" 2>/dev/null || true
    umount "$mount_point/tmp" 2>/dev/null || true
    umount "$mount_point/var" 2>/dev/null || true
    umount "$mount_point/usr" 2>/dev/null || true
    umount "$mount_point" 2>/dev/null || true
    
    log "All filesystems unmounted successfully"
}

################################################################################
# Step 9: Generate summary report
################################################################################
generate_report() {
    log "==================== REPAIR SUMMARY ===================="
    log "Repair completed successfully!"
    log "Log file: $LOG_FILE"
    log ""
    log "Next steps:"
    log "1. Exit this rescue VM"
    log "2. Detach the repaired disk from rescue VM"
    log "3. Re-attach it to the original VM as OS disk"
    log "4. Start the original VM"
    log ""
    log "PowerShell commands to restore:"
    log "  \$BrokenVM = 'YOUR-VM-NAME'"
    log "  \$ResourceGroup = 'YOUR-RG-NAME'"
    log "  az vm repair restore --resource-group \$ResourceGroup --name \$BrokenVM --verbose"
    log "  az vm start --resource-group \$ResourceGroup --name \$BrokenVM"
    log "========================================================"
}

################################################################################
# Main Execution
################################################################################
main() {
    log "========================================="
    log "Azure RHEL VM Boot Repair Script"
    log "Supports RHEL 7.9 - 9.7"
    log "========================================="
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
    fi
    
    # Detect all LVM PV disks (may be multiple)
    # Capture only stdout (device names), not stderr (logs)
    BROKEN_DISKS=( $(detect_disk 2>/dev/null) )
    if [ ${#BROKEN_DISKS[@]} -eq 0 ] || [ -z "${BROKEN_DISKS[0]}" ]; then
        error "No valid LVM PV disks detected. Cannot proceed."
    fi
    log "Activating all LVM VGs across detected PVs: ${BROKEN_DISKS[*]}"
    for disk in "${BROKEN_DISKS[@]}"; do
        if [ -b "$disk" ]; then
            pvs "$disk" &>/dev/null && log "PV $disk ready"
        fi
    done
    vgscan && vgchange -ay
    # Mount the system (pass first valid PV for partition fallback, but LVM will be used)
    FIRST_PV=""
    for disk in "${BROKEN_DISKS[@]}"; do
        if [ -b "$disk" ]; then
            FIRST_PV="$disk"
            break
        fi
    done
    if [ -z "$FIRST_PV" ]; then
        error "No valid block device found among detected PVs."
    fi
    MOUNT_POINT=$(mount_system "$FIRST_PV")
    
    # Detect RHEL version
    detect_rhel_version "$MOUNT_POINT"
    
    # Cleanup old kernels if needed
    cleanup_boot "$MOUNT_POINT"
    
    # Create Azure dracut config
    create_azure_dracut_config "$MOUNT_POINT"
    
    # Find the newest kernel that needs initramfs
    if ls "$MOUNT_POINT/boot/vmlinuz-"* 1>/dev/null 2>&1; then
        NEWEST_KERNEL=$(ls -t "$MOUNT_POINT/boot/vmlinuz-"* | head -1 | xargs basename | sed 's/vmlinuz-//')
        log "Target kernel for initramfs rebuild: $NEWEST_KERNEL"
        # Check if dracut exists
        if [ -x "$MOUNT_POINT/usr/bin/dracut" ] || [ -x "$MOUNT_POINT/sbin/dracut" ]; then
            # Check if initramfs exists for newest kernel
            if [ ! -f "$MOUNT_POINT/boot/initramfs-${NEWEST_KERNEL}.img" ]; then
                log "Missing initramfs for $NEWEST_KERNEL - rebuilding..."
                rebuild_initramfs "$MOUNT_POINT" "$NEWEST_KERNEL"
            else
                warn "Initramfs exists but may be corrupted - rebuilding..."
                rebuild_initramfs "$MOUNT_POINT" "$NEWEST_KERNEL"
            fi
        else
            warn "dracut not found in chroot. Skipping initramfs rebuild."
        fi
    else
        warn "No kernel found in /boot. Skipping initramfs rebuild."
    fi
    # Fix GRUB if config exists
    if [ -f "$MOUNT_POINT/boot/grub2/grub.cfg" ] || [ -f "$MOUNT_POINT/boot/grub/grub.cfg" ]; then
        fix_grub "$MOUNT_POINT" "$BROKEN_DISK"
    else
        warn "GRUB config not found in /boot. Skipping GRUB repair."
    fi
    
    # Unmount everything
    unmount_system "$MOUNT_POINT"
    
    # Generate report
    generate_report
    
    log "Repair script completed successfully!"
}

# Parse command line arguments
SPECIFIC_KERNEL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel)
            SPECIFIC_KERNEL="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--kernel <kernel-version>]"
            echo "  --kernel: Specify kernel version to rebuild initramfs (e.g., 5.14.0-611.49.1.el9_7.x86_64)"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Run main function
main
