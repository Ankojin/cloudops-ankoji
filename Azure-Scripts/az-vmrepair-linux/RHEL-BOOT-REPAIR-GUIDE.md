# Azure RHEL VM Boot Repair - Complete Guide

## Supported Versions: RHEL 7.9 - 9.7 ✅

This guide and scripts support **all RHEL versions from 7.9 to 9.7**, with automatic detection and version-specific configuration.

📖 **For detailed version compatibility information, see:** [RHEL-VERSION-COMPATIBILITY.md](RHEL-VERSION-COMPATIBILITY.md)

| RHEL Version | Status | Auto-Detected |
|--------------|--------|---------------|
| RHEL 7.9 | ✅ Supported | Yes |
| RHEL 8.x (8.0-8.10) | ✅ Supported | Yes |
| RHEL 9.x (9.0-9.7) | ✅ Supported | Yes |

---

## Problem: Kernel Panic After RHEL Patching

**Symptom:** VM fails to boot with error:
```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**Root Cause:** Missing or corrupted initramfs after kernel update, typically missing Hyper-V storage drivers (`hv_storvsc`, `hv_vmbus`)

---

## Solution Workflow

### Step 1: Create Rescue VM and Attach Broken Disk

```powershell
# Edit variables in the script first
.\rescuvm-linux.ps1
```

**What it does:**
- Stops the broken VM
- Creates Ubuntu 22.04 rescue VM in the same VNET (private IP only)
- Attaches broken VM's OS disk as data disk to rescue VM
- Generates random strong password (displayed on screen)

**Key Configuration:**
```powershell
$BrokenVM = "YOUR-VM-NAME"
$ResourceGroup = "YOUR-RESOURCE-GROUP"
$VnetName = "YOUR-VNET"
$SubnetName = "YOUR-SUBNET"
```

---

### Step 2: Connect to Rescue VM

```bash
# Via Bastion or jumpbox
ssh azureuser@<rescue-vm-private-ip>
```

Copy the repair script to the rescue VM:
```bash
# From your local machine
scp fix-rhel-boot-azure.sh azureuser@<rescue-vm-ip>:/tmp/
```

---

### Step 3: Run Boot Repair Script

```bash
# On rescue VM
sudo chmod +x /tmp/fix-rhel-boot-azure.sh
sudo /tmp/fix-rhel-boot-azure.sh
```

**What the script does automatically:**
1. ✅ Detects the broken OS disk (sdb/sdc/sdd)
2. ✅ Activates LVM volumes (auto-detects VG name)
3. ✅ Mounts all filesystems (/, /usr, /var, /boot, /boot/efi)
4. ✅ **Detects RHEL version (7.9, 8.x, 9.x)**
5. ✅ Cleans up old kernels if `/boot` is > 70% full
6. ✅ Creates **version-specific** Azure Hyper-V dracut configuration
7. ✅ Rebuilds initramfs with correct Hyper-V drivers for your RHEL version
8. ✅ Verifies drivers are included in initramfs
9. ✅ Regenerates GRUB configuration (handles RHEL 7/8/9 differences)
10. ✅ Unmounts everything cleanly
11. ✅ Generates detailed log file

**Version-Specific Features:**
- **RHEL 7.9**: Uses legacy Hyper-V driver set, detects CentOS vs RHEL paths
- **RHEL 8.x**: Full Hyper-V drivers including hv_balloon, XZ compression
- **RHEL 9.x**: Latest kernel support (5.14.0+), enhanced LVM detection

**Manual mode (for specific kernel):**
```bash
# RHEL 7.9 example
sudo /tmp/fix-rhel-boot-azure.sh --kernel 3.10.0-1160.el7.x86_64

# RHEL 8.x example
sudo /tmp/fix-rhel-boot-azure.sh --kernel 4.18.0-513.el8.x86_64

# RHEL 9.x example
sudo /tmp/fix-rhel-boot-azure.sh --kernel 5.14.0-611.49.1.el9_7.x86_64
```

---

### Step 4: Restore VM and Cleanup

```bash
# Exit rescue VM
exit
```

```powershell
# From PowerShell on your workstation
.\restore-vm-from-rescue.ps1 `
    -ResourceGroup "bab-sit-dex-upg-swec-rg-01" `
    -BrokenVM "dadexordbslv01" `
    -RescueVM "rescuevm-linux" `
    -CleanupRescueVM
```

**What the restore script does:**
1. ✅ Stops both VMs
2. ✅ Detaches repaired disk from rescue VM
3. ✅ Attaches repaired disk back to original VM as OS disk
4. ✅ Starts the repaired VM
5. ✅ Displays VM status and IP
6. ✅ Optionally deletes rescue VM and resources
7. ✅ Fetches boot diagnostics

---

## Verification Steps

### 1. Check VM Status
```powershell
Get-AzVM -ResourceGroupName "YOUR-RG" -Name "YOUR-VM" -Status
```

### 2. Connect and Verify Boot
```bash
ssh youruser@<vm-private-ip>

# Check running kernel
uname -r

# Check boot logs for errors
journalctl -xb | grep -i error

# Verify Hyper-V modules loaded
lsmod | grep hv_
```

Expected output:
```
hv_storvsc
hv_vmbus
hv_netvsc
hv_utils
```

### 3. Verify initramfs Contains Drivers
```bash
lsinitrd /boot/initramfs-$(uname -r).img | grep -E "hv_storvsc|hv_vmbus"
```

---

## Prevention - Post-Repair Actions

To prevent future issues, add this to all RHEL VMs:

```bash
# Create persistent Azure dracut config
sudo tee /etc/dracut.conf.d/azure.conf <<'EOF'
add_drivers+=" hv_storvsc hv_vmbus hv_netvsc hv_utils hv_balloon "
hostonly="no"
add_dracutmodules+=" lvm "
EOF

# Regenerate all initramfs files
sudo dracut --force --regenerate-all

# Verify
ls -lh /boot/initramfs-*.img
```

---

## Troubleshooting

### Issue: `/boot` is Full
**Solution:** The script automatically removes oldest kernel when > 70% full

**Manual cleanup:**
```bash
# List kernels
ls -lh /boot/vmlinuz-*

# Remove oldest (keep 2-3 latest)
sudo rm -f /boot/*5.14.0-570.30.1*
```

### Issue: LVM Not Activated
```bash
sudo vgscan
sudo vgchange -ay
sudo lvs
```

### Issue: Can't Mount /boot
```bash
# Find boot partition
lsblk | grep -E "sdb|sdc"

# Mount manually
sudo mount /dev/sdb2 /mnt/rescue/boot
```

### Issue: Hyper-V Drivers Not in initramfs
```bash
# Verify dracut config exists
cat /etc/dracut.conf.d/azure.conf

# Rebuild with verbose logging
dracut --force --kver $(uname -r) -v
```

---

## Script Locations

| Script | Purpose | Location |
|--------|---------|----------|
| `rescuvm-linux.ps1` | Create rescue VM | Azure-Scripts/ |
| `fix-rhel-boot-azure.sh` | Repair boot on rescue VM | Azure-Scripts/ |
| `restore-vm-from-rescue.ps1` | Restore disk to original VM | Azure-Scripts/ |

---

## Logs and Diagnostics

### Repair Script Log
```bash
# On rescue VM
cat /tmp/rhel-boot-repair-*.log
```

### Azure Boot Diagnostics
```powershell
# Get boot log
az vm boot-diagnostics get-boot-log `
    --resource-group YOUR-RG `
    --name YOUR-VM `
    --output table

# Get screenshot
az vm boot-diagnostics get-boot-log-uris `
    --resource-group YOUR-RG `
    --name YOUR-VM
```

### Serial Console
```powershell
# Connect to live serial console
az serial-console connect `
    --resource-group YOUR-RG `
    --name YOUR-VM
```

---

## Quick Reference Commands

### Create Rescue VM
```powershell
.\rescuvm-linux.ps1
```

### Repair Boot
```bash
sudo /tmp/fix-rhel-boot-azure.sh
```

### Restore VM
```powershell
.\restore-vm-from-rescue.ps1 -ResourceGroup "RG" -BrokenVM "VM" -RescueVM "rescue"
```

---

## Best Practices

1. **Always test patches** in non-prod first
2. **Enable boot diagnostics** on all VMs
3. **Keep 2-3 kernel versions** on /boot
4. **Monitor /boot disk space** (should be 1GB minimum)
5. **Create Azure dracut config** proactively
6. **Take snapshots** before major updates
7. **Document VM-specific configurations**

---

## Emergency Contact Procedure

If repair fails:
1. Check logs: `/tmp/rhel-boot-repair-*.log`
2. Verify disk is detected: `lsblk`
3. Check LVM: `vgs`, `lvs`
4. Manual mount and chroot
5. Contact Azure Support with boot diagnostics

---

**Last Updated:** 2026-04-29  
**Tested On:** RHEL 9.6, RHEL 9.7  
**Author:** BAB CloudOps Team
