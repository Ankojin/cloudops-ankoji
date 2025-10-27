#####
<#
.SYNOPSIS
    Removes all Azure managed disk snapshots in one or more subscriptions or resource groups, with cost estimation and WhatIf support.

.PARAMETER SubscriptionIds
    One or more Azure subscription IDs to operate on (comma-separated or array).

.PARAMETER WhatIf
    If specified, shows what would be deleted and cost savings, but does not delete anything.

.PARAMETER ResourceGroupName
    (Optional) The resource group to filter snapshots.

.PARAMETER SnapshotCostPerGBMonth
    (Optional) Estimated cost per GB per month for snapshots. Default: $0.05.
.PARAMETER CsvPath
    (Optional) Path to export snapshot details as CSV. Default: .\Snapshots_<SubscriptionId>.csv

.EXAMPLE
    .\Remove-AllSnapshots.ps1 -SubscriptionId "sub1", "sub2"-WhatIf

.EXAMPLE
    .\Remove-AllSnapshots.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "your-resource-group"

.EXAMPLE
    .\Remove-AllSnapshots.ps1 -SubscriptionId "your-subscription-id" -CsvPath "C:\temp\snapshots.csv"
#>
#####
param(
    [Parameter(Mandatory=$true)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$false)]
    [decimal]$SnapshotCostPerGBMonth = 0.05
)

$ErrorActionPreference = "Stop"
$overallSummary = @()

foreach ($SubscriptionId in $SubscriptionIds) {
    Write-Host "`n==============================" -ForegroundColor Cyan
    Write-Host "Processing Subscription: $SubscriptionId" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan

    # Set Azure context
    $setContextResult = az account set --subscription "$SubscriptionId" --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to set Azure context: $setContextResult" -ForegroundColor Red
        $overallSummary += [PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            Snapshots      = 0
            TotalSizeGB    = 0
            MonthlyCost    = 0
            Deleted        = 0
            Failed         = 0
            Status         = "Failed to set context"
        }
        continue
    }

    # Build query command
    $queryCommand = "az snapshot list --query ""[].{Name:name, ResourceGroup:resourceGroup, DiskSizeGB:diskSizeGb, DiskSizeBytes:diskSizeBytes, TimeCreated:timeCreated, Location:location, Sku:sku.name}"" -o json"
    if ($ResourceGroupName) {
        $queryCommand = "az snapshot list --resource-group ""$ResourceGroupName"" --query ""[].{Name:name, ResourceGroup:resourceGroup, DiskSizeGB:diskSizeGb, DiskSizeBytes:diskSizeBytes, TimeCreated:timeCreated, Location:location, Sku:sku.name}"" -o json"
    }

    # Get all snapshots
    $snapshotsJson = Invoke-Expression $queryCommand
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to retrieve snapshots" -ForegroundColor Red
        $overallSummary += [PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            Snapshots      = 0
            TotalSizeGB    = 0
            MonthlyCost    = 0
            Deleted        = 0
            Failed         = 0
            Status         = "Failed to retrieve snapshots"
        }
        continue
    }

    $snapshots = $snapshotsJson | ConvertFrom-Json
    if ($snapshots.Count -eq 0) {
        Write-Host "No snapshots found in this subscription." -ForegroundColor Yellow
        $overallSummary += [PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            Snapshots      = 0
            TotalSizeGB    = 0
            MonthlyCost    = 0
            Deleted        = 0
            Failed         = 0
            Status         = "No snapshots"
        }
        continue
    }

    # Export snapshot details to CSV (including creation date)
    $csvPath = ".\Snapshots_${SubscriptionId}_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    try {
        $snapshots | Select-Object Name, ResourceGroup, DiskSizeGB, Sku, Location, @{Name="CreationDate";Expression={$_."TimeCreated"}} |
            Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Snapshot details exported to: $csvPath" -ForegroundColor Cyan
    } catch {
        Write-Host "Failed to export snapshot details to CSV: $_" -ForegroundColor Red
    }

    # Show snapshots with creation date in console
    Write-Host "`nFound $($snapshots.Count) snapshot(s):" -ForegroundColor Green
    $snapshots | Select-Object Name, ResourceGroup, DiskSizeGB, Sku, Location, @{Name="CreationDate";Expression={$_."TimeCreated"}} | Format-Table -AutoSize

    # Calculate total size and cost
    $totalSizeGB = 0
    foreach ($snapshot in $snapshots) {
        $sizeGB = 0
        if ($snapshot.DiskSizeBytes -and $snapshot.DiskSizeBytes -gt 0) {
            $sizeGB = [math]::Ceiling($snapshot.DiskSizeBytes / 1GB)
        } elseif ($snapshot.DiskSizeGB -and $snapshot.DiskSizeGB -gt 0) {
            $sizeGB = $snapshot.DiskSizeGB
        }
        $totalSizeGB += $sizeGB
    }
    $monthlyCost = $totalSizeGB * $SnapshotCostPerGBMonth

    Write-Host "Found $($snapshots.Count) snapshot(s), $totalSizeGB GB, est. monthly cost: `$$([math]::Round($monthlyCost,2))" -ForegroundColor Green

    if ($WhatIf) {
        Write-Host "[WhatIf] Would delete $($snapshots.Count) snapshot(s) in $SubscriptionId, saving about `$$([math]::Round($monthlyCost,2))/month" -ForegroundColor Magenta
        $overallSummary += [PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            Snapshots      = $snapshots.Count
            TotalSizeGB    = $totalSizeGB
            MonthlyCost    = [math]::Round($monthlyCost,2)
            Deleted        = 0
            Failed         = 0
            Status         = "WhatIf"
        }
        continue
    }

    Write-Host "⚠️  WARNING: This will permanently delete all $($snapshots.Count) snapshot(s) in $SubscriptionId!" -ForegroundColor Red
    $confirmation = Read-Host "Type 'DELETE' to confirm deletion for $SubscriptionId"
    if ($confirmation -ne "DELETE") {
        Write-Host "Operation cancelled for $SubscriptionId." -ForegroundColor Yellow
        $overallSummary += [PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            Snapshots      = $snapshots.Count
            TotalSizeGB    = $totalSizeGB
            MonthlyCost    = [math]::Round($monthlyCost,2)
            Deleted        = 0
            Failed         = 0
            Status         = "Cancelled"
        }
        continue
    }

    # Delete snapshots
    $successCount = 0
    $failCount = 0
    foreach ($snapshot in $snapshots) {
        try {
            $deleteResult = az snapshot delete `
                --name "$($snapshot.Name)" `
                --resource-group "$($snapshot.ResourceGroup)" `
                --only-show-errors 2>&1
            if ($LASTEXITCODE -eq 0) {
                $successCount++
            } else {
                $failCount++
            }
        } catch {
            $failCount++
        }
    }

    $overallSummary += [PSCustomObject]@{
        SubscriptionId = $SubscriptionId
        Snapshots      = $snapshots.Count
        TotalSizeGB    = $totalSizeGB
        MonthlyCost    = [math]::Round($monthlyCost,2)
        Deleted        = $successCount
        Failed         = $failCount
        Status         = "Completed"
    }
}

# Print summary
Write-Host "`n======================" -ForegroundColor Cyan
Write-Host "Summary by Subscription" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
$overallSummary | Format-Table SubscriptionId, Snapshots, TotalSizeGB, MonthlyCost, Deleted, Failed, Status -AutoSize

# Export overall summary to CSV
$summaryCsvPath = ".\Snapshots_Summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
try {
    $overallSummary | Export-Csv -Path $summaryCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Overall summary exported to: $summaryCsvPath" -ForegroundColor Cyan
} catch {
    Write-Host "Failed to export summary to CSV: $_" -ForegroundColor Red
}