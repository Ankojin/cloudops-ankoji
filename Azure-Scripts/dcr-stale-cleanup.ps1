#----------------------------------------------------------
# DCR Stale Association Cleanup
# Finds DCR associations pointing to VMs that no longer exist
#----------------------------------------------------------

$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$ResourceGroup  = "bab-dev-wrkspace-swec-rg-01"
$DCRName        = "msvmi-bab-dev-vm-monitoring-dcr"
$ReportFolder   = "C:\Temp\DCRReports"

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

#----------------------------------------------------------
# Get all 431 DCR associations
#----------------------------------------------------------
Write-Host "Fetching DCR associations..." -ForegroundColor Cyan
$AllAssoc = Get-AzDataCollectionRuleAssociation `
    -DataCollectionRuleName $DCRName `
    -ResourceGroupName $ResourceGroup
Write-Host "Total associations: $($AllAssoc.Count)" -ForegroundColor Yellow

#----------------------------------------------------------
# Get all real VMs (any state)
#----------------------------------------------------------
Write-Host "Fetching all VMs in subscription..." -ForegroundColor Cyan
$AllVMs = Get-AzVM
$VMIds  = $AllVMs | ForEach-Object { $_.Id.ToLower() }
Write-Host "Total real VMs: $($AllVMs.Count)" -ForegroundColor Yellow
Write-Host ""

#----------------------------------------------------------
# Find stale associations (VM no longer exists)
#----------------------------------------------------------
$Stale = $AllAssoc | Where-Object {
    $parts   = $_.Id -split "/providers/"
    $vmPath  = if ($parts.Count -gt 1) { "/providers/" + $parts[1] } else { "" }
    $fullId  = ($parts[0] + $vmPath).ToLower()
    $VMIds -notcontains $fullId
}

Write-Host "Stale associations (VM deleted): $($Stale.Count)" -ForegroundColor Red
Write-Host "Valid associations:              $($AllAssoc.Count - $Stale.Count)" -ForegroundColor Green
Write-Host ""

#----------------------------------------------------------
# Export stale list for review BEFORE removing
#----------------------------------------------------------
$StaleReport = $Stale | ForEach-Object {
    $parts = $_.Id -split "/providers/"
    [PSCustomObject]@{
        AssociationName = $_.Name
        AssociationId   = $_.Id
        VMPath          = if ($parts.Count -gt 1) { ($parts[0] + "/providers/" + $parts[1]) } else { "?" }
    }
}

$StaleReport | Export-Csv "$ReportFolder\Stale_Associations.csv" -NoTypeInformation
Write-Host "Stale list exported to: $ReportFolder\Stale_Associations.csv" -ForegroundColor Cyan
Write-Host ""

#----------------------------------------------------------
# Confirm before removing
#----------------------------------------------------------
if ($Stale.Count -eq 0) {
    Write-Host "Nothing to remove." -ForegroundColor Green
    exit
}

Write-Host "Preview of stale associations to remove:" -ForegroundColor Yellow
$StaleReport | Select-Object AssociationName, VMPath | Format-Table -AutoSize

$Confirm = Read-Host "Type YES to remove all $($Stale.Count) stale associations"

if ($Confirm -ne "YES") {
    Write-Host "Aborted. No changes made." -ForegroundColor Yellow
    exit
}

#----------------------------------------------------------
# Remove stale associations
#----------------------------------------------------------
$Removed = 0
$RemoveFailed = 0

foreach ($Assoc in $Stale) {
    $parts      = $Assoc.Id -split "/providers/Microsoft.Insights"
    $ResourceUri = $parts[0]

    try {
        Remove-AzDataCollectionRuleAssociation `
            -AssociationName $Assoc.Name `
            -ResourceUri $ResourceUri `
            -Force `
            -ErrorAction Stop

        Write-Host "Removed: $($Assoc.Name)" -ForegroundColor Green
        $Removed++
    }
    catch {
        Write-Host "Failed:  $($Assoc.Name) — $($_.Exception.Message)" -ForegroundColor Red
        $RemoveFailed++
    }
}

Write-Host ""
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Stale Cleanup Complete"
Write-Host "Removed : $Removed"
Write-Host "Failed  : $RemoveFailed"
Write-Host "==================================" -ForegroundColor Cyan
