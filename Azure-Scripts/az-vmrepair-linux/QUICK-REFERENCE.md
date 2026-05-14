# RHEL Boot Health - Quick Reference Card

## 📋 Pre-Reboot Checklist

Before rebooting RHEL servers after patching:

- [ ] /boot has > 100MB free space
- [ ] All kernels have initramfs files
- [ ] Hyper-V drivers in initramfs (Azure VMs)
- [ ] GRUB default kernel is valid
- [ ] Azure dracut config exists
- [ ] No critical warnings from verification

## ⚡ Quick Commands

### Single Server Verification
```bash
sudo bash verify-boot-health.sh
```

### Multiple Servers
```bash
./run-multi-server-verification.sh servers.txt
```

### Check Results
```bash
# View summary
cat boot-verification-reports-*/SUMMARY.txt

# Check specific server
cat boot-verification-reports-*/server1.log
```

---

## 🔧 Quick Fixes

### Clean Up /boot
```bash
# Remove oldest kernel
sudo yum remove kernel-$(rpm -q kernel | sort -V | head -1 | sed 's/kernel-//')

# Or use DNF (RHEL 8/9)
sudo dnf remove --oldinstallonly
```

### Rebuild initramfs
```bash
# For specific kernel
sudo dracut --force --kver 5.14.0-611.49.1.el9_7.x86_64

# For current kernel
sudo dracut --force
```

### Add Azure Drivers
```bash
sudo tee /etc/dracut.conf.d/azure.conf <<EOF
add_drivers+=" hv_storvsc hv_vmbus hv_netvsc hv_utils hv_balloon "
hostonly="no"
EOF
sudo dracut --force
```

### Fix GRUB
```bash
# Regenerate config
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Set default kernel
sudo grubby --set-default /boot/vmlinuz-<version>
```

---

## 🚨 Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 0 | All OK | ✓ Safe to reboot |
| 1 | Warnings | ⚠ Review before reboot |
| 2 | Critical | ✗ Fix before reboot |

---

## 📊 Common Issues

| Issue | Check | Fix |
|-------|-------|-----|
| /boot full | `df -h /boot` | Remove old kernels |
| Missing initramfs | `ls /boot/initramfs-*` | `dracut --force --kver <version>` |
| No HV drivers | `lsinitrd \| grep hv_` | Add azure.conf, rebuild |
| Wrong default kernel | `grubby --default-kernel` | `grubby --set-default <path>` |

---

## 📁 Important Files

### Verification
```
verify-boot-health.sh              # Single server check
run-multi-server-verification.sh   # Multi-server check
servers.txt                        # Server list
```

### Repair
```
fix-rhel-boot-azure.sh            # Repair script
rescuvm-linux.ps1                 # Create rescue VM
restore-vm-from-rescue.ps1        # Restore VM
```

### Documentation
```
BOOT-VERIFICATION-GUIDE.md        # Verification guide
RHEL-BOOT-REPAIR-GUIDE.md         # Repair guide
RHEL-VERSION-COMPATIBILITY.md     # Version details
```

---

## 🎯 Decision Tree

```
After Patching
      ↓
Run Verification
      ↓
   Issues? ─────No─────→ ✓ Reboot
      │
     Yes
      ↓
  Critical?
      │
      ├──Yes──→ ✗ Fix First
      │          └→ Re-verify
      │             └→ Then Reboot
      │
      └──No───→ ⚠ Review
                 └→ Optional Fix
                    └→ Reboot
```

---

## 📞 Quick Help

### Get Help
```bash
# Script help
./verify-boot-health.sh --help
./run-multi-server-verification.sh --help

# View documentation
cat BOOT-VERIFICATION-GUIDE.md
cat RHEL-BOOT-REPAIR-GUIDE.md
```

### Check Logs
```bash
# Latest verification log
ls -lt /tmp/boot-verification-*.log | head -1

# Multi-server summary
find . -name "SUMMARY.txt" -type f
```

### Common Diagnostics
```bash
# Current kernel
uname -r

# Installed kernels
rpm -q kernel

# /boot space
df -h /boot

# Hyper-V modules loaded
lsmod | grep hv_

# Default boot kernel
grubby --default-kernel
```

---

## 💡 Pro Tips

1. **Run verification weekly** - Catch issues before they become problems
2. **Keep /boot < 70% full** - Best practice
3. **Maintain 2-3 kernels max** - Current + backup
4. **Enable boot diagnostics** - Essential for Azure VMs
5. **Test in dev first** - Always
6. **Document custom configs** - Kernel parameters, etc.
7. **Use GNU parallel** - Faster multi-server checks

---

## 🔗 Resources

| Resource | Location |
|----------|----------|
| Full Guides | `BOOT-VERIFICATION-GUIDE.md` |
| Repair Workflow | `RHEL-BOOT-REPAIR-GUIDE.md` |
| Version Matrix | `RHEL-VERSION-COMPATIBILITY.md` |
| Main README | `README.md` |

---

## 🆘 Emergency Contacts

```
Critical boot failure?
1. Check logs: /tmp/boot-verification-*.log
2. Try: fix-rhel-boot-azure.sh
3. Contact: BAB CloudOps Team
```

---

**Print this card** and keep it handy for patch day! 🖨️

**Last Updated:** 2026-04-29  
**Maintainer:** BAB CloudOps Team
