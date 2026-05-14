# Recovery from Failed Image Generalization

## Problem
You created an image, but VMs deployed from it fail with:
```
OS Provisioning for VM 'test-sysprep' did not finish in the allotted time.
However, the VM guest agent was detected running. This suggests the guest OS
has not been properly prepared to be used as a VM image.
```

**Root Cause**: The image was not properly generalized. Sysprep didn't complete successfully.

---

## What Went Wrong

The original `Clone-And-Generalize-AVD.ps1` script had critical bugs in the sysprep step:

1. ❌ **Used `-Wait` with sysprep** - This failed because sysprep shuts down the VM
2. ❌ **Only waited 90 seconds** - Sysprep takes 5-15 minutes
3. ❌ **Didn't verify VM shutdown** - Script continued before sysprep completed
4. ❌ **No generalization verification** - Didn't check if VM was actually generalized

**Result**: Image contains:
- Original computer name
- Domain membership
- AVD agents (maybe)
- Non-generalized Windows installation

---

## Immediate Fix (Step-by-Step)

### Step 1: Verify the Problem

```powershell
cd C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\BAB_CloudOps-Ankoji\Azure-Scripts\sysprep

# Run verification script
.\Verify-ImageGeneralization.ps1 -VMName "test-sysprep" -Verbose
```

**Expected output**: VM will show it has OSProfile (NOT generalized)

### Step 2: Delete Failed Resources

```powershell
# 1. Delete the failed test VM
Remove-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "test-sysprep" -Force

# Wait for deletion
Start-Sleep -Seconds 30

# 2. Delete associated resources (NIC, disk, etc.)
Get-AzResource -ResourceGroupName "bab-vdi-avd-weeu-rg-01" | 
    Where-Object { $_.Name -like "*test-sysprep*" } |
    Remove-AzResource -Force

# 3. Verify the bad image version
.\Verify-ImageGeneralization.ps1
```

### Step 3: Delete the Bad Image Version

```powershell
# Option A: Interactive deletion
.\Verify-ImageGeneralization.ps1 -DeleteFailedImage

# Option B: Direct deletion (if you know the version)
Remove-AzGalleryImageVersion `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -GalleryImageDefinitionName "bab-w10-avd-img" `
    -Name "2026.0421.1430" `  # Replace with your failed version
    -Force
```

### Step 4: Delete the Clone VM (if it exists)

```powershell
# If the cloned VM used for image creation still exists, delete it
$cloneVMName = "BABAVDSHDTA-1-GoldenImage"  # Or whatever you named it

Remove-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name $cloneVMName -Force
Get-AzResource -ResourceGroupName "bab-vdi-avd-weeu-rg-01" | 
    Where-Object { $_.Name -like "*$cloneVMName*" } |
    Remove-AzResource -Force
```

### Step 5: Re-create Image with FIXED Script

The script has been fixed. Now run it again:

```powershell
# Use the FIXED script
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage-v2" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -ImageDefinitionName "bab-w10-avd-img" `
    -Location "westeurope" `
    -ReplicaRegions @("swedencentral") `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -CloneDiskType "StandardSSD_LRS" `
    -NetworkSecurityGroupId "/subscriptions/cb801de6-404a-4e76-8e9a-475206cbc2e5/resourceGroups/bab-vdi-devbox-swec-rg-01/providers/Microsoft.Network/networkSecurityGroups/ad-join-deny" `
    -Verbose
```

**What's different now?**
- ✅ Sysprep runs WITHOUT `-Wait`
- ✅ Script monitors VM power state (waits up to 20 minutes)
- ✅ Verifies VM shut down completely
- ✅ Properly runs `Set-AzVM -Generalized`
- ✅ Verifies generalization before creating image

**Expected timeline**:
- Snapshot: 5 minutes
- Clone creation: 10 minutes
- Preparation: 5 minutes
- **Sysprep: 10-15 minutes** (this is the critical part!)
- Image creation: 10 minutes
- **Total: ~45 minutes**

### Step 6: Verify New Image

```powershell
# Wait for image creation to complete, then verify
.\Verify-ImageGeneralization.ps1 -VMName "BABAVDSHDTA-1-GoldenImage-v2"
```

**Expected output**:
```
✅ OSProfile is NULL: VM IS GENERALIZED
```

### Step 7: Test Deploy from New Image

```powershell
# Deploy a test VM from the new image version via Azure Portal
# OR use this PowerShell:

$imageVersion = Get-AzGalleryImageVersion `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -GalleryImageDefinitionName "bab-w10-avd-img" |
    Sort-Object -Property PublishingProfile.PublishedDate -Descending |
    Select-Object -First 1

Write-Host "Latest image version: $($imageVersion.Name)"
Write-Host "Image ID: $($imageVersion.Id)"

# Deploy via Portal using this image ID
```

**Deploy Test VM**:
1. Azure Portal → Virtual Machines → Create
2. Image Source: Shared Image Gallery
3. Select: `bab_avd_shared_win10_gallery/bab-w10-avd-img` (latest version)
4. Name: `test-sysprep-v2`
5. Size: `Standard_D4s_v5`
6. Disk: `StandardSSD_LRS`
7. **Do NOT join domain during deployment**
8. Create

**Wait 5-10 minutes** for VM creation

### Step 8: Verify Test VM Success

```powershell
# Check VM status
Get-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "test-sysprep-v2" -Status

# Should show:
# ProvisioningState: Succeeded
# PowerState: running
```

If successful, you'll see:
- ✅ VM provisions successfully
- ✅ No "OS Provisioning" errors
- ✅ VM shows new computer name (not the original source VM name)
- ✅ VM is not domain-joined
- ✅ VM has no AVD agents

### Step 9: Configure Test VM

```powershell
# Now run post-configuration
$domainPwd = ConvertTo-SecureString "YourPassword" -AsPlainText -Force

.\Configure-AVD-SessionHost.ps1 `
    -VMName "test-sysprep-v2" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -DomainJoinPassword $domainPwd `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Verbose
```

### Step 10: Verify in Host Pool

```powershell
# Check session host registered successfully
Get-AzWvdSessionHost `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool" |
    Where-Object { $_.Name -like "*test-sysprep-v2*" }
```

If you see status `Available` - **SUCCESS!** 🎉

---

## What Was Fixed in the Script

### Before (BROKEN):
```powershell
# WRONG - Used -Wait with a process that shuts down the VM
Start-Process "Sysprep.exe" -ArgumentList "..." -Wait

# WRONG - Only waited 90 seconds
Start-Sleep -Seconds 90

# WRONG - Forced stop without checking if sysprep completed
Stop-AzVM -Name $VM -Force
```

### After (FIXED):
```powershell
# CORRECT - Fire and forget (VM will shutdown when done)
Start-Process "Sysprep.exe" -ArgumentList "..." -NoNewWindow

# CORRECT - Monitor VM power state for up to 20 minutes
while ($checkCount -lt $maxChecks) {
    Start-Sleep -Seconds 30
    $powerState = Get-AzVM ... -Status
    if ($powerState -eq "PowerState/stopped") { break }
}

# CORRECT - Only deallocate after confirmed shutdown
if ($powerState -eq "PowerState/stopped") {
    Stop-AzVM -Name $VM -Force
}

# CORRECT - Verify generalization
Set-AzVM -Name $VM -Generalized
Start-Sleep -Seconds 10
$vmInfo = Get-AzVM -Name $VM
if ($vmInfo.OSProfile) {
    Write-Warning "Generalization incomplete!"
}
```

---

## Prevention for Future

### ✅ Always verify images before deploying to production:
```powershell
.\Verify-ImageGeneralization.ps1
```

### ✅ Test with ONE VM first:
1. Create image
2. Deploy test VM
3. Verify provisioning succeeds
4. Run post-configuration
5. Verify AVD registration
6. Only then deploy production VMs

### ✅ Monitor sysprep logs:
If sysprep fails, check on the source VM:
```powershell
# Connect to VM and check
Get-Content C:\Windows\System32\Sysprep\Panther\setuperr.log -Tail 50
```

### ✅ Don't rush the process:
- Sysprep takes 10-15 minutes
- Image replication takes 10-15 minutes
- **Total: ~45-60 minutes** for the complete process

---

## Quick Command Reference

```powershell
# 1. Verify current state
.\Verify-ImageGeneralization.ps1

# 2. Delete failed VM
Remove-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "test-sysprep" -Force

# 3. Delete bad image version
.\Verify-ImageGeneralization.ps1 -DeleteFailedImage

# 4. Create new image (FIXED script)
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage-v2" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Verbose

# 5. Verify new image
.\Verify-ImageGeneralization.ps1 -VMName "BABAVDSHDTA-1-GoldenImage-v2"

# 6. Deploy test VM (Portal or ARM template)

# 7. Configure test VM
.\Configure-AVD-SessionHost.ps1 `
    -VMName "test-sysprep-v2" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -DomainJoinPassword (ConvertTo-SecureString "..." -AsPlainText -Force) `
    -HostPoolName "bab-avd-hostpool" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5"
```

---

## FAQ

**Q: Can I fix the existing clone VM instead of recreating?**

A: No. Once sysprep fails or is incomplete, you must start over. The VM is in an inconsistent state.

**Q: How long should I wait for sysprep?**

A: The fixed script waits up to 20 minutes. Normal sysprep takes 10-15 minutes.

**Q: Can I skip the clone and sysprep the source VM directly?**

A: **NO! NEVER!** This will destroy your source VM. Always clone first.

**Q: What if sysprep keeps failing?**

A: Check these:
1. Source VM has no AVD agents before cloning
2. VM is not domain-joined during sysprep
3. C:\Windows\System32\Sysprep\Panther\setuperr.log for errors
4. Ensure VM has enough disk space (>10GB free)

**Q: The script says "Sysprep completed" but image still fails?**

A: The old script lied! It said "completed" even if sysprep was still running. The fixed script actually monitors the VM shutdown.

---

**Next**: Run Step 1-10 above to recover and create a working image! 🚀
