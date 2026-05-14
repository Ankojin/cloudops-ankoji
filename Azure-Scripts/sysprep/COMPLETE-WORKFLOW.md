# Complete AVD Deployment Workflow
## From Golden Image to Production Session Hosts

---

## Overview

This guide covers the complete end-to-end workflow for deploying Azure Virtual Desktop session hosts using a golden image approach.

### The Complete Process

```
┌─────────────────────────────────────────────────────────────┐
│  PHASE 1: CREATE GOLDEN IMAGE                               │
│  Script: Clone-And-Generalize-AVD.ps1                       │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
         Generalized Image in Gallery
                   ↓
┌─────────────────────────────────────────────────────────────┐
│  PHASE 2: DEPLOY VMs FROM IMAGE                             │
│  Method: Azure Portal / ARM Template / Bicep               │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
          Fresh VMs (not configured)
                   ↓
┌─────────────────────────────────────────────────────────────┐
│  PHASE 3: POST-CONFIGURATION                                │
│  Script: Configure-AVD-SessionHost.ps1                      │
│  - Domain Join                                               │
│  - Install AVD Agents                                        │
│  - Register with Host Pool                                   │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
      Production-Ready Session Hosts
```

---

## Phase 1: Create Golden Image

### 1.1 Prerequisites
- Working source VM (e.g., BABAVDSHDTA-1)
- Azure PowerShell modules installed
- Contributor access to resource groups

### 1.2 Create the Image

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

**Time**: ~15-30 minutes

**Result**: Generalized image in Shared Image Gallery

### 1.3 Verify Image Creation

```powershell
# Check image version
Get-AzGalleryImageVersion `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -GalleryImageDefinitionName "bab-w10-avd-img" |
    Sort-Object -Property PublishingProfile.PublishedDate -Descending |
    Select-Object -First 1
```

---

## Phase 2: Deploy VMs from Image

### 2.1 Option A: Deploy via Azure Portal

1. Navigate to **Azure Portal → Virtual Machines → Create**
2. Select **Shared Image Gallery** as image source
3. Choose your gallery: `bab_avd_shared_win10_gallery`
4. Select image definition: `bab-w10-avd-img`
5. Choose latest version
6. Configure:
   - **VM Size**: Standard_D4s_v5 or similar
   - **Disk Type**: StandardSSD_LRS
   - **Networking**: Select AVD subnet
   - **Do NOT attach NSG** (image prep NSG was temporary)
7. **Do NOT join domain** during deployment
8. Create the VM

### 2.2 Option B: Deploy via ARM Template (Recommended for Multiple VMs)

```json
{
  "type": "Microsoft.Compute/virtualMachines",
  "properties": {
    "hardwareProfile": {
      "vmSize": "Standard_D4s_v5"
    },
    "storageProfile": {
      "imageReference": {
        "id": "/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/bab_avd_shared_win10_gallery/images/bab-w10-avd-img/versions/{version}"
      },
      "osDisk": {
        "createOption": "FromImage",
        "managedDisk": {
          "storageAccountType": "StandardSSD_LRS"
        }
      }
    }
  }
}
```

### 2.3 Verify VM Deployment

```powershell
# Check VM status
Get-AzVM -ResourceGroupName "bab-vdi-avd-weeu-rg-01" -Name "BABAVDSHDTA-5" -Status
```

**Important**: VMs deployed from the image are NOT:
- Domain-joined
- AVD agent installed
- Registered with host pool

This is by design - configuration happens in Phase 3.

---

## Phase 3: Post-Deployment Configuration

### 3.1 Single VM Configuration

```powershell
# Get domain password
$domainPassword = ConvertTo-SecureString "YourPassword" -AsPlainText -Force

# Configure VM
.\Configure-AVD-SessionHost.ps1 `
    -VMName "BABAVDSHDTA-5" `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -DomainJoinPassword $domainPassword `
    -OUPath "OU=AVD,OU=Servers,DC=bankalbilad,DC=com,DC=sa" `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Verbose
```

**Time**: ~5-10 minutes per VM

### 3.2 Batch Configuration (Multiple VMs)

```powershell
# Configure multiple VMs at once
.\Batch-Configure-AVD.ps1 `
    -VMNames @("BABAVDSHDTA-5", "BABAVDSHDTA-6", "BABAVDSHDTA-7") `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Parallel `
    -MaxParallelJobs 3
```

### 3.3 Verify Configuration

```powershell
# Check session hosts in host pool
Get-AzWvdSessionHost `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool" |
    Select-Object Name, Status, LastHeartBeat, AllowNewSession |
    Format-Table -AutoSize
```

**Expected Status**: `Available`

---

## Complete End-to-End Example

### Scenario: Deploy 3 New Session Hosts

```powershell
# Step 1: Create golden image (one-time, or when updates needed)
.\Clone-And-Generalize-AVD.ps1 `
    -SourceVMName "BABAVDSHDTA-1" `
    -SourceResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -TargetVMName "AVD-GoldenImage-2026-04" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -CloneDiskType "StandardSSD_LRS" `
    -Verbose

# Wait for image creation to complete (~20 minutes)
# Get image ID
$image = Get-AzGalleryImageVersion `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -GalleryName "bab_avd_shared_win10_gallery" `
    -GalleryImageDefinitionName "bab-w10-avd-img" |
    Sort-Object -Property PublishingProfile.PublishedDate -Descending |
    Select-Object -First 1

Write-Host "Image ID: $($image.Id)"

# Step 2: Deploy 3 VMs from image (via Azure Portal or ARM template)
# VMs: BABAVDSHDTA-5, BABAVDSHDTA-6, BABAVDSHDTA-7

# Step 3: Configure all 3 VMs
$domainPassword = Read-Host "Domain password" -AsSecureString

.\Batch-Configure-AVD.ps1 `
    -VMNames @("BABAVDSHDTA-5", "BABAVDSHDTA-6", "BABAVDSHDTA-7") `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -DomainName "bankalbilad.com.sa" `
    -DomainJoinUserName "admin@bankalbilad.com.sa" `
    -HostPoolName "bab-avd-hostpool" `
    -HostPoolResourceGroup "bab-vdi-avd-weeu-rg-01" `
    -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5" `
    -Parallel `
    -Verbose

# Step 4: Verify
Get-AzWvdSessionHost `
    -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
    -HostPoolName "bab-avd-hostpool"
```

---

## Troubleshooting Guide

### Issue: VM deployment from image fails

**Check**:
1. Image version exists and is replicated to target region
2. Sufficient quota in subscription
3. Target subnet has available IPs

### Issue: Domain join fails in Phase 3

**Check**:
1. VM can reach domain controllers:
   ```powershell
   # Run on VM
   Test-NetConnection -ComputerName "bankalbilad.com.sa" -Port 389
   nltest /dsgetdc:bankalbilad.com.sa
   ```
2. DNS settings on VM NIC
3. Domain credentials are correct
4. OU path is valid (if specified)

### Issue: AVD agent installation fails

**Check**:
1. VM has internet connectivity
2. Download URLs are accessible
3. VM is not already registered to another host pool
4. Registration token is not expired

**Verify manually**:
```powershell
# Connect to VM
Get-Service -Name "RDAgentBootLoader", "RDAgent"

# Check registry
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\RDInfraAgent"
```

### Issue: Session host not appearing in host pool

**Wait**:
- Allow 5-10 minutes for heartbeat
- Check VM event logs
- Verify RDAgentBootLoader service is running
- Check registration token was valid

---

## Best Practices

### For Image Creation

1. ✅ Use healthy, working source VMs
2. ✅ Update source VM with latest patches before imaging
3. ✅ Remove sensitive data before cloning
4. ✅ Use StandardSSD_LRS for cost-effectiveness
5. ✅ Attach NSG during clone to prevent domain issues
6. ✅ Version your images (e.g., monthly: YYYY-MM)
7. ✅ Test image on single VM before mass deployment

### For VM Deployment

1. ✅ Deploy to same region as image (or replicated region)
2. ✅ Use consistent VM sizing
3. ✅ Don't join domain during initial deployment
4. ✅ Use ARM templates for repeatable deployments
5. ✅ Tag VMs appropriately (environment, cost center, etc.)

### For Post-Configuration

1. ✅ Generate registration token before batch operations
2. ✅ Use service accounts for domain join
3. ✅ Specify OU path for better organization
4. ✅ Use parallel execution for multiple VMs
5. ✅ Verify each session host before user access
6. ✅ Monitor logs during batch operations
7. ✅ Test one VM fully before configuring others

---

## Maintenance Workflow

### Monthly Image Updates

```powershell
# 1. Update source VM with patches
# 2. Create new golden image
.\Clone-And-Generalize-AVD.ps1 ...

# 3. Deploy test VMs from new image
# 4. Verify test VMs work correctly
# 5. Gradually replace production VMs
# 6. Decommission old VMs after verification
```

### Adding New Session Hosts

```powershell
# 1. Deploy VM from latest image
# 2. Run post-configuration
.\Configure-AVD-SessionHost.ps1 ...

# 3. Verify in host pool
# 4. Enable user access
```

### Replacing Failed Session Hosts

```powershell
# 1. Remove failed VM from host pool
Remove-AzWvdSessionHost -ResourceGroupName "..." -HostPoolName "..." -Name "..."

# 2. Delete failed VM
Remove-AzVM -ResourceGroupName "..." -Name "..." -Force

# 3. Deploy new VM from image (reuse same name if needed)
# 4. Run post-configuration
# 5. Verify new session host
```

---

## Scripts Reference

| Script | Purpose | Phase |
|--------|---------|-------|
| `Clone-And-Generalize-AVD.ps1` | Create golden image | 1 |
| `Configure-AVD-SessionHost.ps1` | Configure single VM | 3 |
| `Batch-Configure-AVD.ps1` | Configure multiple VMs | 3 |
| `RUN-EXAMPLE.ps1` | Quick image creation | 1 |
| `RUN-PostConfig-Example.ps1` | Quick single VM config | 3 |

---

## Estimated Timelines

| Activity | Single VM | 5 VMs (Sequential) | 5 VMs (Parallel) |
|----------|-----------|-------------------|------------------|
| Create golden image | 20 min | 20 min (one-time) | 20 min (one-time) |
| Deploy VMs | 5 min | 25 min | 10 min |
| Post-configuration | 8 min | 40 min | 15 min |
| **Total** | **33 min** | **85 min** | **45 min** |

---

## Support & Documentation

- [Clone-And-Generalize Guide](./USAGE-GUIDE.md)
- [Post-Configuration Guide](./AVD-PostConfig-GUIDE.md)
- [Microsoft AVD Documentation](https://learn.microsoft.com/azure/virtual-desktop/)
- [Troubleshoot AVD Agents](https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-agent)

---

**Author**: BAB CloudOps Team  
**Last Updated**: April 2026  
**Version**: 1.0
