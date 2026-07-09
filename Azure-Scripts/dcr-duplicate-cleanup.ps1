#----------------------------------------------------------
# DCR Duplicate Association Cleanup
# Finds VMs with more than 1 association to the same DCR
#----------------------------------------------------------

$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$ResourceGroup  = "bab-dev-wrkspace-swec-rg-01"
$DCRName        = "msvmi-bab-dev-vm-monitoring-dcr"
$ReportFolder   = "C:\Temp\DCRReports"

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

#----------------------------------------------------------
# Get all DCR associations
#----------------------------------------------------------
Write-Host "Fetching DCR associations..." -ForegroundColor Cyan
$AllAssoc = Get-AzDataCollectionRuleAssociation `
    -DataCollectionRuleName $DCRName `
    -ResourceGroupName $ResourceGroup
Write-Host "Total associations: $($AllAssoc.Count)" -ForegroundColor Yellow
Write-Host ""

#----------------------------------------------------------
# Parse VM path from each association Id
#----------------------------------------------------------
$Parsed = $AllAssoc | ForEach-Object {
    # Id format: /subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/virtualMachines/{vm}/providers/Microsoft.Insights/dataCollectionRuleAssociations/{assoc}
    $vmId = ($_.Id -split "/providers/Microsoft.Insights")[0]
    [PSCustomObject]@{
        AssocName = $_.Name
        AssocId   = $_.Id
        VMId      = $vmId.ToLower()
        VMName    = ($vmId -split "/")[-1]
    }
}

#----------------------------------------------------------
# Group by VM — find duplicates
#----------------------------------------------------------
$Grouped = $Parsed | Group-Object VMId

$Duplicates = $Grouped | Where-Object { $_.Count -gt 1 }
$Unique     = $Grouped | Where-Object { $_.Count -eq 1 }

Write-Host "Unique VMs with 1 association : $($Unique.Count)"
Write-Host "VMs with duplicate associations: $($Duplicates.Count)" -ForegroundColor Red
Write-Host "Total extra associations to remove: $($Duplicates | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum | Select-Object -ExpandProperty Sum)" -ForegroundColor Red
Write-Host ""

if ($Duplicates.Count -eq 0) {
    Write-Host "No duplicates found. DCR is clean." -ForegroundColor Green
    exit
}

#----------------------------------------------------------
# Show duplicates
#----------------------------------------------------------
Write-Host "=== Duplicate Associations ===" -ForegroundColor Yellow
foreach ($Dup in $Duplicates) {
    Write-Host ""
    Write-Host "VM: $($Dup.Group[0].VMName)  ($($Dup.Count) associations)" -ForegroundColor Yellow
    $Dup.Group | Select-Object AssocName | Format-Table -AutoSize
}

#----------------------------------------------------------
# Export duplicate report
#----------------------------------------------------------
$DupReport = foreach ($Dup in $Duplicates) {
    $keep = $true
    foreach ($item in $Dup.Group) {
        [PSCustomObject]@{
            VMName    = $item.VMName
            AssocName = $item.AssocName
            Action    = if ($keep) { "KEEP"; $keep = $false } else { "REMOVE" }
        }
    }
}

$DupReport | Export-Csv "$ReportFolder\Duplicate_Associations.csv" -NoTypeInformation
Write-Host "Report exported to: $ReportFolder\Duplicate_Associations.csv" -ForegroundColor Cyan
Write-Host ""
$DupReport | Format-Table -AutoSize

#----------------------------------------------------------
# Confirm before removing
#----------------------------------------------------------
$RemoveCount = ($DupReport | Where-Object { $_.Action -eq "REMOVE" }).Count
$Confirm = Read-Host "Type YES to remove $RemoveCount duplicate associations (keeping 1 per VM)"

if ($Confirm -ne "YES") {
    Write-Host "Aborted. No changes made." -ForegroundColor Yellow
    exit
}

#----------------------------------------------------------
# Remove extras — keep first, remove the rest
#----------------------------------------------------------
$Removed = 0
$RemoveFailed = 0

foreach ($Dup in $Duplicates) {
    $RemoveList = $Dup.Group | Select-Object -Skip 1

    foreach ($Assoc in $RemoveList) {
        try {
            Remove-AzDataCollectionRuleAssociation `
                -AssociationName $Assoc.AssocName `
                -ResourceUri $Assoc.VMId `
                -ErrorAction Stop

            Write-Host "Removed: $($Assoc.AssocName) from $($Assoc.VMName)" -ForegroundColor Green
            $Removed++
        }
        catch {
            Write-Host "Failed:  $($Assoc.AssocName) — $($_.Exception.Message)" -ForegroundColor Red
            $RemoveFailed++
        }
    }
}

Write-Host ""
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Duplicate Cleanup Complete"
Write-Host "Removed : $Removed"
Write-Host "Failed  : $RemoveFailed"
Write-Host "Remaining associations should be: $($AllAssoc.Count - $Removed)"
Write-Host "==================================" -ForegroundColor Cyan
