<#
.SYNOPSIS
    Convert VM disk storage type from Standard HDD to SSD (Premium or Standard SSD).

.DESCRIPTION
    This script converts OS and/or Data disks for one or more VMs in a specified
    Resource Group from Standard_LRS (HDD) to either Premium_LRS or StandardSSD_LRS.

    Supports:
    - Converting a named list of VMs
    - Converting all VMs in a Resource Group
    - WhatIf/dry-run mode (no changes applied)
    - Deallocating and restarting VMs automatically (required for disk type changes)
    - Resume-safe: skips disks already at the target SKU

.PARAMETER SubscriptionId
    Azure Subscription ID where the VMs reside.

.PARAMETER ResourceGroupName
    Name of the Resource Group containing the target VMs.

.PARAMETER VMNames
    Comma-separated list of VM names to process. Omit to process ALL VMs in the RG.

.PARAMETER TargetSku
    Destination disk SKU. Allowed values: Premium_LRS, StandardSSD_LRS.
    Default: Premium_LRS

.PARAMETER DiskScope
    Which disks to convert: OS, Data, or All.
    Default: All

.PARAMETER WhatIf
    Dry-run mode – reports what would change without making any modifications.

.PARAMETER LogPath
    Directory for log files. Default: C:\Logs\DiskConversion

.EXAMPLE
    # Convert specific VMs to Premium SSD (dry run)
    .\Convert-DiskStorageType.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "RG-Prod-VMs" `
        -VMNames "vm-app01","vm-app02" `
        -TargetSku Premium_LRS `
        -WhatIf

.EXAMPLE
    # Convert ALL VMs in a RG to Standard SSD
    .\Convert-DiskStorageType.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "RG-Prod-VMs" `
        -TargetSku StandardSSD_LRS

.EXAMPLE
    # Convert only OS disks of specific VMs
    .\Convert-DiskStorageType.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "RG-Prod-VMs" `
        -VMNames "vm-db01" `
        -DiskScope OS `
        -TargetSku Premium_LRS

.NOTES
    Author   : BAB CloudOps Team
    Date     : 2026-06-18
    Requires : Az PowerShell module (Az.Compute), Azure authentication
    IMPORTANT: VMs must be deallocated to change disk SKU. This script will
               stop/start VMs automatically. Plan for downtime.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string[]]$VMNames,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Premium_LRS", "StandardSSD_LRS")]
    [string]$TargetSku = "Premium_LRS",

    [Parameter(Mandatory = $false)]
    [ValidateSet("OS", "Data", "All")]
    [string]$DiskScope = "All",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Logs\DiskConversion"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Logging ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry     = "[$timestamp] [$Level] $Message"

    $colorMap = @{
        INFO    = "Cyan"
        WARNING = "Yellow"
        ERROR   = "Red"
        SUCCESS = "Green"
    }
    Write-Host $entry -ForegroundColor $colorMap[$Level]

    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    $logFile = Join-Path $LogPath "DiskConversion-$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value $entry
}

#endregion

#region --- Azure Connection ---

function Connect-ToAzure {
    param([string]$SubId)

    Write-Log "Checking Az.Compute module..."
    if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
        Write-Log "Az.Compute module not found. Installing..." "WARNING"
        Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    }
    Import-Module Az.Compute -ErrorAction Stop

    $context = Get-AzContext
    if (-not $context) {
        Write-Log "No active Azure session. Initiating login..." "WARNING"
        Connect-AzAccount
    }

    Write-Log "Switching to Subscription: $SubId"
    Set-AzContext -SubscriptionId $SubId | Out-Null
    $ctx = Get-AzContext
    Write-Log "Active subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" "SUCCESS"
}

#endregion

#region --- Disk Conversion ---

function Convert-VMDisks {
    param(
        [string]$VMName,
        [string]$RGName,
        [string]$Target,
        [string]$Scope,
        [bool]$DryRun
    )

    Write-Log "------------------------------------------------------------"
    Write-Log "Processing VM: $VMName"

    $vm = Get-AzVM -ResourceGroupName $RGName -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$VMName' not found in resource group '$RGName'. Skipping." "WARNING"
        return
    }

    # Collect disks to convert
    $disksToConvert = @()

    if ($Scope -in "OS", "All") {
        $osDisk = Get-AzDisk -ResourceGroupName $RGName -DiskName $vm.StorageProfile.OsDisk.Name
        if ($osDisk.Sku.Name -ne $Target) {
            $disksToConvert += [PSCustomObject]@{
                Name        = $osDisk.Name
                CurrentSku  = $osDisk.Sku.Name
                DiskType    = "OS"
                DiskObject  = $osDisk
            }
        } else {
            Write-Log "OS disk '$($osDisk.Name)' is already '$Target'. Skipping." "INFO"
        }
    }

    if ($Scope -in "Data", "All") {
        foreach ($dataDiskRef in $vm.StorageProfile.DataDisks) {
            $dataDisk = Get-AzDisk -ResourceGroupName $RGName -DiskName $dataDiskRef.Name
            if ($dataDisk.Sku.Name -ne $Target) {
                $disksToConvert += [PSCustomObject]@{
                    Name        = $dataDisk.Name
                    CurrentSku  = $dataDisk.Sku.Name
                    DiskType    = "Data"
                    DiskObject  = $dataDisk
                }
            } else {
                Write-Log "Data disk '$($dataDisk.Name)' is already '$Target'. Skipping." "INFO"
            }
        }
    }

    if ($disksToConvert.Count -eq 0) {
        Write-Log "No disks require conversion on VM '$VMName'." "SUCCESS"
        return
    }

    Write-Log "Disks to convert on '$VMName':"
    foreach ($d in $disksToConvert) {
        Write-Log "  [$($d.DiskType)] $($d.Name)  |  $($d.CurrentSku) --> $Target"
    }

    if ($DryRun) {
        Write-Log "[WHATIF] Would deallocate '$VMName', convert $($disksToConvert.Count) disk(s), then restart." "WARNING"
        return
    }

    # --- Deallocate VM ---
    $vmStatus = (Get-AzVM -ResourceGroupName $RGName -Name $VMName -Status).Statuses |
                Where-Object { $_.Code -like "PowerState/*" } |
                Select-Object -ExpandProperty Code

    $wasRunning = $vmStatus -eq "PowerState/running"

    if ($wasRunning) {
        Write-Log "Deallocating VM '$VMName'..."
        Stop-AzVM -ResourceGroupName $RGName -Name $VMName -Force | Out-Null
        Write-Log "VM '$VMName' deallocated." "SUCCESS"
    } else {
        Write-Log "VM '$VMName' is already stopped/deallocated."
    }

    # --- Convert each disk ---
    foreach ($disk in $disksToConvert) {
        Write-Log "Converting [$($disk.DiskType)] disk '$($disk.Name)' from '$($disk.CurrentSku)' to '$Target'..."
        $disk.DiskObject.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($Target)
        Update-AzDisk -ResourceGroupName $RGName -DiskName $disk.Name -Disk $disk.DiskObject | Out-Null
        Write-Log "Disk '$($disk.Name)' converted to '$Target'." "SUCCESS"
    }

    # --- Restart if it was running ---
    if ($wasRunning) {
        Write-Log "Restarting VM '$VMName'..."
        Start-AzVM -ResourceGroupName $RGName -Name $VMName | Out-Null
        Write-Log "VM '$VMName' started." "SUCCESS"
    }
}

#endregion

#region --- Main Execution ---

Write-Log "=========================================================="
Write-Log "Disk Storage Type Conversion Script"
Write-Log "Target SKU  : $TargetSku"
Write-Log "Disk Scope  : $DiskScope"
Write-Log "Resource RG : $ResourceGroupName"
Write-Log "Subscription: $SubscriptionId"
if ($WhatIfPreference) { Write-Log "Mode: DRY RUN (WhatIf) - No changes will be made." "WARNING" }
Write-Log "=========================================================="

# Connect to Azure
Connect-ToAzure -SubId $SubscriptionId

# Resolve VM list
if ($VMNames -and $VMNames.Count -gt 0) {
    $targetVMs = $VMNames
    Write-Log "Targeting $($targetVMs.Count) specified VM(s): $($targetVMs -join ', ')"
} else {
    Write-Log "No VMNames specified. Fetching all VMs in resource group '$ResourceGroupName'..."
    $targetVMs = (Get-AzVM -ResourceGroupName $ResourceGroupName).Name
    if (-not $targetVMs) {
        Write-Log "No VMs found in resource group '$ResourceGroupName'. Exiting." "WARNING"
        exit 0
    }
    Write-Log "Found $($targetVMs.Count) VM(s) in RG: $($targetVMs -join ', ')"
}

# Counters
$successCount = 0
$skipCount    = 0
$failCount    = 0

foreach ($vmName in $targetVMs) {
    try {
        Convert-VMDisks `
            -VMName   $vmName `
            -RGName   $ResourceGroupName `
            -Target   $TargetSku `
            -Scope    $DiskScope `
            -DryRun   $WhatIfPreference
        $successCount++
    }
    catch {
        Write-Log "ERROR processing VM '$vmName': $_" "ERROR"
        $failCount++
    }
}

Write-Log "=========================================================="
Write-Log "Conversion Summary"
Write-Log "  Processed : $($successCount + $failCount)"
Write-Log "  Succeeded : $successCount"
Write-Log "  Failed    : $failCount"
Write-Log "=========================================================="

if ($failCount -gt 0) {
    Write-Log "One or more VMs encountered errors. Check the log at: $LogPath" "WARNING"
    exit 1
}

exit 0

#endregion
