# Parameters
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$ResourceGroupNames = @("bab-dev-apex-swec-rg-01"),
    
    [Parameter(Mandatory = $false)]
    [string]$ExcludedVMName = "",
    
    [Parameter(Mandatory = $false)]
    [string]$SnapshotPrefix = "snapshot",
    
    [Parameter(Mandatory = $false)]
    [string]$Location = "swedencentral"
)

$dateStamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Function to extract disk name from resource ID
function Get-DiskNameFromId {
    param ([string]$diskId)
    return ($diskId -split "/")[-1]
}

# Process each resource group
foreach ($ResourceGroupName in $ResourceGroupNames) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Processing Resource Group: $ResourceGroupName" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Verify resource group exists
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Warning "❌ Resource Group '$ResourceGroupName' not found. Skipping..."
        continue
    }

    # Get all VMs in the RG, excluding the specified VM
    $VMs = Get-AzVM -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name -ne $ExcludedVMName }
    
    if ($VMs.Count -eq 0) {
        Write-Host "⚠️ No VMs found in resource group '$ResourceGroupName'. Skipping..." -ForegroundColor Yellow
        continue
    }

    Write-Host "Found $($VMs.Count) VM(s) to process in '$ResourceGroupName'`n"

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
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "🎉 Snapshot process completed for all resource groups." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green