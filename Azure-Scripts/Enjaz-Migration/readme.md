# Azure Cross-Tenant VM Migration Script

## Features
- Migrates VMs across Azure tenants using Service Principals
- Supports both Linux (with password auth) and Windows VMs
- Handles OS + data disks
- Creates NIC in target VNet with static IP
- Resume support for failed jobs
- Per-VM logging

## Prerequisites
- PowerShell 7+
- Azure PowerShell Module (`Az`)
- Valid SPN credentials for both source and target tenants

## How to Run
```powershell
.\Migrate-VMs.ps1
```
Edit `vm-migration.csv` with your VM and tenant details.
