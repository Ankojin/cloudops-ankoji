#!/bin/bash
# =====================================================
# Batch Security Agent & VMware Tools Removal Script
# RHEL 7 / 8 / 9
#
# Removes:
#   - Trend Micro Deep Security (ds_agent)
#   - Imperva RAgent
#   - Fidelis Endpoint / Protect
#   - VMware Tools
# =====================================================

LOG="/var/log/security-agent-removal.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

# Root check
if [[ $EUID -ne 0 ]]; then
  log "ERROR: Must run as root"
  exit 1
fi

log "===== Starting Security Agent & VMware Tools Removal ====="

############################################
# 1. TREND MICRO DEEP SECURITY
############################################
log "---- Removing Trend Micro Deep Security ----"

systemctl stop ds_agent 2>/dev/null || true
systemctl disable ds_agent 2>/dev/null || true

if rpm -q ds_agent >/dev/null 2>&1; then
  log "Uninstalling ds_agent RPM"
  rpm -e ds_agent || rpm -e --noscripts ds_agent || log "Failed to remove ds_agent"
else
  log "ds_agent not installed"
fi

rm -rf /opt/ds_agent /var/opt/ds_agent /var/log/ds_agent

############################################
# 2. IMPERVA RAGENT
############################################
log "---- Removing Imperva RAgent ----"

if [[ -x /opt/imperva/ragent/bin/rainit ]]; then
  /opt/imperva/ragent/bin/rainit stop || true
  log "Imperva rainit stop executed"
else
  log "Imperva rainit not found"
fi

pkill -f "/opt/imperva/installer/bin/ragentinstwd" || true
pkill -f "/opt/imperva/installer/bin/ragentinst" || true

for svc in ragentinst ragent; do
  if systemctl list-unit-files | grep -q "$svc"; then
    log "Stopping & disabling $svc"
    systemctl stop $svc 2>/dev/null || true
    systemctl disable $svc 2>/dev/null || true
    systemctl mask $svc 2>/dev/null || true
  else
    log "$svc service not present"
  fi
done

rpm -qa | grep -i imperva | while read -r pkg; do
  log "Removing Imperva package: $pkg"
  rpm -e "$pkg" || rpm -e --noscripts "$pkg" || log "Failed to remove $pkg"
done

rm -rf /opt/imperva

############################################
# 3. FIDELIS ENDPOINT
############################################
log "---- Removing Fidelis Endpoint ----"

for svc in endpoint.service protect.service; do
  systemctl stop $svc 2>/dev/null || true
  systemctl disable $svc 2>/dev/null || true
done

rpm -qa | grep -i fidelis | while read -r pkg; do
  log "Removing Fidelis package: $pkg"
  rpm -e "$pkg" || rpm -e --noscripts "$pkg" || log "Failed to remove $pkg"
done

rm -rf /home/ansadmin/fidelis /usr/Fidelis /fidelisprotect.log

############################################
# 4. VMWARE TOOLS
############################################
log "---- Removing VMware Tools ----"

if [[ -x /usr/bin/vmware-uninstall-tools.pl ]]; then
  log "vmware-uninstall-tools.pl found, executing"
  /usr/bin/vmware-uninstall-tools.pl >> "$LOG" 2>&1 || log "VMware Tools uninstall returned non-zero (continuing)"
else
  log "VMware Tools not installed or uninstall script missing"
fi

# Remove open-vm-tools packages (handle dependencies)
if rpm -q open-vm-tools-desktop >/dev/null 2>&1; then
  log "Removing open-vm-tools-desktop first (dependency)"
  rpm -e open-vm-tools-desktop 2>/dev/null || rpm -e --noscripts open-vm-tools-desktop 2>/dev/null || log "Failed to remove open-vm-tools-desktop"
fi

if rpm -q open-vm-tools >/dev/null 2>&1; then
  log "Removing open-vm-tools"
  rpm -e open-vm-tools 2>/dev/null || rpm -e --noscripts open-vm-tools 2>/dev/null || yum remove -y open-vm-tools 2>/dev/null || log "Failed to remove open-vm-tools (may have dependencies)"
fi

# Cleanup any remaining VMware packages
rpm -qa | grep -Ei "vmware-tools" | while read -r pkg; do
  log "Removing VMware package: $pkg"
  rpm -e "$pkg" || rpm -e --noscripts "$pkg" || log "Failed to remove $pkg"
done

rm -rf /etc/vmware /usr/lib/vmware /var/lib/vmware

############################################
# FINAL CLEANUP
############################################
systemctl daemon-reload
systemctl reset-failed

log "Active remnants check:"
ps -ef | egrep "ds_agent|ragent|fidelis|vmware" | grep -v grep || log "No running processes found"

lsmod | egrep -i "trend|fidelis|vmw" || log "No related kernel modules loaded"

log "===== Removal Completed Successfully ====="
exit 0