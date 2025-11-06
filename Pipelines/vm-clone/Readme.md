# VM Clone Pipeline

This repository contains an Azure DevOps pipeline for **cloning virtual machines (VMs) across subscriptions and resource groups** using the Azure CLI and PowerShell.

## Overview

The pipeline reads a CSV file from Agent server (10.189.61.20) (`C:\vm-to-clone\vm-to-clone.csv`) describing the VMs to clone, then:
- Detects the OS type of each source VM automatically.
- Creates snapshots of the source OS and data disks.
- Creates new disks from those snapshots in the target resource group.
- Creates a new NIC and VM in the target resource group.
- Attaches all data disks to the new VM (with correct LUNs).
- Deletes all snapshots after successful VM and disk creation.
- Starts the new VM.

## Prerequisites

- Azure DevOps agent with PowerShell 7 and Azure CLI installed.
- Service principal credentials stored as pipeline variables:
  - `AZURE_CLIENT_ID`
  - `AZURE_CLIENT_SECRET`
  - `AZURE_TENANT_ID`
- Resource group and network resources (VNet, NSG, etc.) must exist in the target environment.
- The CSV file `C:\vm-to-clone\vm-to-clone.csv` must be present on the agent.

## CSV Format

The CSV should have the following columns:

```
SourceVMName,NewVMName,StaticIp,SubnetName,VMSize
```

Example:
```
SourceVMName,NewVMName,SubnetName,VMSize
mySourceVM,clonedVM01,default,Standard_D2s_v3
```

## Pipeline Parameters

- **subscriptionName**: Source subscription (`BAB_DEV`, `BAB_SIT`, `BAB_CORE`)
- **targetSubscriptionName**: Target subscription (`BAB_DEV`, `BAB_SIT`, `BAB_CORE`)
- **resourceGroupName**: Source resource group name
- **targetResourceGroupName**: Target resource group name

## How It Works

1. **Login**: Authenticates to Azure using the service principal.
2. **Read CSV**: Loads VM definitions from the CSV file.
3. **For each VM**:
   - Detects OS type.
   - Creates snapshots of OS and data disks.
   - Creates new disks from snapshots.
   - Creates a new NIC in the target VNet/subnet.
   - Creates the new VM and attaches the OS disk.
   - If there are data disks, deallocates the VM, attaches data disks, and restarts the VM.
   - Deletes all snapshots after successful creation.
4. **Error Handling**: If any step fails for a VM, logs the error and continues to the next VM. The pipeline fails if any errors occurred.

## Logs

- Logs are written to `C:\log\clone_log.txt` on the agent.

## Notes

- The pipeline **automatically detects the OS type** for each VM.
- Snapshots are always deleted after successful VM and disk creation.
- No dry-run mode: all actions are executed for real.
- The pipeline stops if any error occurs during the cloning process.

## Customization

- Update the network and storage variable groups as needed for your environment.
- Adjust the CSV path or format if your use case requires it.

---

**For questions or issues, please contact the CloudOps team.**