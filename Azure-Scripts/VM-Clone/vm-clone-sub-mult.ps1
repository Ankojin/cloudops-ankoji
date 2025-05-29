# ---------------------------- CONFIGURATION ----------------------------
$sourceSubscriptionId = "e48414cd-f96d-4414-ae9e-da7fec844f77"
$targetSubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$sourceResourceGroup = "bab-sit-mub-swec-rg-01"
$targetResourceGroup = "bab-dev-mub-swec-rg-01"
$location = "swedencentral"
$vnetrg  = "bab-dev-nw-swec-rg-01"
$vnetName = "bab-dev-nw-swec-vnet-nonpci-01"
$vmSize = "Standard_D2ls_v5"
$csvPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\VM-Clone\vms-to-clone.csv"

# DRY RUN: Set to $true to only print actions, not execute them
$dryRun = $false

# CSV columns: SourceVMName,NewVMName,StaticIp,SubnetName,VMSize
if (Test-Path $csvPath) {
    Write-Host "Importing VM definitions from CSV: $csvPath"
    $vmsToClone = Import-Csv -Path $csvPath
} else {

    throw "CSV file with VM definitions not found at $csvPath. Please provide the file."
}

foreach ($vm in $vmsToClone) {
    $sourceVMName = $vm.SourceVMName
    $newVMName = $vm.NewVMName
    $staticIpAddress = $vm.StaticIp
    $vmSubnetName = if ($vm.PSObject.Properties.Match('SubnetName')) { $vm.SubnetName } else { "" }
    $vmVmSize = if ($vm.PSObject.Properties.Match('VMSize') -and $vm.VMSize) { $vm.VMSize } else { $vmSize }

    Write-Host "`n--- Starting clone for VM '$sourceVMName' as '$newVMName' ---"

    if ($dryRun) {
        Write-Host "[DRY RUN] Would switch to source subscription: $sourceSubscriptionId"
    } else {
        # ---------------------------- SWITCH TO SOURCE SUBSCRIPTION ----------------------------
        Set-AzContext -SubscriptionId $sourceSubscriptionId
    }

    # ---------------------------- Get SOURCE VM ----------------------------
    if ($dryRun) {
        Write-Host "[DRY RUN] Would get source VM '$sourceVMName' in resource group '$sourceResourceGroup'"
        # Simulate sourceVM object for dry run
        continue
    } else {
        try {
            $sourceVM = Get-AzVM -ResourceGroupName $sourceResourceGroup -Name $sourceVMName -ErrorAction Stop
        } catch {
            Write-Warning "Source VM '$sourceVMName' not found in resource group '$sourceResourceGroup'. Skipping."
            continue
        }
    }

    if (-not $sourceVM.StorageProfile -or -not $sourceVM.StorageProfile.OsDisk) {
        Write-Warning "Source VM '$sourceVMName' does not have a valid OS disk. Skipping."
        continue
    }

    try {
        $osDisk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $sourceVM.StorageProfile.OsDisk.Name -ErrorAction Stop
    } catch {
        Write-Warning "OS disk for VM '$sourceVMName' could not be retrieved. Skipping."
        continue
    }

    Write-Host "OS Disk Name: $($sourceVM.StorageProfile.OsDisk.Name)"
    Write-Host "OS Disk ID: $($osDisk.Id)"

    if (-not $osDisk.Id) {
        Write-Warning "OS Disk ID is null for VM '$sourceVMName'. Skipping."
        continue
    }

    if ($dryRun) {
        Write-Host "[DRY RUN] Would get OS disk for VM '$sourceVMName'"
        Write-Host "[DRY RUN] Would switch to target subscription: $targetSubscriptionId"
        Write-Host "[DRY RUN] Would create/check OS snapshot and disk for '$newVMName'"
        Write-Host "[DRY RUN] Would clone data disks for '$newVMName'"
        Write-Host "[DRY RUN] Would create NIC in subnet '$vmSubnetName' with static IP '$staticIpAddress'"
        Write-Host "[DRY RUN] Would create VM '$newVMName' with size '$vmVmSize'"
        Write-Host "[DRY RUN] Would enable boot diagnostics for '$newVMName'"
        Write-Host "[DRY RUN] Would delete snapshots for '$newVMName'"
        Write-Host "[DRY RUN] Would finish clone for '$newVMName'"
        continue
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
        Set-AzContext -SubscriptionId $sourceSubscriptionId
        try {
            $disk = Get-AzDisk -ResourceGroupName $sourceResourceGroup -DiskName $dataDisk.Name -ErrorAction Stop
        } catch {
            Write-Warning "Data disk '$($dataDisk.Name)' could not be retrieved. Skipping..."
            continue
        }

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
    #$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgrg -Name $nsgName
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg -ErrorAction Stop
    $subnetNameToUse = if ($vmSubnetName) { $vmSubnetName } else { "" }
    if (-not $subnetNameToUse) {
        Write-Warning "No subnet specified for VM '$newVMName'. Skipping."
        continue
    }
    $subnet = $vnet | Get-AzVirtualNetworkSubnetConfig -Name $subnetNameToUse
    if (-not $subnet) {
        Write-Warning "Subnet '$subnetNameToUse' not found in vNet '$vnetName'. Skipping."
        continue
    }

    $nicParams = @{
        Name = "$newVMName-NIC"
        ResourceGroupName = $targetResourceGroup
        Location = $location
        SubnetId = $subnet.Id
        PrivateIpAddress = $staticIpAddress
    }
    # Uncomment and set NSG if needed
    # $nicParams.NetworkSecurityGroupId = $nsg.Id

    if ($dryRun) {
        Write-Host "[DRY RUN] Would create NIC with parameters: $nicParams"
    } else {
        $nic = New-AzNetworkInterface @nicParams
    }

    # ---------------------------- CONFIGURE NEW VM ----------------------------
    $vmConfig = New-AzVMConfig -VMName $newVMName -VMSize $vmVmSize
    $osType = $sourceVM.StorageProfile.OsDisk.OsType

    if ($osType -eq "Linux") {
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Linux
    } elseif ($osType -eq "Windows") {
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newOSDisk.Id -CreateOption Attach -Windows
    } else {
        Write-Warning "Unknown OS type: $osType for VM '$sourceVMName'. Skipping."
        continue
    }

    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

    foreach ($disk in $newDataDisks) {
        $vmConfig = Add-AzVMDataDisk -VM $vmConfig `
            -ManagedDiskId $disk.Id -CreateOption Attach -Lun $disk.Lun
    }

    # ---------------------------- ENABLE BOOT DIAGNOSTICS ----------------------------
    $bootDiagStorageAccountName = "babdevvmbootdiag02"
    $bootdiagstracctrg = "bab-dev-vm-boot-diag-swec-rg-01"  
    $bootDiagStorageAccount = Get-AzStorageAccount -ResourceGroupName $bootdiagstracctrg -Name $bootDiagStorageAccountName

    if (-not $bootDiagStorageAccount) {
        Write-Warning "Boot diagnostics storage account '$bootDiagStorageAccountName' not found in resource group '$bootdiagstracctrg'. Skipping VM '$newVMName'."
        continue
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
        Write-Warning "Failed to create the new VM '$newVMName'. Error: $_"
        continue
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

    Write-Host "`n✅ VM '$newVMName' cloned from '$sourceVMName'. OS/data disks and NSG attached."
}