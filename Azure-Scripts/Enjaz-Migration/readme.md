| Column                               | Description                                                       |
| ------------------------------------ | ----------------------------------------------------------------- |
| `VMName`                             | Name of the source VM (used to find the VM and extract disk info) |
| `SourceResourceGroup`                | RG where the VM currently exists                                  |
| `SourceSubscriptionId`               | Subscription where the VM currently exists                        |
| `TargetResourceGroup`                | RG to create managed disks, NIC, and VM                           |
| `TargetSubscriptionId`               | Subscription to create resources                                  |
| `TargetVnetName`, `TargetSubnetName` | Required to create NIC in target                                  |
| `TargetPrivateIP`                    | Optional static IP for NIC                                        |
| `VhdOsUri`                           | Populated by script after SAS URL is generated                    |
| `VhdDataUris`                        | Populated with SAS URLs of copied data disks                      |
| `MigrationStatus`                    | `Pending`, `Success`, `Failed`, etc.                              |
| `ErrorDetails`                       | Any error captured during migration                               |



# Run with service principal
.\vm-migration-phase2.ps1 -UseManagedIdentity $false `
  -TargetTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -TargetClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -TargetClientSecret "your-client-secret" `
  -TargetSubscriptionId "your-subscription-id" `
  -CsvPath ".\vm-migration-map.csv"

# OR run with managed identity
.\vm-migration-phase2.ps1 -UseManagedIdentity $true `
  -TargetSubscriptionId "your-subscription-id" `
  -CsvPath ".\vm-migration-map.csv"
