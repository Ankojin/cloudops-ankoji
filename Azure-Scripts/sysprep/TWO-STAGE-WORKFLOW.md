# Two-Stage AVD Image Creation Workflow

This workflow splits image creation into two stages, allowing validation between sysprep and generalization.

## Why Use Two-Stage Approach?

**Benefits:**
- ✅ Verify sysprep completed successfully before point of no return
- ✅ Option to restart VM for additional changes if needed
- ✅ Troubleshoot sysprep issues without starting over
- ✅ Manual validation of VM state before generalization
- ✅ Safer workflow for production environments

**Single-stage approach (original script):**
- Faster but no validation checkpoint
- VM immediately generalized after sysprep
- Cannot restart VM if issues found

---

## Stage 1: Clone and Sysprep

**Script:** `Clone-And-Sysprep-AVD.ps1`

**What it does:**
1. Creates snapshot of source VM (backup)
2. Clones VM to new name
3. Prepares clone (cleanup, remove agents, optimizations)
4. Runs sysprep
5. **STOPS** when VM shuts down

**VM State After Stage 1:**
- ✅ Sysprepped (generalized Windows OS)
- ❌ NOT generalized in Azure (can still restart if needed)
- ✅ Stopped/deallocated
- ✅ Ready for validation

### Example Usage:

```powershell
.\Clone-And-Sysprep-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-Prepared" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -CloneVMSize "Standard_D4s_v5" `
    -CloneDiskType "StandardSSD_LRS" `
    -Verbose
```

**Optional Parameters:**
- `-NetworkSecurityGroupId` - Attach NSG to prevent domain join during prep
- `-SkipSnapshot` - Skip snapshot creation
- `-SkipPreparation` - Skip VM cleanup (use if manually prepared)

---

## Validation Checkpoint (Between Stages)

**Before proceeding to Stage 2, verify:**

### 1. Check VM stopped successfully
```powershell
Get-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -Name "BABAVDSHDTA-1-Prepared" -Status | 
    Select-Object Name, PowerState, ProvisioningState
```

**Expected:** `PowerState: VM deallocated`

### 2. Check Boot Diagnostics
1. Go to Azure Portal
2. Navigate to VM: `BABAVDSHDTA-1-Prepared`
3. Click **Boot diagnostics**
4. Look for sysprep completion messages (no errors)

### 3. Check Transcript Logs
```powershell
# Review logs in .\logs\ folder
Get-Content ".\logs\AVD-Sysprep-Transcript-*.log" -Tail 50
```

**Look for:**
- ✅ "VM stopped - Sysprep completed!"
- ✅ "Sysprep Process Complete"
- ❌ No error messages

### 4. Optional: Test Boot (if unsure)
```powershell
# ONLY if you need to verify or make changes
# WARNING: Booting will require re-running sysprep

# Start VM
Start-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -Name "BABAVDSHDTA-1-Prepared"

# Verify settings, make changes if needed

# Re-run sysprep when done
Invoke-AzVMRunCommand -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -VMName "BABAVDSHDTA-1-Prepared" `
    -CommandId 'RunPowerShellScript' `
    -ScriptString 'C:\Windows\System32\Sysprep\Sysprep.exe /oobe /generalize /shutdown /mode:vm'
```

---

## Stage 2: Generalize and Create Image

**Script:** `Generalize-And-CreateImage-AVD.ps1`

**What it does:**
1. Verifies VM is stopped
2. Marks VM as generalized in Azure (`Set-AzVM -Generalized`)
3. Creates Shared Image Gallery version
4. Replicates to target regions

**VM State After Stage 2:**
- ✅ Generalized in Azure (**IRREVERSIBLE**)
- ❌ Cannot be started anymore
- ✅ Image version created in gallery
- ✅ Ready for deployment

### Example Usage:

```powershell
.\Generalize-And-CreateImage-AVD.ps1 `
    -VMName "BABAVDSHDTA-1-Prepared" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -ImageDefinitionName "bab-w10-avd-img" `
    -ReplicaRegions @("swedencentral", "northeurope") `
    -Verbose
```

**Optional Parameters:**
- `-Location` - Primary region (default: westeurope)
- `-ReplicaRegions` - Additional regions for replication

---

## Complete Workflow Example

```powershell
# ========================================
# STAGE 1: Clone and Sysprep
# ========================================

.\Clone-And-Sysprep-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVD-W10-Golden-$(Get-Date -Format 'yyyyMMdd')" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -CloneVMSize "Standard_D4s_v5" `
    -CloneDiskType "StandardSSD_LRS" `
    -Verbose

# Wait for completion (5-20 minutes)
# Review logs and verify sysprep succeeded

# ========================================
# VALIDATION CHECKPOINT
# ========================================

# Check VM stopped
Get-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -Name "BABAVD-W10-Golden-$(Get-Date -Format 'yyyyMMdd')" -Status

# Review transcript
Get-Content ".\logs\AVD-Sysprep-Transcript-*.log" -Tail 100

# Check Azure Portal boot diagnostics for sysprep logs

# ========================================
# STAGE 2: Generalize and Create Image
# ========================================

# ONLY proceed if Stage 1 completed successfully
# This step is IRREVERSIBLE

.\Generalize-And-CreateImage-AVD.ps1 `
    -VMName "BABAVD-W10-Golden-$(Get-Date -Format 'yyyyMMdd')" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -ImageDefinitionName "bab-w10-avd-img" `
    -Verbose

# Wait for image creation (10-30 minutes)

# ========================================
# POST-IMAGE CREATION
# ========================================

# Verify image created
Get-AzGalleryImageVersion `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -GalleryImageDefinitionName "bab-w10-avd-img" |
    Sort-Object -Property Name -Descending |
    Select-Object -First 5

# Deploy session hosts from new image
# Use Configure-AVD-SessionHost.ps1 for post-deployment setup

# Clean up source VM (optional)
Remove-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -Name "BABAVD-W10-Golden-$(Get-Date -Format 'yyyyMMdd')" -Force
```

---

## Troubleshooting

### Stage 1 Issues

**Sysprep timeout (VM doesn't stop after 20 minutes):**
- Check boot diagnostics for sysprep errors
- Common causes: Antivirus running, third-party apps, Windows Update
- Manually connect to VM serial console to see sysprep progress

**Preparation script fails:**
```powershell
# Re-run preparation manually
Invoke-AzVMRunCommand -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -VMName "YourVMName" `
    -CommandId 'RunPowerShellScript' `
    -ScriptPath ".\prep-script.ps1"
```

### Stage 2 Issues

**VM has OSProfile after generalization:**
- Wait 30 seconds and retry `Set-AzVM -Generalized`
- Proceed with image creation anyway (usually works)

**Image creation fails:**
- Verify VM is deallocated: `Stop-AzVM -Force`
- Ensure VM was sysprepped successfully in Stage 1
- Check quota for image versions in Shared Image Gallery

### Rollback

**Before Stage 2 (VM not generalized):**
- ✅ Can restart VM and make changes
- ✅ Can re-run sysprep
- ✅ Snapshot exists for rollback

**After Stage 2 (VM generalized):**
- ❌ Cannot restart generalized VM
- ✅ Snapshot still exists for creating new VM
- ✅ Can delete failed image version and retry

---

## Comparison: Two-Stage vs Single-Stage

| Feature | Two-Stage | Single-Stage (original) |
|---------|-----------|-------------------------|
| **Validation checkpoint** | ✅ Yes (between stages) | ❌ No |
| **Can verify sysprep** | ✅ Yes | ⚠️ Only after generalization |
| **Can restart VM** | ✅ Yes (before Stage 2) | ❌ No |
| **Total time** | Same (~30-50 min) | Same (~30-50 min) |
| **Error recovery** | ✅ Easier | ⚠️ Must start over |
| **Production safety** | ✅ Higher | ⚠️ Lower |
| **Complexity** | Two scripts | One script |

---

## When to Use Each Approach

### Use Two-Stage:
- ✅ Production environments
- ✅ First time creating image
- ✅ Complex VM configurations
- ✅ Need manual validation
- ✅ Testing new configurations

### Use Single-Stage:
- ✅ Well-tested process
- ✅ Dev/test environments
- ✅ Automated pipelines
- ✅ Speed is priority
- ✅ Standard configurations

---

## Files Created

1. **Clone-And-Sysprep-AVD.ps1** - Stage 1 script
2. **Generalize-And-CreateImage-AVD.ps1** - Stage 2 script
3. **TWO-STAGE-WORKFLOW.md** - This guide
4. **Clone-And-Generalize-AVD.ps1** - Original single-stage script (still available)

---

## Next Steps

After image creation, use these scripts for deployment:

1. **Deploy VMs from image:** Use Azure Portal or PowerShell
2. **Configure session hosts:** `Configure-AVD-SessionHost.ps1`
3. **Bulk configuration:** `Batch-Configure-AVD.ps1`

See `COMPLETE-WORKFLOW.md` for full deployment guide.
