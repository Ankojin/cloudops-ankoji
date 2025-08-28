param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ExcludedVMName = ""
)

$ErrorActionPreference = 'Stop'
$SnapshotPrefix = "snapshot"
$dateStamp      = Get-Date -Format "yyyyMMdd-HHmmss"

function Get-DiskNameFromId {
    param ([string]$diskId)
    return ($diskId -split "/")[-1]
}

# Treat empty string or "none" as no exclusion
if ([string]::IsNullOrWhiteSpace($ExcludedVMName) -or $ExcludedVMName.ToLower() -eq "none") {
    $excludedList = @()
} else {
    $excludedList = $ExcludedVMName -split ',' | ForEach-Object { $_.Trim() }
}

$VMs = Get-AzVM -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name -notin $excludedList }

foreach ($vm in $VMs) {
    $vmName = $vm.Name
    Write-Host "`nProcessing VM: $vmName"

    # ----- OS Disk -----
    $osSnapshotName = "$SnapshotPrefix-$vmName-os-$dateStamp"
    if (-not (Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $osSnapshotName -ErrorAction SilentlyContinue)) {
        $osDiskName = Get-DiskNameFromId $vm.StorageProfile.OSDisk.ManagedDisk.Id
        $osDiskObj  = Get-AzDisk -DiskName $osDiskName -ResourceGroupName $ResourceGroupName
        $Location   = $osDiskObj.Location

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
        $dataSnapshotName = "$SnapshotPrefix-$vmName-data$lun-$dateStamp"

        if (-not (Get-AzSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $dataSnapshotName -ErrorAction SilentlyContinue)) {
            $dataDiskName = Get-DiskNameFromId $dataDisk.ManagedDisk.Id
            $dataDiskObj  = Get-AzDisk -DiskName $dataDiskName -ResourceGroupName $ResourceGroupName
            $Location     = $dataDiskObj.Location

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