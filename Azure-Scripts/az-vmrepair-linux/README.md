# Azure Linux VM Repair & Verification Toolkit

Complete toolkit for RHEL VMs: **prevent boot issues** before reboot and **repair** if they occur.

## 🚀 Quick Start

### Prevention (Before Reboot) ✅
```bash
# Verify single server
sudo bash verify-boot-health.sh

# Verify multiple servers
./run-multi-server-verification.sh servers.txt
```

### Repair (After Boot Failure) 🔧
```powershell
# 1. Create rescue VM
.\rescuvm-linux.ps1

# 2. On rescue VM - run repair script
sudo /tmp/fix-rhel-boot-azure.sh

# 3. Restore VM
.\restore-vm-from-rescue.ps1 -ResourceGroup "RG" -BrokenVM "VM" -RescueVM "rescue"
```

## 📦 What's Included

### Boot Verification (Prevention)
| File | Purpose |
|------|---------|
| **verify-boot-health.sh** | Check /boot health before reboot |
| **run-multi-server-verification.sh** | Run checks on multiple servers |
| **servers.txt** | Sample server list |
| **BOOT-VERIFICATION-GUIDE.md** | Complete verification guide |

### Boot Repair (Recovery)
| File | Purpose |
|------|---------|
| **fix-rhel-boot-azure.sh** | Repair boot issues on rescue VM |
| **rescuvm-linux.ps1** | Create rescue VM (PowerShell) |
| **restore-vm-from-rescue.ps1** | Restore disk after repair |
| **RHEL-BOOT-REPAIR-GUIDE.md** | Complete repair workflow |
| **RHEL-VERSION-COMPATIBILITY.md** | Version-specific details |

## ✅ Supported RHEL Versions

- **RHEL 7.9** - Legacy support with version-specific handling
- **RHEL 8.0 - 8.10** - Full support
- **RHEL 9.0 - 9.7** - Latest kernels and features

Script automatically detects RHEL version and applies appropriate configuration.

---

## 🎯 Complete Workflow

### Prevention First (Recommended)

```
1. Patch Servers
   ↓
2. Wait (Don't reboot yet!)
   ↓
3. Run Boot Verification
   → verify-boot-health.sh (single server)
   → run-multi-server-verification.sh (multiple servers)
   ↓
4. Review Results
   ├─ All OK? → Safe to reboot
   └─ Issues found? → Fix them first
   ↓
5. Reboot with confidence
   ↓
6. If boot fails → Use repair toolkit below
```

### Verification Workflow (Before Reboot)

```bash
# Single server check
ssh server "sudo bash verify-boot-health.sh"

# Multiple servers
./run-multi-server-verification.sh servers.txt

# Review results
cat boot-verification-reports-*/SUMMARY.txt

# Fix issues found (see BOOT-VERIFICATION-GUIDE.md)
```

### Repair Workflow (After Boot Failure)

```powershell
# 1. Create rescue VM
.\rescuvm-linux.ps1

# 2. Connect and repair
ssh azureuser@rescue-vm-ip
sudo /tmp/fix-rhel-boot-azure.sh

# 3. Restore and start
.\restore-vm-from-rescue.ps1 -ResourceGroup "RG" -BrokenVM "VM" -RescueVM "rescue"
```

---

## 🛠️ Features

### Verification Features
- ✅ Check /boot disk space (critical for reboot)
- ✅ Verify initramfs exists for all kernels
- ✅ Check Hyper-V drivers in Azure VMs
- ✅ Validate GRUB configuration
- ✅ Identify old kernels for cleanup
- ✅ Multi-server parallel execution
- ✅ Detailed reports and summaries

### Repair Features

- ✅ Automatic RHEL version detection (7.9 - 9.7)
- ✅ Dynamic LVM volume group detection
- ✅ Auto-cleanup of old kernels when /boot is full
- ✅ Version-specific dracut configuration
- ✅ Hyper-V driver verification
- ✅ GRUB regeneration for BIOS and UEFI
- ✅ Detailed logging

## 📋 Prerequisites

- Azure subscription with existing VM
- VM stuck in kernel panic after patching
- Network connectivity (Bastion or jumpbox)
- Sufficient Azure permissions (VM Contributor)

## 🔧 Common Use Cases

### Case 1: Missing initramfs After Patch
```bash
sudo /tmp/fix-rhel-boot-azure.sh
# Auto-detects missing initramfs and rebuilds
```

### Case 2: /boot Partition Full
```bash
sudo /tmp/fix-rhel-boot-azure.sh
# Automatically removes oldest kernel to free space
```

### Case 3: Corrupted initramfs
```bash
sudo /tmp/fix-rhel-boot-azure.sh --kernel 5.14.0-611.49.1.el9_7.x86_64
# Rebuilds specific kernel's initramfs
```

## 📖 Documentation

### For Prevention (Before Reboot)
- **[BOOT-VERIFICATION-GUIDE.md](BOOT-VERIFICATION-GUIDE.md)** - Complete verification guide
  - Single server verification
  - Multi-server orchestration
  - Fixing issues before reboot
  - Use cases and best practices

### For Recovery (After Boot Failure)
- **[RHEL-BOOT-REPAIR-GUIDE.md](RHEL-BOOT-REPAIR-GUIDE.md)** - Complete repair workflow
  - Rescue VM creation
  - Boot repair process
  - VM restoration

### Version-Specific Information
- **[RHEL-VERSION-COMPATIBILITY.md](RHEL-VERSION-COMPATIBILITY.md)** - Version details (RHEL 7.9 - 9.7)
  - Compatibility matrix
  - Version-specific configurations
  - Troubleshooting by version

## ⚡ Emergency Recovery

If you need to restore quickly:

```bash
# On rescue VM after mounting
chroot /mnt/rescue
dracut --force --kver $(ls /boot/vmlinuz-* | sort | tail -1 | sed 's|/boot/vmlinuz-||')
exit
# Then unmount and restore
```

## 🐛 Troubleshooting

| Issue | Solution |
|-------|----------|
| Script can't detect disk | Check `lsblk` output, specify disk manually |
| LVM not activated | Run `vgscan && vgchange -ay` |
| /boot full | Script auto-removes old kernels |
| Wrong GRUB path | Script checks all common EFI paths |

See [RHEL-VERSION-COMPATIBILITY.md](RHEL-VERSION-COMPATIBILITY.md) for version-specific issues.

## 📝 Logs

### Verification Logs
- **Single server:** `/tmp/boot-verification-<hostname>-YYYYMMDD-HHMMSS.log`
- **Multi-server:** `./boot-verification-reports-YYYYMMDD-HHMMSS/`
  - `SUMMARY.txt` - Aggregated summary
  - `<server>.log` - Individual server logs
  - `<server>.status` - Status files

### Repair Logs
- **Repair script log:** `/tmp/rhel-boot-repair-YYYYMMDD-HHMMSS.log`
- **Azure boot diagnostics:** Portal → VM → Boot diagnostics

## 🔒 Security

- Scripts never commit credentials
- Passwords auto-generated with strong randomness
- No secrets in logs
- All operations logged for audit

## 🤝 Contributing

When updating scripts:
1. Test on RHEL 7.9, 8.x, and 9.x
2. Update version compatibility matrix
3. Add troubleshooting entries for new issues
4. Update this README

## 📞 Support

For issues or questions:
1. Check logs: `/tmp/rhel-boot-repair-*.log`
2. Review compatibility matrix
3. Check Azure boot diagnostics
4. Contact BAB CloudOps team

---

**Last Updated:** 2026-04-29  
**Maintainer:** BAB CloudOps Team  
**License:** Internal Use Only
