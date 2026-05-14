# Manual AVD Sysprep Guide

## 🎯 Quick Start

### Step 1: Copy Script to VM
1. **RDP** to your AVD VM (BABAVDSHDTA-1-Golden-v3 or v4)
2. Copy `Manual-Prep-And-Sysprep.ps1` to the VM desktop
3. Right-click **PowerShell** → **Run as Administrator**

### Step 2: Run the Script
```powershell
# Navigate to script location
cd C:\Users\<youruser>\Desktop

# Run with prompts (recommended first time)
.\Manual-Prep-And-Sysprep.ps1

# OR run fully automated
.\Manual-Prep-And-Sysprep.ps1 -AutoConfirm
```

### Step 3: What the Script Does
1. ✅ **Pre-flight checks** - domain status, logged-in users, sysprep count
2. ✅ **Domain unjoin** - registry-only (no DC contact needed)
3. ✅ **Delete user profiles** - all 33+ profiles will be removed
4. ✅ **Remove AppX packages** - cleans up user apps
5. ✅ **Clean temp files** - reduces image size
6. ✅ **Verification** - ensures VM is ready
7. ✅ **Sysprep** - with unattend.xml to avoid OOBE timeout

### Step 4: After Sysprep Shuts Down
**DO NOT start the VM!** Instead, run from your workstation:

```powershell
# Generalize the VM in Azure
Set-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -Name "BABAVDSHDTA-1-Golden-v3" `
    -Generalized

# Create image version
$vmId = (Get-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "BABAVDSHDTA-1-Golden-v3").Id
$imageVersion = "2026.$(Get-Date -Format 'MMdd.HHmm')"

New-AzGalleryImageVersion `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -GalleryImageDefinitionName "bab-w10-avd-img" `
    -Name $imageVersion `
    -Location "westeurope" `
    -SourceImageVMId $vmId `
    -TargetRegion @(@{Name='westeurope'; ReplicaCount=1}, @{Name='swedencentral'; ReplicaCount=1})
```

---

## 🔧 Advanced Options

### Skip Domain Unjoin (if already done)
```powershell
.\Manual-Prep-And-Sysprep.ps1 -SkipDomainUnjoin
```

### Skip Profile Cleanup (testing)
```powershell
.\Manual-Prep-And-Sysprep.ps1 -SkipProfileCleanup
```

### Skip Sysprep (just cleanup)
```powershell
.\Manual-Prep-And-Sysprep.ps1 -SkipSysprep
```

### Do Everything Except Sysprep (for testing)
```powershell
.\Manual-Prep-And-Sysprep.ps1 -SkipSysprep -AutoConfirm
# Then verify with Verify-VMState.ps1
# If good, restart VM and run with just sysprep
.\Manual-Prep-And-Sysprep.ps1 -SkipDomainUnjoin -SkipProfileCleanup
```

---

## ⚠️ Common Issues

### Issue: "VM is still domain-joined after running"
**Solution:** The script clears registry but requires a restart. Either:
- Let the script restart for you (choose "yes" when prompted)
- OR run script in two phases:
  ```powershell
  # Phase 1: Domain unjoin only
  .\Manual-Prep-And-Sysprep.ps1 -SkipProfileCleanup -SkipSysprep
  # [VM will restart]
  
  # Phase 2: After restart, continue
  .\Manual-Prep-And-Sysprep.ps1 -SkipDomainUnjoin
  ```

### Issue: "Sysprep count = 7 (limit reached)"
**Solution:** This VM is permanently corrupted. You MUST:
1. Delete this VM
2. Clone a fresh one from source
3. Run the manual script on the NEW clone

### Issue: "Users are logged in"
**Solution:** 
```powershell
# Disconnect all users first
quser  # See who's logged in
logoff <session-id>  # Log them off
```

### Issue: "Some profiles couldn't be deleted"
**Cause:** Profiles are locked/in-use
**Solution:**
1. Reboot the VM
2. Log in as local administrator (not domain user)
3. Run script again

---

## 📊 Expected Output

```
╔════════════════════════════════════════════════════════════╗
║  MANUAL AVD IMAGE PREPARATION AND SYSPREP                  ║
╚════════════════════════════════════════════════════════════╝

═══ PRE-FLIGHT CHECKS ═══

[1/5] Checking domain status...
  Domain-joined: True
  Domain: albtests.com

[2/5] Checking for logged-in users...
  ✓ No users logged in (good)

[3/5] Checking sysprep run count...
  Sysprep count: 7 / 3
  ❌ CRITICAL: Sysprep limit reached!

[4/5] Checking user profiles...
  User profiles found: 33
  Loaded profiles: 0

[5/5] Checking disk space...
  Free space: 45.23 GB

Proceed with preparation? (yes/no): yes

═══ STEP 1: FORCE DOMAIN UNJOIN ═══

VM is domain-joined to: albtests.com
Performing registry-only domain removal (no DC contact)...

  [1/7] Clearing TCP/IP domain parameters... ✓
  [2/7] Clearing Active ComputerName domain... ✓
  [3/7] Clearing ComputerName domain... ✓
  [4/7] Clearing LSA domain secrets... ✓
  [5/7] Clearing cached domain credentials... ✓
  [6/7] Disabling Netlogon service... ✓
  [7/7] Disabling Windows Update... ✓

  Registry changes applied: 3
  ⚠️  Restart required for domain unjoin to take effect!

Restart now? (yes/no): yes
Restarting in 10 seconds...
Re-run this script after restart to continue.

[VM RESTARTS]

[AFTER RESTART - RUN SCRIPT AGAIN]

═══ STEP 2: DELETE USER PROFILES ═══

Found 33 user profiles to remove

  [1/33] AkbSye-B ✓
  [2/33] MoaRag-B ✓
  [3/33] GaiAbu-B ✓
  ...
  [33/33] MUSR_MQADMIN ✓

  Summary:
    Removed: 33
    Skipped: 0 (loaded profiles)
    Failed: 0

═══ STEP 3: REMOVE APPX PACKAGES ═══

Found 47 AppX packages to remove

  [1/47] Microsoft.BingWeather ✓
  [2/47] Microsoft.GetHelp ✓
  ...

  Summary:
    Removed: 35
    Protected: 8 (system packages)
    Skipped: 4

═══ STEP 4: CLEAN TEMP FILES ═══

  Cleaning Windows Temp... ✓
  Cleaning Prefetch... ✓
  Cleaning Windows Update... ✓
  Cleaning Sysprep Panther... ✓
  Cleaning Windows Panther... ✓
  Clearing event logs... ✓ (157 logs)

  Cleaned 5 locations

═══ STEP 5: PRE-SYSPREP VERIFICATION ═══

  [1/4] Domain status... ✓ Workgroup
  [2/4] User profiles... ✓ None
  [3/4] Loaded profiles... ✓ None
  [4/4] Sysprep count... ⚠️  7/3 (last chance!)

  ✅ All checks passed - ready for sysprep!

═══ STEP 6: RUN SYSPREP ═══

Creating unattend.xml...
  ✓ Unattend.xml created at C:\Windows\System32\Sysprep\unattend.xml

⚠️  FINAL WARNING:
  • VM will shut down after sysprep completes
  • This process takes 5-15 minutes
  • DO NOT restart or power on the VM manually
  • After shutdown, generalize in Azure and create image

Start sysprep now? (yes/no): yes

Starting sysprep...
VM will shut down when complete.

[VM SHUTS DOWN AFTER 5-15 MINUTES]
```

---

## ✅ Success Checklist

After running the script:

- [ ] Script completed without errors
- [ ] VM shut down automatically (sysprep finished)
- [ ] Run `Set-AzVM -Generalized` from your workstation
- [ ] Create image version with `New-AzGalleryImageVersion`
- [ ] Test deploy a new VM from the image
- [ ] Verify OOBE doesn't appear (unattend.xml working)
- [ ] Verify VM joins domain (or workgroup) correctly

---

## 🆘 Emergency Recovery

If sysprep fails and VM won't boot:

1. **Restore from snapshot** (if you created one)
2. **OR clone from source again**
3. **Check logs:**
   - `C:\Windows\System32\Sysprep\Panther\setuperr.log`
   - `C:\Windows\System32\Sysprep\Panther\setupact.log`

Common sysprep errors:
- **"SYSPRP Package was installed for a user..."** → User profiles not deleted
- **"Trust relationship failed"** → Domain unjoin incomplete
- **"Generalization State = 7"** → Too many sysprep runs (VM corrupted)
