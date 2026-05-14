# Set variables
$ResourceGroup = "bab-sit-bpm-swec-rg-01"
$BrokenVM = "DABPMAPWSILV1"
$RescueVM = "repair-DABPMAP_"
# Specify the resource group for the rescue VM (can be different from $ResourceGroup)
$RescueVMResourceGroup = "repair-DABPMAPWSILV1-20260430051549"  # Change if rescue VM is in a different RG
$SnapshotSuffix = "-snap"
$CopySuffix = "-copy"

# Get all data disks (exclude OS disk)
$vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $BrokenVM
$dataDisks = $vm.StorageProfile.DataDisks

# Get rescue VM object once (from its own resource group)
$rescueVM = Get-AzVM -ResourceGroupName $RescueVMResourceGroup -Name $RescueVM
$updatedRescueVM = $rescueVM

foreach ($diskRef in $dataDisks) {
    $diskName = $diskRef.Name
    $disk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $diskName

    # Create or get snapshot
    $snapshotName = $diskName + $SnapshotSuffix
    $snapshot = $null
    $snapshotExists = $false
    try {
        $snapshot = Get-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $snapshotName -ErrorAction Stop
        $snapshotExists = $true
        Write-Host "Snapshot $snapshotName already exists. Skipping creation."
    } catch {
        $snapshotConfig = New-AzSnapshotConfig -SourceUri $disk.Id -Location $disk.Location -CreateOption Copy
        $snapshot = New-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $snapshotName -Snapshot $snapshotConfig
        Write-Host "Created snapshot $snapshotName."
    }

    # Create or get copy disk from snapshot
    $copyDiskName = $diskName + $CopySuffix
    $copyDisk = $null
    $copyDiskExists = $false
    try {
        $copyDisk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $copyDiskName -ErrorAction Stop
        $copyDiskExists = $true
        Write-Host "Copy disk $copyDiskName already exists. Skipping creation."
    } catch {
        $diskConfig = New-AzDiskConfig -Location $disk.Location -CreateOption Copy -SourceResourceId $snapshot.Id
        $copyDisk = New-AzDisk -ResourceGroupName $ResourceGroup -DiskName $copyDiskName -Disk $diskConfig
        Write-Host "Created copy disk $copyDiskName."
    }

    # Skip attach if disk is already attached to rescue VM
    $alreadyAttached = $false
    if ($copyDisk -and $copyDisk.Id) {
        # Check if disk is already attached
        foreach ($existingDataDisk in $updatedRescueVM.StorageProfile.DataDisks) {
            if ($existingDataDisk.ManagedDisk.Id -eq $copyDisk.Id) {
                $alreadyAttached = $true
                break
            }
        }
        if ($alreadyAttached) {
            Write-Host "$copyDiskName is already attached to $RescueVM (RG: $RescueVMResourceGroup). Skipping attach."
        } else {
            # Find next available LUN on rescue VM
            $usedLuns = @()
            foreach ($existingDataDisk in $updatedRescueVM.StorageProfile.DataDisks) {
                $usedLuns += $existingDataDisk.Lun
            }
            $nextLun = 0
            while ($usedLuns -contains $nextLun) { $nextLun++ }
            $updatedRescueVM = Add-AzVMDataDisk -VM $updatedRescueVM -Name $copyDiskName -CreateOption Attach -ManagedDiskId $copyDisk.Id -Lun $nextLun
            Write-Host "Prepared to attach $copyDiskName to $RescueVM (RG: $RescueVMResourceGroup) at next available LUN $nextLun"
            # Refresh the rescue VM object so next iteration sees the new disk
            $updatedRescueVM = Update-AzVM -ResourceGroupName $RescueVMResourceGroup -VM $updatedRescueVM
            # Debug: Output the value of $RescueVM before using it as the VM name
            Write-Host "DEBUG: Fetching rescue VM with name: $RescueVM from RG: $RescueVMResourceGroup"
            if ($RescueVM -isnot [string]) {
                Write-Warning "Rescue VM variable is not a string. Resetting to VM name."
                $RescueVM = $updatedRescueVM.Name
            }
            $updatedRescueVM = Get-AzVM -ResourceGroupName $RescueVMResourceGroup -Name $RescueVM
        }
    } else {
        Write-Warning "Copy disk $copyDiskName could not be created or found. Skipping attach."
    }
}

# Final update is not needed as we update after each attach
Write-Host "All data disks attached to $RescueVM (RG: $RescueVMResourceGroup)."