<#
.SYNOPSIS
    Gets unattached managed disks from Azure subscriptions with cost information and optional deletion.

.DESCRIPTION
    This script scans Azure subscriptions to find unattached managed disks,
    calculates their monthly storage costs, and optionally deletes them with confirmation.

.PARAMETER SubscriptionId
    Specific subscription ID(s) to scan. Can be single or multiple subscription IDs.

.PARAMETER SubscriptionName
    Specific subscription name(s) to scan. Supports wildcards.

.PARAMETER WhatIf
    Shows what would happen if the script runs without actually deleting disks.

.PARAMETER DeleteDisks
    Enables disk deletion mode (requires confirmation for each disk).

.PARAMETER Force
    Skips individual disk confirmations (use with caution).

.PARAMETER AllSubscriptions
    Scans all subscriptions the user has access to (default if no subscription specified).

.EXAMPLE
    .\Get-UnattachedDisks.ps1
    Scans all subscriptions and reports unattached disks.

.EXAMPLE
    .\Get-UnattachedDisks.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"
    Scans a specific subscription by ID.

.EXAMPLE
    .\Get-UnattachedDisks.ps1 -SubscriptionId "sub-id-1","sub-id-2" -DeleteDisks
    Scans multiple specific subscriptions and enables deletion mode.

.EXAMPLE
    .\Get-UnattachedDisks.ps1 -SubscriptionName "Production*" -WhatIf
    Scans subscriptions matching "Production*" in what-if mode.

.EXAMPLE
    .\Get-UnattachedDisks.ps1 -AllSubscriptions -DeleteDisks -Force
    Scans all subscriptions and deletes without individual confirmations (DANGEROUS).
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'AllSubs')]
param(
    [Parameter(ParameterSetName = 'ById', Mandatory = $false)]
    [string[]]$SubscriptionId,
    
    [Parameter(ParameterSetName = 'ByName', Mandatory = $false)]
    [string[]]$SubscriptionName,
    
    [Parameter(ParameterSetName = 'AllSubs', Mandatory = $false)]
    [switch]$AllSubscriptions,
    
    [Parameter(Mandatory = $false)]
    [switch]$DeleteDisks,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Connect to Azure (if not already connected)
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Connecting to Azure..." -ForegroundColor Cyan
        Connect-AzAccount
    }
    Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "Failed to connect to Azure. Attempting to connect..." -ForegroundColor Yellow
    Connect-AzAccount
}

# Initialize results array
$results = @()
$deletedDisks = @()
$failedDeletions = @()

# Get subscriptions based on parameters
$subscriptions = @()

if ($PSCmdlet.ParameterSetName -eq 'ById' -and $SubscriptionId) {
    Write-Host "Fetching specific subscription(s) by ID..." -ForegroundColor Cyan
    foreach ($subId in $SubscriptionId) {
        try {
            $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
            $subscriptions += $sub
        }
        catch {
            Write-Host "Warning: Could not find subscription with ID: $subId" -ForegroundColor Yellow
        }
    }
}
elseif ($PSCmdlet.ParameterSetName -eq 'ByName' -and $SubscriptionName) {
    Write-Host "Fetching subscription(s) by name..." -ForegroundColor Cyan
    $allSubs = Get-AzSubscription
    foreach ($subName in $SubscriptionName) {
        $matchedSubs = $allSubs | Where-Object { $_.Name -like $subName }
        if ($matchedSubs) {
            $subscriptions += $matchedSubs
        }
        else {
            Write-Host "Warning: No subscription found matching: $subName" -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host "Fetching all available subscriptions..." -ForegroundColor Cyan
    $subscriptions = Get-AzSubscription
}

# Remove duplicates if any
$subscriptions = $subscriptions | Sort-Object -Property Id -Unique

if ($subscriptions.Count -eq 0) {
    Write-Host "No subscriptions found to scan. Exiting." -ForegroundColor Red
    return
}

# Display subscriptions to be scanned
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "UNATTACHED MANAGED DISKS SCANNER" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Mode: $(if($WhatIfPreference){'WHAT-IF (Simulation)'}elseif($DeleteDisks){'DELETE'}else{'SCAN ONLY'})" -ForegroundColor Yellow
Write-Host "`nSubscriptions to scan ($($subscriptions.Count)):" -ForegroundColor Cyan
foreach ($sub in $subscriptions) {
    Write-Host "  - $($sub.Name) ($($sub.Id))" -ForegroundColor Gray
}

# Confirmation before proceeding
if ($DeleteDisks -and -not $WhatIfPreference) {
    Write-Host "`nWARNING: You are about to scan for unattached disks in deletion mode!" -ForegroundColor Red
    Write-Host "Do you want to continue? (Y/N): " -ForegroundColor Yellow -NoNewline
    $confirm = Read-Host
    if ($confirm -ne 'Y') {
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        return
    }
}

Write-Host ""

foreach ($subscription in $subscriptions) {
    Write-Host "`nProcessing subscription: $($subscription.Name)" -ForegroundColor Yellow
    Write-Host "  Subscription ID: $($subscription.Id)" -ForegroundColor Gray
    
    try {
        # Set context to current subscription
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
        
        # Get all managed disks
        $disks = Get-AzDisk -ErrorAction Stop
        
        Write-Host "  Total disks in subscription: $($disks.Count)" -ForegroundColor Gray
        
        $unattachedCount = 0
        
        foreach ($disk in $disks) {
            # Check if disk is unattached (ManagedBy property is null)
            if ($null -eq $disk.ManagedBy) {
                
                # Skip disks that start with "pvc-" (Kubernetes PVCs)
                if ($disk.Name -like "pvc-*") {
                    Write-Host "  [SKIPPED] Kubernetes PVC disk: $($disk.Name)" -ForegroundColor DarkGray
                    continue
                }
                
                # Check for stale upload state (ActiveUpload older than 24 hours)
                $isStaleUpload = $false
                $uploadAge = $null
                if ($disk.DiskState -eq "ActiveUpload") {
                    $uploadAge = (Get-Date) - $disk.TimeCreated
                    if ($uploadAge.TotalHours -gt 24) {
                        $isStaleUpload = $true
                        Write-Host "  [WARNING] Stale upload detected: $($disk.Name) (ActiveUpload for $([math]::Round($uploadAge.TotalDays, 1)) days)" -ForegroundColor Yellow
                    } else {
                        Write-Host "  [SKIPPED] Disk upload in progress: $($disk.Name) (State: ActiveUpload, Age: $([math]::Round($uploadAge.TotalHours, 1)) hours)" -ForegroundColor Magenta
                        continue
                    }
                }
                
                $unattachedCount++
                
                # Calculate monthly cost based on disk size and SKU
                $monthlyCost = 0
                $diskSizeGB = $disk.DiskSizeGB
                
                # Pricing estimates (approximate USD/month - adjust based on your region)
                switch ($disk.Sku.Name) {
                    "Premium_LRS" { $monthlyCost = $diskSizeGB * 0.15 }
                    "Premium_ZRS" { $monthlyCost = $diskSizeGB * 0.18 }
                    "StandardSSD_LRS" { $monthlyCost = $diskSizeGB * 0.05 }
                    "StandardSSD_ZRS" { $monthlyCost = $diskSizeGB * 0.0625 }
                    "Standard_LRS" { $monthlyCost = $diskSizeGB * 0.04 }
                    "UltraSSD_LRS" { $monthlyCost = $diskSizeGB * 0.12 }
                    default { $monthlyCost = 0 }
                }
                
                # Determine disk age and categorize
                $diskAge = (Get-Date) - $disk.TimeCreated
                $ageCategory = if ($diskAge.TotalDays -gt 180) { "Very Old (>6 months)" }
                              elseif ($diskAge.TotalDays -gt 90) { "Old (>3 months)" }
                              elseif ($diskAge.TotalDays -gt 30) { "Recent (>1 month)" }
                              else { "New (<1 month)" }
                
                # Check for migration-related tags
                $isMigrationRelated = $false
                $migrationInfo = ""
                if ($disk.Tags) {
                    $migrationTags = @('AzHydration-ManagedDisk-CreatedBy', 'AzureMigrate', 'Migration')
                    foreach ($tag in $migrationTags) {
                        if ($disk.Tags.ContainsKey($tag)) {
                            $isMigrationRelated = $true
                            $migrationInfo = "$tag=$($disk.Tags[$tag])"
                            break
                        }
                    }
                }
                
                $diskInfo = [PSCustomObject]@{
                    SubscriptionName = $subscription.Name
                    SubscriptionId   = $subscription.Id
                    ResourceGroup    = $disk.ResourceGroupName
                    DiskName         = $disk.Name
                    Location         = $disk.Location
                    DiskSize_GB      = $diskSizeGB
                    DiskSku          = $disk.Sku.Name
                    DiskState        = $disk.DiskState
                    TimeCreated      = $disk.TimeCreated
                    AgeDays          = [math]::Round($diskAge.TotalDays, 1)
                    AgeCategory      = $ageCategory
                    IsStaleUpload    = $isStaleUpload
                    IsMigrationRelated = $isMigrationRelated
                    MigrationInfo    = $migrationInfo
                    MonthlyCost_USD  = [math]::Round($monthlyCost, 2)
                    Tags             = ($disk.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "; "
                    DeletionStatus   = "N/A"
                    RiskLevel        = if ($isStaleUpload) { "HIGH - Stale Upload" }
                                      elseif ($isMigrationRelated -and $diskAge.TotalDays -gt 30) { "MEDIUM - Old Migration" }
                                      elseif ($diskAge.TotalDays -gt 90) { "MEDIUM - Long Unattached" }
                                      else { "LOW" }
                }
                
                $results += $diskInfo
                
                # Enhanced display with risk indicators
                $displayColor = if ($isStaleUpload) { "Red" } 
                               elseif ($diskAge.TotalDays -gt 90) { "Yellow" } 
                               else { "Green" }
                
                Write-Host "  [UNATTACHED] $($disk.Name)" -ForegroundColor $displayColor
                Write-Host "    Resource Group: $($disk.ResourceGroupName)" -ForegroundColor Gray
                Write-Host "    Size: $($disk.DiskSizeGB)GB | SKU: $($disk.Sku.Name) | State: $($disk.DiskState)" -ForegroundColor Gray
                Write-Host "    Age: $([math]::Round($diskAge.TotalDays, 1)) days ($ageCategory) | Cost: `$$($diskInfo.MonthlyCost_USD)/month" -ForegroundColor Gray
                
                if ($isStaleUpload) {
                    Write-Host "    ⚠️  RISK: Stale upload - may be corrupted or incomplete" -ForegroundColor Red
                }
                if ($isMigrationRelated) {
                    Write-Host "    📦 Migration disk: $migrationInfo" -ForegroundColor Cyan
                }
                
                # Handle deletion if requested
                if ($DeleteDisks -or $WhatIfPreference) {
                    $shouldDelete = $false
                    
                    if ($WhatIfPreference) {
                        Write-Host "    [WHAT-IF] Would delete disk: $($disk.Name)" -ForegroundColor Magenta
                        $diskInfo.DeletionStatus = "WHAT-IF"
                        $shouldDelete = $false
                    }
                    elseif ($Force) {
                        $shouldDelete = $true
                        Write-Host "    [FORCE MODE] Deleting disk without confirmation..." -ForegroundColor Red
                    }
                    else {
                        Write-Host "    Delete this disk? (Y/N/A=Yes to All/Q=Quit): " -ForegroundColor Yellow -NoNewline
                        $response = Read-Host
                        
                        switch ($response.ToUpper()) {
                            "Y" { $shouldDelete = $true }
                            "A" { 
                                $shouldDelete = $true
                                $Force = $true
                                Write-Host "    Switching to 'Yes to All' mode..." -ForegroundColor Yellow
                            }
                            "Q" {
                                Write-Host "    Deletion process cancelled by user." -ForegroundColor Yellow
                                $DeleteDisks = $false
                                break
                            }
                            default { 
                                $shouldDelete = $false
                                Write-Host "    Skipping disk..." -ForegroundColor Gray
                            }
                        }
                    }
                    
                    # Perform deletion
                    if ($shouldDelete) {
                        try {
                            Remove-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Force -ErrorAction Stop
                            Write-Host "    ✓ Successfully deleted" -ForegroundColor Green
                            $diskInfo.DeletionStatus = "DELETED"
                            $deletedDisks += $diskInfo
                        }
                        catch {
                            Write-Host "    ✗ Failed to delete" -ForegroundColor Red
                            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
                            $diskInfo.DeletionStatus = "FAILED: $($_.Exception.Message)"
                            $failedDeletions += $diskInfo
                        }
                    }
                    else {
                        $diskInfo.DeletionStatus = "SKIPPED"
                    }
                }
            }
        }
        
        Write-Host "  Unattached disks found in this subscription: $unattachedCount" -ForegroundColor $(if($unattachedCount -gt 0){'Yellow'}else{'Green'})
    }
    catch {
        Write-Host "  Error processing subscription: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Display summary
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Subscriptions scanned: $($subscriptions.Count)" -ForegroundColor Cyan
Write-Host "Total unattached disks found: $($results.Count)" -ForegroundColor Yellow

if ($results.Count -gt 0) {
    $totalMonthlyCost = ($results | Measure-Object -Property MonthlyCost_USD -Sum).Sum
    Write-Host "Total estimated monthly cost: `$$([math]::Round($totalMonthlyCost, 2))" -ForegroundColor Yellow
    Write-Host "Total estimated annual cost: `$$([math]::Round($totalMonthlyCost * 12, 2))" -ForegroundColor Yellow
    
    # Group by subscription
    Write-Host "`nBreakdown by subscription:" -ForegroundColor Cyan
    $groupedResults = $results | Group-Object -Property SubscriptionName
    foreach ($group in $groupedResults) {
        $subCost = ($group.Group | Measure-Object -Property MonthlyCost_USD -Sum).Sum
        Write-Host "  $($group.Name): $($group.Count) disk(s) - `$$([math]::Round($subCost, 2))/month" -ForegroundColor Gray
    }
    
    if ($DeleteDisks) {
        Write-Host "`nDeletion Summary:" -ForegroundColor Cyan
        Write-Host "  Successfully deleted: $($deletedDisks.Count)" -ForegroundColor Green
        Write-Host "  Failed deletions: $($failedDeletions.Count)" -ForegroundColor Red
        Write-Host "  Skipped: $($results.Count - $deletedDisks.Count - $failedDeletions.Count)" -ForegroundColor Yellow
        
        if ($deletedDisks.Count -gt 0) {
            $savedMonthlyCost = ($deletedDisks | Measure-Object -Property MonthlyCost_USD -Sum).Sum
            Write-Host "`n  Monthly cost savings: `$$([math]::Round($savedMonthlyCost, 2))" -ForegroundColor Green
            Write-Host "  Annual cost savings: `$$([math]::Round($savedMonthlyCost * 12, 2))" -ForegroundColor Green
        }
    }
    
    # Export results
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $exportDir = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts"
    $csvPath = Join-Path $exportDir "UnattachedDisks_$timestamp.csv"

    # Ensure export directory exists
    if (-not (Test-Path $exportDir)) {
        try {
            New-Item -Path $exportDir -ItemType Directory -Force | Out-Null
        } catch {
            Write-Host "Failed to create export directory: $exportDir" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            return
        }
    }

    try {
        $results | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "`nResults exported to: $csvPath" -ForegroundColor Green
    } catch {
        Write-Host "Failed to export results to CSV." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    # Removed Out-GridView display
    # $results | Out-GridView -Title "Unattached Managed Disks - $(if($DeleteDisks){'DELETION MODE'}elseif($WhatIfPreference){'WHAT-IF MODE'}else{'SCAN ONLY'})"
    
    if ($failedDeletions.Count -gt 0) {
        Write-Host "`nFailed deletions details:" -ForegroundColor Red
        $failedDeletions | Format-Table DiskName, ResourceGroup, SubscriptionName, DeletionStatus -AutoSize
    }
}
else {
    Write-Host "`nNo unattached disks found. Great job keeping your environment clean! 🎉" -ForegroundColor Green
}

Write-Host "`n============================================" -ForegroundColor Cyan