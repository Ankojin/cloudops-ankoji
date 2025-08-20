# ---------------------------- CONFIGURATION ----------------------------
$sourceSubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$targetSubscriptionId = "d88f0b5b-6660-4607-8c6a-395820400912"
$sourceResourceGroup = "bab-dev-hid-swec-rg-01"
$targetResourceGroup = "bab-core-hid-swec-rg-01"
$sourceVMName = "DAMFAWBWBDWV1"
$newVMName = "DAMFAWBWBDWV1"
$location = "westeurope"  # Target region for new disks/VM
$vnetrg  = "bab-core-nw-weeu-rg-01"
$vnetName = "bab-core-nw-weeu-vnet-dmz-01"
$subnetName = "snet-dmz-shared-web-01"
$vmSize = "Standard_D2s_v5"

# Storage account for VHD copy (must exist in target region and subscription)
$storageAccountName = "babcorevmbootdiag01"
$storageAccountRG = "bab-core-panfw-weeu-rg-01"
$containerName = "vhds"

# ---------------------------- SWITCH TO SOURCE SUBSCRIPTION ----------------------------
Set-AzContext -SubscriptionId $sourceSubscriptionId

# ---------------------------- Get SOURCE VM ----------------------------
$sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName
if (-not $sourceVM) {
    throw "Source VM '$sourceVMName' not found in resource group '$sourceResourceGroup'."
}

# Verify the source VM's OS disk
if (-not $sourceVM.StorageProfile -or -not $sourceVM.StorageProfile.OsDisk) {
    throw "Source VM '$sourceVMName' does not have a valid OS disk."
}

# Retrieve the OS disk
$osDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $sourceVM.StorageProfile.OsDisk.Name
if (-not $osDisk) {
    throw "OS disk for VM '$sourceVMName' could not be retrieved."
}

Write-Host "OS Disk Name: $($osDisk.Name)"
Write-Host "OS Disk ID: $($osDisk.Id)"
Write-Host "OS Disk Location: $($osDisk.Location)"

# ---------------------------- EXPORT OS AND DATA DISKS TO VHD (GENERATE SAS URLS & COPY WITH AZCOPY) ----------------------------

# OS Disk: Generate SAS URL and copy using AzCopy
Set-AzContext -SubscriptionId $sourceSubscriptionId
$osDiskAccess = Grant-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $osDisk.Name -Access Read -DurationInSecond 7200
$osDiskSasUrl = $osDiskAccess.AccessSAS

Set-AzContext -SubscriptionId $targetSubscriptionId
$storageAccount = Get-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName
$containerName = "vhds"
$azCopyExe = "azcopy"  # Ensure azcopy is in your PATH
$targetVhdName = "$newVMName-osdisk-copy.vhd"

# Generate a SAS token for the destination container with at least "Write", "Create", and "Add" permissions
# You can generate this in the Azure Portal or with PowerShell
$destinationSasToken = "sp=racwl&st=2025-08-05T15:07:16Z&se=2025-08-09T23:22:16Z&spr=https&sv=2024-11-04&sr=c&sig=%2BEMPVGeUbhIUfDa4%2BHf6iPUem1MtGtril4i%2BT5Yy2zw%3D"  # Example: sv=...&ss=b&srt=sco&sp=acwl&se=...&sig=...

$targetVhdUri = "$($storageAccount.PrimaryEndpoints.Blob)$containerName/$targetVhdName`?$destinationSasToken"

Write-Host "Copying OS disk with AzCopy..."
$azCopyCmd = "$azCopyExe copy `"$osDiskSasUrl`" `"$targetVhdUri`" --blob-type PageBlob --overwrite=true"
Write-Host $azCopyCmd
Invoke-Expression $azCopyCmd

Set-AzContext -SubscriptionId $sourceSubscriptionId
Revoke-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $osDisk.Name

# Data Disks: Generate SAS URLs and copy using AzCopy
foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
    Set-AzContext -SubscriptionId $sourceSubscriptionId
    $dataDiskAccess = Grant-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name -Access Read -DurationInSecond 7200
    $dataDiskSasUrl = $dataDiskAccess.AccessSAS

    Set-AzContext -SubscriptionId $targetSubscriptionId
    $dataVhdName = "$newVMName-datadisk-$($dataDisk.Lun)-copy.vhd"
    $dataVhdUri = "$($storageAccount.PrimaryEndpoints.Blob)$containerName/$dataVhdName`?$destinationSasToken"

    Write-Host "Copying data disk $($dataDisk.Name) with AzCopy..."
    $azCopyCmd = "$azCopyExe copy `"$dataDiskSasUrl`" `"$dataVhdUri`" --blob-type PageBlob --overwrite=true"
    Write-Host $azCopyCmd
    Invoke-Expression $azCopyCmd

    Set-AzContext -SubscriptionId $sourceSubscriptionId
    Revoke-AzDiskAccess -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name
}

# ---------------------------- CREATE MANAGED OS DISK FROM COPIED VHD ----------------------------
Set-AzContext -SubscriptionId $targetSubscriptionId

# Dynamically generate a SAS URL for the copied OS disk VHD (sr=b, sp=r)
$osDiskBlob = Get-AzStorageBlob -Container $containerName -Context $storageAccount.Context -Blob $targetVhdName
Write-Host "OS Disk Blob Type: $($osDiskBlob.BlobType)"
if ($osDiskBlob.BlobType -ne "PageBlob") {
    throw "The OS disk VHD must be a PageBlob. Current type: $($osDiskBlob.BlobType)"
}
$osDiskSasToken = New-AzStorageBlobSASToken -Container $containerName -Blob $targetVhdName -Permission r -Context $storageAccount.Context -FullUri -ExpiryTime (Get-Date).AddHours(2)
$osDiskSasUrl = $osDiskSasToken

$osDiskConfig = New-AzDiskConfig -AccountType StandardSSD_LRS `
    -Location $location `
    -CreateOption Import `
    -SourceUri $osDiskSasUrl `
    -OsType $osDisk.OsType

$newOSDiskName = "$newVMName-OSDisk"
$newOSDisk = New-AzDisk -DiskName $newOSDiskName -Disk $osDiskConfig -ResourceGroupName $targetResourceGroup

Write-Host "Managed OS disk '$newOSDiskName' created in $location from VHD."

# ---------------------------- CREATE MANAGED DATA DISKS FROM COPIED VHDs ----------------------------
$newDataDisks = @()
foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
    $dataVhdName = "$newVMName-datadisk-$($dataDisk.Lun)-copy.vhd"
    $dataVhdUri = "$($storageAccount.PrimaryEndpoints.Blob)$containerName/$dataVhdName"

    # Check blob type for data disk
    $dataDiskBlob = Get-AzStorageBlob -Container $containerName -Context $storageAccount.Context -Blob $dataVhdName
    Write-Host "Data Disk Blob Type (LUN $($dataDisk.Lun)): $($dataDiskBlob.BlobType)"
    if ($dataDiskBlob.BlobType -ne "PageBlob") {
        throw "The data disk VHD for LUN $($dataDisk.Lun) must be a PageBlob. Current type: $($dataDiskBlob.BlobType)"
    }

    # Dynamically generate a SAS URL for each copied data disk VHD (sr=b, sp=r)
    $dataDiskSasToken = New-AzStorageBlobSASToken -Container $containerName -Blob $dataVhdName -Permission r -Context $storageAccount.Context -FullUri -ExpiryTime (Get-Date).AddHours(2)
    $dataDiskSasUrl = $dataDiskSasToken

    $dataDiskConfig = New-AzDiskConfig -AccountType StandardSSD_LRS `
        -Location $location `
        -CreateOption Import `
        -SourceUri $dataDiskSasUrl `
        -OsType $dataDisk.OsType

    $clonedDiskName = "$newVMName-DataDisk-$($dataDisk.Lun)"
    $clonedDisk = New-AzDisk -DiskName $clonedDiskName -Disk $dataDiskConfig -ResourceGroupName $targetResourceGroup

    Write-Host "Managed data disk '$clonedDiskName' created in $location from VHD."

    $newDataDisks += [PSCustomObject]@{Id=$clonedDisk.Id; Lun=$dataDisk.Lun}
}

# ---------------------------- CREATE NIC ---------------------------- 
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg
$subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetName

$staticIpAddress = "10.189.60.71"  # Replace with your desired IP address
$nic = New-AzNetworkInterface -Name "$newVMName-NIC" -ResourceGroupName $targetResourceGroup `
    -Location $location `
    -SubnetId $subnet.Id `
    -PrivateIpAddress $staticIpAddress

# ---------------------------- CONFIGURE NEW VM ----------------------------
$vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmSize
$osType = $sourceVM.StorageProfile.OsDisk.OsType

if ($osType -eq "Linux") {
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Linux
} elseif ($osType -eq "Windows") {
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Windows
} else {
    throw "Unknown OS type: $osType"
}

$vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

foreach ($disk in $newDataDisks) {
    $vmConfig = Add-AzVMDataDisk -VM $vmConfig `
        -ManagedDiskId $disk.Id -CreateOption Attach -Lun $disk.Lun
}

# ---------------------------- ENABLE BOOT DIAGNOSTICS ----------------------------
$bootDiagStorageAccountName = "babcorevmbootdiag01"
$bootdiagstracctrg = "bab-core-panfw-weeu-rg-01"
$bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $bootdiagstracctrg -Name $bootDiagStorageAccountName

if (-not $bootDiagStorageAccount) {
    throw "Boot diagnostics storage account '$bootDiagStorageAccountName' not found in resource group '$bootdiagstracctrg'."
}

$vmConfig.DiagnosticsProfile = @{
    BootDiagnostics = @{
        Enabled = $true
        StorageUri = $bootDiagStorageAccount.PrimaryEndpoints.Blob
    }
}

# ---------------------------- CREATE THE NEW VM ----------------------------
try {
    New-AzVM -ResourceGroupName $targetResourceGroup -Location $location -VM $vmConfig
} catch {
    throw "Failed to create the new VM '$newVMName'. Error: $_"
}

Write-Host "`n✅ VM '$newVMName' cloned from '$sourceVMName'. OS/data disks and NIC attached."