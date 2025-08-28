param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludedVMList = @()
)

$ErrorActionPreference = 'Stop'
$SnapshotPrefix = "snapshot"
$DateStamp     = Get-Date -Format "yyyyMMdd-HHmmss"

function IsExcluded($vmName, $excludedList) {
    return $excludedList -contains $vmName
}

# Get all VM names in the resource group
$vms = az vm list --resource-group $ResourceGroupName --query "[].name" -o tsv | ForEach-Object { $_.Trim() }

foreach ($vmName in $vms) {
    if (IsExcluded $vmName $ExcludedVMList) {
        Write-Host "Skipping excluded VM: $vmName"
        continue
    }

    Write-Host "`nProcessing VM: $vmName"

    # ----- OS Disk -----
    $osDiskId = az vm show -g $ResourceGroupName -n $vmName --query "storageProfile.osDisk.managedDisk.id" -o tsv
    $osDiskName = Split-Path $osDiskId -Leaf
    $location = az disk show --ids $osDiskId --query location -o tsv
    $osSnapshotName = "$SnapshotPrefix-$vmName-os-$DateStamp"

    if (-not (az snapshot show -g $ResourceGroupName -n $osSnapshotName -o none 2>$null)) {
        az snapshot create -g $ResourceGroupName -n $osSnapshotName --source $osDiskId --location $location --sku Standard_LRS
        Write-Host "✅ Created OS snapshot: $osSnapshotName"
    } else {
        Write-Host "⚠️ OS snapshot already exists: $osSnapshotName — skipping."
    }

    # ----- Data Disks -----
    $dataDiskIds = az vm show -g $ResourceGroupName -n $vmName --query "storageProfile.dataDisks[].managedDisk.id" -o tsv
    $lunIndex = 0
    foreach ($dataDiskId in $dataDiskIds) {
        $dataDiskName = Split-Path $dataDiskId -Leaf
        $location = az disk show --ids $dataDiskId --query location -o tsv
        $dataSnapshotName = "$SnapshotPrefix-$vmName-data$lunIndex-$DateStamp"

        if (-not (az snapshot show -g $ResourceGroupName -n $dataSnapshotName -o none 2>$null)) {
            az snapshot create -g $ResourceGroupName -n $dataSnapshotName --source $dataDiskId --location $location --sku Standard_LRS
            Write-Host "✅ Created Data snapshot: $dataSnapshotName"
        } else {
            Write-Host "⚠️ Data snapshot already exists: $dataSnapshotName — skipping."
        }
        $lunIndex++
    }
}

Write-Host "`n🎉 Snapshot process completed."