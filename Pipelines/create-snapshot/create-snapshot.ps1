param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ExcludedVMNames
)

Write-Host "DEBUG: ResourceGroupName='$ResourceGroupName'"
Write-Host "DEBUG: ExcludedVMNames='$ExcludedVMNames'"

$ErrorActionPreference = 'Stop'
$SnapshotPrefix = "snapshot"
$DateStamp     = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = "C:\log\snapshot_log.txt"

# --- DEBUG: Show what is being passed from YAML ---
"DEBUG: Received ExcludedVMNames='$ExcludedVMNames'" | Tee-Object -FilePath $LogFile -Append
Write-Host "DEBUG: Received ExcludedVMNames='$ExcludedVMNames'"

function IsExcluded($vmName, $excludedNames) {
    if ([string]::IsNullOrWhiteSpace($excludedNames) -or $excludedNames.ToLower() -eq "none") {
        return $false
    }
    $excludedList = $excludedNames -split ',' | ForEach-Object { $_.Trim() }
    return $excludedList -contains $vmName
}

# Ensure log folder exists
if (-not (Test-Path "C:\log")) { New-Item -Path "C:\log" -ItemType Directory | Out-Null }

# Overwrite the log file at the start
"" | Out-File -FilePath $LogFile -Encoding utf8

# Check if az CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    "Azure CLI (az) is not installed or not in PATH." | Tee-Object -FilePath $LogFile -Append
    exit 1
}

# Check if logged in
try {
    az account show -o none
} catch {
    "Not logged in to Azure CLI. Please login before running this script." | Tee-Object -FilePath $LogFile -Append
    exit 1
}

# Get all VM names in the resource group
$vms = az vm list --resource-group $ResourceGroupName --query "[].name" -o tsv | ForEach-Object { $_.Trim() }

# Parallelize per VM
$vms | ForEach-Object -Parallel {
    param($vmName, $ResourceGroupName, $ExcludedVMNames, $SnapshotPrefix, $DateStamp, $LogFile)

    function IsExcluded($vmName, $excludedNames) {
        if ([string]::IsNullOrWhiteSpace($excludedNames) -or $excludedNames.ToLower() -eq "none") {
            return $false
        }
        $excludedList = $excludedNames -split ',' | ForEach-Object { $_.Trim() }
        return $excludedList -contains $vmName
    }

    try {
        # Disk location cache for this VM
        $diskLocationCache = @{}

        if (IsExcluded $vmName $ExcludedVMNames) {
            "Skipping excluded VM: $vmName" | Tee-Object -FilePath $LogFile -Append
            return
        }

        "Processing VM: $vmName" | Tee-Object -FilePath $LogFile -Append

        # ----- OS Disk -----
        $osDiskId = az vm show -g $ResourceGroupName -n $vmName --query "storageProfile.osDisk.managedDisk.id" -o tsv
        if (-not $osDiskId) {
            "ERROR: No OS disk found for VM $vmName. Skipping." | Tee-Object -FilePath $LogFile -Append
            return
        }
        $osDiskName = Split-Path $osDiskId -Leaf
        if (-not $diskLocationCache.ContainsKey($osDiskId)) {
            $diskLocationCache[$osDiskId] = az disk show --ids $osDiskId --query location -o tsv
        }
        $location = $diskLocationCache[$osDiskId]
        $osSnapshotName = "$SnapshotPrefix-$vmName-os-$DateStamp"

        $snapshotExists = az snapshot show -g $ResourceGroupName -n $osSnapshotName -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            az snapshot create -g $ResourceGroupName -n $osSnapshotName --source $osDiskId --location $location --sku Standard_LRS
            "✅ Created OS snapshot: $osSnapshotName" | Tee-Object -FilePath $LogFile -Append
        } else {
            "⚠️ OS snapshot already exists: $osSnapshotName — skipping." | Tee-Object -FilePath $LogFile -Append
        }

        # ----- Data Disks -----
        $dataDisks = az vm show -g $ResourceGroupName -n $vmName --query "storageProfile.dataDisks[]" -o json | ConvertFrom-Json
        if ($null -eq $dataDisks) { 
            "No data disks for VM: $vmName" | Tee-Object -FilePath $LogFile -Append
            "Finished VM: $vmName" | Tee-Object -FilePath $LogFile -Append
            return
        }

        foreach ($dataDisk in $dataDisks) {
            $dataDiskId = $dataDisk.managedDisk.id
            $lun = $dataDisk.lun
            if (-not $diskLocationCache.ContainsKey($dataDiskId)) {
                $diskLocationCache[$dataDiskId] = az disk show --ids $dataDiskId --query location -o tsv
            }
            $location = $diskLocationCache[$dataDiskId]
            $dataSnapshotName = "$SnapshotPrefix-$vmName-data$lun-$DateStamp"

            $snapshotExists = az snapshot show -g $ResourceGroupName -n $dataSnapshotName -o none 2>$null
            if ($LASTEXITCODE -ne 0) {
                az snapshot create -g $ResourceGroupName -n $dataSnapshotName --source $dataDiskId --location $location --sku Standard_LRS
                "✅ Created Data snapshot: $dataSnapshotName" | Tee-Object -FilePath $LogFile -Append
            } else {
                "⚠️ Data snapshot already exists: $dataSnapshotName — skipping." | Tee-Object -FilePath $LogFile -Append
            }
        }
        "Finished VM: $vmName" | Tee-Object -FilePath $LogFile -Append
    } catch {
        "❌ Error processing VM $($vmName): $($_)" | Tee-Object -FilePath $LogFile -Append
    }
} -ArgumentList $ResourceGroupName, $ExcludedVMNames, $SnapshotPrefix, $DateStamp, $LogFile -ThrottleLimit 4

"`n🎉 Snapshot process completed." | Tee-Object -FilePath $LogFile -Append