# Parameters
$ResourceGroupName = "BAB-DEV-SVCNOW-SWEC-RG-01"
$ExcludedVMName = "DASNWAPTMDWV1"
$SnapshotPrefix = "snapshot"
$Location = "swedencentral"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"  # Shared timestamp for consistency

# Optional: Login
# Connect-AzAccount

# Function to extract disk name from resource ID
function Get-DiskNameFromId {
    param ([string]$diskId)
    return ($diskId -split "/")[-1]
}

# Get all VMs in the RG, excluding the specified VM
$VMs = Get-AzVM -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name -ne $ExcludedVMName }

foreach ($vm in $VMs) {
    $vmName = $vm.Name
    Write-Host "`nProcessing VM: $vmName"

    # Get OS Disk
    $osDiskId = $vm.StorageProfile.OSDisk.ManagedDisk.Id
    $osDiskName = Get-DiskNameFromId $osDiskId
    $osSnapshotName = "$SnapshotPrefix-$vmName-os-$timestamp"

    # Skip if OS snapshot already exists
    if (Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $osSnapshotName -ErrorAction SilentlyContinue) {
        Write-Host "⚠️ OS snapshot already exists: $osSnapshotName — skipping."
    } else {
        $osDiskObj = Get-AzDisk -DiskName $osDiskName -ResourceGroupName $ResourceGroupName
        $osSnapshotConfig = New-AzSnapshotConfig -SourceUri $osDiskObj.Id `
                                                 -Location $Location `
                                                 -CreateOption Copy `
                                                 -SkuName Standard_LRS
        try {
            New-AzSnapshot -Snapshot $osSnapshotConfig -SnapshotName $osSnapshotName -ResourceGroupName $ResourceGroupName
            Write-Host "✅ Created OS snapshot: $osSnapshotName"
        }
        catch {
            Write-Warning "❌ Failed to create OS snapshot for $vmName. Error: $_"
        }
    }

    # Snapshot each data disk
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $dataDiskId = $dataDisk.ManagedDisk.Id
        $dataDiskName = Get-DiskNameFromId $dataDiskId
        $dataSnapshotName = "$SnapshotPrefix-$vmName-data${dataDisk.Lun}-$timestamp"

        # Skip if data snapshot already exists
        if (Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $dataSnapshotName -ErrorAction SilentlyContinue) {
            Write-Host "⚠️ Data snapshot already exists: $dataSnapshotName — skipping."
        } else {
            $dataDiskObj = Get-AzDisk -DiskName $dataDiskName -ResourceGroupName $ResourceGroupName
            $dataSnapshotConfig = New-AzSnapshotConfig -SourceUri $dataDiskObj.Id `
                                                       -Location $Location `
                                                       -CreateOption Copy `
                                                       -SkuName Standard_LRS
            try {
                New-AzSnapshot -Snapshot $dataSnapshotConfig -SnapshotName $dataSnapshotName -ResourceGroupName $ResourceGroupName
                Write-Host "✅ Created Data snapshot: $dataSnapshotName"
            }
            catch {
                Write-Warning "❌ Failed to create Data snapshot for $vmName (LUN $($dataDisk.Lun)). Error: $_"
            }
        }
    }
}

Write-Host "`n🎉 Snapshot process completed."