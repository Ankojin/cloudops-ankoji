# ---------------------------- CONFIGURATION ----------------------------
$sourceResourceGroup = "bab-sit-rmb-swec-rg-01"
$targetResourceGroup = "bab-sit-rmb-swec-rg-01"
$sourceVMName = "D2RMBAPWSILV1-test"
$newVMName = "DARMBAPWSILV1"
$location = "swedencentral"
$vnetrg  = "bab-sit-nw-swec-rg-01"
$vnetName = "bab-sit-nw-swec-vnet-nonpci-01"
$subnetName = "snet-sit-nonpci-app-02"
$vmSize = "Standard_E4-2s_v5"
$useSSHOnly = $false  # Set to $false to enable password login and reset

# If password login is allowed, provide credentials here
$linuxUsername = "azureadmin"         # Replace with valid Linux user
$newPassword = "BabAzur1"  # Replace with secure password.

# ---------------------------- SOURCE VM ----------------------------
$sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName
if (-not $sourceVM) {
    throw "Source VM '$sourceVMName' not found in resource group '$sourceResourceGroup'."
}

if (-not $sourceVM.StorageProfile -or -not $sourceVM.StorageProfile.OsDisk) {
    throw "Source VM '$sourceVMName' does not have a valid OS disk."
}

$osDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $sourceVM.StorageProfile.OsDisk.Name
if (-not $osDisk) {
    throw "OS disk for VM '$sourceVMName' could not be retrieved."
}

Write-Host "OS Disk ID: $($osDisk.Id)"

# ---------------------------- OS DISK SNAPSHOT ----------------------------
$snapshotOSName = "$newVMName-OSSnapshot"
$snapshotOS = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -ErrorAction SilentlyContinue
if (-not $snapshotOS) {
    Write-Host "Creating OS snapshot '$snapshotOSName'..."
    $snapshotOS = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName `
        -Snapshot (New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $location -CreateOption Copy)
} else {
    Write-Host "OS snapshot '$snapshotOSName' already exists. Skipping creation."
}

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
    $disk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name

    $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
    $snapshot = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -ErrorAction SilentlyContinue
    if (-not $snapshot) {
        Write-Host "Creating snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)'..."
        $snapshot = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName `
            -Snapshot (New-AzSnapshotConfig -SourceUri $disk.Id -Location $location -CreateOption Copy)
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

# ---------------------------- CREATE NIC ----------------------------
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg
$subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetName
$staticIpAddress = "10.189.67.107"

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
$bootDiagStorageAccountName = "babsitvmbootdiag02"
$bootdiagstracctrg = "bab-sit-vm-boot-diag-swec-rg-01"
$bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $bootdiagstracctrg -Name $bootDiagStorageAccountName
if (-not $bootDiagStorageAccount) {
    throw "Boot diagnostics storage account '$bootDiagStorageAccountName' not found."
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

# ---------------------------- OPTIONAL: Reset Linux Password ----------------------------
if ($osType -eq "Linux" -and -not $useSSHOnly) {
    Write-Host "`n🔐 Setting Linux password for user '$linuxUsername' on VM '$newVMName'..."

    try {
        Set-AzVMAccessExtension -ResourceGroupName $targetResourceGroup `
            -VMName $newVMName `
            -Name "ResetPassword" `
            -Location $location `
            -UserName $linuxUsername `
            -Password $newPassword `
            -TypeHandlerVersion "1.5" `
            -Publisher "Microsoft.OSTCExtensions" `
            -Type "VMAccessForLinux"

        Write-Host "✅ Linux password reset completed for user '$linuxUsername'."
    } catch {
        Write-Warning "⚠️ Failed to reset Linux password on VM '$newVMName'. Error: $_"
    }
}

# ---------------------------- DELETE SNAPSHOTS AFTER VM CREATION ----------------------------
try {
    Remove-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -Force
    Write-Host "Deleted OS snapshot '$snapshotOSName'."
} catch {
    Write-Warning "Failed to delete OS snapshot '$snapshotOSName'. Error: $_"
}

foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
    $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
    try {
        Remove-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -Force
        Write-Host "Deleted data disk snapshot '$snapshotName'."
    } catch {
        Write-Warning "Failed to delete data disk snapshot '$snapshotName'. Error: $_"
    }
}

Write-Host "`n✅ VM '$newVMName' cloned from '$sourceVMName'. OS/data disks attached, static IP set. SSH-only: $useSSHOnly"
