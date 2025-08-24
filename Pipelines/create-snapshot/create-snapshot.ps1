param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$false)]
    [string]$ExcludedVMName = ""
)

$ResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } else { Read-Host "Enter the Resource Group Name" }
if (-not $ExcludedVMName) {
    $ExcludedVMName = Read-Host "Enter the VM name to exclude (press Enter to skip)"
}
$SnapshotPrefix    = "snapshot"
$Location          = "swedencentral"
$dateStamp         = Get-Date -Format "yyyyMMdd-HHmmss"   # date only

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

    # ----- OS Disk -----
    $osSnapshotName = "$SnapshotPrefix-$vmName-os-$dateStamp"
    if (-not (Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $osSnapshotName -ErrorAction SilentlyContinue)) {
        $osDiskName = Get-DiskNameFromId $vm.StorageProfile.OSDisk.ManagedDisk.Id
        $osDiskObj  = Get-AzDisk -DiskName $osDiskName -ResourceGroupName $ResourceGroupName
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
    else {
        Write-Host "⚠️ OS snapshot already exists: $osSnapshotName — skipping."
    }

    # ----- Data Disks -----
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $lun = $dataDisk.Lun
        $dataSnapshotName = "$SnapshotPrefix-$vmName-data$lun-$dateStamp"   # <-- UNIQUE per LUN

        if (-not (Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $dataSnapshotName -ErrorAction SilentlyContinue)) {
            $dataDiskName = Get-DiskNameFromId $dataDisk.ManagedDisk.Id
            $dataDiskObj  = Get-AzDisk -DiskName $dataDiskName -ResourceGroupName $ResourceGroupName
            $dataSnapshotConfig = New-AzSnapshotConfig -SourceUri $dataDiskObj.Id `
                                                       -Location $Location `
                                                       -CreateOption Copy `
                                                       -SkuName Standard_LRS
            try {
                New-AzSnapshot -Snapshot $dataSnapshotConfig -SnapshotName $dataSnapshotName -ResourceGroupName $ResourceGroupName
                Write-Host "✅ Created Data snapshot: $dataSnapshotName"
            }
            catch {
                Write-Warning "❌ Failed to create Data snapshot for $vmName (LUN $lun). Error: $_"
            }
        }
        else {
            Write-Host "⚠️ Data snapshot already exists: $dataSnapshotName — skipping."
        }
    }
}

Write-Host "`n🎉 Snapshot process completed."