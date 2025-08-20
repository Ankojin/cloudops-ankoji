# ---------------------------- CONFIGURATION ----------------------------
$sourceResourceGroup = "BAB-VDI-AVD-WEEU-RG-01"
$targetResourceGroup = "BAB-VDI-AVD-WEEU-RG-01"
$location = "westeurope"
$vnetrg  = "bab-vdi-nw-weeu-rg-01"
$vnetName = "bab-vdi-nw-weeu-vnet-vdi-01"
$nsgName = "test-ad-join-nsg"
$nsgrg = "bab-vdi-avd-weeu-rg-01"
$useSSHOnly = $true  # Set to $false if you want password login for Linux

# Specify the path to your CSV file
$csvPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\VM-Clone\vms-to-clone.csv"

# ---------------------------- NSG, VNET, BOOT DIAG ----------------------------
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgrg -Name $nsgName
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg

$bootDiagStorageAccountName = "babvdivmbootdiag01"
$bootdiagstracctrg = "bab-vdi-avd-weeu-rg-01"
$bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $bootdiagstracctrg -Name $bootDiagStorageAccountName
if (-not $bootDiagStorageAccount) {
    throw "Boot diagnostics storage account '$bootDiagStorageAccountName' not found in resource group '$bootdiagstracctrg'."
}

# ---------------------------- LOOP THROUGH CSV ----------------------------
Import-Csv $csvPath | ForEach-Object {
    $sourceVMName = $_.SourceVMName
    $newVMName = $_.NewVMName
    $staticIpAddress = $_.StaticIp
    $subnetName = $_.SubnetName
    $vmSize = $_.VMSize

    Write-Host "`n--- Cloning VM: $sourceVMName to $newVMName ---"

    $sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName
    if (-not $sourceVM) {
        Write-Warning "Source VM '$sourceVMName' not found. Skipping."
        return
    }

    if (-not $sourceVM.StorageProfile -or -not $sourceVM.StorageProfile.OsDisk) {
        Write-Warning "Source VM '$sourceVMName' does not have a valid OS disk. Skipping."
        return
    }

    $osDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $sourceVM.StorageProfile.OsDisk.Name
    if (-not $osDisk) {
        Write-Warning "OS disk for VM '$sourceVMName' could not be retrieved. Skipping."
        return
    }

    $snapshotOSName = "$newVMName-OSSnapshot"
    $snapshotOS = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName -ErrorAction SilentlyContinue
    if (-not $snapshotOS) {
        Write-Host "Creating OS snapshot '$snapshotOSName'..."
        $snapshotOS = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotOSName `
            -Snapshot (New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $location -CreateOption Copy -SkuName Standard_LRS)
    } else {
        Write-Host "OS snapshot '$snapshotOSName' already exists. Skipping creation."
    }

    $newOSDiskName = "$newVMName-OSDisk"
    $newOSDisk = Get-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName -ErrorAction SilentlyContinue
    if (-not $newOSDisk) {
        Write-Host "Creating OS disk '$newOSDiskName'..."
        $newOSDisk = New-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $newOSDiskName `
            -Disk (New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $snapshotOS.Id -SkuName StandardSSD_LRS)
    } else {
        Write-Host "OS disk '$newOSDiskName' already exists. Skipping creation."
    }

    # Clone data disks
    $newDataDisks = @()
    foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
        $disk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name
        $snapshotName = "$newVMName-DataDisk-$($dataDisk.Lun)-Snap"
        $snapshot = Get-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName -ErrorAction SilentlyContinue
        if (-not $snapshot) {
            Write-Host "Creating snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)'..."
            $snapshot = New-AzSnapshot -ResourceGroupName $targetResourceGroup -SnapshotName $snapshotName `
                -Snapshot (New-AzSnapshotConfig -SourceUri $disk.Id -Location $location -CreateOption Copy -SkuName Standard_LRS)
        } else {
            Write-Host "Snapshot '$snapshotName' for data disk with LUN '$($dataDisk.Lun)' already exists. Skipping creation."
        }

        $clonedDiskName = "$newVMName-DataDisk-$($dataDisk.Lun)"
        $clonedDisk = Get-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $clonedDiskName -ErrorAction SilentlyContinue
        if (-not $clonedDisk) {
            Write-Host "Creating cloned disk '$clonedDiskName'..."
            $clonedDisk = New-AzDisk -ResourceGroupName $targetResourceGroup -DiskName $clonedDiskName `
                -Disk (New-AzDiskConfig -Location $location -CreateOption Copy -SourceResourceId $snapshot.Id -SkuName StandardSSD_LRS)
        } else {
            Write-Host "Cloned disk '$clonedDiskName' already exists. Skipping creation."
        }

        $newDataDisks += [PSCustomObject]@{Id=$clonedDisk.Id; Lun=$dataDisk.Lun}
    }

    # Create NIC
    try {
        $subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetName
        if (-not $subnet) {
            Write-Error "Subnet '$subnetName' not found in VNet '$vnetName'. Exiting."
            return
        }
        $nic = New-AzNetworkInterface -Name "$newVMName-NIC" -ResourceGroupName $targetResourceGroup `
            -Location $location `
            -SubnetId $subnet.Id `
            -PrivateIpAddress $staticIpAddress `
            -NetworkSecurityGroupId $nsg.Id
        if (-not $nic) {
            Write-Error "NIC creation failed for '$newVMName'. Exiting."
            return
        }
    } catch {
        Write-Error "Failed to create NIC for '$newVMName'. Error: $_"
        return
    }

    # Configure new VM
    try {
        $vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmSize
        $osType = $sourceVM.StorageProfile.OsDisk.OsType
        if ($osType -eq "Linux") {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Linux
        } elseif ($osType -eq "Windows") {
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Windows
        } else {
            Write-Error "Unknown OS type: $osType. Exiting."
            return
        }
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

        foreach ($disk in $newDataDisks) {
            $vmConfig = Add-AzVMDataDisk -VM $vmConfig `
                -ManagedDiskId $disk.Id -CreateOption Attach -Lun $disk.Lun
        }

        # Enable boot diagnostics
        $vmConfig.DiagnosticsProfile = @{
            BootDiagnostics = @{
                Enabled = $true
                StorageUri = $bootDiagStorageAccount.PrimaryEndpoints.Blob
            }
        }
    } catch {
        Write-Error "Failed to configure VM '$newVMName'. Exiting."
        return
    }

    # Create the new VM
    try {
        New-AzVM -ResourceGroupName $targetResourceGroup -Location $location -VM $vmConfig
        Write-Host "✅ VM '$newVMName' cloned from '$sourceVMName'."
    } catch {
        Write-Warning "Failed to create the new VM '$newVMName'. Error: $_"
    }

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
}
