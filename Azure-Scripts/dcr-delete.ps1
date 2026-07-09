$dcr = Get-AzDataCollectionRule `
    -ResourceGroupName "bab-dev-wrkspace-swec-rg-01" `
    -Name "msvmi-bab-dev-vm-monitoring-dcr"

Get-AzVM | ForEach-Object {
    $associations = Get-AzDataCollectionRuleAssociation `
        -TargetResourceId $_.Id `
        -ErrorAction SilentlyContinue

    foreach ($association in $associations) {
        if ($association.DataCollectionRuleId -eq $dcr.Id) {
            Write-Host "Removing DCR from $($_.Name)"

            Remove-AzDataCollectionRuleAssociation `
                -AssociationName $association.Name `
                -TargetResourceId $_.Id
        }
    }
}