# Deploy-LogicApp_start_single_csv.ps1

## Overview
This PowerShell script automates the deployment of Azure Logic Apps for VM start operations. It supports both single deployments and bulk deployments from a CSV file, enabling flexible scheduling and resource management for Azure VMs.

## Features
- **Single Mode**: Deploy a Logic App for a specific VM or set of VMs with custom scheduling.
- **CSV Mode**: Bulk deploy Logic Apps using a CSV file containing deployment details for multiple VMs.
- **Custom Scheduling**: Specify start hour, minute, and days of the week for VM operations.
- **Logging**: All operations are logged to a timestamped log file for auditing and troubleshooting.

## Parameters
| Name                | Type    | Description                                                                                 |
|---------------------|---------|---------------------------------------------------------------------------------------------|
| SubscriptionId      | string  | Azure subscription ID for Logic App deployment                                               |
| LogicAppResourceGroup | string | Resource group where Logic Apps will be deployed                                             |
| DeploymentMode      | string  | 'Single' or 'CSV' (default: 'Single')                                                        |
| VMSubscriptionId    | string  | Subscription ID for target VMs                                                               |
| WeekDays            | string  | Days to run (comma-separated, e.g., Sunday,Monday,Tuesday)                                   |
| CsvFilePath         | string  | Path to CSV file for bulk deployment (CSV mode only)                                         |
| LogicAppName        | string  | Name of the Logic App (Single mode only)                                                     |
| DefinitionFile      | string  | Path to Logic App definition JSON file                                                       |
| VMResourceGroup     | string  | Resource group of target VMs                                                                 |
| VMNames             | string  | Comma-separated list of VM names                                                             |
| StartHour           | int     | Hour to start VMs (default: 7)                                                               |
| StartMinute         | int     | Minute to start VMs (default: 0)                                                             |
| LogPath             | string  | Path to log file (default: timestamped log in current directory)                             |

## Usage
### Single Mode
Deploy a Logic App for a specific VM or set of VMs:
```powershell
./Deploy-LogicApp_start_single_csv.ps1 -SubscriptionId <sub-id> -LogicAppResourceGroup <rg> -DeploymentMode 'Single' -VMSubscriptionId <vm-sub-id> -LogicAppName <name> -DefinitionFile <json> -VMResourceGroup <vm-rg> -VMNames "VM1,VM2" -StartHour 8 -StartMinute 0 -WeekDays "Monday,Tuesday"
```

### CSV Mode
Bulk deploy Logic Apps using a CSV file:
```powershell
./Deploy-LogicApp_start_single_csv.ps1 -SubscriptionId <sub-id> -LogicAppResourceGroup <rg> -DeploymentMode 'CSV' -VMSubscriptionId <vm-sub-id> -CsvFilePath <path-to-csv>
```

#### CSV File Format
The CSV file should contain the following columns:
- LogicAppType
- LogicAppName
- ResourceGroup
- VmNames
- StartHour
- StartMinute
- WeekDays
- DefinitionFile

Example:
```
LogicAppType,LogicAppName,ResourceGroup,VmNames,StartHour,StartMinute,WeekDays,DefinitionFile
Application,bab_bo_dev,BAB-DEV-BO-SWEC-RG-01,"DABORAPXXDWV1DASAPAPBODWV1,DASAPAPDMDWV1,DASAPWBBODWV1",8,0,"Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday",.\logicapp_start.json
```

## Logging
All actions and errors are logged to the file specified by `-LogPath`. The default log file is created in the current directory with a timestamp.

## Security & Best Practices
- **Do not hardcode secrets**. Use environment variables or Azure Key Vault for sensitive information.
- **Validate CSV files** before running bulk operations to avoid deployment errors.
- **Test with a single VM** before running bulk deployments.

## Future Enhancements
- Add stop functionality for VMs.
- Improve error handling for Azure CLI operations.

## Author
CloudOps Team
