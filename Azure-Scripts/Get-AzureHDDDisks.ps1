<#
.SYNOPSIS
    Find all Standard HDD (Standard_LRS) managed disks assigned to VMs in Azure
    and export the results to a CSV file.

.DESCRIPTION
    This script enumerates all VMs across one or more Azure subscriptions,
    identifies OS and data disks that use the Standard HDD SKU (Standard_LRS),
    and exports a report to CSV with columns:
        VMName, ResourceGroup, DiskName, DiskType, DiskSizeGB, LUN

    HDD disk = SKU tier Standard_LRS (as opposed to Premium_LRS / UltraSSD_LRS).

.PARAMETER SubscriptionIds
    One or more Azure Subscription IDs to scan.
    If omitted, the script scans the currently active subscription context.

.PARAMETER OutputPath
    Full path to the output CSV file.
    Defaults to .\HDD-Disks-Report_<timestamp>.csv in the current directory.

.PARAMETER ResourceGroupName
    Optional. Limit the scan to a single resource group.

.EXAMPLE
    Get-AzureHDDDisks.p.\s1

.EXAMPLE
    .\Get-AzureHDDDisks.ps1 -SubscriptionIds "aaaa-bbbb-cccc","dddd-eeee-ffff" `
        -OutputPath "C:\Reports\HDD-Disks.csv"

.EXAMPLE
    .\Get-AzureHDDDisks.ps1 -ResourceGroupName "RG-Production"

.NOTES
    Requires Az PowerShell module (Az.Compute, Az.Accounts).
    Run  Install-Module Az -Scope CurrentUser  if not already installed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = ""
)

#region --- Logging -----------------------------------------------------------
$LogFile = Join-Path $PSScriptRoot ("Get-AzureHDDDisks_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp][$Level] $Message"
    $entry | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor $(
        switch ($Level) {
            "WARN"  { "Yellow" }
            "ERROR" { "Red"    }
            default { "Cyan"   }
        }
    )
}
#endregion

#region --- Validate Az module -----------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    Write-Log "Az.Compute module not found. Install with: Install-Module Az -Scope CurrentUser" -Level ERROR
    exit 1
}
#endregion

#region --- Resolve output path ----------------------------------------------
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot ("HDD-Disks-Report_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".csv")
}

$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    Write-Log "Output directory '$outputDir' does not exist. Creating it." -Level WARN
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
#endregion

#region --- Resolve subscriptions --------------------------------------------
if (-not $SubscriptionIds) {
    try {
        $currentContext = Get-AzContext -ErrorAction Stop
        if (-not $currentContext) {
            Write-Log "No active Azure context found. Run Connect-AzAccount first." -Level ERROR
            exit 1
        }
        $SubscriptionIds = @($currentContext.Subscription.Id)
        Write-Log "No subscription specified – using active context: $($currentContext.Subscription.Name) ($($SubscriptionIds[0]))"
    }
    catch {
        Write-Log "Failed to retrieve Azure context: $_" -Level ERROR
        exit 1
    }
}
#endregion

#region --- Main scan --------------------------------------------------------
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($subId in $SubscriptionIds) {
    try {
        Write-Log "Switching to subscription: $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Cannot switch to subscription '$subId': $_" -Level ERROR
        continue
    }

    # Fetch VMs (optionally scoped to a resource group)
    try {
        if ($ResourceGroupName) {
            Write-Log "Fetching VMs in resource group '$ResourceGroupName'..."
            $vms = Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        }
        else {
            Write-Log "Fetching all VMs in subscription $subId..."
            $vms = Get-AzVM -ErrorAction Stop
        }
    }
    catch {
        Write-Log "Failed to retrieve VMs in subscription '$subId': $_" -Level ERROR
        continue
    }

    Write-Log "Found $($vms.Count) VM(s). Scanning disks..."

    foreach ($vm in $vms) {
        $vmName = $vm.Name
        $rgName = $vm.ResourceGroupName

        # ---- Collect all disk names for this VM (OS + data) ----
        $diskNames = [System.Collections.Generic.List[string]]::new()

        # OS disk
        $osDiskName = $vm.StorageProfile.OsDisk.Name
        if ($osDiskName) {
            $diskNames.Add($osDiskName)
        }

        # Data disks
        foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
            if ($dataDisk.Name) {
                $diskNames.Add($dataDisk.Name)
            }
        }

        if ($diskNames.Count -eq 0) {
            Write-Log "  VM '$vmName' has no managed disks – skipping." -Level WARN
            continue
        }

        # ---- Look up each disk and check SKU ----
        foreach ($diskName in $diskNames) {
            try {
                $disk = Get-AzDisk -ResourceGroupName $rgName -DiskName $diskName -ErrorAction Stop
            }
            catch {
                Write-Log "  Could not retrieve disk '$diskName' for VM '$vmName': $_" -Level WARN
                continue
            }

            $sku = $disk.Sku.Name   # e.g. Standard_LRS, Premium_LRS, UltraSSD_LRS

            # Standard HDD = Standard_LRS
            if ($sku -ne "Standard_LRS") {
                continue
            }

            # Determine OS vs data
            $diskType = if ($diskName -eq $osDiskName) { "OS Disk" } else { "Data Disk" }

            # LUN for data disks
            $lun = ""
            if ($diskType -eq "Data Disk") {
                $matchedDataDisk = $vm.StorageProfile.DataDisks | Where-Object { $_.Name -eq $diskName }
                if ($matchedDataDisk) {
                    $lun = $matchedDataDisk.Lun
                }
            }

            $results.Add([PSCustomObject]@{
                VMName        = $vmName
                ResourceGroup = $rgName
                SubscriptionId = $subId
                DiskName      = $diskName
                DiskType      = $diskType
                SKU           = $sku
                DiskSizeGB    = $disk.DiskSizeGB
                LUN           = $lun
                DiskState     = $disk.DiskState
            })

            Write-Log "  [HDD] VM: $vmName | Disk: $diskName ($diskType, $($disk.DiskSizeGB) GB)"
        }
    }
}
#endregion

#region --- Export -----------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Log "No Standard HDD disks found across the scanned subscription(s)." -Level WARN
}
else {
    try {
        $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Log "Exported $($results.Count) HDD disk record(s) to: $OutputPath"
    }
    catch {
        Write-Log "Failed to write CSV to '$OutputPath': $_" -Level ERROR
        exit 1
    }
}

Write-Log "Script complete. Log file: $LogFile"
#endregion
