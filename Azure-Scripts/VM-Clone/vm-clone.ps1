# ---------------------------- CONFIGURATION ----------------------------
$sourceResourceGroup = "bab-dev-BDS-swec-rg-01"
$targetResourceGroup = "bab-dev-BDS-swec-rg-01"
$sourceVMName = "DABDMDBSQDWV1-test"
$newVMName = "DABDMDBSQDWV1"
$location = "swedencentral"
$vnetrg  = "bab-dev-nw-swec-rg-01"
$vnetName = "bab-dev-nw-swec-vnet-nonpci-01"
$subnetName = "snet-dev-nonpci-db-03"
$nsgName = "test-ad-join-nsg"
$nsgrg ="bab-dev-shp-swec-rg-01"
$vmSize = "Standard_D2ls_v5"
$useSSHOnly = $false  # Set to $false if you want password login for Linux

# ---------------------------- STOP SOURCE VM ----------------------------
$sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName
if (-not $sourceVM) {
    throw "Source VM '$sourceVMName' not found in resource group '$sourceResourceGroup'."
}
# Stop-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName -Force -NoWait
# Write-Host "Waiting for VM to deallocate..."

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
Write-Host "OS Disk ID: $($osDisk.Id)"

# ---------------------------- OS DISK SNAPSHOT ----------------------------
# Check if the OS snapshot already exists
$snapshotOSName = "$newVMName-OSSnapshot"
$snapshotOS = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -ErrorAction SilentlyContinue
if (-not $snapshotOS) {
    Write-Host "Creating OS snapshot '$snapshotOSName'..."
    $snapshotOS = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName `
        -Snapshot (New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $location -CreateOption Copy)
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
    $disk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name

    # Check if the data disk snapshot already exists
    $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
    $snapshot = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -ErrorAction SilentlyContinue
    if (-not $snapshot) {
        Write-Host "Creating snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)'..."
        $snapshot = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName `
            -Snapshot (New-AzSnapshotConfig -SourceUri $disk.Id -Location $location -CreateOption Copy)
    } else {
        Write-Host "Snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)' already exists. Skipping creation."
    }

    # Check if the cloned data disk already exists
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

# Specify the desired static private IP address
$staticIpAddress = "10.189.57.222"  # Replace with your desired IP address

$nic = New-AzNetworkInterface -Name "$newVMName-NIC" -ResourceGroupName $targetResourceGroup `
    -Location $location `
    -SubnetId $subnet.Id `
    -NetworkSecurityGroupId $nsg.Id `
    -PrivateIpAddress $staticIpAddress

# ---------------------------- CONFIGURE NEW VM ----------------------------
$vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmSize

$osType = $sourceVM.StorageProfile.OsDisk.OsType

if ($osType -eq "Linux") {
    # Attach the OS disk without setting an OS profile
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Linux
} elseif ($osType -eq "Windows") {
    # Attach the OS disk without setting an OS profile
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
# Specify the storage account for boot diagnostics
$bootDiagStorageAccountName = "babdevvmbootdiag02"
$bootdiagstracctrg = "bab-dev-vm-boot-diag-swec-rg-01"  
$bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $bootdiagstracctrg -Name $bootDiagStorageAccountName

if (-not $bootDiagStorageAccount) {
    throw "Boot diagnostics storage account '$bootDiagStorageAccountName' not found in resource group '$bootdiagstracctrg'."
}

# Enable boot diagnostics directly in the VM configuration
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

Write-Host "`n✅ VM '$newVMName' cloned from '$sourceVMName'. OS/data disks and NSG attached. No public IP."
