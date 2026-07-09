# DCR Association Audit — shows what resource types are contributing to the 431 count

$ResourceGroup = "bab-dev-wrkspace-swec-rg-01"
$DCRName       = "msvmi-bab-dev-vm-monitoring-dcr"

Write-Host "Fetching all DCR associations..." -ForegroundColor Cyan

$AllAssoc = Get-AzDataCollectionRuleAssociation `
    -DataCollectionRuleName $DCRName `
    -ResourceGroupName $ResourceGroup

Write-Host "Total associations returned: $($AllAssoc.Count)" -ForegroundColor Yellow
Write-Host ""

# Dump first object to confirm property names (remove after confirming)
Write-Host "Sample association properties:" -ForegroundColor DarkGray
$AllAssoc[0] | Select-Object Name, Id, ResourceId, DataCollectionRuleId | Format-List
Write-Host ""

# Break down by resource type using .Id (the association's full ARM path)
# Format: /subscriptions/.../providers/Microsoft.Compute/virtualMachines/{vm}/providers/Microsoft.Insights/dataCollectionRuleAssociations/{assoc}
$Breakdown = $AllAssoc | ForEach-Object {
    $armId = if ($_.Id) { $_.Id } elseif ($_.ResourceId) { $_.ResourceId } else { "" }
    $parts = $armId -split "/providers/"
    $resourceType = if ($parts.Count -gt 1) {
        $seg = $parts[1] -split "/"
        "$($seg[0])/$($seg[1])"   # e.g. Microsoft.Compute/virtualMachines
    } else { "Unknown" }
    [PSCustomObject]@{
        ResourceType = $resourceType
        ResourceName = ($armId -split "/")[-3]   # VM/Arc name sits 3 segments before the trailing assoc path
        AssocName    = $_.Name
        ArmId        = $armId
    }
}

Write-Host "=== Breakdown by Resource Type ===" -ForegroundColor Cyan
$Breakdown |
    Group-Object ResourceType |
    Sort-Object Count -Descending |
    Format-Table @{L="Resource Type"; E={$_.Name}}, Count -AutoSize

# Export full list for review
$ReportPath = "C:\Temp\DCRReports\DCR_Full_Audit.csv"
$Breakdown | Select-Object ResourceType, ResourceName, AssocName, ArmId |
    Export-Csv $ReportPath -NoTypeInformation
Write-Host "Full audit exported to: $ReportPath" -ForegroundColor Green
