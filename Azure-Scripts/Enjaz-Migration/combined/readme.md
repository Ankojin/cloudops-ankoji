# Azure VM Migration Automation

This repository contains a PowerShell script to automate the migration of on-premises or cross-subscription Azure VMs to Azure using parallelized snapshot, copy, and VM creation phases. The script is optimized for large-scale migrations (50+ VMs) and supports both Service Principal and Managed Identity authentication.

---

## Features

- **Parallel snapshot and SAS generation** for source disks.
- **Parallel AzCopy** of VHDs to target storage accounts.
- **Parallel managed disk and VM creation** in the target subscription/resource group.
- **Throttling** to avoid Azure API limits.
- **Idempotent**: Skips resources that already exist.
- **Custom logging** and error handling.
- **CSV-driven**: All VM and migration parameters are managed via a CSV file.

---

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+
- Az PowerShell modules:
  - `Az.Accounts`
  - `Az.Compute`
  - `Az.Storage`
  - `Az.Network`
  - `Az.Resources`
- [AzCopy](https://docs.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10) installed and available in your system PATH.
- Contributor/Owner permissions on both source and target Azure subscriptions.
- A properly formatted CSV file (see below).

---

## CSV File Format

The migration script expects a CSV file with the following columns (example):

| VMName         | SourceResourceGroup | SourceSubscriptionId | SourceTenantId | SourceClientId | SourceClientSecret | TargetResourceGroup | TargetSubscriptionId | TargetTenantId | TargetClientId | TargetClientSecret | TargetLocation | TargetVnetName | TargetSubnetName | TargetStorageAccount | TargetContainer | TargetPrivateIP | OSType | VMSize           | LicenseType      | SasTokenDurationSeconds |
|----------------|--------------------|---------------------|----------------|---------------|-------------------|---------------------|---------------------|----------------|---------------|-------------------|----------------|----------------|------------------|---------------------|-----------------|-----------------|--------|------------------|------------------|------------------------|
| ENJAVDPHEA-10  | mySrcRG            | ...                 | ...            | ...           | ...               | myTargetRG          | ...                 | ...            | ...           | ...               | westeurope     | myVnet         | mySubnet         | mystorageaccount    | migration       | 10.0.0.10       | Windows| Standard_DS2_v2  | Windows_Server   | 86400                  |

- **LicenseType**: `Windows_Server` or `Windows_Client`
- **OSType**: `Windows` or `Linux`
- **SasTokenDurationSeconds**: Duration for snapshot SAS tokens (e.g., `86400` for 24 hours)

---

## Usage

1. **Clone the repository** and open in VS Code or your preferred editor.

2. **Prepare your CSV file** as described above.

3. **Run the script**:

   ```powershell
   .\vm-migration-combined.ps1 -CsvPath "C:\path\to\your.csv" -LogPath "C:\path\to\migration.log"
   ```

   - To use Managed Identity, add `-UseManagedIdentity`.

4. **Monitor progress** in the log file and the output CSV.

---

## How It Works

1. **Snapshot Phase**:  
   Creates snapshots of source OS/data disks and generates SAS URIs in parallel.

2. **AzCopy Phase**:  
   Copies VHDs from snapshots to the target storage account using AzCopy, in parallel.

3. **VM Creation Phase**:  
   Imports VHDs as managed disks and creates VMs in the target resource group, in parallel.

4. **CSV Updates**:  
   The script updates the CSV after each phase with status and error details.

---

## Customization

- **Throttle Limit**:  
  Adjust the `ThrottleLimit` parameter in the script or function calls to control parallelism.

- **Logging**:  
  Logs are written to the path specified by `-LogPath`.

- **Error Handling**:  
  Errors are logged and written to the CSV for each VM.

---

## Troubleshooting

- Ensure all required Az modules are installed and imported.
- Make sure AzCopy is installed and available in your system PATH.
- Check the log file for detailed error messages.
- Ensure your Azure account/service principal has sufficient permissions.

---

## License

MIT License

---

## Support

For issues or feature requests, please open an issue in this repository.