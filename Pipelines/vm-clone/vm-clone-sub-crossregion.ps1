<#
.SYNOPSIS
    Clones an Azure VM across subscriptions and regions with VHD-based disk copy.

.DESCRIPTION
    This script clones a source VM from one subscription/region to another by:
    - Exporting managed disks to VHDs using AzCopy
    - Creating new managed disks in target region
    - Creating new VM with cloned disks and network configuration
    
    The source VM can remain running during the clone operation. The script will create
    a crash-consistent point-in-time copy of the disks.
    
.PARAMETER ExistingVhdAction
    Action to take when VHD already exists in storage container.
    Valid values: 'Skip', 'Overwrite', 'Prompt' (default)

.PARAMETER SourceSubscriptionId
    Source Azure subscription ID

.PARAMETER TargetSubscriptionId
    Target Azure subscription ID

.PARAMETER SourceResourceGroup
    Source resource group name

.PARAMETER TargetResourceGroup
    Target resource group name

.PARAMETER SourceVMName
    Name of the source VM to clone (can be running or stopped)

.PARAMETER NewVMName
    Name for the new cloned VM

.PARAMETER Location
    Target Azure region for the new VM

.PARAMETER VnetRG
    Target VNet resource group

.PARAMETER VnetName
    Target VNet name

.PARAMETER SubnetName
    Target subnet name

.PARAMETER VMSize
    Target VM size

.PARAMETER StorageAccountName
    Storage account for VHD intermediate storage

.PARAMETER StorageAccountRG
    Storage account resource group

.PARAMETER ContainerName
    Storage container name for VHDs (default: vhds)

.PARAMETER StaticIpAddress
    Static IP address for the new VM

.PARAMETER BootDiagStorageAccount
    Boot diagnostics storage account (optional)

.PARAMETER BootDiagStorageRG
    Boot diagnostics storage resource group (optional)

.EXAMPLE
    .\vm-clone-sub-crossregion.ps1 -SourceSubscriptionId "source-sub-id" -TargetSubscriptionId "target-sub-id" -SourceResourceGroup "source-rg" -TargetResourceGroup "target-rg" -SourceVMName "SourceVM" -NewVMName "ClonedVM" -Location "swedencentral" -VnetRG "vnet-rg" -VnetName "vnet-name" -SubnetName "subnet-name" -VMSize "Standard_D4s_v5" -StorageAccountName "storage-account" -StorageAccountRG "storage-rg" -StaticIpAddress "10.0.0.10"

.EXAMPLE
    .\vm-clone-sub-crossregion.ps1 -SourceSubscriptionId "source-sub-id" ... -ExistingVhdAction Skip
    # Skips copying if VHD already exists

.NOTES
    Requires: Az PowerShell module, AzCopy utility
    Author: Azure Cloud Operations
    Version: 3.1 - VM deallocation no longer required, supports running VMs
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Skip', 'Overwrite', 'Prompt')]
    [string]$ExistingVhdAction = 'Prompt',
    
    [Parameter(Mandatory=$true)]
    [string]$SourceSubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceVMName,
    
    [Parameter(Mandatory=$true)]
    [string]$NewVMName,
    
    [Parameter(Mandatory=$true)]
    [string]$Location,
    
    [Parameter(Mandatory=$true)]
    [string]$VnetRG,
    
    [Parameter(Mandatory=$true)]
    [string]$VnetName,
    
    [Parameter(Mandatory=$true)]
    [string]$SubnetName,
    
    [Parameter(Mandatory=$true)]
    [string]$VMSize,
    
    [Parameter(Mandatory=$true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory=$true)]
    [string]$StorageAccountRG,
    
    [Parameter(Mandatory=$false)]
    [string]$ContainerName = "vhds",
    
    [Parameter(Mandatory=$true)]
    [string]$StaticIpAddress,
    
    [Parameter(Mandatory=$false)]
    [string]$BootDiagStorageAccount = "babsitvmbootdiag02",
    
    [Parameter(Mandatory=$false)]
    [string]$BootDiagStorageRG = "bab-sit-vm-boot-diag-swec-rg-01"
)

# ---------------------------- CONFIGURATION ----------------------------
$sourceSubscriptionId = $SourceSubscriptionId
$targetSubscriptionId = $TargetSubscriptionId
$sourceResourceGroup = $SourceResourceGroup
$targetResourceGroup = $TargetResourceGroup
$sourceVMName = $SourceVMName
$newVMName = $NewVMName
$location = $Location
$vnetrg = $VnetRG
$vnetName = $VnetName
$subnetName = $SubnetName
$vmSize = $VMSize

# Storage account for VHD copy (must exist in target region and subscription)
$storageAccountName = $StorageAccountName
$storageAccountRG = $StorageAccountRG
$containerName = $ContainerName

# ---------------------------- SWITCH TO SOURCE SUBSCRIPTION ----------------------------
Set-AzContext -SubscriptionId $sourceSubscriptionId

# ---------------------------- Get SOURCE VM ----------------------------
Write-Host "`n=== RETRIEVING SOURCE VM ===" -ForegroundColor Cyan
$sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName
if (-not $sourceVM) {
    throw "Source VM '$sourceVMName' not found in resource group '$sourceResourceGroup'."
}

Write-Host "✅ Source VM found: $($sourceVM.Name)"
Write-Host "   VM Size: $($sourceVM.HardwareProfile.VmSize)"
Write-Host "   Location: $($sourceVM.Location)"

# Get VM status
$sourceVMStatus = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName -Status
$vmStatus = $sourceVMStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }

Write-Host "✅ VM Power State: $($vmStatus.Code)" -ForegroundColor Green

if ($vmStatus.Code -ne "PowerState/deallocated") {
    Write-Host "⚠️  Source VM is running. Current state: $($vmStatus.Code)" -ForegroundColor Yellow
    Write-Host "⚠️  Cloning from a running VM is supported but may result in crash-consistent point-in-time copy" -ForegroundColor Yellow
    Write-Host "✅ Proceeding with clone operation without deallocating source VM" -ForegroundColor Green
} else {
    Write-Host "✅ Source VM is deallocated - optimal for consistent disk copy" -ForegroundColor Green
}

# Validate storage profile
if (-not $sourceVM.StorageProfile -or -not $sourceVM.StorageProfile.OsDisk -or -not $sourceVM.StorageProfile.OsDisk.Name) {
    throw "Source VM '$sourceVMName' has invalid storage configuration."
}

Write-Host "✅ Storage Profile validated"
Write-Host "   OS Disk: $($sourceVM.StorageProfile.OsDisk.Name)"
Write-Host "   OS Type: $($sourceVM.StorageProfile.OsDisk.OsType)"
Write-Host "   Caching: $($sourceVM.StorageProfile.OsDisk.Caching)"

# Retrieve OS disk
try {
    $osDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $sourceVM.StorageProfile.OsDisk.Name -ErrorAction Stop
    if (-not $osDisk) {
        throw "OS disk object is null."
    }
} catch {
    throw "Failed to retrieve OS disk '$($sourceVM.StorageProfile.OsDisk.Name)': $_"
}

Write-Host "✅ OS Disk retrieved: $($osDisk.Name) ($($osDisk.DiskSizeGB) GB, $($osDisk.Sku.Name))"

# Validate disk ownership
if ($osDisk.ManagedBy -and $osDisk.ManagedBy -notlike "*$sourceVMName*") {
    throw "OS disk is attached to another VM: $($osDisk.ManagedBy)"
}

# ---------------------------- EXPORT OS AND DATA DISKS TO VHD ----------------------------
Write-Host "`n=== EXPORTING DISKS TO VHD ===" -ForegroundColor Cyan

# Switch to target subscription first to check existing VHDs
Set-AzContext -SubscriptionId $targetSubscriptionId
Write-Host "Validating target storage account..."

try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName -ErrorAction Stop
    Write-Host "✅ Storage account: $storageAccountName ($($storageAccount.Location), $($storageAccount.Sku.Name))"
} catch {
    Write-Error "❌ Storage account '$storageAccountName' not found in '$storageAccountRG'"
    throw
}

# Create storage context
Write-Host "Creating storage context..."
try {
    $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $storageAccountRG -Name $storageAccountName -ErrorAction Stop)[0].Value
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey -ErrorAction Stop
    Write-Host "✅ Storage context created"
} catch {
    Write-Error "❌ Failed to create storage context. Ensure you have proper RBAC permissions."
    throw
}

# Verify/create container
$container = Get-AzStorageContainer -Name $containerName -Context $storageContext -ErrorAction SilentlyContinue
if (-not $container) {
    Write-Host "Creating container '$containerName'..."
    $container = New-AzStorageContainer -Name $containerName -Context $storageContext -Permission Off
    Write-Host "✅ Container created"
} else {
    Write-Host "✅ Container exists: $containerName"
}

# ---------------------------- CHECK EXISTING VHDS FIRST ----------------------------
$targetVhdName = "$newVMName-osdisk-copy.vhd"

# Check if all VHDs already exist when ExistingVhdAction is Skip
if ($ExistingVhdAction -eq 'Skip') {
    Write-Host "`n=== CHECKING FOR EXISTING VHDS (Skip Mode) ===" -ForegroundColor Yellow
    
    # Check OS disk VHD
    $existingOsVhd = Get-AzStorageBlob -Container $containerName -Context $storageContext -Blob $targetVhdName -ErrorAction SilentlyContinue
    $allVhdsExist = $existingOsVhd -ne $null
    
    if ($existingOsVhd) {
        Write-Host "✅ OS disk VHD exists: $targetVhdName ($([math]::Round($existingOsVhd.Length / 1GB, 2)) GB)" -ForegroundColor Green
    } else {
        Write-Host "❌ OS disk VHD missing: $targetVhdName" -ForegroundColor Red
        $allVhdsExist = $false
    }
    
    # Check data disk VHDs
    $existingDataVhds = @()
    if ($sourceVM.StorageProfile.DataDisks.Count -gt 0) {
        foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
            $dataVhdName = "$newVMName-datadisk-$($dataDisk.Lun)-copy.vhd"
            $existingDataVhd = Get-AzStorageBlob -Container $containerName -Context $storageContext -Blob $dataVhdName -ErrorAction SilentlyContinue
            
            if ($existingDataVhd) {
                Write-Host "✅ Data disk VHD exists: $dataVhdName (LUN $($dataDisk.Lun), $([math]::Round($existingDataVhd.Length / 1GB, 2)) GB)" -ForegroundColor Green
                $existingDataVhds += $dataVhdName
            } else {
                Write-Host "❌ Data disk VHD missing: $dataVhdName (LUN $($dataDisk.Lun))" -ForegroundColor Red
                $allVhdsExist = $false
            }
        }
    }
    
    if ($allVhdsExist) {
        Write-Host "`n✅ All VHDs exist - Skipping disk export entirely!" -ForegroundColor Green
        Write-Host "   No SAS tokens will be generated" -ForegroundColor Green
        
        # Skip to disk creation section
        $skipDiskExport = $true
    } else {
        Write-Host "`n⚠️  Some VHDs are missing - Proceeding with export for missing VHDs only" -ForegroundColor Yellow
        $skipDiskExport = $false
    }
} else {
    $skipDiskExport = $false
}

# Only proceed with export if not skipping
if (-not $skipDiskExport) {
    # Generate SAS token for destination
    Write-Host "Generating SAS token for destination container..."
    try {
        $destinationSasToken = New-AzStorageContainerSASToken -Container $containerName -Context $storageContext -Permission racwl -ExpiryTime (Get-Date).AddHours(4) -ErrorAction Stop
        Write-Host "✅ SAS token generated (expires in 4 hours)"
    } catch {
        Write-Error "❌ Failed to generate SAS token. Verify storage account permissions."
        throw
    }

    # Verify AzCopy
    $azCopyExe = "azcopy"
    if (-not (Get-Command $azCopyExe -ErrorAction SilentlyContinue)) {
        throw "AzCopy not found. Install from https://aka.ms/downloadazcopy"
    }
    $azCopyVersion = & $azCopyExe --version
    Write-Host "✅ AzCopy: $azCopyVersion"

    # ---------------------------- COPY OS DISK VHD ----------------------------
    $targetVhdUri = "$($storageAccount.PrimaryEndpoints.Blob)$containerName/$targetVhdName`?$destinationSasToken"

    # Check if VHD exists (re-check for non-Skip modes)
    $existingOsVhd = Get-AzStorageBlob -Container $containerName -Context $storageContext -Blob $targetVhdName -ErrorAction SilentlyContinue

    $shouldCopyOs = $true
    if ($existingOsVhd) {
        Write-Host "`n⚠️  OS disk VHD '$targetVhdName' already exists" -ForegroundColor Yellow
        Write-Host "   Size: $([math]::Round($existingOsVhd.Length / 1GB, 2)) GB"
        Write-Host "   Last Modified: $($existingOsVhd.LastModified)"
        
        $shouldCopyOs = switch ($ExistingVhdAction) {
            'Skip' { 
                Write-Host "✅ Skipping OS disk copy (mode: Skip)" -ForegroundColor Green
                $false 
            }
            'Overwrite' { 
                Write-Host "⚠️  Overwriting VHD (mode: Overwrite)" -ForegroundColor Yellow
                $true 
            }
            'Prompt' { 
                $response = Read-Host "Overwrite existing VHD? (Y/N)"
                $response -eq 'Y'
            }
        }
    }

    # Only generate SAS token for OS disk if we need to copy it
    $osDiskSasUrl = $null
    if ($shouldCopyOs) {
        Write-Host "Generating SAS token for source OS disk..."
        Set-AzContext -SubscriptionId $sourceSubscriptionId
        $osDiskAccess = Grant-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $osDisk.Name -Access Read -DurationInSecond 7200
        $osDiskSasUrl = $osDiskAccess.AccessSAS
        Set-AzContext -SubscriptionId $targetSubscriptionId

        Write-Host "`nCopying OS disk with AzCopy..."
        Write-Host "  Source: $($osDisk.Name) ($($osDisk.DiskSizeGB) GB)"
        Write-Host "  Destination: $targetVhdName"
        Write-Host "  This may take several minutes..."

        $azCopyCmd = "$azCopyExe copy `"$osDiskSasUrl`" `"$targetVhdUri`" --blob-type PageBlob --overwrite=true --log-level=INFO"
        Invoke-Expression $azCopyCmd

        if ($LASTEXITCODE -ne 0) {
            Write-Error "❌ AzCopy failed (exit code: $LASTEXITCODE)"
            Set-AzContext -SubscriptionId $sourceSubscriptionId
            Revoke-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $osDisk.Name
            throw "AzCopy operation failed"
        }
        Write-Host "✅ OS disk copied successfully" -ForegroundColor Green

        # Revoke OS disk access
        Set-AzContext -SubscriptionId $sourceSubscriptionId
        Revoke-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $osDisk.Name
        Write-Host "✅ OS disk access revoked"
        Set-AzContext -SubscriptionId $targetSubscriptionId
    } else {
        Write-Host "✅ OS disk copy skipped - no SAS token generated" -ForegroundColor Green
    }

# ---------------------------- COPY DATA DISKS ----------------------------
if ($sourceVM.StorageProfile.DataDisks.Count -gt 0) {
    Write-Host "`n=== COPYING DATA DISKS ===" -ForegroundColor Cyan
    Write-Host "Processing $($sourceVM.StorageProfile.DataDisks.Count) data disk(s)..."
    
    foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
        Write-Host "`nData Disk: $($dataDisk.Name) (LUN: $($dataDisk.Lun))"
        
        $dataVhdName = "$newVMName-datadisk-$($dataDisk.Lun)-copy.vhd"
        $existingDataVhd = Get-AzStorageBlob -Container $containerName -Context $storageContext -Blob $dataVhdName -ErrorAction SilentlyContinue
        
        $shouldCopyData = $true
        if ($existingDataVhd) {
            Write-Host "  ⚠️  VHD exists: $dataVhdName" -ForegroundColor Yellow
            Write-Host "     Size: $([math]::Round($existingDataVhd.Length / 1GB, 2)) GB"
            
            $shouldCopyData = switch ($ExistingVhdAction) {
                'Skip' { 
                    Write-Host "  ✅ Skipping (mode: Skip)" -ForegroundColor Green
                    $false 
                }
                'Overwrite' { 
                    Write-Host "  ⚠️  Overwriting (mode: Overwrite)" -ForegroundColor Yellow
                    $true 
                }
                'Prompt' { 
                    $response = Read-Host "  Overwrite? (Y/N)"
                    $response -eq 'Y'
                }
            }
        }
        
        # Only generate SAS token and copy if needed
        if ($shouldCopyData) {
            Write-Host "  Generating SAS token for data disk..."
            Set-AzContext -SubscriptionId $sourceSubscriptionId
            $dataDiskAccess = Grant-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name -Access Read -DurationInSecond 7200
            $dataDiskSasUrl = $dataDiskAccess.AccessSAS

            Set-AzContext -SubscriptionId $targetSubscriptionId
            $dataVhdUri = "$($storageAccount.PrimaryEndpoints.Blob)$containerName/$dataVhdName`?$destinationSasToken"

            Write-Host "  Copying with AzCopy..."
            $azCopyCmd = "$azCopyExe copy `"$dataDiskSasUrl`" `"$dataVhdUri`" --blob-type PageBlob --overwrite=true --log-level=INFO"
            Invoke-Expression $azCopyCmd

            if ($LASTEXITCODE -ne 0) {
                Write-Error "  ❌ AzCopy failed (exit code: $LASTEXITCODE)"
                Set-AzContext -SubscriptionId $sourceSubscriptionId
                Revoke-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name
                throw "AzCopy failed for data disk"
            }
            Write-Host "  ✅ Data disk copied" -ForegroundColor Green

            # Revoke access after copying
            Set-AzContext -SubscriptionId $sourceSubscriptionId
            Revoke-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name
            Write-Host "  ✅ Access revoked"
            Set-AzContext -SubscriptionId $targetSubscriptionId
        } else {
            Write-Host "  ✅ Data disk copy skipped - no SAS token generated" -ForegroundColor Green
        }
    }
}

# Close the export section condition
} else {
    Write-Host "`n✅ Skipping entire disk export process - all VHDs exist" -ForegroundColor Green
}

# ---------------------------- CREATE MANAGED DISKS ----------------------------
Set-AzContext -SubscriptionId $targetSubscriptionId
Write-Host "`n=== CREATING MANAGED DISKS ===" -ForegroundColor Cyan

# Get OS disk blob URI (without SAS)
$osDiskBlob = Get-AzStorageBlob -Container $containerName -Context $storageContext -Blob $targetVhdName
$osDiskBlobUri = $osDiskBlob.ICloudBlob.Uri.AbsoluteUri

if ($osDiskBlob.BlobType -ne "PageBlob") {
    throw "OS disk VHD must be PageBlob, found: $($osDiskBlob.BlobType)"
}

# Create OS disk
$storageAccountId = $storageAccount.Id
$osDiskConfig = New-AzDiskConfig `
    -AccountType StandardSSD_LRS `
    -Location $location `
    -CreateOption Import `
    -StorageAccountId $storageAccountId `
    -SourceUri $osDiskBlobUri `
    -OsType $osDisk.OsType

$newOSDiskName = "$newVMName-OSDisk"
try {
    $newOSDisk = New-AzDisk -DiskName $newOSDiskName -Disk $osDiskConfig -ResourceGroupName $targetResourceGroup -ErrorAction Stop
    Write-Host "✅ OS disk created: $newOSDiskName" -ForegroundColor Green
} catch {
    Write-Error "❌ Failed to create OS disk: $_"
    throw
}

# Create data disks
$newDataDisks = @()
if ($sourceVM.StorageProfile.DataDisks.Count -gt 0) {
    Write-Host "`nCreating data disks..."
    foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
        $dataVhdName = "$newVMName-datadisk-$($dataDisk.Lun)-copy.vhd"
        $dataDiskBlob = Get-AzStorageBlob -Container $containerName -Context $storageContext -Blob $dataVhdName
        $dataDiskBlobUri = $dataDiskBlob.ICloudBlob.Uri.AbsoluteUri
        
        if ($dataDiskBlob.BlobType -ne "PageBlob") {
            throw "Data disk VHD LUN $($dataDisk.Lun) must be PageBlob"
        }

        Set-AzContext -SubscriptionId $sourceSubscriptionId
        $sourceDiskObj = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name
        Set-AzContext -SubscriptionId $targetSubscriptionId
        
        $dataDiskConfig = New-AzDiskConfig `
            -AccountType $sourceDiskObj.Sku.Name `
            -Location $location `
            -CreateOption Import `
            -StorageAccountId $storageAccountId `
            -SourceUri $dataDiskBlobUri

        $clonedDiskName = "$newVMName-DataDisk-$($dataDisk.Lun)"
        try {
            $clonedDisk = New-AzDisk -DiskName $clonedDiskName -Disk $dataDiskConfig -ResourceGroupName $targetResourceGroup -ErrorAction Stop
            Write-Host "  ✅ Data disk created: $clonedDiskName (LUN $($dataDisk.Lun))" -ForegroundColor Green
            
            $newDataDisks += [PSCustomObject]@{
                Id = $clonedDisk.Id
                Lun = $dataDisk.Lun
                Caching = $dataDisk.Caching
            }
        } catch {
            Write-Error "  ❌ Failed to create data disk LUN $($dataDisk.Lun): $_"
            throw
        }
    }
}

# ---------------------------- CREATE NIC ----------------------------
Write-Host "`n=== CREATING NETWORK INTERFACE ===" -ForegroundColor Cyan

$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg
$subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetName

$staticIpAddress = $StaticIpAddress
Write-Host "VNet: $vnetName, Subnet: $subnetName"
Write-Host "Static IP: $staticIpAddress"

try {
    $nic = New-AzNetworkInterface `
        -Name "$newVMName-NIC" `
        -ResourceGroupName $targetResourceGroup `
        -Location $location `
        -SubnetId $subnet.Id `
        -PrivateIpAddress $staticIpAddress `
        -ErrorAction Stop
    
    Write-Host "✅ NIC created: $($nic.Name) ($($nic.IpConfigurations[0].PrivateIpAddress))" -ForegroundColor Green
} catch {
    Write-Error "❌ Failed to create NIC: $_"
    throw
}

# ---------------------------- CREATE VM ----------------------------
Write-Host "`n=== CREATING VIRTUAL MACHINE ===" -ForegroundColor Cyan

$vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmSize
$osType = $sourceVM.StorageProfile.OsDisk.OsType

if (-not $newOSDisk -or -not $newOSDisk.Id) {
    throw "OS disk validation failed"
}

# Attach OS disk
if ($osType -eq "Linux") {
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Linux -Caching $sourceVM.StorageProfile.OsDisk.Caching
} elseif ($osType -eq "Windows") {
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Windows -Caching $sourceVM.StorageProfile.OsDisk.Caching
} else {
    throw "Unknown OS type: $osType"
}

# Attach NIC
$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

# Attach data disks
if ($newDataDisks.Count -gt 0) {
    foreach ($disk in $newDataDisks) {
        $vmConfig = Add-AzVMDataDisk -VM $vmConfig -ManagedDiskId $disk.Id -CreateOption Attach -Lun $disk.Lun -Caching $disk.Caching
    }
}

# Boot diagnostics
try {
    $bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $BootDiagStorageRG -Name $BootDiagStorageAccount -ErrorAction Stop
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Enable -ResourceGroupName $BootDiagStorageRG -StorageAccountName $BootDiagStorageAccount
    Write-Host "✅ Boot diagnostics enabled"
} catch {
    Write-Warning "Boot diagnostics not enabled: $_"
}

# Create VM
Write-Host "`nCreating VM '$newVMName'..."
try {
    $vmResult = New-AzVM -ResourceGroupName $targetResourceGroup -Location $location -VM $vmConfig -ErrorAction Stop
    
    Write-Host "`n" + ("=" * 60) -ForegroundColor Green
    Write-Host "✅ VM CREATED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host ("=" * 60) -ForegroundColor Green
    Write-Host "`nVM: $newVMName"
    Write-Host "Resource Group: $targetResourceGroup"
    Write-Host "Location: $location"
    Write-Host "Size: $vmSize"
    Write-Host "OS: $osType"
    Write-Host "IP: $staticIpAddress"
    
    Write-Host "`nTo start the VM:"
    Write-Host "Start-AzVM -ResourceGroupName $targetResourceGroup -Name $newVMName" -ForegroundColor Cyan
    
} catch {
    Write-Host "`n" + ("=" * 60) -ForegroundColor Red
    Write-Error "❌ VM CREATION FAILED"
    Write-Host ("=" * 60) -ForegroundColor Red
    Write-Host "`nError: $_"
    Write-Host "`nCleanup commands:"
    Write-Host "Remove-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName -Force"
    foreach ($disk in $newDataDisks) {
        Write-Host "Remove-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $(Split-Path $disk.Id -Leaf) -Force"
    }
    Write-Host "Remove-AzNetworkInterface -ResourceGroupName $targetResourceGroup -Name $($nic.Name) -Force"
    throw
}