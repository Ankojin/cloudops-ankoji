# ---------------------------- CONFIGURATION ----------------------------
# $sourceSubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"  # Replace with the source subscription ID
# $targetSubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"  # Replace with the target subscription ID
$sourceSubscriptionId = "cb801de6-404a-4e76-8e9a-475206cbc2e5"  # Replace with the source subscription ID
$targetSubscriptionId = "cb801de6-404a-4e76-8e9a-475206cbc2e5"  # Replace with the target subscription ID
$sourceResourceGroup = "bab-vdi-avd-weeu-rg-01"
$targetResourceGroup = "bab-vdi-avd-weeu-rg-01"
$sourceVMName = "BABAVDSHDTA-2"
$newVMName = "BABAVDSHDTA-3"
$location = "westeurope"
$vnetrg  = "bab-vdi-nw-weeu-rg-01"
$vnetName = "bab-vdi-nw-weeu-vnet-vdi-01"
$subnetName = "snet-vdi-avd-01"
$nsgName = "test-ad-join-nsg"
$nsgrg ="bab-vdi-avd-weeu-rg-01"
$vmSize = "Standard_E8s_v5"

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

# Debugging output
Write-Host "OS Disk Name: $($sourceVM.StorageProfile.OsDisk.Name)"
Write-Host "OS Disk ID: $($osDisk.Id)"

if (-not $osDisk.Id) {
    throw "OS Disk ID is null. Ensure the source VM's OS disk is retrieved correctly."
}

# ---------------------------- SWITCH TO TARGET SUBSCRIPTION ----------------------------
Set-AzContext -SubscriptionId $targetSubscriptionId

# ---------------------------- OS DISK SNAPSHOT ----------------------------
$snapshotOSName = "$newVMName-OSSnapshot"
$snapshotOS = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -ErrorAction SilentlyContinue
if (-not $snapshotOS) {
    Write-Host "Creating OS snapshot '$snapshotOSName'..."
    $snapshotOS = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName `
        -Snapshot (New-AzSnapshotConfig -SourceResourceId $osDisk.Id -Location $location -CreateOption Copy)
} else {
    Write-Host "OS snapshot '$snapshotOSName' already exists. Skipping creation."
}

# Check if the OS disk already exists
$newOSDiskName = "$newVMName-OSDisk"
$newOSDisk = Get-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName -ErrorAction SilentlyContinue
if (-not $newOSDisk) {
    Write-Host "Creating OS disk '$newOSDiskName'..."
    $newOSDisk = New-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName `
        -Disk (New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $snapshotOS.Id)
} else {
    Write-Host "OS disk '$newOSDiskName' already exists. Skipping creation."
}

# ---------------------------- CLONE DATA DISKS ----------------------------
$newDataDisks = @()
foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
    # Switch to source subscription to retrieve the data disk
    Set-AzContext -SubscriptionId $sourceSubscriptionId
    $disk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name

    if (-not $disk) {
        Write-Host "Data disk '$($dataDisk.Name)' could not be retrieved. Skipping..."
        continue
    }

    # Switch to target subscription to create the snapshot and cloned disk
    Set-AzContext -SubscriptionId $targetSubscriptionId
    $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
    $snapshot = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -ErrorAction SilentlyContinue
    if (-not $snapshot) {
        Write-Host "Creating snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)'..."
        $snapshot = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName `
            -Snapshot (New-AzSnapshotConfig -SourceResourceId $disk.Id -Location $location -CreateOption Copy)
    } else {
        Write-Host "Snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)' already exists. Skipping creation."
    }

    $clonedDiskName = "$newVMName-DataDisk-$($dataDisk.Lun)"
    $clonedDisk = Get-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $clonedDiskName -ErrorAction SilentlyContinue
    if (-not $clonedDisk) {
        Write-Host "Creating cloned disk '$clonedDiskName'..."
        $clonedDisk = New-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $clonedDiskName `
            -Disk (New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id)
    } else {
        Write-Host "Cloned disk '$clonedDiskName' already exists. Skipping creation."
    }

    $newDataDisks += [PSCustomObject]@{Id=$clonedDisk.Id; Lun=$dataDisk.Lun}
}

# ---------------------------- CREATE NIC WITH NSG ---------------------------- 
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgrg -Name $nsgName
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg
$subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetName

$staticIpAddress = "10.189.50.134"  # Replace with your desired IP address
$nic = New-AzNetworkInterface -Name "$newVMName-NIC" -ResourceGroupName $targetResourceGroup `
    -Location $location `
    -SubnetId $subnet.Id `
    -NetworkSecurityGroupId $nsg.Id `
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
$bootDiagStorageAccountName = "babvdivmbootdiag01"
$bootdiagstracctrg = "bab-vdi-avd-weeu-rg-01"  
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

# ---------------------------- DELETE SNAPSHOTS AFTER VM CREATION ----------------------------
# Delete OS snapshot
try {
    Remove-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -Force
    Write-Host "Deleted OS snapshot '$snapshotOSName'."
} catch {
    Write-Warning "Failed to delete OS snapshot '$snapshotOSName'. Error: $_"
}

# Delete data disk snapshots
foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
    $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
    try {
        Remove-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -Force
        Write-Host "Deleted data disk snapshot '$snapshotName'."
    } catch {
        Write-Warning "Failed to delete data disk snapshot '$snapshotName'. Error: $_"
    }
}

Write-Host "`n✅ VM '$newVMName' cloned from '$sourceVMName'. OS/data disks and NSG attached."