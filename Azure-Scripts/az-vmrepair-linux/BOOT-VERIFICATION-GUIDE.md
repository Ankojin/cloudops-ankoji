# RHEL Boot Health Verification Toolkit

Pre-reboot verification toolkit for RHEL servers to prevent kernel panic issues after patching.

## 📋 Problem Statement

After patching RHEL servers, rebooting without verification can cause:
- Kernel panic due to missing initramfs
- Boot failures from full /boot partitions
- Missing Hyper-V drivers in Azure VMs
- GRUB misconfigurations

**This toolkit prevents these issues by checking BEFORE reboot.**

---

## 🎯 What It Checks

### Critical Checks ✗
1. **Missing initramfs** - VM won't boot without it
2. **/boot disk space** - Must have > 100MB free
3. **Hyper-V drivers** - hv_storvsc, hv_vmbus required in Azure
4. **GRUB configuration** - Default kernel must exist

### Warning Checks ⚠
5. **Old kernels** - Identifies cleanup candidates
6. **/boot usage** - Warns at >70% full
7. **Azure dracut config** - Ensures future patches include drivers
8. **System update status** - Shows pending updates

---

## 📦 Files Included

| File | Purpose |
|------|---------|
| **verify-boot-health.sh** | Single server verification script |
| **run-multi-server-verification.sh** | Multi-server orchestration script |
| **servers.txt** | Sample server list file |
| **BOOT-VERIFICATION-GUIDE.md** | This guide |

---

## 🚀 Quick Start

### Single Server Check

```bash
# On the RHEL server
sudo bash verify-boot-health.sh
```

### Multiple Servers Check

```bash
# From your jumpbox/workstation
./run-multi-server-verification.sh servers.txt
```

---

## 📖 Detailed Usage

### 1. Single Server Verification

**On the RHEL server directly:**
```bash
# Download script
scp verify-boot-health.sh azureuser@server:/tmp/

# Run on server
ssh azureuser@server
sudo bash /tmp/verify-boot-health.sh

# Check results
cat /tmp/boot-verification-*.log
```

**Exit Codes:**
- `0` = All checks passed ✓
- `1` = Warnings found ⚠
- `2` = Critical issues found ✗

---

### 2. Multi-Server Verification

#### Step 1: Prepare Server List

Edit `servers.txt`:
```bash
# Production servers
server1.example.com
10.0.1.100
server3.example.com

# Comments and blank lines are ignored
```

#### Step 2: Configure SSH Access

```bash
# Set SSH user and key
export SSH_USER="azureuser"
export SSH_KEY="~/.ssh/id_rsa"

# Or use command line options
./run-multi-server-verification.sh servers.txt -u admin -k ~/.ssh/my-key.pem
```

#### Step 3: Run Verification

```bash
# Run on all servers in parallel
./run-multi-server-verification.sh servers.txt

# Limit parallel jobs
./run-multi-server-verification.sh servers.txt -j 10

# With custom timeout
./run-multi-server-verification.sh servers.txt -t 120
```

#### Step 4: Review Results

```bash
# Summary report
cat boot-verification-reports-*/SUMMARY.txt

# Individual server logs
cat boot-verification-reports-*/server1.example.com.log
```

---

## 📊 Sample Output

### Single Server - All Clear ✓
```
[OK] /boot has sufficient space (45% used)
[OK] initramfs exists for 5.14.0-611.49.1.el9_7.x86_64 (192M)
[OK] Critical driver found: hv_storvsc
[OK] Critical driver found: hv_vmbus
[OK] Default kernel has initramfs

✓ NO ISSUES FOUND - Safe to reboot
```

### Single Server - Issues Found ✗
```
[ERROR] /boot is 92% full - CRITICAL! Clean up required before reboot
[ERROR] MISSING initramfs for 5.14.0-611.49.1.el9_7.x86_64
[ERROR] CRITICAL driver MISSING: hv_storvsc - VM may not boot!

✗ 3 ISSUE(S) FOUND - DO NOT REBOOT
```

### Multi-Server Summary
```
========================================
Multi-Server Boot Verification Summary
========================================
Total Servers: 15

Results:
  ✓ Success:  10
  ⚠ Warnings: 3
  ✗ Critical: 2
  ⨯ Failed:   0

========================================
✓ SAFE TO REBOOT (10 servers):
========================================
  ✓ server1.example.com (warnings: 0)
  ✓ server2.example.com (warnings: 1)
  ...

========================================
✗ DO NOT REBOOT (2 servers):
========================================
  ✗ server13.example.com (CRITICAL ISSUES: 3)
    Critical errors:
      [ERROR] /boot is 95% full - CRITICAL!
      [ERROR] MISSING initramfs for kernel
      [ERROR] CRITICAL driver MISSING: hv_storvsc
```

---

## 🔧 Fixing Issues

### Issue 1: /boot Full

**Problem:**
```
[ERROR] /boot is 92% full - CRITICAL!
```

**Solution:**
```bash
# List kernels by age
ls -lt /boot/vmlinuz-*

# Remove oldest kernel (keep current and one backup)
sudo yum remove kernel-3.10.0-1160.el7.x86_64

# Or remove old rescue kernels
sudo rm -f /boot/*rescue*

# Verify space
df -h /boot
```

---

### Issue 2: Missing initramfs

**Problem:**
```
[ERROR] MISSING initramfs for 5.14.0-611.49.1.el9_7.x86_64
```

**Solution:**
```bash
# Rebuild initramfs
sudo dracut --force --kver 5.14.0-611.49.1.el9_7.x86_64

# Verify creation
ls -lh /boot/initramfs-5.14.0-611.49.1.el9_7.x86_64.img

# Check Hyper-V drivers included
sudo lsinitrd /boot/initramfs-5.14.0-611.49.1.el9_7.x86_64.img | grep hv_
```

---

### Issue 3: Missing Hyper-V Drivers

**Problem:**
```
[ERROR] CRITICAL driver MISSING: hv_storvsc - VM may not boot!
```

**Solution:**
```bash
# Create Azure dracut config
sudo tee /etc/dracut.conf.d/azure.conf <<EOF
add_drivers+=" hv_storvsc hv_vmbus hv_netvsc hv_utils hv_balloon "
hostonly="no"
EOF

# Rebuild initramfs for current kernel
sudo dracut --force

# Verify drivers
sudo lsinitrd | grep hv_
```

---

### Issue 4: GRUB Misconfiguration

**Problem:**
```
[ERROR] Default kernel MISSING initramfs - CRITICAL!
```

**Solution:**
```bash
# Set correct default kernel
sudo grubby --set-default /boot/vmlinuz-5.14.0-611.49.1.el9_7.x86_64

# Regenerate GRUB config
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# For UEFI systems
sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg

# Verify
sudo grubby --default-kernel
```

---

## 🎭 Use Cases

### Use Case 1: Pre-Reboot Verification After Patching

**Scenario:** You patched 50 RHEL servers last week, need to verify before reboot.

```bash
# 1. Create server list
cat > patched-servers.txt <<EOF
server1.example.com
server2.example.com
# ... add all 50 servers
EOF

# 2. Run verification on all
./run-multi-server-verification.sh patched-servers.txt -j 10

# 3. Review summary
cat boot-verification-reports-*/SUMMARY.txt

# 4. Fix critical servers
# (use fix-rhel-boot-azure.sh for servers with issues)

# 5. Reboot safe servers
for server in $(grep "^  ✓" boot-verification-reports-*/SUMMARY.txt | awk '{print $2}'); do
    ssh $server "sudo reboot"
done
```

---

### Use Case 2: Continuous Monitoring

**Scenario:** Run weekly checks to catch issues before they cause problems.

```bash
# Create cron job on jumpbox
crontab -e

# Add weekly check every Sunday at 2 AM
0 2 * * 0 /path/to/run-multi-server-verification.sh /path/to/servers.txt

# Email results
0 2 * * 0 /path/to/run-multi-server-verification.sh servers.txt && \
    mail -s "Weekly Boot Health Report" admin@example.com < boot-verification-reports-*/SUMMARY.txt
```

---

### Use Case 3: Pre-Maintenance Window Validation

**Scenario:** Validate all servers before scheduled maintenance window.

```bash
# T-24 hours: Run verification
./run-multi-server-verification.sh prod-servers.txt

# Review and fix issues
./fix-rhel-boot-azure.sh  # on servers with issues

# T-1 hour: Re-verify
./run-multi-server-verification.sh prod-servers.txt

# Maintenance window: Reboot with confidence
```

---

## 🔍 Advanced Options

### Parallel Execution

```bash
# Run 20 checks in parallel (faster for large environments)
./run-multi-server-verification.sh servers.txt -j 20

# Install GNU parallel for better performance
sudo yum install parallel
```

### Custom SSH Configuration

```bash
# Use specific SSH key
./run-multi-server-verification.sh servers.txt -k ~/.ssh/prod-key.pem

# Use different username
./run-multi-server-verification.sh servers.txt -u root

# Increase timeout for slow connections
./run-multi-server-verification.sh servers.txt -t 300
```

### Filtering and Reporting

```bash
# Check only servers with critical issues
grep "CRITICAL" boot-verification-reports-*/SUMMARY.txt

# Get list of servers safe to reboot
grep "✓" boot-verification-reports-*/SUMMARY.txt | awk '{print $2}'

# Count servers by status
grep -c "SUCCESS" boot-verification-reports-*/*.status
```

---

## 🛡️ Best Practices

### 1. Before Patching
- ✅ Take VM snapshots
- ✅ Enable boot diagnostics
- ✅ Document current kernel version

### 2. After Patching (Before Reboot)
- ✅ Run boot verification
- ✅ Fix critical issues
- ✅ Review warnings
- ✅ Plan rollback procedure

### 3. During Reboot
- ✅ Monitor serial console
- ✅ Check boot diagnostics
- ✅ Have rescue plan ready

### 4. After Reboot
- ✅ Verify services started
- ✅ Check kernel version: `uname -r`
- ✅ Verify Hyper-V drivers: `lsmod | grep hv_`

---

## 📝 Output Files

### Multi-Server Reports Directory Structure
```
boot-verification-reports-20260429-140530/
├── SUMMARY.txt                          # Summary report
├── server1.example.com.log              # Detailed log
├── server1.example.com.status           # Status file
├── server2.example.com.log
├── server2.example.com.status
└── ...
```

### Single Server Log Location
```
/tmp/boot-verification-<hostname>-YYYYMMDD-HHMMSS.log
```

---

## 🐛 Troubleshooting

### Problem: SSH Connection Fails

```bash
# Check SSH connectivity manually
ssh -v azureuser@server

# Verify SSH key permissions
chmod 600 ~/.ssh/id_rsa

# Test with password authentication
./run-multi-server-verification.sh servers.txt -u admin
# (will prompt for password)
```

### Problem: Permission Denied

```bash
# Ensure user has sudo access
ssh server "sudo whoami"

# Or run script as root
./run-multi-server-verification.sh servers.txt -u root
```

### Problem: Script Not Found

```bash
# Verify script location
ls -l verify-boot-health.sh

# Ensure both scripts are in same directory
ls -l run-multi-server-verification.sh verify-boot-health.sh
```

---

## 🔗 Related Tools

- **[fix-rhel-boot-azure.sh](fix-rhel-boot-azure.sh)** - Repair boot issues on rescue VM
- **[RHEL-BOOT-REPAIR-GUIDE.md](RHEL-BOOT-REPAIR-GUIDE.md)** - Complete repair workflow
- **[RHEL-VERSION-COMPATIBILITY.md](RHEL-VERSION-COMPATIBILITY.md)** - Version-specific details

---

## 💡 Tips

1. **Run verification BEFORE scheduling reboot windows**
2. **Keep /boot at < 70% full as best practice**
3. **Always keep 2-3 kernel versions** (current + backup)
4. **Enable Azure boot diagnostics** for all VMs
5. **Test in dev/staging first** before production
6. **Document any custom kernel parameters**
7. **Use GNU parallel** for faster multi-server checks

---

## 📞 Support

For issues or questions:
1. Check individual server logs in output directory
2. Review error messages in SUMMARY.txt
3. Consult RHEL-VERSION-COMPATIBILITY.md for version-specific issues
4. Contact BAB CloudOps team

---

**Last Updated:** 2026-04-29  
**Maintainer:** BAB CloudOps Team  
**License:** Internal Use Only
