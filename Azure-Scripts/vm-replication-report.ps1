# Login and select subscription
 Connect-AzAccount
 Select-AzSubscription -SubscriptionId "d88f0b5b-6660-4607-8c6a-395820400912"
$query = @"
Resources
| where type == 'microsoft.compute/virtualmachines'
| project name, resourceGroup, location, properties.hardwareProfile.vmSize, properties.storageProfile.osDisk.osType
"@

# Run the query in Azure Resource Graph
$results = Search-AzGraph -Query $query

# Output results to CSV or screen
$results | Export-Csv -Path "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Azure-Scripts\AzureMigrateVMs.csv" -NoTypeInformation
Write-Host "✅ Export completed: C:\AzureMigrateVMs.csv"