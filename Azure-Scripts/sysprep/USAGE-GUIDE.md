# AVD Clone and Generalization - Usage Guide

## Problem Statement
When deploying AVD VMs, you encounter this error:
```
OS Provisioning for VM 'BABAVDSHDTA-2' did not finish in the allotted time. 
However, the VM guest agent was detected running. This suggests the guest OS 
has not been properly prepared to be used as a VM image.
```

## Root Cause
The VM was not properly generalized using sysprep before being captured as an image.

## Solution
Use the `Clone-And-Generalize-AVD.ps1` script to properly prepare and generalize the VM.

---

## Prerequisites

1. **Azure PowerShell modules**:
   ```powershell
   Install-Module -Name Az.Compute -Force
   Install-Module -Name Az.Resources -Force
   Install-Module -Name Az.Network -Force
   ```

2. **Azure authentication**:
   ```powershell
   Connect-AzAccount
   ```

3. **Permissions**: Contributor role on the resource group

---

## Quick Start - Fix Your VM

**⚠️ IMPORTANT: Use a HEALTHY source VM!**
- ✅ Use VMs with `ProvisioningState=Succeeded` (like BABAVDSHDTA-1)
- ❌ Don't use failed VMs (like BABAVDSHDTA-2 with OSProvisioningClientError)

### Step 1: Run with Default Values (Dry Run First)
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
    -SubscriptionId "your-subscription-id-here" `
    -WhatIf
```

### Step 2: Execute the Full Process
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -ImageDefinitionName "bab-w10-avd-img" `
    -Location "westeurope" `
    -ReplicaRegions @("swedencentral") `
    -SubscriptionId "your-subscription-id-here" `
    -CloneDiskType "StandardSSD_LRS" `
    -NetworkSecurityGroupId "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/networkSecurityGroups/ad-join-deny" `
    -Verbose
```

---

## What the Script Does

**🔒 IMPORTANT: Your source VM is NEVER modified! It remains operational throughout the entire process.**

### Phase 1: Snapshot Creation (Can be skipped with `-SkipSnapshot`)
- Creates a snapshot of the **ORIGINAL, UNMODIFIED** source VM's OS disk
- Timestamp-based naming for tracking
- **Purpose**: True backup of the original state for rollback
- ✅ Source VM untouched

### Phase 2: VM Cloning
- Creates a new managed disk from the original source VM disk
  - **Disk Type**: StandardSSD_LRS by default (configurable)
  - **Size**: Same as source or custom via `-CloneVMSize`
- Creates new VM with copied configuration from source
- Creates new network interface
  - **Optional NSG**: Attach NSG to prevent domain join (recommended for domain-joined sources)
- **Result**: Separate clone VM ready for modification
- ✅ Source VM still running and unchanged

### Phase 3: Preparation of CLONE ONLY (Can be skipped with `-SkipPreparation`)
- **Runs ONLY on the cloned VM**, not the source
- Disables Windows Update on the clone
- Cleans temporary files and caches on the clone
- Removes AVD agents from the clone (properly using Get-Package, not Win32_Product)
- Clears sysprep history on the clone
- Enables CD/DVD-ROM on the clone (required for Azure)
- ✅ Source VM completely untouched

### Phase 4: Sysprep & Generalization of Clone
- Runs sysprep on the **CLONE** with AVD-specific flags: `/oobe /generalize /shutdown /mode:vm`
- Waits for proper shutdown of the clone
- Deallocates the cloned VM
- Generalizes the clone in Azure (marks as template)
- ✅ Source VM remains operational

### Phase 5: Shared Image Gallery
- Creates or updates gallery
- Creates or updates image definition
- Creates timestamped image version (YYYY.MMDD.HHmm format) from the generalized clone
- Replicates to specified regions
- ✅ Source VM can continue serving users

---

## Script Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `SourceVMName` | Yes | - | Name of existing AVD VM (working VM, not failed one) |
| `SourceResourceGroupName` | Yes | - | Resource group of source VM |
| `TargetVMName` | Yes | - | Name for the cloned VM |
| `SubscriptionId` | Yes | - | Azure subscription ID |
| `GalleryName` | No | bab_avd_shared_win10_gallery | Shared Image Gallery name |
| `ImageDefinitionName` | No | bab-w10-avd-img | Image definition name |
| `Location` | No | westeurope | Primary Azure region |
| `ReplicaRegions` | No | @("swedencentral") | Additional replication regions |
| `CloneVMSize` | No | Same as source | VM size for clone (e.g., Standard_D4s_v5) |
| `CloneDiskType` | No | StandardSSD_LRS | Disk type: Standard_LRS, StandardSSD_LRS, Premium_LRS |
| `NetworkSecurityGroupId` | No | - | NSG resource ID to prevent domain join |
| `SkipPreparation` | No | False | Skip clone VM prep (use if clone already prepared) |
| `SkipSnapshot` | No | False | Skip snapshot creation (not recommended) |
| `WhatIf` | No | False | Dry run mode - shows what would happen |
| `Verbose` | No | False | Detailed logging output |

---

## Advanced Usage Scenarios

### Scenario 1: Clone VM Already Prepared
If you've already run cleanup scripts manually on the clone:
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-2" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-2-Clone" `
    -SubscriptionId "your-sub-id" `
    -SkipPreparation
```

**Note**: This skips preparation of the clone, not the source. Source is never prepared anyway!

### Scenario 2: Quick Test (No Snapshot)
For testing in dev environment:
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-2" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-2-Clone" `
    -SubscriptionId "your-sub-id" `
    -SkipSnapshot
```

### Scenario 3: Custom VM Size and Disk Type
Create a smaller/larger clone with different disk type:
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
    -SubscriptionId "your-sub-id" `
    -CloneVMSize "Standard_D4s_v5" `
    -CloneDiskType "Premium_LRS"
```

### Scenario 4: Prevent Domain Join (Critical for Domain-Joined VMs)
Attach NSG to block domain communication during preparation:
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
    -SubscriptionId "your-sub-id" `
    -NetworkSecurityGroupId "/subscriptions/cb801de6-404a-4e76-8e9a-475206cbc2e5/resourceGroups/bab-vdi-devbox-swec-rg-01/providers/Microsoft.Network/networkSecurityGroups/ad-join-deny"
```
**Important**: 
- ✅ NSG is attached **only to the clone VM** during preparation
- ❌ NSG is **NOT included in the final image** (only the OS disk is captured)
- 🆕 New VMs deployed from the image will need their own network configuration

### Scenario 5: Multi-Region Replication
```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
    -SubscriptionId "your-sub-id" `
    -ReplicaRegions @("swedencentral", "northeurope", "uksouth")
```

---

## Disk Types Explained

| Disk Type | Performance | Cost | Use Case |
|-----------|-------------|------|----------|
| **StandardSSD_LRS** | Good | Moderate | **Recommended** - Default, best balance |
| Standard_LRS | Basic | Low | Dev/Test only |
| Premium_LRS | Excellent | High | Production workloads needing high IOPS |
| UltraSSD_LRS | Extreme | Very High | Mission-critical, latency-sensitive workloads |

**Why StandardSSD_LRS is default:**
- ✅ 99.9% availability SLA
- ✅ Good performance for AVD workloads
- ✅ Lower cost than Premium
- ✅ Better than Standard HDD for OS disks

---

## Troubleshooting

### Issue: "VM failed to deallocate"
**Solution**: Manually stop the VM in Azure Portal, then re-run with `-SkipPreparation -SkipSnapshot`

### Issue: "Image version already exists"
The script uses timestamp format (YYYY.MMDD.HHmm), so this is rare. If it happens:
- Wait 1 minute and retry
- Or manually delete the image version from the gallery

### Issue: Sysprep fails
**Check**:
1. Cloned VM is not domain-joined (should be in workgroup)
   - **Solution**: Use `-NetworkSecurityGroupId` parameter to attach NSG that blocks domain traffic
2. No pending Windows updates on the clone
3. Review sysprep logs on the **clone VM**: `C:\Windows\System32\Sysprep\Panther\setuperr.log`
4. Check if sysprep has been run too many times (Azure limit: 1001 times)

**Note**: If sysprep fails, your source VM is still safe and operational!

### Issue: Clone tries to join domain
**Solution**: 
```powershell
# Add NSG parameter to prevent domain join
-NetworkSecurityGroupId "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Network/networkSecurityGroups/ad-join-deny"
```
This blocks outbound traffic to domain controllers during preparation.

### Issue: Script hangs at "Waiting for VM shutdown"
**Solution**:
- Check Azure Portal for VM status
- If VM is stopped, manually deallocate it
- Re-run script with `-SkipPreparation -SkipSnapshot`

---

## Log Files

The script creates detailed logs in `.\logs\`:
- `AVD-Clone-YYYYMMDD.log` - Main log file
- `AVD-Clone-Transcript-YYYYMMDD-HHMMSS.log` - Full transcript

Review these if issues occur.

---

## Frequently Asked Questions (FAQ)

### Q: Does the image include the NSG?
**A: No.** The NSG is only attached to the clone VM's NIC during Steps 2-4 to prevent domain join while preparing the image. The final Shared Image Gallery image contains **only the generalized OS disk** - no networking components (NIC, NSG, IP config) are included.

### Q: Will new VMs deployed from the image have the NSG?
**A: No.** When deploying new AVD session hosts from the image, you'll create fresh network interfaces. You can attach whatever NSG you need at deployment time based on your production network security requirements.

### Q: Why use the NSG during cloning if it's not in the image?
**A: Prevention.** If the source VM was domain-joined, the clone might try to re-join the domain during the preparation phase. The NSG blocks domain controller traffic, ensuring the clone stays in a workgroup state for proper sysprep/generalization.

### Q: What VM size will be used for the image?
**A: The image captures the OS disk only** - not the VM size. When deploying from the image, you can choose any compatible VM size. The `-CloneVMSize` parameter only affects the temporary clone VM used to create the image.

### Q: What disk type is used in the image?
**A: StandardSSD_LRS by default** for the clone VM. However, the image is just the disk contents. When deploying new VMs from the image, you can choose any disk type (Standard_LRS, StandardSSD_LRS, Premium_LRS) for those deployments.

---

## After Image Creation

### Deploy New AVD Session Hosts

1. **Use Azure Portal**:
   - Navigate to your Host Pool
   - Add session hosts
   - Select your Shared Image Gallery image

2. **Use PowerShell**:
   ```powershell
   $imageId = "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{image-def}/versions/{version}"
   
   New-AzWvdSessionHost `
       -HostPoolName "your-hostpool" `
       -ResourceGroupName "your-rg" `
       -VMTemplate @{ImageReference = @{Id = $imageId}} `
       ...
   ```

---

## Best Practices

1. ✅ **Always run `-WhatIf` first** to preview changes
2. ✅ **Source VM safety**: Your source VM is NEVER modified and remains operational throughout
3. ✅ **Use healthy source VMs**: Clone from working VMs (ProvisioningState=Succeeded), not failed ones
4. ✅ **Attach NSG for domain-joined VMs**: Use `-NetworkSecurityGroupId` to prevent clone from re-joining domain
5. ✅ **Use StandardSSD_LRS**: Default disk type balances cost and performance (configurable)
6. ✅ **Keep snapshots** for at least 7 days for rollback capability
7. ✅ **Tag your images** with version info and deployment date after creation
8. ✅ **Test deployment** from new image before retiring old hosts
9. ✅ **Document** any custom software in the image in the gallery description
10. ✅ **Source VM can stay running** - it's completely untouched during the process
11. ⚠️ **Monitor disk costs** from snapshots and cloned VMs
12. ⚠️ **Clean up clone VM** after image creation (see Cleanup section)

---

## Cleanup

After successful image deployment:

```powershell
# Remove cloned VM (no longer needed)
Remove-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "BABAVDSHDTA-1-GoldenImage" -Force

# Remove cloned disk
Remove-AzDisk -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -DiskName "BABAVDSHDTA-1-GoldenImage-OsDisk" -Force

# Remove cloned NIC
Remove-AzNetworkInterface -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "BABAVDSHDTA-1-GoldenImage-nic" -Force

# Remove old snapshots (after 7+ days)
Get-AzSnapshot -ResourceGroupName "bab-vdi-avd-weeu-rg-01" | 
    Where-Object {$_.TimeCreated -lt (Get-Date).AddDays(-7)} |
    Remove-AzSnapshot -Force
```

**Note**: The NSG used during cloning is not deleted - it's reusable for future image creation.

---

## Support

For issues, check:
1. Script logs in `.\logs\`
2. Azure Activity Log in Portal
3. VM boot diagnostics
4. Sysprep logs in the VM

---

## Differences from Old Scripts

| Old Scripts | New Script |
|-------------|------------|
| ❌ Modifies source VM | ✅ Source VM never touched |
| ❌ Snapshot after modification | ✅ Snapshot before any changes |
| ❌ Uses failed VMs | ✅ Uses healthy VMs as source |
| ❌ No NSG support | ✅ NSG attachment to prevent domain join |
| ❌ Fixed disk type | ✅ Configurable disk type (StandardSSD_LRS default) |
| ❌ Fixed VM size | ✅ Optional custom VM size for clone |
| ❌ Hardcoded values | ✅ Fully parameterized |
| ❌ No logging | ✅ Comprehensive logging with Write-Log |
| ❌ No error handling | ✅ Try-catch with detailed errors |
| ❌ Arbitrary sleeps | ✅ Proper state polling with timeout |
| ❌ Win32_Product (slow) | ✅ Get-Package (fast and reliable) |
| ❌ No WhatIf support | ✅ Full WhatIf/ShouldProcess support |
| ❌ No multi-subscription | ✅ Context switching included |
| ❌ Manual steps | ✅ Fully automated end-to-end |
| ❌ No validation | ✅ Pre-flight checks and validation |
| ❌ Destroys source VM | ✅ Creates safe clone, keeps source |

---

## Summary

### What Makes This Script Safe?

✅ **Non-destructive workflow**:
- Source VM is **NEVER** modified
- Snapshot taken **BEFORE** any changes
- All modifications occur on a **separate clone**
- Source VM remains operational throughout
- Safe rollback via original snapshot

✅ **What's included in the final image**:
- Generalized OS disk only
- VM hardware configuration (size, etc.)
- Installed software and configurations

❌ **What's NOT included in the image**:
- Network configuration (NIC, IP, NSG)
- VM identity and secrets
- Domain membership
- NSG used during cloning (temporary only)

### Workflow Diagram

```
┌─────────────────────────────┐
│  Source VM (Running)        │ ← NEVER TOUCHED, STAYS OPERATIONAL
│  BABAVDSHDTA-1 (Healthy!)   │ ← Use WORKING VM, not failed one
└───────────┬─────────────────┘
            │
            ├──→ Step 1: Snapshot (unmodified backup)
            │
            ├──→ Step 2: Clone to new VM
            │              ↓
            │    ┌──────────────────────────────┐
            │    │  Clone VM                    │
            │    │  BABAVDSHDTA-1-GoldenImage   │
            │    │  + StandardSSD_LRS disk      │
            │    │  + NSG attached (no domain!) │
            │    └───────────┬──────────────────┘
            │                │
            │                ├──→ Step 3: Prepare (cleanup, remove agents)
            │                │    (NSG prevents domain re-join)
            │                │
            │                ├──→ Step 4: Sysprep & Generalize
            │                │
            │                └──→ Step 5: Create Image in Gallery
            │                              ↓
            │                    ┌──────────────────────┐
            │                    │ Generalized Image    │
            │                    │ Ready for Deployment │            │                    │ (OS disk ONLY)       │
            │                    │ No NIC, no NSG!      │            │                    └──────────────────────┘
            │
   Still Running & Unchanged!
   (Can be used to replace failed BABAVDSHDTA-2)
```

---

**Author**: BAB CloudOps Team  
**Last Updated**: April 2026  
**Version**: 2.0 - Fixed workflow to protect source VM

---

## 🎯 Recommended Production Command

**For domain-joined AVD VMs** (most common scenario):

```powershell
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "BABAVDSHDTA-1-GoldenImage" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -ImageDefinitionName "bab-w10-avd-img" `
    -Location "westeurope" `
    -ReplicaRegions @("swedencentral") `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -CloneDiskType "StandardSSD_LRS" `
    -NetworkSecurityGroupId "/subscriptions/cb801de6-404a-4e76-8e9a-475206cbc2e5/resourceGroups/bab-vdi-devbox-swec-rg-01/providers/Microsoft.Network/networkSecurityGroups/ad-join-deny" `
    -Verbose
```

**What this does:**
- ✅ Uses healthy source VM (BABAVDSHDTA-1)
- ✅ StandardSSD_LRS disk for clone (cost-effective)
- ✅ NSG prevents domain re-join
- ✅ Creates generalized golden image
- ✅ Source VM stays operational
