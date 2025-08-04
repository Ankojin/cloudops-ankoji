#!/bin/bash

# This script mounts unused Azure SCSI and NVMe data disks sequentially using LVM and XFS.
# Mount points will be: /u01, /u02, ..., up to /u10
# It skips used disks and avoids duplicate fstab entries.

LOG="/var/log/mount-disks.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Starting mount process at $(date) ==="

mount_point_counter=1

create_and_mount_disk() {
    device="$1"
    mountpoint="u$(printf '%02d' $mount_point_counter)"
    vgname="${mountpoint}vg"
    lvname="${mountpoint}lv"
    lvpath="/dev/${vgname}/${lvname}"
    mountdir="/${mountpoint}"

    echo "Checking $device..."

    if ! [ -b "$device" ]; then
        echo "Device $device not found or not a block device, skipping."
        return
    fi

    # Skip if VG already exists
    if vgdisplay "$vgname" &>/dev/null; then
        echo "Volume group $vgname already exists, skipping."
        return
    fi

    # Skip if disk has partitions or is already in use
    if lsblk -no TYPE "$device" | grep -qE 'part|lvm'; then
        echo "$device is partitioned or in use, skipping."
        return
    fi

    echo "Setting up $device as $mountdir..."

    # Create VG and LV
    vgcreate "$vgname" "$device" || { echo "Failed to create VG on $device"; return; }
    lvcreate -l 100%VG -n "$lvname" "$vgname" || { echo "Failed to create LV on $device"; return; }

    # Format with XFS
    if ! blkid "$lvpath" | grep -q 'TYPE="xfs"'; then
        mkfs.xfs "$lvpath"
    else
        echo "$lvpath already formatted, skipping mkfs."
    fi

    mkdir -p "$mountdir"

    # Add to fstab if not already present
    if ! grep -qs "$lvpath" /etc/fstab; then
        echo "$lvpath  $mountdir  xfs  defaults  0 2" >> /etc/fstab
    else
        echo "fstab entry for $lvpath already exists, skipping."
    fi

    mount "$mountdir" && echo "Mounted $lvpath at $mountdir"

    mount_point_counter=$((mount_point_counter + 1))
}

# === Process Azure SCSI Disks ===
echo "--- Scanning Azure SCSI Disks ---"
for lun in $(seq 0 9); do
    if [ "$mount_point_counter" -gt 10 ]; then break; fi
    device="/dev/disk/azure/scsi1/lun$lun"
    create_and_mount_disk "$device"
done

# === Process NVMe Disks (/dev/nvme0n2 to /dev/nvme0n9) ===
echo "--- Scanning NVMe Disks ---"
for i in $(seq 2 9); do
    if [ "$mount_point_counter" -gt 10 ]; then break; fi
    device="/dev/nvme0n$i"
    create_and_mount_disk "$device"
done

echo "=== Mount process completed at $(date) ==="